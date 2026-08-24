terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "compute" {
  project            = var.project_id
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iap" {
  project            = var.project_id
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_network" "iot" {
  name                    = "${var.instance_name}-vpc"
  auto_create_subnetworks = false

  depends_on = [google_project_service.compute]
}

resource "google_compute_subnetwork" "iot" {
  name          = "${var.instance_name}-subnet"
  ip_cidr_range = var.subnet_cidr
  network       = google_compute_network.iot.id
  region        = var.region
}

# IAP TCP forwarding is the only permitted ingress path. The VM has an
# ephemeral external address solely for package downloads during the test day;
# no public SSH, VNC, Kubernetes, or HTTP firewall rule is created.
resource "google_compute_firewall" "allow_iap_ssh" {
  name      = "${var.instance_name}-allow-iap-ssh"
  network   = google_compute_network.iot.name
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iot-l1"]
}

resource "google_compute_instance" "l1" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["iot-l1"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2604-lts-amd64"
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.iot.id

    # This address is for outbound package/image downloads only. Inbound
    # access remains limited by the IAP-only firewall above.
    access_config {}
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    iot-vagrant-version    = var.vagrant_version
  }

  advanced_machine_features {
    enable_nested_virtualization = true
  }

  allow_stopping_for_update = true

  labels = {
    project   = "inception-of-things"
    lifecycle = "test-day"
  }

  metadata_startup_script = file("${path.module}/startup.sh")

  depends_on = [
    google_project_service.compute,
    google_project_service.iap,
    google_compute_firewall.allow_iap_ssh,
  ]
}
