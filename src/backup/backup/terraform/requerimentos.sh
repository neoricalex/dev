#!/usr/bin/env bash

echo "==> Instalar o Terraform"
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/neoricalex-hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/neoricalex-hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform -y

sudo apt-get update && sudo apt-get install -y gnupg software-properties-common

wget -O- https://apt.releases.hashicorp.com/gpg | \
            gpg --dearmor | \
            sudo tee /usr/share/keyrings/neoricalex-hashicorp-archive-keyring.gpg

gpg --no-default-keyring \
    --keyring /usr/share/keyrings/neoricalex-hashicorp-archive-keyring.gpg \
    --fingerprint

echo "deb [signed-by=/usr/share/keyrings/neoricalex-hashicorp-archive-keyring.gpg] \
        https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list

# https://github.com/neoricalex/kvm_packer
# https://computingforgeeks.com/how-to-provision-vms-on-kvm-with-terraform/
# https://blog.stephane-robert.info/docs/infra-as-code/provisionnement/terraform/premiere-infra/
# https://github.com/terraform-google-modules/terraform-google-bootstrap
# https://phoenixnap.com/kb/build-linux-kernel
# https://linuxconfig.org/grub-compile-from-source-on-linux