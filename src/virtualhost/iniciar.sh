#!/usr/bin/env sh

set -e

# Função para irmos informando o usuário via terminal (CLI) aquilo que estamos a fazer
function info() {
	if [[ -t 1 ]]; then
		printf "%bNEORICALEX:%b %b%s%b\n" "\x1b[1m\x1b[32m" "\x1b[0m" \
		                          "\x1b[1m\x1b[37m" "$1" "\x1b[0m"
	else
		printf "*** %s\n" "$1"
	fi
}
# Função para irmos avisando o usuário via terminal (CLI) aquilo que estamos a fazer
function aviso() {
	if [[ -t 1 ]]; then
		printf "%b***%b %b%s%b\n" "\x1b[1m\x1b[33m" "\x1b[0m" \
			                  "\x1b[1m\x1b[37m" "$1" "\x1b[0m" >&2
	else
		printf "*** %s\n" "$1" >&2
	fi
}

# A famosa função "Oups"para irmos falando ao usuário quando as coisas poderem dar errado
function oups() {
	set -e
	if [[ -t 1 ]]; then
		printf "%b!!!%b %b%s%b\n" "\x1b[1m\x1b[31m" "\x1b[0m" \
		                          "\x1b[1m\x1b[37m" "$1" "\x1b[0m" >&2
	else
		printf "!!! %s\n" "$1" >&2
	fi
}

instalar(){

    if [ "$1" == "packer" ]; then
      info "==> Instalando o $1..."
      # Add Hashicorp's official GPG key
      sudo apt-get update
      sudo apt-get install ca-certificates curl gnupg # Falta propositalmente o -y 
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
      sudo chmod a+r /etc/apt/keyrings/hashicorp.gpg

      # Add the repository to Apt sources
      echo \
        "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" main" | \
        sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
      sudo apt-get update

      # To install the latest version
      sudo apt install packer -y

    elif [ "$1" == "kvm" ]; then
      info "==> Instalando o $1"
      sudo apt update
      sudo apt install -y qemu qemu-kvm qemu-efi qemu-utils qemu-block-extra \
              libvirt-daemon libvirt-clients bridge-utils virt-manager qemu-system \
              qemu-utils qemu-block-extra libvirt-daemon-system cpu-checker \
              libguestfs-tools libosinfo-bin dnsmasq-base ebtables libvirt-dev \
                      virtinst virt-top genisoimage

      aviso "==> Ligar o Libvirt"
      sudo gpasswd -a $USER libvirt
      sudo systemctl start libvirtd
      sudo systemctl enable --now libvirtd

      aviso "==> Compatibilizar o Libvirt com o Terraform..."
      sudo sed -i.bak -e 's/#security_driver = "selinux"/security_driver = "none"/' /etc/libvirt/qemu.conf
      sudo systemctl restart libvirtd

      aviso "==> Ligar o modulo vhost_net..."
      sudo modprobe vhost_net
      echo vhost_net | sudo tee -a /etc/modules

      # nmcli device status
      #sudo cp local/scripts/kvm/interfaces /etc/network/interfaces
      #sudo reboot

      info "==> Instalando o Cockpit..."
      sudo apt install cockpit -y
      sudo systemctl enable --now cockpit.socket

    elif [ "$1" == "vagrant" ]; then
      info "==> Instalando o $1..."
      wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
      echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
      sudo apt update && sudo apt install vagrant -y

      aviso "==> Instalando os requerimentos dos plugins do $1"

      sudo cp /etc/apt/sources.list /etc/apt/sources.list."$(date +"%F")"
      sudo sed -i -e '/^# deb-src.*universe$/s/# //g' /etc/apt/sources.list
      sudo apt-get -y update

      sudo apt-get -y build-dep vagrant 

      #sudo apt-get -y install nfs-kernel-server
      #sudo systemctl enable --now nfs-server

      #sudo apt-get -y build-dep vagrant ruby-libvirt
      #sudo apt-get -y install ebtables dnsmasq-base

      #sudo apt install -y \
      #    ruby-dev ruby-libvirt libxslt-dev libxml2-dev zlib1g-dev libvirt-dev zlib1g-dev

      vagrant plugin install vagrant-libvirt
      #vagrant plugin install vagrant-mutate
    
    elif [ "$1" == "terraform" ]; then
      info "==> Instalando o Terraform"
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

    fi
}

checkar(){
  info "==> Checkando se o $1 está instalado..."
  if ! command -v $1 &> /dev/null;
  then
    instalar $1
  fi
}

iniciar(){
    if [ "$1" == "terraform" ]; then
        aviso "==> Iniciando o $1..."
        if [ ! -f ".terraform.lock.hcl" ]; then terraform init; fi
        if [ ! -f "vps" ]; then 
            terraform plan -out=vps
            terraform apply "vps"
            aviso "==> Aguardando 15 segundos para que o $1 plan "vps" seja completamente aplicado e tenhamos um IP disponivel..."
            sleep 15
            terraform plan -out=vps
            terraform apply "vps"

        fi
        if [ ! -f "iso/jammy-server-cloudimg-amd64.img" ]; then
            aviso "==> Iniciando o download da jammy-server-cloudimg-amd64.img..."
            wget http://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img -O iso/jammy-server-cloudimg-amd64.img
            aviso "==> Customizar a jammy-server-cloudimg-amd64.img com a --root-password password:neoricalex ..."
            sudo virt-customize -a iso/jammy-server-cloudimg-amd64.img --root-password password:neoricalex

        fi

    elif [ "$1" == "vps" ]; then
        aviso "==> Iniciando o $1..."
        sudo apt install -y net-tools sshpass
        ip_vps=$(for mac in `sudo virsh domiflist vps |grep -o -E "([0-9a-f]{2}:){5}([0-9a-f]{2})"` ; do sudo arp -e |grep $mac  |grep -o -P "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}" ; done)
        sshpass -p neoricalex ssh -tt -o StrictHostKeyChecking=accept-new neoricalex@$ip_vps 'rm iniciar_nfdos*; wget https://raw.githubusercontent.com/neoricalex/dev/main/src/virtualhost/localhost/scripts/iniciar_nfdos.sh; bash iniciar_nfdos.sh'
        #sshpass -p neoricalex ssh -tt -o StrictHostKeyChecking=accept-new neoricalex@$ip_vps 'cd nfdos; git config --global user.email "you@example.com"; git config --global user.name "Your Name"; git add . ; git commit -m "Commit Automatico!"; git pull; bash compilar_nfdos.sh'
        #ssh -tt neoricalex@$ip_vps 'cd nfdos && sudo bash build.sh'
    fi

}
checkar kvm
checkar terraform
cd localhost
iniciar terraform
#terraform destroy -auto-approve
iniciar vps
#terraform destroy -auto-approve
cd ..

#sudo modprobe nbd max_part=8
#sudo qemu-nbd --connect=/dev/nbd0 /var/lib/libvirt/images/vps-vm-disk
#sudo qemu-nbd --disconnect /dev/nbd0