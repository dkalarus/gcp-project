terraform {
  backend "gcs" {
    bucket = "backend-terraform-dk"
    prefix = "terraform/state1"
  }
}