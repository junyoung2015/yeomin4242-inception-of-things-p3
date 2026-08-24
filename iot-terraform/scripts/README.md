# L1 host scripts

startup.sh is executed by Compute Engine as root during instance creation.
It installs the x86/KVM host dependencies but deliberately does not install a
Vagrant plugin into an unknown OS Login user's home directory.

After the first IAP SSH login, run:

    cd ~/inception-of-things/iot-terraform
    ./scripts/prepare-host-user.sh
    exit

Reconnect through IAP, then run:

    cd ~/inception-of-things/iot-terraform
    ./scripts/validate-setup.sh

The validation must pass before starting P1 or P2. It confirms that the L1 is
x86_64, /dev/kvm exists, the logged-in user can use libvirt and Docker, and
Vagrant is exactly 2.4.9 with vagrant-libvirt.
