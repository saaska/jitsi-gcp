#!/bin/bash
echo SETUP: Working in $PWD as $(whois)

echo SETUP: Updating all apt packages...
sudo apt-get update 
echo SETUP: Updated apt packages

echo SETUP: Installing pip
sudo apt-get -y -q -q install python3-pip 			
# Install pip3 for python dependencies
echo SETUP: Installed pip
echo SETUP: Installing Cloud DNS client package
pip3 install google-cloud-dns  		
# Install DNS resolver and GCP Cloud DNS libraries
echo SETUP: Installed Google Cloud DNS package for Python
echo SETUP: Running DNS Update Script...
python3 ./gcp-renew-dns.py		
echo SETUP: Ran DNS Update Script
# Configure cron to run the script at startup
if grep -e "@reboot python3 /usr/local/bin/gcp-renew-dns" /etc/crontab; then
    echo '@reboot python3 /usr/local/bin/gcp-renew-dns.py &'>> /etc/crontab 
fi
echo SETUP: Cron DNS update setup step complete

# Get Docker and docker-compose
# get docker signing keys
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Added Docker signing keys 
# add docker package repository
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
echo SETUP: Added Docker package repository 
# update packages
sudo apt-get update>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Updated Docker package info
# install docker packages
sudo apt-get -y -q install docker-ce docker-ce-cli containerd.io docker-compose>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Installed Docker packages

# Install Google Cloud Ops Agent for monitoring
curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
echo SETUP: Installed Google Cloud Ops Agent
sudo bash add-google-cloud-ops-agent-repo.sh --also-install

# Add jitsi user 
JITSI_USER=jitsi
JITSI_GROUP=jitsi
sudo groupadd -r $JITSI_GROUP && sudo useradd -r -s /bin/false -g $JITSI_GROUP $JITSI_USER
sudo usermod -aG docker $JITSI_USER

JITSI_DIR=/usr/share/jitsi

# Get jitsi-docker from GitHub Releases
LATEST_JITSI_DOCKER=$(curl -s https://api.github.com/repos/jitsi/docker-jitsi-meet/tags | grep "tarball_url" | grep -Eo 'https://[^\"]*'| head -1)
echo SETUP: Downloading $LATEST_JITSI_DOCKER
mkdir $JITSI_DIR
chown $JITSI_GROUP:$JITSI_USER $JITSI_DIR
curl -sL $LATEST_JITSI_DOCKER | runuser -u jitsi tar xzC $JITSI_DIR
echo SETUP: Downloaded latest docker-jitsi-meet release
mv $JITSI_DIR/jitsi-docker-* $JITSI_DIR/docker-jitsi-meet

# Get Let's encrypt SSL keys
sudo apt-get -y -q install jq  # install JSON processor for the keys obtained from secrets
mkdir $JITSI_DIR/certs
chmod 700 $JITSI_DIR/certs
META_URL=http://metadata.google.internal/computeMetadata/v1
META_HEADER="Metadata-Flavor: Google"
TOKEN=$(gcloud auth print-access-token)
PROJECT_ID=$(curl -s "$META_URL/project/project-id" -H "$META_HEADER")
KEY_SECRET_NAME=$(curl -s "$META_URL/instance/attributes/keysecret" -H "$META_HEADER")
FULLCHAIN_SECRET_NAME=$(curl -s "$META_URL/instance/attributes/fullchainsecret" -H "$META_HEADER")
curl -s https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$KEY_SECRET_NAME/versions/latest:access  \
   --request "GET" --header "authorization: Bearer $TOKEN" --header "content-type: application/json" --silent \
   | jq -r ".payload.data" | base64 --decode | tee $JITSI_DIR/certs/key.pem > /dev/null
curl -s https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$FULLCHAIN_SECRET_NAME/versions/latest:access  \
   --request "GET" --header "authorization: Bearer $TOKEN" --header "content-type: application/json" --silent \
   | jq -r ".payload.data" | base64 --decode | tee $JITSI_DIR/certs/fullchain.pem > /dev/null
chmod 400 $JITSI_DIR/certs/*
echo SETUP: Retrieved SSL certificates

# Set up Jitsi Docker
cd $JITSI_DIR/docker-jitsi-meet
# set correct domain name, ports, and config dir
HOSTNAME=$(curl -s "$META_URL/instance/attributes/hostname" -H "$META_HEADER")
DOMAIN=$(curl -s "$META_URL/instance/attributes/domain" -H "$META_HEADER")
sed -e 's/HTTP_PORT=8000/HTTP_PORT=80\nENABLE_HTTP_REDIRECT=1/' \
    -e 's/HTTPS_PORT=8443/HTTPS_PORT=443/' \
    -e "s%#PUBLIC_URL=https://meet.example.com%PUBLIC_URL=https://$HOSTNAME.$DOMAIN%" \
    -e "s%^CONFIG=[^\n]+%CONFIG=$JITSI_DIR/config%" env.example > .env
# generate passwords
./gen-passwords.sh
# Add cert path mapping
sed -i -e "1,/prosody:/ s%volumes:%volumes:\n            - $JITSI_DIR/certs/fullchain.pem:/config/keys/cert.crt\n            - $JITSI_DIR/certs/key.pem:/config/keys/cert.key%" docker-compose.yml
echo SETUP: Configured Jitsi
# make dirs for config files
sudo mkdir -p $JITSI_DIR/config/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
sudo chown -R $JITSI_GROUP:$JITSI_USER $JITSI_DIR/config

# start Jitsi
echo SETUP: Launching Jitsi
sudo docker-compose up -d
echo SETUP: Done.
date
