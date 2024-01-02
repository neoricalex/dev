#!/usr/bin/perl

# Main qemu-web-desktop service script.
#
#   You must edit the /etc/qemu-web-desktop/config.pl file to configure the service.
#   Think about editing the /usr/share/qemu-web-desktop/html/desktop/index.html
#   to comment/un-comment sections (GPU, oneshot, user scripts, ...).
#
#   When relevant, the equivalent OpenStack naming is indicated (as documented 
#   in https://docs.openstack.org/nova/latest/configuration/config.html)
#
# This script is triggered by a FORM or runs as a script.
# to test this script, launch from the project root level something like:
#
#   cd remote-desktop
#   perl src/cgi-bin/qemu-web-desktop.pl --dir_service=src/html/desktop \
#     --dir_html=src/html --dir_snapshots=/tmp \
#     --dir_machines=src/html/desktop/machines/ --oneshot=1
#
# Then follow printed instructions in the terminal:
# open a browser at something like:
# - http://localhost:38443/vnc.html?host=localhost&port=38443
#
# The script is effectively used in two steps (when executed as a CGI):
# - The HTML FORM launches the script as a CGI which starts the session.
#   QEMU and VNC are initiated, the message is displayed, but does not wait for
#   the end of the session.
#
# A running session with an attached JSON file can be stopped with:
#
#   perl qemu-web-desktop.pl --session_stop=/path/to/json
#
# To stop and clear all running sessions use:
#
#   perl qemu-web-desktop.pl --dir_snapshots=/tmp  --session_purge=1
#
# To monitor all running sessions, use:
#
#   perl src/cgi-bin/qemu-web-desktop.pl --service_monitor=1
#
#
# Requirements
# ============
# sudo apt install apache2 libapache2-mod-perl2
# sudo apt install qemu-kvm bridge-utils qemu iptables dnsmasq libguestfs-tools
# sudo apt install novnc websockify
#
# sudo apt install libsys-cpu-perl libsys-cpuload-perl libsys-meminfo-perl \
#   libcgi-pm-perl liblist-moreutils-perl libnet-dns-perl libjson-perl \
#   libproc-background-perl libproc-processtable-perl libemail-valid-perl \
#   libnet-smtps-perl libmail-imapclient-perl libnet-ldap-perl libemail-valid-perl \
#   libwww-perl liburi-perl
# optional: libtext-qrcode-perl
#
# (c) 2020- Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.
# https://gitlab.com/soleil-data-treatment/remote-desktop



# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    use CGI::Carp('fatalsToBrowser');
}

# dependencies -----------------------------------------------------------------

use strict;
use warnings qw( all );

use CGI;                # use CGI.pm
use File::Temp      qw/ tempdir tempfile /;
use File::Path      qw/ rmtree  /;
use File::Basename  qw/ fileparse dirname /;
use List::MoreUtils qw(uniq); # liblist-moreutils-perl
use List::Util;
use Sys::CPU;           # libsys-cpu-perl           for CPU::cpu_count
use Sys::CpuLoad;       # libsys-cpuload-perl       for CpuLoad::load
use JSON;               # libjson-perl              for JSON
use IO::Socket::INET;
use IO::Socket::IP;
use Sys::MemInfo;
use Proc::Background;   # libproc-background-perl   for Background->new
use Proc::ProcessTable; # libproc-processtable-perl
use Proc::Killfam;      # libproc-processtable-perl for killfam (kill pid and children)

use Net::SMTPS;         # libnet-smtps-perl         for smtp user check and emailing
use Mail::IMAPClient;   # libmail-imapclient-perl   for imap user check
use Net::LDAP;          # libnet-ldap-perl          for ldap user check
use Email::Valid;       # libemail-valid-perl
use LWP::UserAgent;     # libwww-perl               for new and get(URL)
use Net::Ping;          # perl                      to test server up-down
use URI;                # liburi-perl               to split URL into parts


# see http://honglus.blogspot.com/2010/08/resolving-perl-cgi-buffering-issue.html
$| = 1;
CGI->nph(1);

# use https://perl.apache.org/docs/2.0/api/Apache2/RequestIO.html
# for flush with CGI
my $r = shift;
if (not $r or not $r->can("rflush")) {
  push @ARGV, $r; # put back into ARGV when not a RequestIO object
}

use constant IS_MOD_PERL => exists $ENV{'MOD_PERL'};
use constant IS_CGI      => IS_MOD_PERL || exists $ENV{'GATEWAY_INTERFACE'};

# ------------------------------------------------------------------------------
#                 service configuration: tune for your needs
# ------------------------------------------------------------------------------

# NOTE: This is where you can tune the default service configuration.
#       Adapt the path, and default VM specifications.

# we use a Hash to store the configuration. This is simpler to pass to functions.
our %config;

$config{version}                  = "23.06.22";  # year.month.day

my $dirname = dirname(__FILE__);

if (-e '/etc/qemu-web-desktop/config.pl') {
  require '/etc/qemu-web-desktop/config.pl';
} elsif (-e "$dirname/../config.pl") {
  require "$dirname/../config.pl";
} else {
  die "Can not find config.pl (e.g. /etc/qemu-web-desktop/config.pl or $dirname/../config.pl";
}

# search detached GPU (via vfio-pci). Only use video part, no audio.
{
  # can be a VGA adaptor or a 'controller'
  my ($device_pci1, $device_model1, $device_name1) = pci_devices("lspci -nnk","vga","vfio");
  my ($device_pci2, $device_model2, $device_name2) = pci_devices("lspci -nnk","controller","vfio");
  
  my @gpu_pci  = (@$device_pci1,   @$device_pci2);
  my @gpu_model= (@$device_model1, @$device_model2);
  my @gpu_name = (@$device_name1,  @$device_name2);
  $config{gpu_model}             = \@gpu_model;
  $config{gpu_name}              = \@gpu_name;
  $config{gpu_pci}               = \@gpu_pci;
}

# ------------------------------------------------------------------------------
# update config with input arguments from the command line (when run as script)
# ------------------------------------------------------------------------------

# the 'service_monitor' can be set to true to generate a list of running sessions.
# each of these can display its configuration, and be stopped/cleaned.
$config{service_monitor}          = 0;
$config{session_stop}             = ""; # contains a json ref, stop service
$config{session_purge}            = 0;  # when true stop/clean all
$config{oneshot}                  = 0;

