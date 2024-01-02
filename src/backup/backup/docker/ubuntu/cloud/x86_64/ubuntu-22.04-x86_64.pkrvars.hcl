efi_boot          = true
efi_firmware_code = "/usr/share/OVMF/OVMF_CODE.fd"
efi_firmware_vars = "/usr/share/OVMF/OVMF_VARS.fd"

iso_checksum      = "file:http://cloud-images.ubuntu.com/releases/22.04/release/SHA256SUMS"
iso_url           = "http://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"

vm_name           = "ubuntu-22.04-x86_64"
headless         = true
qemu_accelerator = "none"
vnc_bind_address = "0.0.0.0"
cpus      = "2"
memory    = "2048"
disk_size = "10000"

boot_wait = "3m"