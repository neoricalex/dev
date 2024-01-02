# /etc/qemu-web-desktop/config.pl: Configuration for qemu-web-desktop
#
# Think about editing the /usr/share/qemu-web-desktop/html/desktop/index.html
# to comment/un-comment sections (GPU, oneshot, user scripts, ...).
#
# When relevant, the equivalent OpenStack naming is indicated (as documented 
# in https://docs.openstack.org/nova/latest/configuration/config.html)

# WHERE THINGS ARE -------------------------------------------------------------

# name of service, used as directory and e.g. http://127.0.0.1/desktop
$config{service}                  = "qemu-web-desktop";

# full path to Apache HTML root
#   Apache default on Debian is /var/www/html
$config{dir_html}                 = "/usr/share/$config{service}/html";

# full path to root of the service area
#   e.g. /var/www/html/desktop
$config{dir_service}              = "/var/lib/$config{service}";

# full path to machines (ISO,VM)
$config{dir_machines}             = "$config{dir_service}/machines";

# full path to snapshots and temporary files OpenStack DEFAULT.instances_path
$config{dir_snapshots}            = "$config{dir_service}/snapshots";

# full path to snapshot config/lock files. Must NOT be accessible from http://
#   e.g. /tmp to store "desktop_XXXXXXXX.json" files
#
# NOTE: apache has a protection in:
#   /etc/systemd/system/multi-user.target.wants/apache2.service
#   PrivateTmp=true
# which creates a '/tmp' in e.g. /tmp/systemd-private-*-apache2.service-*/
$config{dir_cfg}                  = File::Spec->tmpdir();  # OpenStack DEFAULT.tempdir

# full path to noVNC, e.g. "/usr/share/novnc". Must contain "vnc.html"
$config{dir_novnc}                = "/usr/share/novnc";
# websockify command, e.g. "/usr/bin/websockify"
$config{dir_websockify}           = "websockify";

# MACHINE DEFAULT SETTINGS -----------------------------------------------------

# max session life time in sec. 1 day is 86400 s. Highly recommended.
#   Use 0 to disable (infinite). This value bounds the selectable life-time from the form.
$config{snapshot_lifetime}        = 86400*4; 

# default nb of CPU per session.
$config{snapshot_alloc_cpu}       = 1; # OpenStack DEFAULT.initial_cpu_allocation_ratio ?

# default nb of RAM per session (in GB).
$config{snapshot_alloc_mem}       = 4; # OpenStack DEFAULT.initial_ram_allocation_ratio ?

# default size of disk per session (in GB). Only for ISO machines.
$config{snapshot_alloc_disk}      = 10.0; # OpenStack DEFAULT.initial_disk_allocation_ratio ?

# default machine to run
$config{machine}                  = 'slax.iso';

# QEMU executable. Adapt to the architecture you run on.
$config{qemu_exec}                = "qemu-system-x86_64";

# QEMU video driver, can be "qxl" or "vmware"
$config{qemu_video}               = "qxl"; 

# Boot delay before displaying the URL [sec]
$config{boot_delay}               = 5;

# set a list of mounts to export into VMs.
# these are tested for existence before mounting. The QEMU mount_tag is set to 
# the last word of mount path prepended with 'host_'.
# Use e.g. `mount -t 9p -o trans=virtio,access=client host_media /mnt/media` in guest.
my @mounts                        = ('/mnt','/media');
$config{dir_mounts}               = [@mounts];

# SERVICE CONTRAINTS -----------------------------------------------------------

# max amount [0-1] of CPU load. Deny service when above.
$config{service_max_load}         = 0.8  ;

# max number of active sessions. Deny service when above.
$config{service_max_session_nb}   = 10; # OpenStack config DEFAULT.max_concurrent_snapshots ?

# max number of active sessions per user. Deny service when above.
$config{service_max_session_nb_per_user}   = 3;

# max number of active CPU fraction per user. Deny service when above.
$config{service_max_cpu_fraction_nb_per_user}= 0.3;

# max number of active memory fraction per user. Deny service when above.
$config{service_max_mem_fraction_nb_per_user}= 0.3;

# the base port for the VNC screen. 
# the VNC port is chosen randomly up to service_port_vnc+service_max_session_nb
$config{service_port_vnc}         = 5901; # OpenStack config vmware.vnc_port

# the port where the VNC screens are broadcasted (e.g. 6080 for websockify)
# use 0 to select a random base port
$config{service_port}             = 6080; # OpenStack vnc.novncproxy_port
$config{service_port_multiple}    = 0;    # when true, use one websockify per instance
  # 0: websockify uses only one port (recommended, except when using 'oneshot' sessions)
  # 1: the websockify port is chosen randomly up to service_port+service_max_session_nb

# in case there is a proxy server to pass, specify it here
$config{service_proxy}            = "";   # "http://195.221.0.35:8080/";

# a list of other servers to be used when current one does not have enough resources
# can be a server name, IP, including protocol (http, https). Indicate a 
# comma-separated list. All of URL, server names and IP are allowed. 
# e.g. 'https://grades-01.synchrotron-soleil.fr,https://re-grades-01.exp.synchrotron-soleil.fr';
$config{fallback_servers}         = ''; 

