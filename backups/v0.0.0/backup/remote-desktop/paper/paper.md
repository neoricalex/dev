---
title: 'DARTS: The Data Analysis Remote Treatment Service'
tags:
  - remote desktop
  - data analysis as a service (DAaaS)
  - qemu/kvm
  - virtualization
authors:
  - name: Emmanuel Farhi
    orcid: 0000-0002-8508-8106
    equal-contrib: true
    affiliation: 1
affiliations:
  - name: Synchrotron SOLEIL, France
    index: 1
date: 31 May 2023
bibliography: paper.bib
command: pandoc --bibliography=paper.bib  -o paper.pdf paper.md
---

# Summary

This paper presents the Data Analysis Remote Treatment Service (DARTS), an open-source
remote desktop service that launches on-demand virtual machines in the cloud,
and displays them in a browser. The released environments can be used for scientific
data treatment, for example. DARTS can be deployed and configured within minutes on a server,
and can run any virtual machine. The service is fully configurable, supports GPU
allocation, is scalable and resilient within a farm of servers. DARTS is
designed around simplicity and efficiency. It targets laboratories and
facilities that wish to quickly deploy remote data analysis solutions without
investing in complex hypervisor infrastructures. DARTS is operated at Synchrotron SOLEIL, France, in order to provide a ready-to-use data treatment service for X-ray experiments.

# Statement of need

Synchrotron radiation facilities and other large-scale research facilities generate increasingly massive and complex amounts of data due to the nature of their experiments. This trend, referred to as the "data deluge," [@Wang:2018] is closely linked to the evolution of technological bricks such as detectors, storage, network, and computing capability.

To overcome this challenge, a sensible solution is to provide suitable software on powerful computers with an interactive remote access without the need for data transportation. By doing so, researchers can efficiently access and analyse their data without requiring expensive local hardware or software. Data analysis is a vital preliminary step in the production of scientific publications, which are the actual metric upon which research facilities are evaluated in their societal impact.

While the Jupyter ecosystem [@Kluyver:2016; @Randles:2017] is now widely used for scientific data analysis, it still requires users to have basic knowledge of commands and scripting, and does not allow to launch full GUI applications. Alternatively, a number of commercial solutions exist, such as Amazon WorkSpaces [@AWS:2023], FastX [@FastX:2023], and NX/NoMachine [@NoMachine:2023]. Other community related software exist, such as the VISA platform [@VISA:2021], the ISIS Data Analysis as a Service [@IDAAS:2023], and the CoESRA service [@GURU2016221], but none of them is fully open-source and easily installable and deployable.

The Data Analysis Remote Treatment Service (DARTS) is a lightweight, on-demand, cloud service to instantiate and display ready-to-use complete scientific software environments.

# Implementation

The conceptual design of the Data Analysis Remote Treatment Service (DARTS) is based on the following sequential steps:

1. Identify a user and computing requirements from a web form (landing page).
2. Launch a copy of a master virtual machine.
3. Display it in a browser. 

The DARTS service starts from the landing page, in which a user feeds information (credentials, computing requirements), and selects one of the available environments (from the `machines.conf` file). This information is collected by the main script (`qemu-web-desktop.pl`), which imports the main configuration `config.pl` and takes care of the whole service steps (instantiation, monitoring, self-cleaning). A snapshot of the selected master virtual machine environment is created, to hold user-level changes in the instance. It is then started and attached to the QEMU embedded VNC server. A start-up configuration script can be injected via `virt-customize` [@Richard:2011] to be executed during the boot process. A websocket exposes the internal VNC port as a URL, and displayed with noVNC. The result page is generated with the proper URL for the user to connect. The performance of the virtualization layer reaches native speed for both CPU and GPU, as well as for disk and network.

Relying on a steady software stack (Apache2, Perl, QEMU) with limited dependencies, DARTS is easy to deploy and operate. In practice, the only DARTS-related maintenance action consists of adding or updating the virtual machines. The simplicity of DARTS only requires a fraction of a single staff member for its administration.

# Research applications

DARTS is especially suited for small to medium research laboratories and facilities willing to quickly deploy a remote data analysis infrastructure, with minimal maintenance. 

At the Synchrotron SOLEIL, the service has been operated continuously since 2020 for our users on two servers equiped with GPUs [@DARTS:2023]. Our current production environments are a default Debian system holding X-ray data treatment software (currently 631 scientific applications and libraries), a reduced system meant to be distributed to the users as they leave the facility, and a Windows 10 system with commercial software. Our Debian images are built automatically via a set of shell scripts [@Picca:2022]. This choice is meant to minimize our maintenance. These images mount a persistent user folder (also accessible via a JupyterHub service), as well as the experimental data storage via NFS, CIFS/Samba, and SSHFS. In addition, information from the authentication service (LDAP) is used to customize each instance and install specific files and applications on top of existing master virtual machines.

# Author contribution statement

Conceptualization, coding, development and paper writing by Emmanuel Farhi. 

# Acknowledgements

We thank the members of the Data Reduction and Analysis Group at Synchrotron SOLEIL, and particularly Frédéric-Emmanuel Picca for his continuous support during the development of this project. We also thank Roland Mas, from the GNURANDAL company, for the Debian packaging. This project has received support from the European Union’s Horizon 2020 research and innovation programme under grant agreement No 957189 “BIG-MAP” [@Vegge:2020].

# References

