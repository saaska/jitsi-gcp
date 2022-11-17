# jitsi-gcp
Scripts and stuff to run a Jitsi installation in Google Cloud

[Jitsi](https://github.com/jitsi/) is a set of projects for a Zoom/Google Meet-like videoconferencing. It has a React client that can run in browser and as a mobile app through React Native, and a set of server systems. The former are available free for public use at https://meet.jit.si, as-a-service commercially, or can be run independently.

This repo contains script I used to run my own Jitsi installation on Google Cloud Platform.

Clients send media to a Jitsi server through WebRTC, which needs SSL, so you need a domain name and SSL certificates for it. 

1. DNS Config and service account permissions
2. Upload SSL certificates into [Secret Manager](https://console.cloud.google.com/security/secret-manager), note their names
3. Configure firewall rules to let Jitsi connections in

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