for(my $i = 0; $i < @ARGV; $i++) {
  $_ = $ARGV[$i];
  if(/--help|-h|--version|-v$/) {
    print STDERR "$0: launch a QEMU/KVM machine in a browser window. Version $config{version}\n\n";
    print STDERR "Usage: $0 --option1=value1 ...\n\n";
    print STDERR "Valid options are:\n";
    foreach my $key (keys %config) {
      print STDERR "  --$key=VALUE [$config{$key}]\n";
    }
    print "\n(c) 2020- Emmanuel Farhi - GRADES - Synchrotron Soleil. AGPL3.\n";
    exit;
  } elsif (/^--(\w+)=(\w+)$/) {      # e.g. '--opt=value'
    if (exists($config{$1})) {
      $config{$1} = $2;
    } 
  } elsif (/^--(\w+)=([a-zA-Z0-9_\ \"\.\-\:\~\\\/]+)$/) {      # e.g. '--opt=file'
    if (exists($config{$1})) {
      $config{$1} = $2;
    } 
  }
}

$config{session_nb}               = 0;

if ($config{session_stop}) {
  # wait for session to end, and clean files/PIDs.
  my $session_ref = session_load(\%config, $config{session_stop});
  if ($session_ref) {
    session_stop($session_ref);
  }
  exit;
}

# for I/O, to generate HTML display and email content.
my $error       = "";
my $output      = "";

# Check running snapshots and clean any left over.
{
  (my $err, my $nb) = service_housekeeping(\%config);  # see below for private subroutines.
  $error .= $err;
  $config{session_nb} = $nb;
};


if ($config{certificate_crt} and -e $config{certificate_crt} 
and $config{certificate_key} and -e $config{certificate_key}) {
  $config{http} = "https";  # secured connection with certificates
} else { $config{http} = "http"; }


# ------------------------------------------------------------------------------
# Session variables: into a hash as well.
# ------------------------------------------------------------------------------

my %session;

# transfer defaults
$session{machine}     = $config{machine};
# OpenStack DEFAULT.instance_name_template ?
$session{dir_snapshot}= tempdir(TEMPLATE => "$config{service}" . "_XXXXXXXX", 
  DIR => $config{dir_snapshots}) || die "Can not create snapshot directory in $config{dir_snapshots}.";
$session{name}        = File::Basename::fileparse($session{dir_snapshot});
$session{snapshot}    = "$session{dir_snapshot}/$config{service}.qcow2";
$session{json}        = "$config{dir_cfg}/$session{name}.json";
$session{output}      = "$session{dir_snapshot}/index.html";
$session{qrcode}      = "";

$session{user}        = "";
$session{password}    = "";
$session{persistent}  = "";  # not persistent implies lower server load
$session{cpu}         = $config{snapshot_alloc_cpu};  # default: cores
$session{memory}      = $config{snapshot_alloc_mem};  # default: in GB
$session{disk}        = $config{snapshot_alloc_disk}; # default: only for ISO
$session{video}       = $config{qemu_video};          # default: driver to use
$session{gpu}         = ""; # indicates PCI GPU passthrough request when not empty
$session{config_script}= ""; # a file/URL to execute before starting the VM
$session{snapshot_lifetime} = $config{snapshot_lifetime}; # default [sec]
$session{oneshot}     = $config{oneshot};

$session{user_email}  = "";

$session{date}        = localtime();
# see https://www.oreilly.com/library/view/perl-cookbook/1565922433/ch11s03.html#:~:text=To%20append%20a%20new%20value,values%20for%20the%20same%20key.
#   on how to handle arrays in a hash.
# push new PID: push @{ $session{pid} }, 1234;
# get PIDs:     my @pid = @{ $session{pid} };
$session{pid}         = ();     # we search all children in session_stop
# push @{ $session{pid} }, $$;    # do NOT add our own PID = common Perl for all cgi's
$session{pid_wait}    = $$;     # PID to wait for (daemon).
$session{port}        = $config{service_port}; # e.g. 6080 for websockify
$session{qemuvnc_ip}  = "127.0.0.1"; # OpenStack vnc.server_listen vnc.proxyclient_address
# cast a random token key for VNC: 8 random chars in [a-z A-Z digits]
sub rndStr{ join'', @_[ map{ rand @_ } 1 .. shift ] };
$session{token_vnc}   = rndStr (8, 'a'..'z', 'A'..'Z', 0..9);
$session{token_file}  = "";
$session{runs_as_cgi} = IS_CGI;
$session{url}         = "";

# ------------------------------------------------------------------------------
# Update session info from CGI
# ------------------------------------------------------------------------------

$CGI::POST_MAX  = 65535;      # max size of POST message
my $q           = new CGI;    # create new CGI object "query"

if (my $res = $q->cgi_error()){
  if ($res =~ /^413\b/o) { $error .= "Maximum data limit exceeded.\n";  }
  else {                   $error .= "An unknown error has occured.\n"; }
}

$session{remote_host} = $q->remote_host(); # the 'client'
if ($session{remote_host} =~ "::1") {
  $session{remote_host} = "localhost";
}
$session{server_name} = $q->server_name(); # the 'server' OpenStack DEFAULT.host
if ($session{server_name} =~ "::1") {
  $session{server_name} = "localhost";
}
$config{server_name} = $session{server_name};

# check input arguments values (not 'password')
for ('machine','user','cpu','memory','gpu','snapshot_lifetime',
  'session_stop','session_purge') {
  my $val = $q->param($_);
  if (defined($val)) {
    if ( $val =~ /^([a-zA-Z0-9_.\-@\/: ]+)$/ ) {
      # all is fine
    } else {
      $error .= "$_ is not defined or contains invalid characters.";
    }
  }
}

# these are the "input" to collect from the HTML FORM. Store in $session
for ('machine','user','cpu','memory','gpu','config_script','snapshot_lifetime',
  'session_stop','session_purge','password','oneshot','fallback_servers') {
  my $val = $q->param($_);
  if (defined($val)) {
    $session{$_} = $val;
  } 
}

# we get the list of fallback servers to be used when current machine is over-subscribed.
# The POST message will be updated with a reduced fallback_servers list
# and sent via LWP::UserAgent -> post
if (not defined $session{fallback_servers} and defined $config{fallback_servers}) {
  $session{fallback_servers} = $config{fallback_servers};
}
my $need_fallback_server = 0;


# check if the 'Manage button' was hit, instead of Create
if (defined $q->param('manage')) {
  $session{machine} = 'monitor';
}

if (not $session{runs_as_cgi}) {
  # not a CGI: running as detached script
  print STDERR $0.": Running as detached script. No token. No authentication.\n";
  $config{check_user_with_email}  = 0;
  $config{check_user_with_ldap}   = 0;
  $config{check_user_with_imap}   = 0;
  $config{check_user_with_smtp}   = 0;
}

# assemble welcome message -----------------------------------------------------
my $ok   = '<font color=green>[OK]</font>';

# header with images, and start a list of items <li>
$output .= <<END_HTML;
<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN">
<html>
<head>
  <title>$config{service}: $session{machine} [$session{server_name}]</title>
</head>
<body>
  <a href="$config{http}://$session{server_name}/$config{service}/" target=_blank>
  <img alt="DARTS" title="DARTS"
    src="$config{http}://$session{server_name}/$config{service}/images/darts_logo.png"
    align="right" height="128" width="173"></a>
  <h1>Data Analysis Remote Treatment Service: $session{machine}</h1>
  <hr><ul>
END_HTML

# $output .= "<li>$ok Starting on $session{date}</li>\n";
# $output .= "<li>$ok The server name is $session{server_name}.</li>\n";
# $output .= "<li>$ok You are accessing this service from $session{remote_host}.</li>\n";

# stop/purge sessions from FORM (not args) - authentication is not needed as it was checked via form
if ($session{session_stop}) {
  # trigger session to end, and clean files/PIDs.
  my $session_ref = session_load(\%config, $session{session_stop});
  if ($session_ref) {
    session_stop($session_ref);
  }
  print "Content-type:text/html\r\n\r\n";
  print "$output\n\n";
  print "OK Stopped $session{session_stop} $session{machine} that was started on [$session{date}] by $session{user} $session{user_email}\n";
  exit;
}


# service monitoring requires user authentication
if ($session{machine} =~ 'monitor') {
  $config{service_monitor} = 1;
}

if ($session{machine} =~ 'purge' or $session{session_purge}) {
  $config{session_purge} = 1;
}

# handle 'admin'actions
if (not $error and ($config{service_monitor} or $config{session_purge})) {
  (my $out, my $err) = session_authenticate(\%config, \%session);
  
  if (not $err) { # must be identified
    my $user  = $session{user};
    if ($session{session_purge}) { $user = $session{session_purge}; }
    my @admin = @{ $config{user_admin} };
    my $isadmin = 0;
    $session{machine} = "administration";
    if ($session{runs_as_cgi} and not grep( /^$user$/, @admin ) ) {
      $isadmin = 0;
    } else { $isadmin = 1; }
    
    if ($config{service_monitor}) {
      $output = service_monitor(\%config, $output, $isadmin, $user);
    } elsif ($config{session_purge}) {
      if (not $isadmin) {
        $err .= "User $user is not among the 'user_admin' list";
      } else {
        $config{snapshot_lifetime} = 1;
        print STDERR $0." [$session{date}] Stopping all session, requested by $user\n";
        service_housekeeping(\%config);
        $output .= '</ul><h1>OK: Purged all</h1>';
      }
    }
  } 
  
  if (not $err) {
    # display...
    print "Content-type:text/html\r\n\r\n";
    print "$output\n\n";
    if (defined($r) and $r->can("rflush")) { 
      $r->rflush; 
    }
    exit;
  } else {
    $error .= $err;
  }
}


# ------------------------------------------------------------------------------
# Session checks: cpu, memory, disk, VM, config_script
# ------------------------------------------------------------------------------
$session{memory} = $session{memory}*1024; # GB -> MB

if ($config{service_monitor} or $config{session_purge}) {
  # admin actions must always be possible
} else {
  if ($config{session_nb} > $config{service_max_session_nb}) {
    $error .= "Too many active sessions $config{session_nb}. Max $config{service_max_session_nb}. Try again later.";
    $need_fallback_server = 1;
  }
  if (Sys::CPU::cpu_count()-Sys::CpuLoad::load() < $session{cpu}) {
    $error .= "Not enough free CPU's. Try again later.\n";
    $need_fallback_server = 1;
  }
  if (Sys::CpuLoad::load() / Sys::CPU::cpu_count() > $config{service_max_load}) {
    $error .= "Server load exceeded. Try again later.\n";
    $need_fallback_server = 1;
  }
  my ($total_memory_kb, $free_memory_kb, $avail_memory_kb) = get_freemem();
  if ($avail_memory_kb / 1024 < $session{memory}) { # in MB
    $error .= "Not enough free memory. Try again later.\n";
    $need_fallback_server = 1;
  }
  if (not -e "$config{dir_machines}/$session{machine}") {
    $error .= "Can not find virtual machine.\n";
  }
  (my $nb_session, my $nb_cpu, my $nb_mem) = service_check_user_max(\%config, $session{user});
  if ($nb_session > $config{service_max_session_nb_per_user}) {
    $error .= "Too many opened sessions ($nb_session) for user. Try again later.\n";
    $need_fallback_server = 1;
  }
  if ($nb_cpu/Sys::CPU::cpu_count() > $config{service_max_cpu_fraction_nb_per_user}) {
    $error .= "Too many used CPUs ($nb_cpu) for user. Try again later.\n";
    $need_fallback_server = 1;
  }
  if ($nb_mem/($avail_memory_kb / 1024) > $config{service_max_mem_fraction_nb_per_user}) {
    $error .= "Too much memory ($nb_mem) used for user. Try again later.\n";
    $need_fallback_server = 1;
  }
}

# find a free GPU when requested
if (defined($session{gpu}) and $session{gpu} =~ /yes|gpu|true|1/i) { 
  # look for detached GPU PCI, and check if it is used by a running session
  $session{gpu} = "";
  foreach my $pci (@{ $config{gpu_pci} }) {
    if (not $session{gpu} and not session_use_gpu(\%config, $pci)) {
      $session{gpu} = $pci; # this is what we need to pass to qemu
    }
  }
  if ($session{gpu}) {
    $output .= "<li>$ok Assigned GPU at PCI $session{gpu}.</li>\n";
  } else {
    $error .= "Can not find a free GPU as requested. Try again without.\n";
    $need_fallback_server = 1;
  }
}

# check if the current server is oversubscribed and there are fallback servers
if ($need_fallback_server and length($session{fallback_servers})) {

  # for loop: search a valid server separated with ','
  my $host="";
  my $fallback_server = "";

  for $host (split /,/, $session{fallback_servers}) {
    # get server to try: test if $host is not empty and active
    my $p   = Net::Ping->new();
    my $url = URI->new($host);
    my $h   = $host;
    if ($url->can("host")) { $h = $url->host; }
    if (length($host) and $url and $p->ping($h, 0.1)) {
      # server is active, remove it from the list of fallback_servers (replace with ' ')
      $session{fallback_servers} =~ s/$host/ /ig;
      if (not $url->scheme) {
        # add protocol/scheme
        $host = "$config{http}://$host";
      }
      if (not $url->path and IS_CGI) {
        # add CGI path
        $host .= $ENV{SCRIPT_NAME};
      }
      $fallback_server = $host;
      last;    
    }
    $p->close();
  }
  # end for. $host now contains the server to forward the POST to.
  
  if ($fallback_server) {
    # update the fallback_servers in the POST message
    print STDERR "$0: Warning: $error\n";
    print STDERR "$0: forwarding request to: $fallback_server\n";
    
    $q->param( fallback_servers => $session{fallback_servers} );
    
    # send POST message to $host server
    # ignore SSL certificate failures (we trust our fallback servers)
    my $ua = LWP::UserAgent->new(
      ssl_opts => { SSL_verify_mode => 0, verify_hostname => 0}); 
    # use a specific proxy, or system configuration (e.g. HTTP_PROXY env var)
    if ($config{service_proxy}) {
      $ua->proxy(['http', 'ftp', 'https'], $config{service_proxy});
    } else { $ua->env_proxy; }
    
    # forward POST with updated fallback_servers list
    my %params; # hash to store CGI arguments from the form
    foreach my $p ($q->param) {
      $params{$p} = $q->param($p);
    }
    
    # send to fallback server
    my $response = $ua->post($fallback_server, \%params); 

    # display message
    if ($response->is_success) {
      my $output = $response->as_string();
      # must clean the message up to '<!DOCTYPE html'
      my $doctype_index = index($output, '<!DOCTYPE html'); # start at 0
      if ($doctype_index > -1) { 
        $output = substr($output, $doctype_index); # skip protocol info
      }
      print "Content-type:text/html\r\n\r\n";
      print "$output\n\n";
      $session{server_name} = $fallback_server;
      session_save(\%session);

      # exit
      exit
    } else {
      print STDERR "$0: forward not succesful from $fallback_server:\n";
      print STDERR $response->as_string();
    }
  } # else proceed with error message: no localhost cpu/mem/gpu resource left
}

# ------------------------------------------------------------------------------
# User credentials checks, find communication ports
# ------------------------------------------------------------------------------
{
  (my $out, my $err, my $session_ref) = session_authenticate(\%config, \%session);
  $output .= $out;
  $error  .= $err;
  %session     = %{ $session_ref };
}

if (defined($session{oneshot}) and $session{oneshot} =~ /yes|oneshot|true|1/i) {
  $output .= "<li>$ok Using single login session (<b>one-shot</b> login).</li>\n";
  $session{oneshot} = "yes";
  $session{token_vnc}= "";
  # must use one websockify per session
  $config{service_port_multiple} = 1;
} else {
  $output .= "<li>$ok Using multiple login session (reconnect/share).</li>\n";
  $session{oneshot} = "";
}

# find a free port for websockify/noVNC on server. This is what goes in the URL given to user.
if ($session{port} and $config{service_port_multiple}) { 
  # range [service_port service_port+service_max_session_nb]
  my @port_list = List::Util::shuffle( $config{service_port} .. $config{service_port}+$config{service_max_session_nb}-1 );
  foreach my $port (@port_list) {
    my $socket = IO::Socket::INET->new(Proto => 'tcp', 
      LocalAddr => $session{qemuvnc_ip}, LocalPort => $port);
    if ($socket) { # must have been created on server
      $session{port} = $port;
      $socket->close;
      last;
    }
  }
} elsif (not $session{port})  {
  # port=0: request random port (0) to system in range [0 65535]
  my $socket = IO::Socket::INET->new(Proto => 'tcp', LocalAddr => $session{qemuvnc_ip});
  $session{port} = $socket->sockport();
  $socket->close;
}

my $port_vnc = undef;
# find another free VNC port at qemuvnc_ip (client). Random in 5900 range + max_nb
my @vnc_list = List::Util::shuffle( 
  $config{service_port_vnc} .. $config{service_port_vnc}+$config{service_max_session_nb}-1 );
for my $port (@vnc_list) {
  my $socket = IO::Socket::IP->new(Proto => 'tcp',
    PeerAddr => $session{qemuvnc_ip}, PeerPort => $port);
  if (not $socket) { # must not exist yet on client
    $port_vnc = $port;
    last;
  } else { $socket->close; }
}
if (not defined($port_vnc)) {
  $error .= "Can not find a port for the display.\n";
}
$session{port_vnc} = $port_vnc;

# ==============================================================================
# DO the work
# ==============================================================================

# NOTES: must make sure all commands redirect STDOUT to /dev/null not to collide
# with HTML generation. We use Proc::Background to launch tasks.

# Create snapshot --------------------------------------------------------------
if (not $error) {

  my $cmd  = "";
  my $res  = "";
  
  if ($session{machine} =~ /\.iso$/i) { # machine ends with .ISO
    $cmd      = "qemu-img create -f qcow2 $session{snapshot} $session{disk}G";
    $res      = `$cmd`; # execute command
    $output   .= "<li>$ok Will use ISO from ";
  } else {
    # qemu-img now requires to specify master "backing" file format with '-F FMT'
    my $img_info = `qemu-img info $config{dir_machines}/$session{machine}`;
    my @backing_format = $img_info =~ /file format:\s*([a-z0-9]+)/i;
    my $F     = $backing_format[0];
    $cmd      = "qemu-img create -F $F -b $config{dir_machines}/$session{machine}"
              . " -f qcow2 $session{snapshot}";
    $res      = `$cmd`; # execute command
    $output  .= "<li>$ok Creating snapshot from ";
  }
  $output .= "<a href='$config{http}://$session{server_name}/$config{service}/machines/$session{machine}' target=_blank>"
  . "$session{machine}</a> as session $session{name}</li>\n";
  
  # check for existence of cloned VM
  sleep(1); # make sure the VM has been cloned
  if (not $error and not -e $session{snapshot}) {
    $error .= "Could not clone $session{machine} into snapshot.\n";
  }
} # Create snapshot

# LAUNCH optional 'configuration' scripts (system wide, and user level)
{
  my $cmd = "";
  if (not $error and $config{config_script}) {
    foreach my $c (@{ $config{config_script} }) {
      $cmd .= session_run_script(\%config, \%session, $c);
    }
  }
  if (not $error and $session{config_script}) {
    $cmd .= session_run_script(\%config, \%session, $session{config_script});
  }
  if ($cmd) {
    # call virt customize with the list of all scripts to execute, in order
    my $res = `virt-customize -a $session{snapshot} $cmd`;
  }
}

# LAUNCH CLONED VM -------------------------------------------------------------
my $proc_qemu  = ""; # REQUIRED killed at END
if (not $error) {
  
  # common options for QEMU
  my $cmd = "$config{qemu_exec} -smp $session{cpu} "
    . " -name $session{name}:$session{user}:$session{machine}"
    . " -machine pc,accel=kvm -enable-kvm -cpu host,kvm=off"
    . " -m $session{memory} -device virtio-balloon"
    . " -hda $session{snapshot} -device ich9-ahci,id=ahci"
    . " -netdev user,id=mynet0 -device virtio-net,netdev=mynet0"
    . " -usb -device usb-tablet"
    . " -vga $session{video}";
    

  # performance options: network 
  #   see: https://elinux.org/images/3/3b/Kvm-network-performance.pdf
  # should use virtio-net. e1000 is best among emulated devices
  #   -netdev user,id=mynet0 -device virtio-net,netdev=mynet0
  
  # performance options: disk
  #   -device ich9-ahci,id=ahci
  
  # performance options: memory
  #   -device virtio-balloon (allows to only assign what is used by guests)
      
  # handle ISO boot
  if ($session{machine} =~ /\.iso$/i) {
    $cmd .= " -boot d -cdrom $config{dir_machines}/$session{machine}";
  } else {
    $cmd .= " -boot c";
  }
  
  # attach GPU on pre-assigned PCI
  if ($session{gpu}) {
    $cmd .= " -device vfio-pci,host=$session{gpu},multifunction=on";
  }
  
  # we add mounts using QEMU virt-9p, with tags 'host_<last_word>'
  #   see https://wiki.qemu.org/Documentation/9psetup
  # mounts are activated in the guest with:
  #   mount -t 9p -o trans=virtio,access=client [mount tag] [mount point]
  my @mounts = @{ $config{dir_mounts} };
  for(my $i = 0; $i <= $#mounts; $i++) {
    if (-d $mounts[$i]) { # mount must exist as a directory
      my $tag = (split '/', $mounts[$i])[-1];
      $cmd .= " -fsdev local,security_model=none,id=fsdev$i,path=$mounts[$i] -device virtio-9p-pci,id=fs$i,fsdev=fsdev$i,mount_tag=host_$tag";
    }
  }
  
  # add QEMU internal VNC
  my $port_vnc_5900=$port_vnc-5900;
  $cmd .= " -vnc $session{qemuvnc_ip}:$port_vnc_5900";
  
  my ($token_handle, $token_name) = tempfile(UNLINK => 1);
  if ($session{token_vnc} && $config{service_port_multiple}) {
    # must avoid output to STDOUT, so redirect STDOUT to NULL.
    #   file created just for the launch, removed immediately. 
    #   Any 'pipe' such as "echo 'change vnc password\n$token_vnc\n' | qemu ..." is shown in 'ps'.
    #   With a temp file and redirection, the token does not appear in the process list (ps).

    print $token_handle "change vnc password\n$session{token_vnc}\n";
    close($token_handle);
    # redirect 'token' to QEMU monitor STDIN to set the VNC password
    $cmd .= ",password -monitor stdio > /dev/null < $token_name";
  } else {
    $cmd .= ' > /dev/null';
  }
  
  # as stated in 
  # https://stackoverflow.com/questions/6024472/start-background-process-daemon-from-cgi-script
  # it is probably better to use 'batch' to launch background tasks.
  #   system("at now <<< '$cmd'")
  # $proc_qemu = system("echo '$cmd' | at now") || "";
  $proc_qemu = Proc::Background->new($cmd);
  if (not $proc_qemu) {
    $error  .= "Could not start QEMU/KVM for $session{machine}.\n";
  } else {
    # $output .= "<li>$ok Started QEMU/KVM for $session{machine} with VNC.</li>\n";
    push @{ $session{pid} }, $proc_qemu->pid;
  }
  sleep(1);
  unlink($token_name);
} # LAUNCH CLONED VM

# LAUNCH NOVNC (do not wait for VNC to stop) -----------------------------------
my $proc_novnc  = ""; # REQUIRED killed at END
# default is to use a single websockify instance (daemon)
my $dir_token   = $config{dir_snapshots} . "/websockify-target.d";
if ($config{service_port_multiple}) {
  # store the token in each snapshot
  $dir_token = $session{dir_snapshot} . "/websockify-target.d";
}
if (not $error and not -e "$dir_token") {
  if (not mkdir($dir_token)) { 
    $error .= "Could not create directory for tokens." 
  };
}

# push the token into websocket dir
if (not $error and $session{token_vnc}) {
  $session{token_file} = "$dir_token/$session{token_vnc}";
  open my $fh, ">", $session{token_file};
  print $fh "$session{token_vnc}: $session{qemuvnc_ip}:$session{port_vnc}\n";
  close $fh;
}

if (not $error) {
  # we set a timeout for 1st connection, to make sure the session does not block
  # resources. Also, by setting a log record to the snapshot, we can add the 
  # session name to the process command line. Used for parsing PIDs.
  my $cmd = "$config{dir_websockify}" .
    " --web $config{dir_novnc}";
    
  if (not $config{service_port_multiple} and $session{token_file}) {
    $cmd .= " -D" .
      " --token-plugin=TokenFile" .
      " --token-source=$dir_token";
  }
  
  if ($session{oneshot}) { $cmd .= " --run-once"; }
  
  if ($config{certificate_crt} and -e $config{certificate_crt}) {
    $cmd .= " --cert=$config{certificate_crt}";
  }
  if ($config{certificate_key} and -e $config{certificate_key}) {
    $cmd .= " --key=$config{certificate_key}";
  }
  
  $cmd .= " $session{port}";
  if ($config{service_port_multiple}) {
    $cmd .= " $session{qemuvnc_ip}:$session{port_vnc}";
  }

  # $proc_novnc = system("echo '$cmd' | at now") || "";
  $proc_novnc = Proc::Background->new($cmd);
  
  if ($config{service_port_multiple}) {
    if (not $proc_novnc) {
      $error .= "Could not start websockify/noVNC.\n";
    } else {
      # need to clear the multiple websockify calls
      push @{ $session{pid} }, $proc_novnc->pid;
    }
  }
} # LAUNCH NOVNC

# store the PID to wait for. Depends on persistent state.
if (not $error) {
  if ($proc_novnc and $proc_qemu) { 
    if (not $session{oneshot}) { 
      # qemu and session{name} alow to find the PID
      $session{pid_wait} = $proc_qemu->pid;
    } else {
      # $config{dir_novnc}/utils/websockify/run and $session{port}
      $session{pid_wait} = $proc_novnc->pid;
    }
  }
  
  if ($config{service_port_multiple}) {
    $session{url} = "$config{http}://$session{server_name}:$session{port}/vnc.html?resize=scale&autoconnect=true&host=$session{server_name}&port=$session{port}";
  } else {
    # in case of an Apache2 port redirection, change ':$session{port}' into e.g. 
    # the Apache2 Location (e.g. '/darts').
    $session{url} = "$config{http}://$session{server_name}:$session{port}/vnc.html?resize=scale&autoconnect=true&path=?token=$session{token_vnc}&port=$session{port}";
  }
}

# COMPLETE OUTPUT MESSAGE ------------------------------------------------------
if (not $error) {

  # save session info only when no error if found
  session_save(\%session);

  # $output .= "<li>$ok No error, all is fine.</li>\n";
  $output .= "<li>$ok Connect to your machine at <a href=$session{url} target=_blank>$session{url}</a>.</li>\n";
  if ($session{token_vnc} and $config{service_port_multiple}) {
    $output .= "<li><b>$ok Security token is: $session{token_vnc}</b></li>\n";
  }
  if ($session{snapshot_lifetime}) {
    my $datestring = localtime(time()+$session{snapshot_lifetime});
    $output .= "<li>$ok You can use your machine until <b>$datestring.</b></li>\n";
  }
  $output .= "</ul><hr>\n";
  my $output_token = "";
  if ($session{token_vnc} and $config{service_port_multiple}) {
    $output_token = "<h2>Security token: $session{token_vnc}</h2>";
  }
  my $output_share = "";
  my $output_persistent = "";
  if (not $session{oneshot}) {
    $output_share = "<button onClick=\"SelfCopy(this.id)\" id=\"$session{url} $session{token_vnc}\" style=\"padding:0;border:0;background:none;outline:none\"><img alt=\"copy\" src=\"$config{http}://$session{server_name}/$config{service}/images/share-button.png\" title=\"Copy link to clipboard, share it with your colleagues.\" height=40></button>";
    $output_persistent = "<li>You can close the browser and reconnect any time (within life-time) with the link above.</li>" .
    "<li>Select the <span style=\"color:green\">[Manage sessions]</span> item in the service login page to list, reconnect or abort your sessions.</li>" .
    "<li>You can collaborate in the same session with your colleagues. Just send them the link above.</li>" .
    "<li>Please <b>shut-down the machine properly</b> (do not just logout or suspend).</li>";
  }
  
  # Conditional import of Text::QRCode module when installed
  my $icon = "
        <img alt='$session{machine}' title='$session{machine}'
        src='$config{http}://$session{server_name}/$config{service}/images/logo-system.png'
        align='center' border='1' height='128'>";
  
  my $qr_enabled = eval
  {
    require Text::QRCode;
    Text::QRCode->import();
    1;
  };
  
  if ($qr_enabled) {
    # https://metacpan.org/pod/Text::QRCode
    my $arrayref = Text::QRCode->new()->plot("$session{url}");
    $session{qrcode} = join "\n", map { join '', @$_ } @$arrayref; 
  
    # code from HTML::QRCode
    my $w = "<td style=\"border:0;margin:0;padding:0;width:3px;height:3px;background-color: white;\">";
    my $b = "<td style=\"border:0;margin:0;padding:0;width:3px;height:3px;background-color: black;\">";
 
    $icon
        = '<table style="margin:0;padding:0;border-width:0;border-spacing:0;">';
    $icon
        .= '<tr style="border:0;margin:0;padding:0;">'
        . join( '', map { $_ eq '*' ? $b : $w } @$_ ) . '</tr>'
        for (@$arrayref);
    $icon .= '</table>';
  }

  $output .= <<END_HTML;
    <h1>Hello $session{user} !</h1>
    
    <p>Your machine $config{service} $session{machine} has just started. 
    Click on the following link.</p>
    
    <div style="text-align: center;">
      <a href=$session{url} target=_blank>$icon</a>
      <br></br>
      <b><a href="$session{url}" target=_blank>
      <img alt="connect" 
        src="$config{http}://$session{server_name}/$config{service}/images/connect-button.jpeg" 
        title="Connect !" height=40></a></b> 
        $output_share
        $output_token
    </div>
    
    <p>
    NOTES: <ul>
    $output_persistent
    <li>The virtual machine is created on request, and not kept. 
      Your work <b>must be saved elsewhere</b> 
      (e.g. mounted disk, ssh/sftp, Dropbox, OwnCloud...).</li>
    <li>To <b>kill</b> this session, click on <form action="$config{http}://$session{server_name}/cgi-bin/qemu-web-desktop.pl" method=post target=_blank>
    <input type=hidden name=session_stop value="$session{name}">
    <input type=image alt="stop" src="$config{http}://$session{server_name}/$config{service}/images/stop-button.png" title=STOP height="32">
    </form></li>
    </ul></p>

    <hr>
    <small><a href="$config{http}://$session{server_name}/$config{service}/" target=_blank>Data Analysis Remote Treatment Service</a> (c) 2020- - <a href="http://www.synchrotron-soleil.fr" target="_top">Synchrotron Soleil</a> - Thanks for using our data analysis services !</small>
    <a href="http://www.synchrotron-soleil.fr" target="_top">
    <img alt="SOLEIL" title="SOLEIL"
    src="$config{http}://$session{server_name}/$config{service}/images/logo_soleil.png"
    align="right" border="0" height="48"></a>
    </body>
    
  <script>
  function SelfCopy(copyText)
  {
      navigator.clipboard.writeText(copyText);
      alert("Copied to clipboard for sharing: " + copyText);
  }
  </script>
  </html>
END_HTML
} else {
  $output .= "</ul><hr>\n";
  $output .= "<h1>[ERROR]</h1>\n\n";
  $output .= "<p><div style='color:red'>$error</div></p>\n";
  $output .= "</body></html>\n";
}

# send message via email when possible
if ($config{check_user_with_email} and not $error) {
  # send the full output message (with URL)
  session_email(\%config, \%session, $output);
}

# write an HTML file to store the message output
# display the output message (redirect) ----------------------------------------
if (not $error) {
  open my $fh, ">", $session{output};
  print $fh "$output\n";
  close $fh;
  
  print STDERR $0.": $session{name}: $session{date}: START $session{machine} by $session{user} $session{user_email}\n";
  print STDERR $0.": $session{name}: json:  $session{json}\n";
  print STDERR $0.": $session{name}: URL:   $session{url}\n";
  print STDERR $0.": $session{name}: PIDs:  @{$session{pid}}\n" if ($session{pid});
} else {
  print STDERR $0.": $session{name}: $session{date}: ERROR $error\n";
}
if ($session{runs_as_cgi}) {
  # CGI redirect works, but requires that the temporary file be accessible
  # my $redirect="http://$session{server_name}/qemu-web-desktop/snapshots/$session{name}.html";
  # print $q->redirect($redirect); # this works (does not wait for script to end before redirecting)
  
  if (not $error) { sleep($config{boot_delay}); } # make sure the display comes in.
  print "Content-type:text/html;\r\n\r\n";
  print "$output\n\n";
    
  # the 1st argument of CGI is an Apache RequestIO
  if (defined($r) and $r->can("rflush")) { 
    $r->rflush; 
  }
}

# wait for end of processes.
if (not $error and $proc_novnc and $proc_qemu and $session{oneshot}) { 
	$proc_novnc->wait;
	session_stop(\%session);
}











# ==============================================================================
# support subroutines
# - session_save
# - session_load
# - session_stop
# - session_run_script
# - service_housekeeping
# - service_check_user_max
# - service_monitor
# - session_email
# - session_authenticate
# - session_check_smtp
# - session_check_imap
# - session_check_ldap
# - flatten
# - proc_getchildren
# - proc_running
# - pci_devices

# ==============================================================================
# no warnings "all";

# session_save(\%session): save session hash into a JSON.
sub session_save {
  my $session_ref  = shift;
  
  if (not $session_ref) { return; }
  my %session = %{ $session_ref };

  open my $fh, ">", $session{json};
  my $json = JSON::encode_json(\%session);
  print $fh "$json\n";
  close $fh;
} # session_save

# $session = session_load(\%config, $file): load session hash from JSON.
#   return $session reference
sub session_load {
  my $config_ref  = shift;
  my $file        = shift;
  
  if (not $config_ref or not $file) { return undef; } 
  my %config      = %{ $config_ref };

  # we test if the given ref is partial (just session name)
  if (not -e $file) {
     if (-e "$config{dir_cfg}/$file" or -e "$config{dir_cfg}/$file.json") {
      $file = "$config{dir_cfg}/$file";
    }
    if (-e "$file.json") {
      $file = "$file.json";
    }
  }
  if (not -e $file) { return undef; }
  
  open my $fh, "<", $file;
  my $json = <$fh>;
  close $fh;
  my $session = decode_json($json);
  return $session;
} # session_load

# session_stop(\%session): stop given session, and remove files.
sub session_stop {
  my $session_ref  = shift;
  if (not $session_ref) { return; }
  
  my %session = %{ $session_ref };

  # remove directory and JSON config
  if ($session{dir_snapshot} and -e $session{dir_snapshot})  
    { rmtree($session{dir_snapshot}); } 
  if ($session{json} and -e $session{json})          
    { unlink($session{json}); }
  if ($session{output} and -e $session{output})          
    { unlink($session{output}); }
  if ($session{token_file} and -e $session{token_file})
    { unlink($session{token_file}); }
  if ($session{qrcode} and -e $session{qrcode})
    { unlink($session{qrcode}); }
  
  my $now         = localtime();
  if ($session{remote_host}) { 
    print STDERR $0." [$now] STOP $session{name} $session{machine} started on [$session{date}] for $session{user}\@$session{remote_host} $session{user_email}\n";
  }
  
  # make sure QEMU/noVNC and asssigned SHELLs are killed
  # sometimes, PID's can change (more forks e.g. by websocket)
  if ($session{pid}) {
    my @pids = reverse uniq sort @{ $session{pid} };
    print STDERR $0." [$now]   Kill @pids\n";
    map {
      my @all = flatten(proc_getchildren($_));  # get all children from that PID
      killfam('KILL', reverse uniq sort @all);  # by reverse creation date/PID
    } reverse uniq sort @pids;
  }
  
} # session_stop

# (TF, $content) = session_test_script(\%session, content)
# Test the script '$content' after replacing symbols
#   The test expression must be found with syntax 'if(exp):'. It is extracted,
#   removed from the $content (which is returned after removal). Then it is 
#   evaluated, and its result is placed in TF (returned). False is returned
#   when the test can not be evaluated (fails).
# return (TF, $content)
sub session_test_script {
  my $session_ref = shift;
  my $content     = shift;
  my $TF          = 0;
  
  if (not $session_ref) { return (0,$content); }
  if (not $content)     { return (0,$content); }
  
  my %session = %{ $session_ref };
  
  # replace @symbols@ (globally)
  $content=~s/\@USER\@/$session{user}/g;
  $content=~s/\@SESSION_NAME\@/$session{name}/g;
  $content=~s/\@VM\@/$session{machine}/g;
  $content=~s/\@PW\@/$session{password}/g;
  
  # trim
  $content =~ s/^\s+|\s+$//g ; 

  # now search for the expression "if(EXPR):". Get 1st match.
  if ($content =~ m/if\((.*)\):/) {
    my $test = $1;
    $content =~ s/if\((.*)\)://; # remove match
    $content =~ s/^\s+|\s+$//g ; # trim again
    # evaluate the EXPR in test.
    $TF = eval $test;
    if ($@) { $TF = 0; } # error -> fails
    return ($TF,$content);
  } else {
    # no match: use content as is.
    return (1, $content);
  }
  
} # session_test_script

# session_run_script(\%config, \%session, $script): install a script for boot in VM
# The script can be specifyed as:
#   "http://some/url"
#   "/some/local/path/to/script"
#   "exec: some commands" separated with EOL (\n) or ';'
#   "virt-customize: commands" separated with EOL (\n)
#
# In addition, the script text (expression, file or URL) may contain the syntax:
#   if(EXPR):
# so that the script content is evaluated when EXPR is true.
# The script content and EXPR may use the @USER@ @PW@ @SESSION_NAME@ and @VM@ symbols,  
# which are replaced by the user name, the session name and the VM name.
sub session_run_script {
  my $config_ref  = shift;
  my $session_ref = shift;
  my $script      = shift;
  
  if (not $session_ref) { return ""; }
  if (not $config_ref)  { return ""; }
  my %config  = %{ $config_ref };
  my %session = %{ $session_ref };
  
  if (length($script) > $config{service_max_script_length} || not $script) {
    return "";
  }
  my $TF=0;
  ($TF,$script) = session_test_script(\%session, $script);
  if (not $TF) { return ""; }
  
  my $content     = undef;
  my $virt_customize_commands = 0;
  
  # add 'file://' for local file
  if (rindex($script, "bash:", 0) == 0 or rindex($script, "exec:", 0) == 0) {
    $content = substr($script, 5);
  }
  elsif (rindex($script, "virt-customize:", 0) == 0) {
    $content = substr($script, 15);
    $virt_customize_commands = 1;
  }
  elsif (-e "$script") {
    $script = "file://".$script;
  }
  
  # get script from $script URL
  # we try a few times to get the content. A single attempt is often not enough.
  if (not defined ($content) or not $content) {
    for (1..5) {
      my $ua = LWP::UserAgent->new(timeout => 2);
      # use a specific proxy, or system configuration (e.g. HTTP_PROXY env var)
      if ($config{service_proxy}) {
        $ua->proxy(['http', 'ftp', 'https'], $config{service_proxy});
      } else { $ua->env_proxy; }
      my $response = $ua->get($script);
      if (not $response->is_error) {
        $content = $response->content;
        last;
      }
    }
  }
    
  if (defined ($content) and length($content)) {
    # remove invalid characters
    $content=~s/[^\x00-\x7f]//g;
    if (length($content) < $config{service_max_script_length}) {
    
      # test if script is active
      ($TF, $content) = session_test_script(\%session, $content);
      if (not $TF) { return ""; }
      
      # store script in our 'snapshot' directory for local exec.
      my ($script_handle, $script_name) = tempfile(TEMPLATE => "$session{dir_snapshot}/configuration_script_XXXXXXXX");
      if (not $script_name) { return ""; }
      print $script_handle "$content\n";
      close $script_handle;
      
      # output script into apache2/log
      print STDERR $0.": $session{name}: $session{date}: $session{user} uses config_script=$script -> $script_name\n";
#      print STDERR "$content\n";
      
      # call virt-customize: start VM, execute script, stop it. Only runs on stopped VMs.
      # virt-customize -a vm.qcow2 --run snapshot/script
      # my $cmd = "virt-customize -a $session{snapshot} ";
      my $cmd= "";
      if ($virt_customize_commands == 0) {
        $cmd = " --firstboot $script_name";
      } else {
        $cmd = " --commands-from-file $script_name";
      }
      return $cmd;
    }
  }
} # session_run_script

# service_housekeeping(\%config): scan 'snapshot' and 'cfg' directories.
#   - kill over-time sessions
#   - check that 'snapshots' have a 'cfg'.
#   - remove orphan 'snapshots' (may be left from a hard reboot).
# return ($error,$nb) string (or empty when all is OK) and number of sessions.
sub service_housekeeping {
  my $config_ref  = shift;
  
  if (not $config_ref) { return; }
  my %config = %{ $config_ref };

  my $dir     = $config{dir_snapshots};
  my $cfg     = $config{dir_cfg};
  my $service = $config{service};
  
  # clean:
  # - remove orphan snapshots (no corresponding JSON file)
  # - remove orphan JSON      (no corresponding snapshots)
  # - remove snapshots that have gone above their lifetime
  my $now         = localtime();
  foreach my $snapshot (glob("$dir/$service"."_*")) {
    
    if (-d $snapshot) { # is a snapshot directory
      my $snaphot_name = fileparse($snapshot); # just the session name
      
      if (not -e "$cfg/$snaphot_name.json") {
        # remove orphan $snapshot (no JSON)
        print STDERR $0." [$now] housekeeping: $snapshot (left-over, no JSON)\n";
        rmtree( $snapshot ) || print STDERR "Failed removing $snapshot";
      } else {
        my $session_ref = session_load(\%config, "$cfg/$snaphot_name.json");
        if ($session_ref) {
          my %session = %{ $session_ref };
          if ($session{snapshot_lifetime}
            and (time > (stat $snapshot)[9] + $session{snapshot_lifetime}) 
             or (time > (stat $snapshot)[9] + $config{snapshot_lifetime}) ) { 
            # json exists, lifetime exceeded
            print STDERR $0." [$now] housekeeping: $cfg/$snaphot_name.json (exceeded life-time)\n";
            session_stop($session_ref);
          }
        } else { rmtree( $snapshot ) || print STDERR "Failed removing $snapshot"; }
      }
    }
  } # for snapshot
  
  # scan JSON files
  foreach my $json (glob("$cfg/*.json")) {
    
    # session exists, load JSON
    my $session_ref = session_load(\%config, $json);
    if ($session_ref) {
      my %session = %{ $session_ref };
      if (not -d $session{dir_snapshot}) { 
        print STDERR $0." [$now] housekeeping: $json (left-over, no snapshot)\n";
        unlink($json); 
      }          # snapshot does not exist
    }
  }
  
  # now count how many active sessions we have.
  my @jsons = glob("$cfg/$service"."_*.json");
  my $nb    = scalar(@jsons);
  my $err   = "";
  $config{session_nb} = $nb;
  $err = "";
  return ($err,$nb);
} # service_housekeeping

# service_monitor(\%config, $out, $isadmin, $user): present a list of running sessions 
#   as well as the server usage and history.
#   return appended string $out
sub service_monitor {
  my $config_ref  = shift;
  my $out         = shift;
  my $isadmin     = shift;
  my $user        = shift;
  
  if (not $config_ref) { return; }
  my %config = %{ $config_ref };

  # first display server ID and usage
  my $cpu_count       = Sys::CPU::cpu_count();
  my $cpu_load        = Sys::CpuLoad::load();
  my $load            = $cpu_load  / $cpu_count;
  my ($total_memory_kb, $free_memory_kb, $avail_memory_kb) = get_freemem(); # in kB
  my $avail_memory_GB = $avail_memory_kb  / 1024/1024; # in GB
  my $total_memory_GB = $total_memory_kb  / 1024/1024;
  my $now             = localtime();
  
  # display a table with current info
  $out .= "</ul><br><br><h1>Current $config{service} service status ($now)</h1>";
  $out .= "This page lists the service status, and your active sessions. <br>";
  $out .= "<img src=\"$config{http}://$config{server_name}/$config{service}/images/virtualmachines.png\" height=128 align=right>";
  $out .= "<table  border='1'>\n";
  $out .= "<tr><th>Server           </th><th>$config{server_name} running '$config{service}' version $config{version}</th></tr>\n";
  $out .= "<tr><td>#CPU total       </td><td>$cpu_count</td></tr>\n";
  $out .= "<tr><td>#CPU used        </td><td>$cpu_load</td></tr>\n";
  $out .= "<tr><td>Load [0-1]       </td><td>$load</td></tr>\n";
  $out .= "<tr><td>Total memory (GB)</td><td>$total_memory_GB</td></tr>\n";
  $out .= "<tr><td>Available memory (GB) </td><td>$avail_memory_GB</td></tr>\n";
  $out .= "<tr><td>Active sessions  </td><td>$config{session_nb} (total)</td><br>\n";
  $out .= "</table>\n";
  
  # display a list of active sessions for the given user
  my $dir     = $config{dir_snapshots};
  my $cfg     = $config{dir_cfg};
  my $service = $config{service};
  
  # iter=1: normal user; 2: admin user
  for my $iter (1..2) {
  
    # {name} {machine} {user} {date} {cpu} {mem} {lifetime} {url} {PIDs}
    if ($iter == 1) {
      $out .= "<br><hr><br><h1>Active sessions for $user</h1><table  border='1'>\n";
      $out .= "<tr><th>Start Date</th><th>Name</th><th>Machine</th><th>User</th>";
      $out .= "<th>CPU </th><th>Memory (MB)</th><th>GPU</th><th>lifetime (h)</th><th>URL</th>";
      $out .= "<th>PID's </th></tr>\n";
    } elsif ($iter == 2 and $isadmin) {
      $out .= "<br><hr><br><h1>Active sessions [$config{session_nb}] (administration)</h1><table  border='1'>\n";
      $out .= "<tr><th>Start Date</th><th>Name</th><th>Machine</th><th>User</th>";
      $out .= "<th>CPU </th><th>Memory (MB)</th><th>GPU</th><th>lifetime (h)</th><th>URL</th>";
      $out .= "<th>PID's <form action=\"$config{http}://$config{server_name}/cgi-bin/qemu-web-desktop.pl\" method=post target=_blank><input type=hidden name=session_purge value=$user><input type=submit value=\"STOP ALL\"></input></form> </th></tr>\n";
    }

    foreach my $snapshot (glob("$dir/$service"."_*")) {
      if (-d $snapshot) { # is a snapshot directory
        my $snaphot_name = fileparse($snapshot); # just the session name
        if (-e "$cfg/$snaphot_name.json") {
          my $session_ref = session_load(\%config, "$cfg/$snaphot_name.json");
          if ($session_ref) {
            my %session = %{ $session_ref };
            my $flag=0;
            
            if    ($iter == 1 and $user =~ $session{user}) { $flag = 1; }
            elsif ($iter == 2 and $isadmin)                { $flag = 1; }
            if ($session{pid} and $flag) {
              my @pids = @{ $session{pid} };
              $out .= "<tr>";
              $out .= "<td>$session{date}</td>";
              $out .= "<td>$session{name}</td>";
              $out .= "<td><a href='$config{http}://$session{server_name}/$config{service}/machines/$session{machine}'>$session{machine}</a></td>";
              if ($session{user_email}) {
                $out .= "<td><a href='mailto:$session{user_email}'>$session{user}</a></td>";
              } else  {
                $out .= "<td>$session{user}</td>";
              }
              $out .= "<td>$session{cpu}</td>";
              $out .= "<td>$session{memory}</td>";
              if ($session{gpu}) {
                $out .= "<td>$session{gpu}</td>";
              } else { $out .= "<td></td>"; }
              my $lt = $session{snapshot_lifetime}/3600;
              $out .= "<td>$lt</td>";
              if ($session{oneshot}) {
                $out .= "<td>one-shot";
              } else {
                $out .= "<td><a href='$session{url}' target=_blank><img alt=connect 
          src=\"$config{http}://$session{server_name}/$config{service}/images/connect-button.jpeg\" 
          title=Connect height=32></a>";
                if ($session{token_vnc} && $config{service_port_multiple}) {
                  $out .= " $session{token_vnc}";
                }
              }
              $out .= "</td>";
              # create a STOP button for each
              $out .= "<td>@pids <form action=\"$config{http}://$session{server_name}/cgi-bin/qemu-web-desktop.pl\" method=post target=_blank><input type=hidden name=session_stop value=\"$session{name}\"><input type=image alt=stop src=\"$config{http}://$session{server_name}/$config{service}/images/stop-button.png\" title=STOP height=32></form></td>\n";
            }
          }
        }
      }
    } # foreach snapshot
    $out .= "</table>";
    
    # display full list of sessions (when user is marked as 'admin')
    if (not $isadmin) { return $out; }
  } # for 1..2
  
  return $out;
}

# session_email(\%config, \%session, $output): send an email with URL
sub session_email {
  my $config_ref  = shift;
  my $session_ref = shift;
  my $out         = shift;
  
  if (not $config_ref or not $session_ref or not $out) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  if (not $session{user} or not $config{smtp_server} 
   or not $config{smtp_port}) {
    return;
  }

#   auto    use the provided smtp/email settings to decide what to do
#   SSL     use the server, port SSL, and email_from with email_passwd
#   simple  just use the server, and port 25
#   port    just use the server with given port

  my $smtp;
  my $method = $config{email_method};
  if ($method =~ 'auto') {
    if ( not $config{smtp_port} and not $config{smtp_use_ssl}) {
      $method = 'simple';
    } elsif ($config{smtp_port} and $config{smtp_use_ssl} and $config{email_passwd}) {
      $method = 'SSL';
    } else {
      $method = 'port';
    }
  }
  
  if ($method =~ 'SSL' and $config{smtp_port} and $config{smtp_use_ssl} 
    and $config{email_passwd}) {
    $smtp = Net::SMTPS->new($config{smtp_server}, Port => $config{smtp_port},  
      doSSL => $config{smtp_use_ssl}, SSL_version=>'TLSv1');
  } elsif ($method =~ 'port' and $config{smtp_port}) {
    $smtp = Net::SMTP->new($config{smtp_server}, Port=>$config{smtp_port}, Timeout => 10);
  } else {
    $smtp = Net::SMTP->new($config{smtp_server}, Timeout => 10); # e.g. port 25
  } 
  
  if ($smtp) {
    if ($config{email_passwd}) {
      $smtp->auth($config{email_from},$config{email_passwd}) || return;
    }
    $smtp->mail($config{email_from});
    $smtp->recipient($session{user_email});
    $smtp->data();
    $smtp->datasend("From: $config{email_from}\n");
    $smtp->datasend("To: $session{user_email}\n");
    # could add BCC to internal monitoring address $smtp->datasend("BCC: address\@example.com\n");
    $smtp->datasend("Subject: [Desktop] Remote $session{machine} connection information\n");
    $smtp->datasend("Content-Type: text/html; charset=\"UTF-8\" \n");
    $smtp->datasend("\n"); # end of header
    $smtp->datasend($out);
    $smtp->dataend;
    $smtp->quit;
  }

} # session_email

# ==============================================================================

# service_check_user_max(\%config, $user)
#   check resources used by user
#   return: ($nb_session, $nb_cpu)
sub service_check_user_max {

  my $config_ref  = shift;
  my $user        = shift;
  
  if (not $config_ref ) { return(0,0,0); }
  my %config      = %{ $config_ref };
  
  my $nb_session = 0;
  my $nb_cpu     = 0;
  my $nb_mem     = 0;
  
  # get the list of active sessions for the given user
  my $dir     = $config{dir_snapshots};
  my $cfg     = $config{dir_cfg};
  my $service = $config{service};
  
  foreach my $snapshot (glob("$dir/$service"."_*")) {
    if (-d $snapshot) { # is a snapshot directory
      my $snaphot_name = fileparse($snapshot); # just the session name
      if (-e "$cfg/$snaphot_name.json") {
        my $session_ref = session_load(\%config, "$cfg/$snaphot_name.json");
        if ($session_ref) {
          my %session = %{ $session_ref };
          if ($session{pid} and $user =~ $session{user}) {
            $nb_cpu     += $session{cpu};
            $nb_session ++;
            $nb_mem     += $session{memory};
          }
        }
      }
    }
  }
  
  return ($nb_session, $nb_cpu, $nb_mem);
  
} # service_check_user_max

# session_authenticate(\%config, \%session)
#   check user credentials with SMTP, LDAP, IMAP and sendemail.
#   return: ($out, $err, $session)
sub session_authenticate {

  my $config_ref  = shift;
  my $session_ref = shift;
  
  if (not $config_ref or not $session_ref) { return ("",""); }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  
  my $out = "";
  my $err = "";

  if ($session{runs_as_cgi}) { # authentication block
    my $authenticated = "";
    if (not $err) {
      # $out .= "<li>$ok Hello <b>$session{user}</b> !</li>\n";
    }
    # when all fails or is not checked, consider sending an email.

    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_email} 
                           and Email::Valid->address($session{user})) {
      $authenticated = "EMAIL";
      $session{user_email} = $session{user};
      
      $out .= "<li>[OK] An email will be sent to indicate the URL.</li>\n";
    }
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_imap}) {
      $authenticated .= session_check_imap(\%config, \%session); # checks IMAP("user","password")
    }
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_smtp}) {
      $authenticated .= session_check_smtp(\%config, \%session); # checks SMTP("user","password")
    }
    if (index($authenticated, "SUCCESS") < 0 and $config{check_user_with_ldap}) {
      my $authenticated_ldap = "";
      my $session_ref;
      ($authenticated_ldap, $session_ref) = session_check_ldap(\%config, \%session); # checks LDAP("user","password")
      $authenticated .= $authenticated_ldap;
      if ($session_ref) {
        %session     = %{ $session_ref };
      }
    }
    if ($config{check_user_custom}) {
      $authenticated = session_check_custom(\%config, \%session, $authenticated); # checks custom("user","password",$authenticated)
    }
    # now we search for a "SUCCESS"
    if (index($authenticated, "SUCCESS") > -1) {
      # $out .= "<li>$ok You are authenticated: $authenticated</li>\n";
    } elsif (not $authenticated) {
      $out .= "<li><b><font color=orange>[WARNING]</font></b> Service is running without user authentication.</li>\n";
      # no authentication configured...
    } else {
      $err  .= "User $session{user} failed authentication. Check your username / password:  $authenticated"; 
    }
    
    
  } # authentication block
  return ($out, $err, \%session);
  
} # session_authenticate

