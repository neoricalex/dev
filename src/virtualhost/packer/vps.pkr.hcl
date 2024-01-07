variable "vm_name" {
  type    = string
  default = "vps"
}
variable "version" {
  type    = string
  default = "v0.0.1"
}
variable "ssh_username" {
  type    = string
  default = "neoricalex"
}
variable "ssh_password" {
  type      = string
  default   = "neoricalex"
  sensitive = true
}
variable "cpus" {
  type    = string
  default = "2"
}
variable "memory" {
  type    = string
  default = "2048"
}
variable "disk_size" {
  type    = string
  default = "25000"
}
variable "iso_url" {
  type    = string
  default = "img/ubuntu-22.04-server-cloudimg-amd64.img"
}
variable "iso_checksum" {
  type    = string
  default = "http://cloud-images.ubuntu.com/releases/22.04/release/SHA256SUMS"
}
variable "iso_checksum_type" {
  type    = string
  default = "file"
}
variable "output_image_type" {
  type    = string
  default = "qcow2"
}
variable "output_dir" {
  type    = string
  default = "output"
}
variable "qemu_accelerator" {
  type    = string
  default = "kvm"
}
variable "headless" {
  type    = bool
  default = true
}
variable "use_backing_file" {
  type    = bool
  default = false
}
variable "boot_wait" {
  type    = string
  default = "3m"
}
variable "vnc_bind_address" {
  type    = string
  default = "127.0.0.1"
}
variable "use_default_display" {
  type    = bool
  default = false
}

locals {
  build_time = formatdate("YYYY-MM-DD-hhmmss", timestamp())
  vm_name    = "${var.vm_name}-${var.version}"
  // output_dir = "${var.output_dir}/${var.vm_name}-qemu-${var.version}-${local.build_time}"
  output_dir = "${var.output_dir}"
}

source "qemu" "template" {
  vm_name   = "${local.vm_name}"
  cpus      = "${var.cpus}"
  memory    = "${var.memory}"
  disk_size = "${var.disk_size}"

  iso_url      = "${var.iso_url}"
  iso_checksum = "${var.iso_checksum_type}:${var.iso_checksum}"

  communicator = "ssh"
  ssh_timeout  = "1h"
  ssh_username = "${var.ssh_username}"
  ssh_password = "${var.ssh_password}"

  output_directory = "${local.output_dir}"
  shutdown_command = "echo '${var.ssh_password}' | sudo -S shutdown -P now"
  shutdown_timeout = "15m"

  boot_wait = "${var.boot_wait}"

  accelerator = "${var.qemu_accelerator}"

  format           = "${var.output_image_type}"
  use_backing_file = var.use_backing_file
  disk_image       = true
  disk_compression = true

  headless            = var.headless
  use_default_display = var.use_default_display
  vnc_bind_address    = var.vnc_bind_address

  cd_files = ["./cd_files/user-data", "./cd_files/meta-data", "./cd_files/network-config"]
  cd_label = "cidata"

  qemuargs = [
    ["-serial", "mon:stdio"],
    ["-device", "virtio-net,netdev=forward,id=net0"],
    ["-netdev", "user,hostfwd=tcp::{{ .SSHHostPort }}-:22,id=forward"],
  ]

}

build {
  sources = ["source.qemu.template"]

  # wait for cloud-init to successfully finish
  provisioner "shell" {
    inline = [
      "cloud-init status --wait > /dev/null 2>&1"
    ]
  }

  #provisioner "shell" {
  #  inline = [
  #    "#touch ~/hello-world"
  #  ]
  #}

  # add qcow2 image an extension
  post-processor "shell-local" {
    keep_input_artifact = true
    inline = [
      "cp ${local.output_dir}/${local.vm_name} ${local.output_dir}/${local.vm_name}.qcow2",
      "qemu-img resize ${local.output_dir}/${local.vm_name}.qcow2 +25G",
    ]
  }
  provisioner "shell" {
    execute_command   = "echo '${var.ssh_password}' | {{ .Vars }} sudo -S -E sh -eux '{{ .Path }}'"
    expect_disconnect = true
    scripts = [
      "./scripts/disable-updates.sh",
      "./scripts/diversos.sh",
    ]
  }

  post-processor "vagrant" {
    keep_input_artifact = true
    compression_level    = 6
    provider_override   = "libvirt"
    output = "${local.output_dir}/${local.vm_name}.box"
}

  # Convert Qemu Image (qcow2) to Hyper-V (vhdx) image
  # Convert Qemu Image (qcow2) to VMWare (vmdk) image
  # Convert Qemu Image (qcow2) to Virtualbox (vdi) image
  //post-processor "shell-local" {
  //  keep_input_artifact = true
  //  inline = [
  //   "qemu-img convert ${local.output_dir}/${local.vm_name}.qcow2 -O vhdx -o subformat=dynamic ${local.output_dir}/${local.vm_name}.vhdx",
  //   "qemu-img convert ${local.output_dir}/${local.vm_name}.qcow2 -O vmdk ${local.output_dir}/${local.vm_name}.vmdk",
  //   "qemu-img convert ${local.output_dir}/${local.vm_name}.qcow2 -O vdi ${local.output_dir}/${local.vm_name}.vdi",
  //  ]
  //}

  # compress output images
  // post-processor "shell-local" {
  //   keep_input_artifact = true
  //   inline = [
  //     "gzip ${local.output_dir}/* ",
  //   ]
  // }

}