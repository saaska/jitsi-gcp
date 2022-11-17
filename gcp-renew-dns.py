# Adapted from https://www.ditoweb.com/2022/01/a-programmers-solution-to-dynamic-ips-on-gce/
#
# Will deregister a hostname in a zone in Google Cloud DNS
# and register it back with the current public IP of the instance.
#
# PREREQUISITES:
# 1. pip3 install dnspython google-cloud-dns
# 2. Set the following metadata (Management>Metadata) in instance settings:
#    ZONE (demo-zone), HOSTNAME (demosite), DOMAIN (mydemos.onine)
# 3. The instance/account must have GCP "DNS Administrator" IAM role enabled

import json, requests, time, sys

from google.cloud import dns

# ========================
# Get settings from Metadata API
keys = ['project', 'zone', 'domain', 'hostname']
metadata_root_url = 'http://metadata.google.internal/computeMetadata/v1/'
metadata_proot_ath = {k: f'instance/attributes/{k}' if k != 'project' else 'project/project-id' for k in keys}
_ = {}
try:
    for key in keys:
        r = requests.get(f'{metadata_root_url}{metadata_proot_ath[key]}?alt=text', 
                         headers={'Metadata-Flavor': 'Google'})
        if r.status_code == 200:
            _[key] = r.content.decode('latin-1')
        else:
            raise ValueError(f'Error: request for {key} got status code {r.status_code}')
except Exception as e:
    print(f'Error: please set VM metadata: hostname, domain, zone.\nException info:\n{e}')
    sys.exit(-1)

PROJECT, ZONE, DOMAIN, HOSTNAME = _['project'], _['zone'], _['domain'], _['hostname']
DOMAIN += '.'
HOSTNAME += '.' + DOMAIN

# ========================
# Obtain Cloud DNS API objects
gcp_dns = dns.Client(PROJECT)
zone = gcp_dns.zone(ZONE, DOMAIN)

# ========================
# Get currently assigned IP from the specified hostname record
old_ip, old_ttl = None, 60
recs = [_ for _ in  zone.list_resource_record_sets() if _.record_type == 'A' and _.name == HOSTNAME]
if recs:
    old_ip, old_ttl = recs[0].rrdatas[0], recs[0].ttl

# ========================
# Get the current public IP address of our instance
try:
    new_ip = requests.get(f'{metadata_root_url}/instance/network-interfaces/0/access-configs/0/external-ip?alt=text', 
                          headers={'Metadata-Flavor': 'Google'}).content.decode('latin-1')
except Exception as e:
    print(f'Error getting public IP from VM metadata. Exception info:\n{e}')
    sys.exit(-1)

# ========================
print(f'Old IP address: {old_ip}\nNew IP address: {new_ip}')

ttl = 60  # TTL for hostname DNS Records = 1 minute

if old_ip and old_ip != new_ip:
    # Remove the old DNS record
    record1 = zone.resource_record_set(HOSTNAME, 'A', old_ttl, [old_ip])
    changes = zone.changes()
    changes.delete_record_set(record1)
    changes.create()
    changes.reload()
    while changes.status != 'done':
        print(f'Record Deletion Status: {changes.status}')
        time.sleep(20)
        changes.reload()
    print(f'Record Deletion Status: {changes.status}')
    
if old_ip != new_ip:
    # Create new DNS A record for the current IP address
    record = zone.resource_record_set(HOSTNAME, 'A', ttl, new_ip)
    changes = zone.changes()
    changes.add_record_set(record)
    changes.create()
    changes.reload()
    while changes.status != 'done':
        print(f'Record Update Status: {changes.status}')
        time.sleep(20)
        changes.reload()
    print(f'Record Update Status: {changes.status}')
    print(f'{HOSTNAME} now points to {new_ip}.\n')
