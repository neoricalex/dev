#!/usr/bin/env sh

export DEBIAN_FRONTEND=noninteractive

echo "==> Instalar o qemu guest agent"
apt install -y qemu-guest-agent

echo "==> Instalar o git"
apt install -y git

echo "==> Limpar"
apt -y autoremove
