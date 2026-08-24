# Inception of Things

This is a 42 Inception of Things implementation prepared for an x86 GCP test
host. The original local VirtualBox provider blocks remain available, but the
cloud path uses the supported nested-virtualization stack:

    GCE Ubuntu 26.04 x86 L1
      -> KVM/libvirt L2 VMs for P1 and P2
      -> Docker/k3d directly on L1 for P3 and bonus

The GCP route deliberately has no public ingress firewall, VNC service, or
hard-coded credential. IAP SSH is the only inbound management path.

## Parts

| Part | Result | GCP execution route |
| --- | --- | --- |
| P1 | yeominS K3s server and yeominSW K3s worker | Vagrant with libvirt/KVM |
| P2 | One yeominS K3s VM, three apps, Traefik host routing | Vagrant with libvirt/KVM |
| P3 | Public GitHub-backed Argo CD GitOps | Docker/k3d on L1 |
| Bonus | ClusterIP GitLab-backed Argo CD GitOps | Same Docker/k3d cluster on L1 |
| iot-terraform | Isolated GCE L1 host | Terraform from Cloud Shell |

P1 and P2 both use 192.168.56.0/24, so they must never run at the same time.
Their required fixed addresses are 192.168.56.110 for yeominS and
192.168.56.111 for yeominSW.

## GCP prerequisites

Use a billing-enabled GCP project with permission to create a custom VPC,
subnet, firewall rule, disk, Compute Engine instance, and to enable APIs. The
operator also needs IAP TCP forwarding and OS Login administrator access.

The Terraform configuration creates an Ubuntu 26.04 x86 N2 instance with KVM
nested virtualization enabled. It uses an ephemeral external address only for
outbound package downloads; the VPC firewall permits TCP 22 only from the IAP
TCP forwarding range.

Start with the detailed Terraform instructions in
[iot-terraform/README.md](iot-terraform/README.md).

## L1 preparation

After Terraform applies and the startup script has completed, log in through
IAP as the OS Login user and run:

    cd ~/inception-of-things/iot-terraform
    ./scripts/prepare-host-user.sh
    exit

Reconnect through IAP, validate the host, and create the static libvirt
network:

    cd ~/inception-of-things/iot-terraform
    ./scripts/validate-setup.sh
    cd ..
    sudo ./scripts/ensure-libvirt-network.sh

The Vagrant plugin is installed per OS Login user. Reconnect after
prepare-host-user.sh so that Docker, libvirt, and KVM Unix group memberships
take effect.

## P1

Generate the ignored, runtime-only join token on L1 before Vagrant starts:

    cd ~/inception-of-things/p1
    ./scripts/prepare-runtime.sh
    vagrant up --provider=libvirt
    ./scripts/validate-cluster.sh

The validation checks both machine names, the two required static addresses,
the K3s server/agent services, and two Ready nodes. Delete the L2 VMs before
moving to P2:

    vagrant destroy -f

## P2

Run P2 only after the P1 VMs have been destroyed:

    cd ~/inception-of-things/p2
    vagrant up --provider=libvirt
    ./scripts/validate-cluster.sh

The validation runs from L1 and checks the three deployments, app-2's three
ready replicas, Traefik, all host routes, and the default app-3 route. Clean
up when evidence is collected:

    vagrant destroy -f

## P3

P3 intentionally requires the actual public GitHub repository URL and branch.
It does not infer an origin remote. The remote dev directory must match the
current source tree before installation begins.

    export REPO_URL=https://github.com/GITHUB_OWNER/yeomin4242-inception-of-things-p3.git
    export TARGET_REVISION=main
    cd ~/inception-of-things/p3
    ./install_and_setup.sh
    ./validate_gitops.sh

The k3d load balancer binds only to 127.0.0.1:8888. The app can be checked
through its Ingress host:

    curl -H 'Host: playground.local' http://127.0.0.1:8888/

To demonstrate the required automatic update, use a separate clean clone of
the public source:

    export GITOPS_REPO_DIR=$HOME/iot-gitops-proof
    ./verify_auto_sync.sh

That command commits and pushes the real dev deployment image change from v1
to v2, then waits for Argo CD's automatic reconciliation. It does not request
a manual synchronization.

## Bonus

The cloud bonus uses one in-cluster GitLab CE deployment in namespace gitlab.
Do not also bring up bonus/Vagrantfile. The root password is generated into a
Kubernetes Secret at runtime; the GitLab tokens used for import and proof are
temporary, minimally scoped, and revoked by the scripts.

    export REPO_URL=https://github.com/GITHUB_OWNER/yeomin4242-inception-of-things-p3.git
    export TARGET_REVISION=main
    cd ~/inception-of-things/bonus
    ./install_bonus.sh
    ./test_bonus.sh

The bonus test changes the real deployment manifest in the local GitLab main
branch, pushes it without embedding a credential in the remote URL, and proves
that playground-app-gitlab becomes Synced and Healthy with the v2 image.

## Cleanup

For the k3d-based P3 or bonus route:

    cd ~/inception-of-things/bonus
    ./delete_bonus.sh

For P3 alone:

    cd ~/inception-of-things/p3
    ./delete.sh

Finally, from the Terraform directory:

    terraform destroy

The Terraform state, generated runtime files, kubeconfigs, Vagrant state, and
evidence directories are ignored. Do not publish them to either GitHub or
GitLab.
