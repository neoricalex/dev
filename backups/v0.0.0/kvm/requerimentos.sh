#!/usr/bin/env bash

echo "==> Instalar o KVM"
sudo apt update
sudo apt install -y qemu qemu-kvm qemu-efi qemu-utils qemu-block-extra \
				libvirt-daemon libvirt-clients bridge-utils virt-manager qemu-system \
				qemu-utils qemu-block-extra libvirt-daemon-system cpu-checker \
				libguestfs-tools libosinfo-bin dnsmasq-base ebtables libvirt-dev \
                virtinst virt-top

echo "==> Ligar o Libvirt"
sudo gpasswd -a $USER libvirt
sudo systemctl start libvirtd
sudo systemctl enable --now libvirtd

echo "==> Compatibilizar o Libvirt com o Terraform..."
sudo sed -i.bak -e 's/#security_driver = "selinux"/security_driver = "none"/' /etc/libvirt/qemu.conf
sudo systemctl restart libvirtd

echo "==> Ligar o modulo vhost_net..."
sudo modprobe vhost_net
echo vhost_net | sudo tee -a /etc/modules

# nmcli device status
#sudo cp ./interfaces /etc/network/interfaces
#sudo reboot

echo "Instalando o Cockpit..."
sudo apt install cockpit -y
sudo systemctl enable --now cockpit.socket
