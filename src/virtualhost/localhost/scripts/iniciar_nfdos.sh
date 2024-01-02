#!/usr/bin/env sh

# NFDOS
export NFDOS=$HOME/nfdos
export NFDOS_HOME=$NFDOS/builder
export NFDOS_VERSAO="0.5.0"
# NFDOS Core
export NFDOS_ROOT=$NFDOS_HOME/core
export NFDOS_ROOTFS=$NFDOS_ROOT/rootfs
export NFDOS_DISCO=$NFDOS_ROOT/nfdos.img

set -e

# Função para irmos informando o usuário via terminal (CLI) aquilo que estamos a fazer
function info() {
	if [[ -t 1 ]]; then
		printf "%b$USER@$HOSTNAME:%b %b%s%b\n" "\x1b[1m\x1b[32m" "\x1b[0m" \
		                          "\x1b[1m\x1b[37m" "$1" "\x1b[0m"
	else
		printf "*** %s\n" "$1"
	fi
}
# Função para irmos avisando o usuário via terminal (CLI) aquilo que estamos a fazer
function aviso() {
	if [[ -t 1 ]]; then
		printf "%b$USER@$HOSTNAME:%b %b%s%b\n" "\x1b[1m\x1b[33m" "\x1b[0m" \
			                  "\x1b[1m\x1b[37m" "$1" "\x1b[0m" >&2
	else
		printf "*** %s\n" "$1" >&2
	fi
}

# A famosa função "Oups"para irmos falando ao usuário quando as coisas poderem dar errado
function oups() {
	set -e
	if [[ -t 1 ]]; then
		printf "%b$USER@$HOSTNAME:%b %b%s%b\n" "\x1b[1m\x1b[31m" "\x1b[0m" \
		                          "\x1b[1m\x1b[37m" "$1" "\x1b[0m" >&2
	else
		printf "!!! %s\n" "$1" >&2
	fi
}

info "==> Checkando se a pasta $NFDOS existe..."
if [ ! -d "$NFDOS" ]; then
    git clone https://github.com/neoricalex/nfdos.git
fi

info "==> Checkando se a $NFDOS_ROOT/nfdos.iso existe"
if [ ! -f "$NFDOS_ROOT/nfdos.iso" ]; then
	aviso "==> Entrando na pasta nfdos e excutando o compilar_nfdos.sh..."
	cd nfdos && bash compilar_nfdos.sh
else
	aviso "==> A $NFDOS_ROOT/nfdos.iso existe"
fi


# https://github.com/neoricalex/kvm_packer
# https://computingforgeeks.com/how-to-provision-vms-on-kvm-with-terraform/
# https://blog.stephane-robert.info/docs/infra-as-code/provisionnement/terraform/premiere-infra/
# https://github.com/terraform-google-modules/terraform-google-bootstrap
# https://phoenixnap.com/kb/build-linux-kernel
# https://linuxconfig.org/grub-compile-from-source-on-linux