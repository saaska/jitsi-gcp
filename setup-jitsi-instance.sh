#!/bin/bash
if grep -q "SETUP: Done" "/var/log/setup-jitsi.log"; then
  echo "SETUP already done. Terminating script."
  exit 0
fi

{
SRCDIR=$(pwd)  
echo SETUP: Working in $SRCDIR as $(whoami)

JITSI_DIR=/usr/share/jitsi
JITSI_USER=jitsi
JITSI_GROUP=jitsi

export DEBIAN_FRONTEND=noninteractive

# get metadata
META_URL=http://metadata.google.internal/computeMetadata/v1
META_HEADER="Metadata-Flavor: Google"
PROJECT_ID=$(curl -s "$META_URL/project/project-id" -H "$META_HEADER")
DOMAIN=$(curl -s "$META_URL/instance/attributes/domain" -H "$META_HEADER")
HOSTNAME=$(curl -s "$META_URL/instance/attributes/hostname" -H "$META_HEADER")
ZONE=$(curl -s "$META_URL/instance/attributes/zone" -H "$META_HEADER")
KEY_SECRET_NAME=$(curl -s "$META_URL/instance/attributes/keysecret" -H "$META_HEADER")
FULLCHAIN_SECRET_NAME=$(curl -s "$META_URL/instance/attributes/fullchainsecret" -H "$META_HEADER")
LE_EMAIL=$(curl -s "$META_URL/instance/attributes/letsencrypt_email" -H "$META_HEADER")

echo SETUP: Adding user and group...
groupadd -r $JITSI_GROUP && useradd -r -s /bin/false -g $JITSI_GROUP $JITSI_USER

echo SETUP: Updating all apt packages...
apt-get -qq update
echo SETUP: Updated apt packages

# Install pip3 for python dependencies
echo SETUP: Installing pip...
apt-get -y -qq install python3-pip

# Install DNS resolver and GCP Cloud DNS libraries
echo SETUP: Installing Google Cloud DNS package for Python...
pip3 install google-cloud-dns requests
echo SETUP: Installed Google Cloud DNS package for Python

echo SETUP: Running DNS Update Script...
python3 ./gcp-renew-dns.py >> /var/log/renewdns.log
echo SETUP: Ran DNS Update Script

# Configure cron to run the DNS update script at startup
cp ./gcp-renew-dns.py /usr/local/bin
if ! grep -e '@reboot         root    sleep 10; date >> /var/log/renewdns.log; /usr/bin/python3 /usr/local/bin/gcp-renew-dns.py >> /var/log/renewdns.log &' /etc/crontab; then
    echo '@reboot         root    sleep 10; date >> /var/log/renewdns.log; /usr/bin/python3 /usr/local/bin/gcp-renew-dns.py >> /var/log/renewdns.log &'>> /etc/crontab
fi
echo SETUP: Cron DNS update setup step complete

mkdir $JITSI_DIR

install_ops_agent() {
    # Install Google Cloud Ops Agent for monitoring
    echo SETUP: Installing Google Cloud Ops Agent...
    curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
    bash add-google-cloud-ops-agent-repo.sh --also-install
    echo SETUP: Installed Google Cloud Ops Agent
}

install_ssl_keys() {
    # Get the SSL keys
    echo SETUP: Retrieving SSL certificates from GCP project secrets...
    apt-get -y -qq install jq  # install JSON processor for the keys obtained from secrets
    TOKEN=$(gcloud auth print-access-token)
    curl -s https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$KEY_SECRET_NAME/versions/latest:access  \
      --request "GET" --header "authorization: Bearer $TOKEN" --header "content-type: application/json" --silent \
      | jq -r ".payload.data" | base64 --decode | sudo tee /etc/ssl/$HOSTNAME.$DOMAIN.privkey.pem > /dev/null
    curl -s https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$FULLCHAIN_SECRET_NAME/versions/latest:access  \
      --request "GET" --header "authorization: Bearer $TOKEN" --header "content-type: application/json" --silent \
      | jq -r ".payload.data" | base64 --decode | sudo tee /etc/ssl/$HOSTNAME.$DOMAIN.fullchain.pem > /dev/null
    chmod 400 /etc/ssl/$HOSTNAME.$DOMAIN.privkey.pem /etc/ssl/$HOSTNAME.$DOMAIN.fullchain.pem
    echo SETUP: Retrieved SSL certificates from secrets
}

generate_le_ssl_keys() {
    echo SETUP: Asking for SSL certificates from Let\'s Encrypt...
    # Installs nginx to demonstrate webserver control for Let s Encrypt certs
    apt-get -y -qq install nginx

    # Installs Let s Encrypt certbot and uses it to generates SSL keys
    apt-get -y -qq install snapd
    snap install core
    snap install --classic certbot
    ln -s /snap/bin/certbot /usr/bin/certbot
    certbot -d demo.saaska.me --nginx --email $LE_EMAIL --agree-tos -n
    systemctl restart nginx
    echo SETUP: Got SSL certificates from Let\'s Encrypt
}

install_jitsi_debian() {
    echo SETUP: Installing Prosody and Jitsi...
    apt-get -y -qq install extrepo
    extrepo enable prosody && extrepo enable jitsi-stable
    apt-get -qq update  
    apt-get -y -qq install apt-transport-https nginx-full prosody openjdk-11-jre debconf-utils
    hostnamectl set-hostname $HOSTNAME.$DOMAIN
    printf "DefaultTasksMax=65535\nDefaultLimitNPROC=65000\n" >> /etc/systemd/system.conf
    systemctl daemon-reload
    # provide answers for non-interactive install of Jitsi Meet
    echo "jitsi-videobridge jitsi-videobridge/jvb-hostname string $HOSTNAME.$DOMAIN" | debconf-set-selections
    echo "jitsi-meet jitsi-meet/jaas-choice boolean false" | debconf-set-selections
        echo "jitsi-meet jitsi-meet/cert-choice select I want to use my own certificate" | debconf-set-selections
    if [ -n "$LE_EMAIL" ]; then
      KEYPATH=/etc/letsencrypt/live/$HOSTNAME.$DOMAIN/privkey.pem # have email - means get from LetsEncrypt
      CERTPATH=/etc/letsencrypt/live/$HOSTNAME.$DOMAIN/fullchain.pem
    else
      KEYPATH=/etc/ssl/$HOSTNAME.$DOMAIN.privkey.pem # no email means get key and cert chain from secrets``
      CERTPATH=/etc/ssl/$HOSTNAME.$DOMAIN.fullchain.pem
    fi  
    echo "jitsi-meet jitsi-meet/cert-path-key string $KEYPATH" | debconf-set-selections
    echo "jitsi-meet jitsi-meet/cert-path-crt string $CERTPATH" | debconf-set-selections

    # jitsi-meet installation
    apt-get -y -qq install jitsi-meet
    rm /etc/nginx/sites-enabled/default
    systemctl restart jicofo jitsi-videobridge2 prosody nginx

    echo SETUP: Installed Prosody and Jitsi
}

install_jitsi_docker() {
    # Get Docker and docker-compose
    # get Docker signing keys
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo SETUP: Added Docker signing keys 
    # add Docker package repository
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
    echo SETUP: Added Docker package repository 
    # update packages
    apt-get -qq update
    echo SETUP: Updated Docker package info
    # install docker packages
    apt-get -y -qq install docker-ce docker-ce-cli containerd.io docker-compose
    echo SETUP: Installed Docker packages

    # Add jitsi user to docker group
    usermod -aG docker $JITSI_USER

    # Get jitsi-docker from GitHub Releases
    LATEST_JITSI_DOCKER=$(curl -s https://api.github.com/repos/jitsi/docker-jitsi-meet/tags | grep "tarball_url" | grep -Eo 'https://[^\"]*'| head -1)
    echo SETUP: Downloading $LATEST_JITSI_DOCKER
    chown $JITSI_GROUP:$JITSI_USER $JITSI_DIR
    curl -sL $LATEST_JITSI_DOCKER | runuser -u jitsi tar xzC $JITSI_DIR
    echo SETUP: Downloaded latest docker-jitsi-meet release
    mv $JITSI_DIR/jitsi-docker-* $JITSI_DIR/docker-jitsi-meet

    # Set up Jitsi Docker
    cd $JITSI_DIR/docker-jitsi-meet
    # set correct domain name, ports, and config dir
    sed -e 's/HTTP_PORT=8000/HTTP_PORT=80\nENABLE_HTTP_REDIRECT=1/' \
        -e 's/HTTPS_PORT=8443/HTTPS_PORT=443/' \
        -e "s%#PUBLIC_URL=https://meet.example.com%PUBLIC_URL=https://$HOSTNAME.$DOMAIN%" \
        -e "s%^CONFIG=[^\n]+%CONFIG=$JITSI_DIR/config%" env.example > .env
    # generate passwords
    ./gen-passwords.sh
    # Add cert path mapping
    sed -i -e "1,/prosody:/ s%volumes:%volumes:\n            - /etc/ssl/$HOSTNAME.$DOMAIN.fullchain.pem:/config/keys/cert.crt\n            - /etc/ssl/$HOSTNAME.$DOMAIN.privkey.pem:/config/keys/cert.key%" docker-compose.yml
    echo SETUP: Configured Jitsi
    # make dirs for config files
    mkdir -p $JITSI_DIR/config/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
    chown -R $JITSI_GROUP:$JITSI_USER $JITSI_DIR/config

    # start Jitsi
    echo SETUP: Launching Jitsi
    docker-compose up -d
}

configure_websockets() {
    # add websockets to Prosody config
    sed -i -e "/^VirtualHost \"$HOSTNAME.$DOMAIN\"/i consider_websocket_secure = true" \
           -e "/^VirtualHost \"$HOSTNAME.$DOMAIN\"/,/^Component/ {
                  /    modules_enabled = {/a \        \"websocket\"\;\n        \"smacks\"\;" \
              -e '/main_muc = /a\    cross_domain_websocket = true' \
           -e '}' prosody/conf.avail/$HOSTNAME.$DOMAIN.cfg.lua

    # add websockets to nginx config
    sed -i "/ location = \/xmpp-websocket {/a\        add_header 'x-jitsi-shard' 'shard1';\n        add_header 'x-jitsi-region' 'europe';\n        add_header 'Access-Control-Expose-Headers' 'X-Jitsi-Shard, X-Jitsi-Region';" nginx/sites-available/$HOSTNAME.$DOMAIN.conf

    # add websockets url to the Jitsi JS
    sed -i "s#// websocket: 'wss://#websocket: 'wss://#" jitsi/meet/$HOSTNAME.$DOMAIN-config.js

    # restart the servers
    systemctl restart jicofo jitsi-videobridge2 prosody nginx
}

configure_addons() {
  # create a git repo with Jitsi settings in /etc
  cd /etc
  cp $SRCDIR/etc-gitignore /etc/.gitignore
  git init
  git config user.name 'ubuntu'
  git config user.email '26275111+saaska@users.noreply.github.com'
  git add .
  git commit -m init

  # add history completion
  cp $SRCDIR/home-inputrc /root/.inputrc  
  cp $SRCDIR/home-inputrc /etc/skel/.inputrc  
}

install_ops_agent
if [ -n "$LE_EMAIL" ]; then
  generate_le_ssl_keys # have email - means get from LetsEncrypt
else
  install_ssl_keys # no email means get key and cert chain from secrets``
fi  
install_jitsi_debian
configure_addons
configure_websockets

date && echo SETUP: Done.
} >> /var/log/setup-jitsi.log 2>&1
