# jitsi-gcp
Scripts and stuff to run a Jitsi installation in Google Cloud

[Jitsi](https://github.com/jitsi/) is a set of projects for a Zoom/Google Meet-like videoconferencing. It has a React client that can run in browser and as a mobile app through React Native, and a set of server systems. The former are available free for public use at https://meet.jit.si, as-a-service commercially, or can be run independently.

This repo contains script I used to run my own Jitsi installation on Google Cloud Platform.

Clients send media to a Jitsi server through WebRTC, which needs SSL, so you need a domain name and SSL certificates for it. 

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
