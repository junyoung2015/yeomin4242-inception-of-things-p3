# GCP L1 infrastructure

This Terraform workspace creates the temporary L1 host for the GCP validation
route. It is intentionally designed for a same-day test followed by
terraform destroy.

The instance is an x86 Ubuntu 26.04 LTS N2 VM with nested virtualization
enabled. Linux KVM/libvirt runs P1 and P2 inside it; P3 and the bonus use
Docker/k3d directly on L1.

## Security model

Terraform creates only:

- one dedicated custom VPC and subnet;
- one IAP-only TCP 22 firewall rule;
- one Ubuntu 26.04 x86 L1 Compute Engine instance; and
- the required Compute Engine and IAP API enablement resources.

The instance has an ephemeral external address for outbound package/image
downloads during the test day. There is no public SSH, VNC, Kubernetes API,
HTTP, HTTPS, or Docker firewall rule. OS Login is enabled and project SSH key
metadata is blocked.

## Required GCP access

Before running Terraform, the account needs a billing-enabled project and
permission to:

- enable Compute Engine and IAP APIs;
- create and delete Compute Engine instances, disks, networks, subnets, and
  firewall rules;
- use IAP TCP forwarding; and
- use OS Login administrator access.

The target region is asia-northeast3 and the default zone is asia-northeast3-a.
Confirm N2 capacity and CPU quota in the chosen zone before applying. If a
school or organization policy blocks nested virtualization or IAP, a project
administrator must change that policy.

## Cloud Shell workflow

Cloud Shell is preferred because it already provides gcloud authenticated for
the selected console project. Terraform availability in Cloud Shell changes
over time, so install and verify it in the Cloud Shell home directory if
needed.

    gcloud config set project YOUR_PROJECT_ID
    gcloud services enable compute.googleapis.com iap.googleapis.com
    gcloud compute machine-types describe n2-standard-8 \
      --zone=asia-northeast3-a \
      --format='value(name)'
    gcloud compute regions describe asia-northeast3 \
      --format='yaml(quotas)'

    if ! command -v terraform >/dev/null; then
      TERRAFORM_VERSION=1.11.4
      curl -fsSLO https://releases.hashicorp.com/terraform/$TERRAFORM_VERSION/terraform_$TERRAFORM_VERSION_linux_amd64.zip
      unzip -q terraform_$TERRAFORM_VERSION_linux_amd64.zip -d $HOME/bin
      export PATH=$HOME/bin:$PATH
    fi
    terraform version

Copy the project source into Cloud Shell without copying local runtime files,
then configure Terraform:

    cd ~/inception-of-things/iot-terraform
    cp terraform.tfvars.example terraform.tfvars
    editor terraform.tfvars
    terraform init
    terraform fmt -check
    terraform validate
    terraform plan

Review the plan carefully. It should contain the dedicated VPC/subnet, one
IAP SSH firewall rule, API enablement, and one L1 instance. Apply only after
that review:

    terraform apply

## First login and L1 validation

Terraform prints a ready-to-copy IAP command:

    terraform output -raw iap_ssh_command

Wait for startup completion, then inspect the non-secret bootstrap log through
the IAP session:

    sudo tail -n 200 /var/log/iot-bootstrap.log
    cd ~/inception-of-things/iot-terraform
    ./scripts/prepare-host-user.sh
    exit

Reconnect with the same IAP command. The reconnect applies docker, libvirt,
and kvm group membership. Then run:

    cd ~/inception-of-things/iot-terraform
    ./scripts/validate-setup.sh
    cd ..
    sudo ./scripts/ensure-libvirt-network.sh
    sudo virsh net-dumpxml iot-vagrant-private

The libvirt network is 192.168.56.0/24 with host bridge address
192.168.56.1 and DHCP disabled. Vagrant keeps its independent NAT adapter for
management and package downloads.

## Cleanup

Destroy P1/P2 guests first from their respective directories. Delete the k3d
cluster with the relevant P3 or bonus cleanup script. Then return here:

    terraform destroy

Verify that the Compute Engine instance, boot disk, VPC, subnet, and IAP
firewall rule disappeared. Do not commit terraform.tfvars, state files,
runtime secrets, Kubernetes configuration, or evidence output.
