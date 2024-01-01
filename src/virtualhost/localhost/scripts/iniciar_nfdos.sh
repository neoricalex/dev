#!/usr/bin/env sh

# Função para irmos informando o usuário via terminal (CLI) aquilo que estamos a fazer
function info() {
	if [[ -t 1 ]]; then
		printf "%b$USER@$HOSTNAME:%b %b%s%b\n" "\x1b[1m\x1b[32m" "\x1b[0m" \
		                          "\x1b[1m\x1b[37m" "$1" "\x1b[0m"
	else
		printf "==> %s\n" "$1"
	fi
}

info "==> Checkando se a pasta nfdos existe..."
if [ ! -d "nfdos" ]; then
    git clone https://github.com/neoricalex/nfdos.git
fi

info "==> Entrando na pasta nfdos e excutando o compilar_nfdos.sh..."
cd nfdos && bash compilar_nfdos.sh

# https://github.com/neoricalex/kvm_packer
# https://computingforgeeks.com/how-to-provision-vms-on-kvm-with-terraform/
# https://blog.stephane-robert.info/docs/infra-as-code/provisionnement/terraform/premiere-infra/
# https://github.com/terraform-google-modules/terraform-google-bootstrap
# https://phoenixnap.com/kb/build-linux-kernel
# https://linuxconfig.org/grub-compile-from-source-on-linux