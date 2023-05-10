#!/bin/bash

read -p "*** WARNING! ***
This will erase all Terraform state in this directory and start anew
Do you want to continue (y/n)? """ yn
if ! [[ $yn == "y" ]]; then exit; fi

rm -rf .terraform* &> /dev/null
rm -rf terraform.tfstate* &> /dev/null

if [[ -n "DEVSHELL_PROJECT_ID" ]]; then
    read -p "Enter the project name [$DEVSHELL_PROJECT_ID]: " GCP_PROJECT_ID
    GCP_PROJECT_ID=${GCP_PROJECT_ID:-$DEVSHELL_PROJECT_ID}
else
    read -p "Enter the project name: " GCP_PROJECT_ID
fi

read -p "Hostname [demo]: " HOSTNAME
HOSTNAME=${HOSTNAME:-demo}
read -p "Domain name [saaska.me]: " DOMAIN
DOMAIN=${DOMAIN:-saaska.me}
read -p "GCP region in which to deploy resources [europe-west3-c]: " ZONE
ZONE=${ZONE:-europe-west3-c}
read -p "GCP DNS zone name [saaska-zone]: " DNS_ZONE
DNS_ZONE=${DNS_ZONE:-saaska-zone}
read -p "The address range allowed to SSH [0.0.0.0/0]: " SSH_ALLOWED_FROM
SSH_ALLOWED_FROM=${SSH_ALLOWED_FROM:-0.0.0.0/0}
read -p "GCP service account for the setup scripts: [jitsi-service-account]: " SERVICE_ACCOUNT
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-jitsi-service-account}
echo "** SSL certificates must be either provided as GCP secrets or obtained from Let's Encrypt **"
while true; do 
  read -p "Get certificates from Let's Encrypt after VM launch [y]: " yn
  yn=${yn:-y}
  case $yn in
  [Yy] )
    while true; do
      read -p "Email for Let's Encrypt contact (required): " LE_EMAIL
      if [ ! -z $LE_EMAIL ]; then
        break
      fi  
    done  
    SSL_KEY=
    SSL_FULLCHAIN=
    break;;
  [Nn] )
    LE_EMAIL=
    read -p "GCP secret containing SSL private key [ssl-privkey]: " SSL_KEY
    SSL_KEY=${SSL_KEY:-ssl-privkey}
    read -p "GCP secret containing full cert chain [ssl-fullchain]: " SSL_FULLCHAIN
    SSL_FULLCHAIN=${SSL_FULLCHAIN:-ssl-fullchain}
    break;;
  * ) 
    echo "Please answer y or n.";;
  esac
done
while true; do
  read -p "Use a Spot (cheaper, pre-emptible) instance [y]: " yn
  yn=${yn:-y}
  case $yn in
    [Yy] ) PREEMPTIBLE=true; break;;
    [Nn] ) PREEMPTIBLE=false; break;;
    * ) echo "Please answer y or n.";;
  esac
done

cat <<EOF >vars.tfvars
project_id        = "$GCP_PROJECT_ID"
hostname          = "$HOSTNAME"
domain            = "$DOMAIN"
zone              = "$ZONE"
dns_zone          = "$DNS_ZONE"
ssh_allowed_from  = "$SSH_ALLOWED_FROM"
service_account   = "$SERVICE_ACCOUNT"
letsencrypt_email = "$LE_EMAIL"
ssl_key           = "$SSL_KEY"
ssl_fullchain     = "$SSL_FULLCHAIN"
preemptible       = "$PREEMPTIBLE"
EOF

terraform init

echo Trying to import in case resources already exist, please ignore errors...

terraform import -var-file=vars.tfvars -no-color google_dns_managed_zone.dns_zone $GCP_PROJECT_ID/saaska-zone > /dev/null
terraform import -var-file=vars.tfvars -no-color google_compute_firewall.allow_prosody $GCP_PROJECT_ID/allow-prosody > /dev/null
terraform import -var-file=vars.tfvars -no-color google_compute_firewall.allow_jitsi $GCP_PROJECT_ID/allow-jitsi > /dev/null
terraform import -var-file=vars.tfvars -no-color google_compute_firewall.allow_internal $GCP_PROJECT_ID/allow-internal > /dev/null
terraform import -var-file=vars.tfvars -no-color google_compute_firewall.allow_ssh $GCP_PROJECT_ID/allow-ssh > /dev/null
terraform import -var-file=vars.tfvars -no-color google_service_account.jitsi_service_account $GCP_PROJECT_ID/$SERVICE_ACCOUNT@$GCP_PROJECT_ID.iam.gserviceaccount.com > /dev/null
terraform import -var-file=vars.tfvars -no-color google_project_iam_member.role_dns_admin "$GCP_PROJECT_ID roles/dns.admin serviceAccount:$SERVICE_ACCOUNT@$GCP_PROJECT_ID.iam.gserviceaccount.com" > /dev/null
terraform import -var-file=vars.tfvars -no-color google_project_iam_member.role_metric_writer "$GCP_PROJECT_ID roles/monitoring.metricWriter serviceAccount:$SERVICE_ACCOUNT@$GCP_PROJECT_ID.iam.gserviceaccount.com" > /dev/null
terraform import -var-file=vars.tfvars -no-color google_project_iam_member.role_secret_accessor "$GCP_PROJECT_ID roles/secretmanager.secretAccessor serviceAccount:$SERVICE_ACCOUNT@$GCP_PROJECT_ID.iam.gserviceaccount.com" > /dev/null
terraform import -var-file=vars.tfvars -no-color google_compute_instance.jitsi_instance $GCP_PROJECT_ID/europe-west3-c/$HOSTNAME > /dev/null

echo Import step complete, running \"terraform plan:\"

terraform plan -var-file=vars.tfvars

echo -n "
Finished.
Run \"terraform apply -var-file=vars.tfvars\" now to make the above changes? "
read yn
if [[ $yn == "y" ]]; then terraform apply -var-file=vars.tfvars; fi
