# jitsi-gcp
Scripts and stuff to run a Jitsi installation in Google Cloud

[Jitsi](https://github.com/jitsi/) is a set of projects for a Zoom/Google Meet-like videoconferencing. It has a React client that can run in browser and as a mobile app through React Native, and a set of server systems. The former are available free for public use at https://meet.jit.si, as-a-service commercially, or can be run independently.

This repo contains script I used to run my own Jitsi installation on Google Cloud Platform.

Clients send media to a Jitsi server through WebRTC, which needs SSL, so you need a domain name and SSL certificates for it. 

1. DNS Config and service account permissions
2. Upload SSL certificates into [Secret Manager](https://console.cloud.google.com/security/secret-manager), note their names
3. Configure firewall rules to let Jitsi connections in
4. Create and run the instance

## 1. DNS Config and service account permissions

The first thing is to register a domain and create a zone in [Google Cloud DNS](https://console.cloud.google.com/net-services/dns/zones) to manage the domain names. For experimentation, VMs may often be created and deleted, spot instances that can be stopped at any time can be used to save costs. So [gcp_renew-dns.py](./gcp_renew-dns.py) is a script that, when run from inside a VM instance, will renew a given DNS name to point to that instance's current IP address. 

To be able to do that, VM service account needs to have a DNS Administrator role. 

If you have `jq` installed where you run gcloud (GCP Cloud shell does), run
```bash
export GCP_PROJECT=$(gcloud config get project)
export SERVICE_ACC=$(gcloud iam service-accounts create jitsi-service-account \
    --display-name="Jitsi Service Account" \
    --format=json | jq -r ".email")
gcloud projects add-iam-policy-binding $GCP_PROJECT\
    --member=serviceAccount:${SERVICE_ACC} --role=roles/dns.admin
gcloud projects add-iam-policy-binding $GCP_PROJECT\
    --member=serviceAccount:${SERVICE_ACC} --role=roles/monitoring.metricWriter
gcloud projects add-iam-policy-binding $GCP_PROJECT\
    --member=serviceAccount:${SERVICE_ACC} --role=roles/secretmanager.secretAccessor
```

## 2. Upload SSL certificates to GCP's Secret Manager

The two files we need are the server private key and the full certification chain file. In a  Let's Encrypt-supplied certificate archive, as of November 2022, they are called `<HOSTNAME>/key.pem` and `<HOSTNAME>/fullchain.pem`. Upload them to the [Secret Manager](https://console.cloud.google.com/security/secret-manager) and record their names, you will need them.

## 3. Configure firewall rules

We will use two network tags, `jitsi` and `jibri` for our instances. To create firewall rules to allow instances tagged in this way to receive connections, you can use gcloud:
```bash
gcloud compute firewall-rules create allow-jitsi --allow=tcp:80,tcp:443,tcp:4443,tcp:5349,udp:10000,udp:3478 --target-tags=jitsi
```

## 4. Create and run the instance
```bash
# Change these vars if needed 
REGIONZONE=europe-west3-c
GCP_PROJECT=$(gcloud config get project)
MACHINETYPE=e2-standard-2
DNSZONE=saaska-zone
HOSTNAME=demo
DOMAIN=saaska.me
FULLCHAINSECRET=demo-fullchain-pem
KEYSECRET=demo-key-pem
SERVICE_ACC=jitsi-service-account2@${GCP_PROJECT}.iam.gserviceaccount.com

gcloud compute instances create jitsi-demo-instance --project=$GCP_PROJECT \
     --zone=$REGIONZONE --machine-type=e2-standard-2 \
     --network-interface=network-tier=PREMIUM,subnet=default \
     --metadata=domain=$DOMAIN,fullchainsecret=$FULLCHAINSECRET,\
       hostname=$HOSTNAME,keysecret=$KEYSECRET,zone=$DNSZONE,\
       startup-script=\#\!/bin/bash$'\n'sudo\ apt-get\ update$'\n'sudo\ apt-get\ install\ -y\ git$'\n'cd\ /tmp$'\n'git\ clone\ https://github.com/saaska/jitsi-gcp$'\n'cd\ jitsi-gcp$'\n'bash\ setup-jitsi-instance.sh \
     --no-restart-on-failure --maintenance-policy=TERMINATE --preemptible \
     --provisioning-model=SPOT --instance-termination-action=STOP \
     --service-account=$SERVICE_ACC \
     --scopes=https://www.googleapis.com/auth/cloud-platform \
     --tags=jitsi,http-server,https-server \
     --create-disk=auto-delete=yes,boot=yes,device-name=demo-instance,image=projects/debian-cloud/global/images/debian-11-bullseye-v20221102,mode=rw,size=10,type=projects/jitsi-demos/zones/$REGIONZONE/diskTypes/pd-balanced \
     --no-shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
     --reservation-affinity=any
```