# session_check_smtp(\%config, \%session)
#   smtp_server, smtp_port, smtp_use_ssl are all needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
sub session_check_smtp {
  my $config_ref  = shift;
  my $session_ref = shift;
  
  if (not $config_ref or not $session_ref) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  my $res="";

  # return when check can not be done
  if (not $config{check_user_with_smtp} or not $config{smtp_server} 
   or not $config{smtp_port} or not $config{smtp_use_ssl}) { return ""; }
  
  if (not $session{user} or not $session{password}) {
    return "FAILED: [SMTP] Missing Username/Password.";
  }
  
  # must use encryption to check user.
  my $smtps = Net::SMTPS->new($config{smtp_server}, Port => $config{smtp_port},  
    doSSL => $config{smtp_use_ssl}, SSL_version=>'TLSv1') 
    or return "FAILED: [SMTP] Cannot connect to server. $@"; 

  # when USERNAME/PW is wrong, dies with no auth.
  if (not $smtps->auth ( $session{user}, $session{password} )) {
    $res = "FAILED: [SMTP] Wrong username/password (failed authentication).";
  } else { 
    $res = "SUCCESS: [SMTP] $session{user} authenticated.";
  }
  
  $smtps->quit;
  return $res;
  
} # session_check_smtp

# session_check_imap(\%config, \%session)
#   imap_server, imap_port are all needed.
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
sub session_check_imap {
  my $config_ref  = shift;
  my $session_ref = shift;

  if (not $config_ref or not $session_ref) { return; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };
  my $res = "";
  
  # return when check can not be done
  if (not $config{check_user_with_imap} or not $config{imap_server} 
   or not $config{imap_port}) { return ""; }
  
  if (not $session{user} or not $session{password}) {
    return "FAILED: [IMAP] Missing Username/Password.";
  }

  # Connect to IMAP server
  my $client = Mail::IMAPClient->new(
    Server   => $config{imap_server},
    User     => $session{user},
    Password => $session{password},
    Port     => $config{imap_port},
    Timeout  => 10,
    Ssl      =>  1)
    or return "FAILED: [IMAP] Cannot authenticate username/password. $@"; # die when not auth

  # List folders on remote server (see if all is ok)
  if ($client->IsAuthenticated()) {
    $res = "SUCCESS: [IMAP] $session{user} authenticated.";
  } else {
    $res = "FAILED: [IMAP] Wrong username/password (failed authentication).";
  }

  $client->logout();
  return $res;
  
} # session_check_imap

