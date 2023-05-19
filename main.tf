variable project_id {
  type = string
  description = "Id (not name) of the GCP project"
}

variable zone {
  type = string
  description = "Region in which to deploy resources"
}

variable dns_zone {
  type = string
  description = "Name of the Cloud DNS zone in GCP"
}

variable hostname {
  type = string
  description = "Hostname of the instance"
}

variable domain {
  type = string
  description = "Domain used by the Cloud DNS zone"
}

variable ssh_allowed_from {
  type = string
  description = "The network range that is allowed to connect through SSH"
}

variable service_account {
  type = string
  description = "The name of the service account that has DNS Admin, Secret Accessor and Metric Writer roles"
}

variable ssl_key {
  type = string
  description = "The name of the GCP secret containing the SSL private key"
}

variable ssl_fullchain {
  type = string
  description = "The name of the GCP secret containing the full certificate chain for the domain"
}

variable letsencrypt_email {
  type = string
  description = "Email contact for Let's Encrypt certificates"
}

variable preemptible {
  type = string
  description = "Use a Spot (cheaper pre-emptible) instance"
}

module "project-services" {
  source  = "terraform-google-modules/project-factory/google//modules/project_services"
  version = "~> 14.2"

  project_id = var.project_id

  activate_apis = [
    "compute.googleapis.com",
    "iam.googleapis.com",
    "dns.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

# terraform import google_dns_managed_zone.dns_zone jitsi-demos-377011/saaska-zone
resource "google_dns_managed_zone" "dns_zone" {
  dns_name      = "${var.domain}."
  force_destroy = false 
  name          = var.dns_zone
  project       = var.project_id
}

# terraform import google_compute_firewall.allow_prosody jitsi-demos-377011/allow-prosody
resource "google_compute_firewall" "allow_prosody" {
  allow {
    ports    = ["3478", "10000"]
    protocol = "udp"
  }
  allow {
    ports    = ["4443", "5222", "5281", "5280", "5349", "6443"]
    protocol = "tcp"
  }
  direction     = "INGRESS"
  name          = "allow-prosody"
  network       = "default"
  priority      = 1000
  project       = var.project_id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-prosody"]
}

# terraform import google_compute_firewall.allow_jitsi jitsi-demos-377011/allow-jitsi
resource "google_compute_firewall" "allow_jitsi" {
  allow {
    ports    = ["3478", "10000"]
    protocol = "udp"
  }
  allow {
    ports    = ["443", "4443", "5349", "80"]
    protocol = "tcp"
  }
  direction     = "INGRESS"
  name          = "allow-jitsi"
  network       = "default"
  priority      = 1000
  project       = var.project_id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-jitsi"]
}

# These two rules are replication of the needed default rules in case they are changed.
# terraform import google_compute_firewall.default_allow_internal jitsi-demos-377011/allow-internal
resource "google_compute_firewall" "allow_internal" {
  allow {
    ports    = ["0-65535"]
    protocol = "tcp"
  }
  allow {
    ports    = ["0-65535"]
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
  description   = "Allow internal traffic on the default network"
  direction     = "INGRESS"
  name          = "allow-internal"
  network       = "default"
  priority      = 65534
  project       = var.project_id
  source_ranges = ["10.128.0.0/9"]
  target_tags   = ["allow-internal"]
}

# terraform import google_compute_firewall.default_allow_ssh jitsi-demos-377011/allow-ssh
resource "google_compute_firewall" "allow_ssh" {
  allow {
    ports    = ["22"]
    protocol = "tcp"
  }
  description   = "Allow SSH"
  direction     = "INGRESS"
  name          = "allow-ssh"
  network       = "default"
  priority      = 65532
  project       = var.project_id
  source_ranges = [var.ssh_allowed_from]
  target_tags   = ["allow-ssh"]
}

# terraform import google_service_account.jitsi_service_account jitsi-demos-377011/jitsi-service-account@jitsi-demos-377011.iam.gserviceaccount.com
resource "google_service_account" "jitsi_service_account" {
  account_id   = var.service_account
  display_name = "Jitsi Meet own installation Service Account"
  project      = var.project_id
}

resource "google_project_iam_member" "role_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.jitsi_service_account.email}"
}

resource "google_project_iam_member" "role_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.jitsi_service_account.email}"
}

resource "google_project_iam_member" "role_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.jitsi_service_account.email}"
}

# terraform import google_compute_instance.demo_instance projects/jitsi-demos-377011/zones/europe-west3-c/instances/demo-instance
resource "google_compute_instance" "jitsi_instance" {
  project = var.project_id
  name = "${var.hostname}"
  machine_type = "e2-standard-2"
  boot_disk {
    auto_delete = true
    device_name = "${var.hostname}"
    initialize_params {
      image = "debian-cloud/debian-11"
    }
  }
  metadata = {
    keysecret         = var.ssl_key
    domain            = var.domain
    fullchainsecret   = var.ssl_fullchain
    hostname          = var.hostname
    zone              = var.dns_zone
    letsencrypt_email = var.letsencrypt_email
    startup-script    = "#!/bin/bash\nsudo apt-get update\nsudo apt-get install -y git\ngit clone https://github.com/saaska/jitsi-gcp /tmp/jitsi-gcp\ncd /tmp/jitsi-gcp\nbash ./setup-jitsi-instance.sh"
  }
  network_interface {
    access_config {
    }
    network            = "default"
    subnetwork         = "default"
    stack_type         = "IPV4_ONLY"
    subnetwork_project = var.project_id
  }
  scheduling {
    automatic_restart           = false
    preemptible                 = var.preemptible
  }
  service_account {
    email  = google_service_account.jitsi_service_account.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  tags = ["http-server", "https-server", "allow-jitsi", "allow-prosody", "allow-ssh", "allow-internal"]
  zone = var.zone
}