# the max length of user customization script (URL length or direct exec: commands)
$config{service_max_script_length}= 65535; # e.g. 65535

# Scripts to execute when any VM starts. Supports Linux and Windows guests.
# see: https://libguestfs.org/virt-customize.1.html --commands-from-file
# Can be specifyed as:
#   "http://some/url"
#   "/some/local/path/to/script"
#   "exec: some commands" separated with EOL or ';'
#   "virt-customize: commands" separated with EOL
# The symbols `@USER@` `@PW@` `@SESSION_NAME@` and `@VM@` are replaced by the user 
# name, password, the session ID, and the virtual machine name. 
#
# In addition, when the above script description is preceded by `if(EXPR):` 
# the given expression is evaluated with Perl and the script is only executed
# when result is True. The `EXPR` condition may use the `@...@` symbols above.
#
# Scripts are executed at boot, in background, as root.
# It is possible to define as many scripts as needed. Strings are separated by ','
my @config_scripts=("");
$config{config_script}            = [@config_scripts];

# a list of GPU PCI addresses NOT to be used, as returned by lspci e.g. 
# "06:05.0,00:1b.0". Items can be separated by spaces or commas.
$config{gpu_blacklist}            = "";


# USER AUTHENTICATION ----------------------------------------------------------

# the name of the SMTP server, and optional port.
#   when empty, no email is needed
#   The SMTP server is used to send emails, and check user credentials.
$config{smtp_server}              = ''; # "smtp.synchrotron-soleil.fr"; 

# the SMTP port e.g. 465, 587, or left blank
# and indicate if SMTP uses encryption
$config{smtp_port}                = 587; 
$config{smtp_use_ssl}             = 'starttls'; # 'starttls' or blank

# the name of the IMAP server, and optional port.
#   when empty, no email is needed
#   The IMAP server is used to check user credentials.
$config{imap_server}              = ''; # 'smtp.synchrotron-soleil.fr'; 

# the IMAP port e.g. 993, or left blank
$config{imap_port}                = 993; 

# the name of the LDAP server.
#   The LDAP server is used to check user credentials.
$config{ldap_server}              = '';     # 195.221.10.1'; 
$config{ldap_port}                = 389;    # default is 389
$config{ldap_domain}              = 'EXP';  # DC

# the email address of the sender of the messages on the SMTP server. 
$config{email_from}               = ''; # 'luke.skywalker@synchrotron-soleil.fr';

# the password for the sender on the SMTP server, or left blank when none.
$config{email_passwd}             = "";

# the method to use for sending messages. Can be:
#   auto    use the provided smtp/email settings to decide what to do
#   SSL     use the SMTP server, port SSL, and email_from with email_passwd
#   port    just use the server with given SMTP port
#   simple  just use the server, and port 25
$config{email_method}             = "auto";

# how to check users

# the email authentication is less secure. Use it with caution.
#   the only test is for an "email"-like input, but not actual valid / registered email.
#   When authenticated with email, only single-shot sessions can be launched.
$config{check_user_with_email}    = 0;  # send URL via email.
$config{check_user_with_imap}     = 0;  

# In case of IMAP error "Unable to connect to <server>: SSL connect attempt 
# failed error:1425F102:SSL routines:ssl_choose_client_version:unsupported protocol.
# See:
# https://stackoverflow.com/questions/53058362/openssl-v1-1-1-ssl-choose-client-version-unsupported-protocol

$config{check_user_with_smtp}     = 0;
$config{check_user_with_ldap}     = 0;

# Custom user authentication.
#   When defined, this authenticator is ALWAYS executed (whatever be the other 
#   authenticator results).
#
# First, specify a function that should get (user, pw, authenticated, session_ref) 
# as arguments and return a string starting by "SUCCESS" or "FAILED". The default  
# return value should be the previous authenticator results.
# Any "SUCCESS" in the returned string fully qualifies the authentication.
#
#  sub check_user_func {
#    my $user          = shift;
#    my $pw            = shift;
#    my $authenticated = shift; # previous authenticator results
#    my $session_ref   = shift;  
#    if (not $session_ref) { return $authenticated; }
#    my %session       = %{ $session_ref };
#    my $res           = "";
#
#    res = "SUCCESS: [Custom] $user authenticated.";
#
#    res = "FAILED: [Custom] $user failed authentication.";
#
#    return "$authenticated and $res";
#  }
#
# Then send its reference to the configuration:
#
#   $config{check_user_custom} = \&check_user_func;
#
# or directly as an anonymous function
#
#   $config{check_user_custom} = sub { };

$config{check_user_custom}   = "";


# Encryption (HTTPS). Set these to valid 'crt' and 'key' files with proper certificates
# to allow secured encryption of websockify/novnc. The CRT and KEY should both be set.
# OpenStack DEFAULT.key DEFAULT.cert
$config{certificate_crt} = ''; # '/etc/apache2/certificate/apache-certificate.crt';
$config{certificate_key} = ''; # '/etc/apache2/certificate/apache.key';

# set the list of 'admin' users that can access the Monitoring pages.
# these must also be identified with their credentials.
my @admin = ('');              # 'picca','farhie','roudenko','bac','ounsy','bellachehab'
$config{user_admin} = [@admin];

# KEEP THIS LINE!
1;