# session_check_ldap(\%config, \%session)
#   ldap_server is needed. Return ($res, $session)
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded

# used: http://articles.mongueurs.net/magazines/linuxmag68.html
sub session_check_ldap {
  my $config_ref  = shift;
  my $session_ref = shift;

  if (not $config_ref or not $session_ref) { return ""; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };

  if (not %config or not %session) { return ""; }
  my $res    = "";
  my $filter = "";

  # return when check can not be done
  if (not $config{check_user_with_ldap} or not $config{ldap_server}
   or not $config{ldap_port}) { return ""; }

  if (not $session{user} or not $session{password}) {
    return "FAILED: [LDAP] Missing Username/Password.";
  }

  my $ldap = Net::LDAP->new($config{ldap_server}, port=>$config{ldap_port})
    or return "FAILED: [LDAP] Cannot connect to server. $@";
    
  # check if "user" was given as an email.
  if (Email::Valid->address($session{user})) {
    $session{user_email} = $session{user};
    $filter = "mail=$session{user}";
  } else {
    $filter = "cn=$session{user}"; # may also be "uid=$session{user}"
  }
    
  # identify the DN
  my $mesg = $ldap->search(
    base => "dc=$config{ldap_domain}",
    filter => $filter,
    attrs => ['dn','mail','cn','uid']);
  
  if (not $mesg or not $mesg->count) {
    $res = "FAILED: [LDAP] empty LDAP search.\n";
  } else {
  
    foreach my $entry ($mesg->all_entries) {
      my $dn    = $entry->dn();
      my $email = $entry->get_value('mail');
      my $cn    = $entry->get_value('cn'); # may also be 'uid'
      my $bmesg = $ldap->bind($dn,password=>$session{password});
      if ( $bmesg and $bmesg->code() == 0 ) {
        if (not Email::Valid->address($session{user}) && $email) {
          $session{user_email} = $email;
        } elsif (Email::Valid->address($session{user})) {
          $session{user} = $cn;
        }
        $res = "SUCCESS: [LDAP] $session{user} authenticated.";
      }
      else{
        my $error = $bmesg->error();
        $res = "FAILED: [LDAP] Wrong username/password (failed authentication). $error\n";
      }
    }
  }
  
  $ldap->unbind;
  return ($res,\%session);

} # session_check_ldap

