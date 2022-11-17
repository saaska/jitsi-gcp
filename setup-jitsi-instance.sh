#!/bin/bash
echo SETUP: Working in $PWD as $(whois) > /var/log/setup-jitsi.log

echo SETUP: Updating all apt packages...>> /var/log/setup-jitsi.log
sudo apt-get update 
echo SETUP: Updated apt packages>> /var/log/setup-jitsi.log

echo SETUP: Get dynamic DNS update script, run it, and add to run at startup>> /var/log/setup-jitsi.log
sudo apt-get -y -q -q install python3-pip 			# Install pip3 for python dependencies
echo SETUP: Installed pip>> /var/log/setup-jitsi.log
pip3 install google-cloud-dns  		# Install DNS resolver and GCP Cloud DNS libraries
echo SETUP: Installed Google Cloud DNS package for Python>> /var/log/setup-jitsi.log
sudo curl -s "https://gist.githubusercontent.com/saaska/2815148e66b1a1cc0b7d6901770b5246/raw/dd8b782a5e3ad3f0a468f376ae0634702f136ddf/gcp-renew-dns.py" \
	-o /usr/local/bin/gcp-renew-dns.py >>/var/log/setup-jitsi.log 2>&1  	# Download python script from a specified repository
echo SETUP: Got DNS Update Script>> /var/log/setup-jitsi.log
echo SETUP: Running Update Script...>> /var/log/setup-jitsi.log
python3 /usr/local/bin/gcp-renew-dns.py>>/var/log/setup-jitsi.log 2>&1		# Run the script.
echo SETUP: Ran DNS Update Script>> /var/log/setup-jitsi.log
if grep -e "@reboot python3 /usr/local/bin/gcp-renew-dns" /etc/crontab; then
    echo '@reboot python3 /usr/local/bin/gcp-renew-dns.py &'>> /etc/crontab # Configure cron to run the script at start-up.
fi
echo SETUP: Cron DNS update setup step complete>> /var/log/setup-jitsi.log

# Get Docker and docker-compose
# get docker signing keys
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Added Docker signing keys >> /var/log/setup-jitsi.log
# add docker package repository
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list
echo SETUP: Added Docker package repository >> /var/log/setup-jitsi.log
# update packages
sudo apt-get update>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Updated Docker package info>> /var/log/setup-jitsi.log
# install docker packages
sudo apt-get -y -q install docker-ce docker-ce-cli containerd.io docker-compose>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Installed Docker packages>> /var/log/setup-jitsi.log

# Get jitsi
sudo apt-get -y -q install wget unzip>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Installed wget and unzip>> /var/log/setup-jitsi.log
wget --no-verbose https://github.com/jitsi/docker-jitsi-meet/archive/refs/tags/stable-7882.zip -O /tmp/jitsi-docker.zip>>/var/log/setup-jitsi.log 2>&1
echo SETUP: Downloaded jitsi-docker release ZIP>> /var/log/setup-jitsi.log
sudo unzip /tmp/jitsi-docker.zip -d /opt/jitsi-docker
echo SETUP: Unpacked jitsi-docker release ZIP>> /var/log/setup-jitsi.log
rm /tmp/jitsi-docker.zip

# Get Let's encrypt SSL keys
sudo apt-get -y -q install jq  # install JSON processor for the keys obtained from secrets
sudo mkdir /opt/jitsi-docker/certs
META_URL=http://metadata.google.internal/computeMetadata/v1
META_HEADER="Metadata-Flavor: Google"
TOKEN=$(gcloud auth print-access-token)
PROJECT_ID=$(curl -s "$META_URL/project/project-id" -H "$META_HEADER")
KEY_SECRET_NAME=$(curl -s "$META_URL/instance/attributes/keysecret" -H "$META_HEADER")
FULLCHAIN_SECRET_NAME=$(curl -s "$META_URL/instance/attributes/fullchainsecret" -H "$META_HEADER")
curl -s https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$KEY_SECRET_NAME/versions/latest:access  \
   --request "GET" --header "authorization: Bearer $TOKEN" --header "content-type: application/json" --silent \
   | jq -r ".payload.data" | base64 --decode | sudo tee /opt/jitsi-docker/certs/key.pem > /dev/null
curl -s https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/$FULLCHAIN_SECRET_NAME/versions/latest:access  \
   --request "GET" --header "authorization: Bearer $TOKEN" --header "content-type: application/json" --silent \
   | jq -r ".payload.data" | base64 --decode | sudo tee /opt/jitsi-docker/certs/fullchain.pem > /dev/null
echo SETUP: Retrieved SSL certificates>> /var/log/setup-jitsi.log

# Set up Jitsi config
cd $(ls -d /opt/jitsi-docker/docker-jitsi*)
cp env.example .env
./gen-passwords.sh
mkdir -p ~/.jitsi-meet-cfg/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
# Set correct ports
HOSTNAME=$(curl -s "$META_URL/instance/attributes/hostname" -H "$META_HEADER")
DOMAIN=$(curl -s "$META_URL/instance/attributes/domain" -H "$META_HEADER")
sed -i -e 's/HTTP_PORT=8000/HTTP_PORT=80\nENABLE_HTTP_REDIRECT=1/' -e 's/HTTPS_PORT=8443/HTTPS_PORT=443/' -e "s%#PUBLIC_URL=https://meet.example.com%PUBLIC_URL=https://$HOSTNAME.$DOMAIN"% .env
# Add cert path mapping
sed -i -e "1,/prosody/ s%volumes:%volumes:\n            - /opt/jitsi-docker/certs/fullchain.pem:/config/keys/cert.crt\n            - /opt/jitsi-docker/certs/key.pem:/config/keys/cert.key%" docker-compose.yml
echo SETUP: Configured Jitsi>> /var/log/setup-jitsi.log

# start Jitsi
sudo docker-compose up -d
echo SETUP: Launched Jitsi>> /var/log/setup-jitsi.log
date>> /var/log/setup-jitsi.log
