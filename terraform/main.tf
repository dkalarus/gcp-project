provider "google" {
  project = var.project
  region  = var.region
}
resource "google_compute_network" "vpc-network" {
  project                 = var.project
  name                    = "vpc-network-${var.project_name}"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnetwork" {
  name                     = "subnetwork-${var.project_name}"
  ip_cidr_range            = "10.2.0.0/24"
  region                   = var.region
  network                  = google_compute_network.vpc-network.id
  private_ip_google_access = true
  secondary_ip_range {
    range_name    = "tf-secondary-range-pods"
    ip_cidr_range = "172.16.0.0/16"
  }
  secondary_ip_range {
    range_name    = "tf-secondary-range-services"
    ip_cidr_range = "192.168.0.0/20"
  }
}

resource "google_compute_instance" "vm-bastion" {
  name         = "vm-bastion-${var.project_name}"
  machine_type = "e2-micro"
  zone         = "${var.region}-${var.zone}"

  tags = ["bastion", "vm"]

  boot_disk {
    initialize_params {
      image = "ubuntu-1804-bionic-v20220824"
      size  = 30
    }
  }

  network_interface {
    network    = google_compute_network.vpc-network.self_link
    subnetwork = google_compute_subnetwork.subnetwork.self_link

    access_config {
      // Ephemeral public IP
    }
  }

  metadata = {
    ssh-keys = "${var.gce_ssh_user}:${file(var.gce_ssh_pub_key_file)}"
  }
}

resource "google_compute_firewall" "ssh-rule" {
  project = var.project
  name    = "ssh-rule"
  network = google_compute_network.vpc-network.self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["91.233.157.117/32"]
  target_tags   = ["vm"]
}

resource "google_artifact_registry_repository" "docker-registry" {
  location      = var.region
  repository_id = "docker-registry"
  format        = "DOCKER"
}

resource "google_storage_bucket" "storage-db-backup" {
  name          = "storage-db-backup-${var.project_name}"
  location      = "EU"
  force_destroy = true
}

resource "google_compute_global_address" "priv-conn-ip-range" {
  name         = "priv-conn-ip-range"
  purpose      = "VPC_PEERING"
  address_type = "INTERNAL"
  address      = "10.100.0.0"
  prefix_length = 20
  network      = google_compute_network.vpc-network.id

}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc-network.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.priv-conn-ip-range.name]
}

resource "google_sql_database_instance" "postgres" {
  name             = "postgres-${var.project_name}"
  region           = var.region
  database_version = "POSTGRES_14"

  depends_on = [google_service_networking_connection.private_vpc_connection]

  settings {
    tier = "db-f1-micro"
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc-network.id
    }
  }
}






resource "google_service_account" "gke-service-account" {
  account_id   = "gke-service-account"
  display_name = "Service Account GKE"
}

resource "google_container_cluster" "gke-cluster" {
  name     = "gke-cluster"
  location = var.region
  # We can't create a cluster with no node pool defined, but we want to only use
  # separately managed node pools. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
    node_locations = [
    "${var.region}-a", "${var.region}-b"
  ]
  ip_allocation_policy {
    cluster_secondary_range_name = "tf-secondary-range-pods"
    services_secondary_range_name = "tf-secondary-range-services"
  }
  network = google_compute_network.vpc-network.name
  subnetwork = google_compute_subnetwork.subnetwork.name
  master_authorized_networks_config {
    
    cidr_blocks {
      cidr_block = "10.2.0.0/24"
    }
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = "10.1.0.0/28"
  }
}

resource "google_container_node_pool" "gke-node-pool" {
  name       = "gke-node-pool"
  location   = var.region
  cluster    = google_container_cluster.gke-cluster.name
  node_count = 1
  node_locations = [
     "${var.region}-a", "${var.region}-b"
  ]



  node_config {
    machine_type = "e2-medium"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    service_account = google_service_account.gke-service-account.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}