# session_check_custom(\%config, \%session, $authenticated)
#   check with a user function defined in %config
#   return ""         when no check is done
#          "FAILED"   when authentication failed
#          "SUCCESS"  when authentication succeeded
#
# specify an authenticator function in /etc/qemu-web-desktop/config.pl such as:
#
#  sub check_user_func {
#    my $user          = shift;
#    my $pw            = shift;
#    my $authenticated = shift; # previous authenticator results
#    my $session_ref   = shift;  
#    if (not $session_ref) { return $authenticated; }
#    my %session       = %{ $session_ref };
#    return "$auth and SUCCESS: [Custom] $user authenticated.";
#  }
#
#  $config{check_user_custom}   = \&check_user_func;

sub session_check_custom {
  my $config_ref  = shift;
  my $session_ref = shift;
  my $authenticated = shift;

  if (not $config_ref or not $session_ref) { return ""; }
  my %config      = %{ $config_ref };
  my %session     = %{ $session_ref };

  if (not %config or not %session) { return ""; }
  
  # check if existing custom auth
  if (not $config{check_user_custom}) { return ""; }
  my $res    = "";
  
  if (not $session{user}) {
    return "FAILED: [custom auth] Missing Username.";
  }
  
  # execute the referenced function
  my $cref = $config{check_user_custom};
  eval { $res = &$cref($session{user}, $session{password}, $authenticated, \%session); }; 
  print STDERR "$0: Error when executing custom authenticator: $@" if $@;
  
  return $res;

} # session_check_custom

