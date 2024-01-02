# Defining VM Volume
resource "libvirt_volume" "vps-qcow2" {
  name = "vps-v0.0.1.qcow2"
  pool = "default" # List storage pools using virsh pool-list
  #source = "https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2"
  source = "../docker/discos/vps-v0.0.1.qcow2"
  format = "qcow2"
}

# Define KVM domain to create
resource "libvirt_domain" "vps" {
  name   = "vps"
  memory = "4096"
  vcpu   = 2

  network_interface {
    network_name = "default" # List networks with virsh net-list
  }

  disk {
    volume_id = "${libvirt_volume.vps-qcow2.id}"
  }

  console {
    type = "pty"
    target_type = "serial"
    target_port = "0"
  }

  graphics {
    type = "spice"
    listen_type = "address"
    autoport = true
  }
}

# Output Server IP
output "ip" {
  value = "${libvirt_domain.vps.network_interface.0.addresses.0}"
}