variable "project_id" {
  description = "Billing-enabled GCP project ID used only for this test deployment."
  type        = string
}

variable "region" {
  description = "Region for the isolated test VPC and subnet."
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "Zone for the nested-virtualization-capable N2 instance."
  type        = string
  default     = "asia-northeast3-a"
}

variable "instance_name" {
  description = "Name of the temporary L1 Compute Engine host."
  type        = string
  default     = "iot-l1-kvm"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$", var.instance_name))
    error_message = "instance_name must be a valid GCE resource name."
  }
}

variable "machine_type" {
  description = "x86 N2 machine type sized for two L2 VMs and the GitLab bonus."
  type        = string
  default     = "n2-standard-8"
}

variable "boot_disk_size_gb" {
  description = "Size of the temporary pd-balanced boot disk."
  type        = number
  default     = 100

  validation {
    condition     = var.boot_disk_size_gb >= 100
    error_message = "Use at least 100 GiB for boxes, container images, and GitLab PVCs."
  }
}

variable "subnet_cidr" {
  description = "Private CIDR for the dedicated GCP VPC."
  type        = string
  default     = "10.42.0.0/24"
}

variable "vagrant_version" {
  description = "Vagrant version recorded in instance metadata and installed by startup.sh."
  type        = string
  default     = "2.4.9"

  validation {
    condition     = var.vagrant_version == "2.4.9"
    error_message = "This test plan is pinned to Vagrant 2.4.9."
  }
}