# session_use_gpu(\%config, $pci): return true if the given PCI is used by any running session
sub session_use_gpu {
  my $config_ref  = shift;
  my $pci         = shift;

  if (not $config_ref) { return 0; }
  my %config      = %{ $config_ref };
  my $cfg     = $config{dir_cfg};
  
  if ($pci =~ $config{gpu_blacklist}) { return 1; } # PCI is black-listed
  
  # scan JSON files
  foreach my $json (glob("$cfg/*.json")) {
    
    # session exists, load JSON
    my $session_ref = session_load(\%config, $json);
    if ($session_ref) {
      my %session = %{ $session_ref };
      if ($session{gpu} =~ $pci) { return 1; }          # PCI is used
    }
  }
  return 0; # no session is using that PCI slot
} # session_use_gpu

# proc_getchildren($pid): return all children PID's from parent.
# use: my @children = flatten(proc_getchildren($$));
sub flatten {
  map { ref $_ ? flatten(@{$_}) : $_ } @_;
}

sub proc_getchildren {
  my $parent= shift;
  my @pid = [];
  push @pid, $parent;
  if (not $parent) { return; }
  
  my $proc_table=Proc::ProcessTable->new();
  for my $proc (@{$proc_table->table()}) {
    if ($proc->ppid == $parent) {
      my $child = $proc->pid;
      push @pid, $child;
      my @pid_children = flatten(proc_getchildren($child));
      push @pid, @pid_children;
    }
  }
  return flatten(@pid);
} # proc_getchildren

