% QWDCTL(1)
% Roland Mas
% April 2021

# NAME

qwdctl - Control qemu-web-desktop

# SYNOPSIS

**qwdctl** *keyword*

# DESCRIPTION

**qwdctl** is a simple script that downloads virtual machine images
for use with **qemu-web-desktop** and/or refreshes the list of
available images so that **qemu-web-desktop** can display it in its
web interface.

Supported virtual machine formats are: ISO, QCOW2, VDI, VMDK, RAW, VHD/VHDX, QED

Each entry in the configuration file `/etc/qemu-web-desktop/machines.conf` 
spans on 3 lines:

-  [name.ext] 
-  url=[URL to virtual machine disk, optional]
-  description=[description to be shown in the service page] 

Images listed in the configuration file without a `url=` parameter are
expected to be downloaded by hand and installed into
`/var/lib/qemu-web-desktop/machines` by the local administrator. Then, just 
specify the [name.ext] and description.

# SUBCOMMANDS

**download**
:   Downloads virtual machine images referenced in the
    `/etc/qemu-web-desktop/machines.conf` file. A **refresh** is automatically
    launched afterwards.

**refresh**
:   Regenerates the list of available images based on the
    `/etc/qemu-web-desktop/machines.conf` file. 
    The generated file is e.g. `/var/lib/qemu-web-desktop/machines.html`
    which should be linked into `/usr/share/qemu-web-desktop/html/desktop/`.
    
**status**
:   List the running sessions

# FILES

- /etc/qemu-web-desktop/machines.conf
- /var/lib/qemu-web-desktop/machines.html
- /var/lib/qemu-web-desktop/machines
- /usr/share/qemu-web-desktop/html/desktop
