output "instance_name" {
  description = "Temporary L1 Compute Engine instance name."
  value       = google_compute_instance.l1.name
}

output "zone" {
  description = "Zone containing the L1 instance."
  value       = google_compute_instance.l1.zone
}

output "internal_ip" {
  description = "Private address of the L1 instance in the dedicated VPC."
  value       = google_compute_instance.l1.network_interface[0].network_ip
}

output "iap_ssh_command" {
  description = "IAP-only SSH command. No public SSH firewall rule exists."
  value       = format("gcloud compute ssh %s --project %s --zone %s --tunnel-through-iap", google_compute_instance.l1.name, var.project_id, google_compute_instance.l1.zone)
}

output "bootstrap_log" {
  description = "Startup-script log path to inspect after IAP SSH."
  value       = "/var/log/iot-bootstrap.log"
}