# proc_running($pid): checks if $pid is running. 
#   input $pid is a PID number.
#   return 0 or 1 (running).
sub proc_running {
  my $pid   = shift;
  if (not $pid) { return 0; }
  
  my $found = 0; # we now search for the PID.
  my $proc_table=Proc::ProcessTable->new();
  for my $proc (@{$proc_table->table()}) {     
    if ($proc->pid == $pid) {
      # session is still running
      $found = $pid;
      last;
    }
  }
  return $found;
} # proc_running

# pci_devices($cmd,$type,$module): extract GPU info from lspci and identify the devices
#   input:  $cmd    command to execute, e.g. 'lspci -nnk'
#           $type   type of devive,     e.g. "vga" or empty (can be any word to search for)
#           $module used kernel module, e.g. "nvidia" or "vfio" or empty
#   output: list of devices matching criteria, (@$device_pci, @$device_model, @$device_name)
#
# example: my ($device_pci, $device_model, $device_name) = pci_devices("lspci -nnk","audio","");
#          print "$_\n" for @$device_pci;
# example: pci_devices("lspci -nnk","vga",  "vfio");
sub pci_devices {
  my $cmd    = shift;
  my $type   = shift;
  my $module = shift;

  my $device_found = 0;
  my @device_pci   = ();
  my @device_model = ();
  my @device_name  = ();
  my ($pci, $device, $descr, $vendor, $model);
  open(LSPCI , "$cmd|") or return (\@device_pci, \@device_model, \@device_name);
  while (my $line = <LSPCI>) {
    chomp $line;
    # we first search the device syntax has XX:YY.Z descr: text [vendor:model] rest
    if (! $device_found) {
      ($pci, $device, $descr, $vendor, $model) = $line =~
          m/(\S+)\s+ ([^:]+):\s+ ((?:(?!\s*\[\S+\:\S+\]).)+)\s* \[(\S+)\:(\S+)\] (.*)/x;
      if (defined $pci and defined $vendor and defined $model) {
        $device_found=1;
      }
    } else {
      # now we search for the driver in use, not in a PCI address line
      my ($before, $kernel) = split(':\s*', $line);
      if ($before =~ /kernel/i) {
        if ((not $module or $kernel =~ /$module/i) and $pci and (not $type or $device =~ /$type/i)) {
          push @device_pci,   $pci;
          push @device_model, "$vendor:$model";
          push @device_name,  "$device $descr";
          # print "[$type $kernel] PCI=$pci hardware=$vendor:$model is '$descr'\n";
        }
        $device_found=0;
      }
    }
  }
  close(LSPCI);
  return (\@device_pci, \@device_model, \@device_name);
} # pci_devices

# get_freemem(): get the total/free/available memory, in kB
#   The available memory is the sum of the free and cached memory.
#
# ($total_mem, $free_mem, $avail_mem) = get_freemem()
sub get_freemem {
  my $free_memory_kb  = 0;
  my $avail_memory_kb = 0;
  my $total_memory_kb = 0;
  
  my @meminfo = `/bin/cat /proc/meminfo`;
  foreach (@meminfo) {
    chomp;
    if (/^Mem(Total|Free|Available):\s+(\d+) kB/) {
      my $counter_name = $1;
      if ($counter_name eq 'Free') {
          $free_memory_kb = $2;
      }
      elsif ($counter_name eq 'Total') {
          $total_memory_kb = $2;
      }
      elsif ($counter_name eq 'Available') {
          $avail_memory_kb = $2;
      }
    }
  }
  if (not $total_memory_kb) { $total_memory_kb = Sys::MemInfo::totalmem()/1024; }
  if (not $free_memory_kb)  { $free_memory_kb  = Sys::MemInfo::freemem() /1024; }
  if (not $avail_memory_kb) { $avail_memory_kb = $free_memory_kb; }
  
  return ($total_memory_kb, $free_memory_kb, $avail_memory_kb);
}
