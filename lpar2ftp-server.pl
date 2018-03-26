#!/usr/bin/env perl
# LPAR2ftp server

# SYNOPSIS
#  lpar2min-agent.pl [-d] [-c] [-n __NMON_DIR__] __LPAR2min-SERVER__[:__PORT__]
#
#  -d  forces sending out data immediately to check communication channel (DEBUG purposes)
#  -c  agent collects revive
#  options -c and -n are mutual exclusive
#  no option - agent collects & sends standard OS agent data
#
#  agent can send data to more servers,
#  each server can have own port to send to
#
# =====================================================
# place me into crontab
# * * * * * /usr/bin/perl /opt/lpar2min-agent/lpar2min-agent.pl __LPAR2min-SERVER__ > /var/tmp/lpar2min-agent.out 2>&1
#
# The agent collects all data and sends them every 5 minutes to LPAR2min server
#
# If you use other than standard LPAR2min port then place if after SERVER by ':' delimited
# * * * * * /usr/bin/perl /opt/lpar2min-agent/lpar2min-agent.pl __LPAR2min-SERVER__:__PORT__ > /var/tmp/lpar2min-agent.out 2>&1
#
# If you want to send data into more LPAR2min server instances (number is not restricted)
# * * * * * /usr/bin/perl /opt/lpar2min-agent/lpar2min-agent.pl __LPAR2min-SERVER1__  __LPAR2min-SERVER2__ > /var/tmp/lpar2min-agent.out 2>&1
#
#
# NMON usage: 
# ================================================
# /usr/bin/perl /opt/lpar2min-agent/lpar2min-agent.pl -n __NMON_DIR__  __LPAR2min-SERVER__  >/var/tmp/lpar2min-agent-nmon.out 2>&1
#

my $version = "5.05-2";
print "LPAR2min server version:$version\n" . (localtime) . "\n";
use Socket;
use strict;
use Time::Local;
use threads;
use Thread::Semaphore;

#use warnings;
use File::Copy;
use Getopt::Std;

#use Data::Dumper;

use sigtrap 'handler', \&my_handler, 'ABRT';
use sigtrap 'handler', \&my_handler, 'BUS';
use sigtrap 'handler', \&my_handler, 'SEGV';
use sigtrap 'handler', \&my_handler, 'SYS';

# for NMON and HMC possibility is necessary to read it first
my $perl_version = $];    #  5.008008 for 5.8.8
if ( $perl_version < 5.007 ) {

  # our is not supported on perl 5.6
  use vars qw($opt_n $opt_c $opt_d);
}
else {
  our $opt_n;
  our $opt_c;
  our $opt_d;
}
getopts('dcn:');          # options

# first server name needed for log-, timestamp- and store- file names
if ( $#ARGV < 0 ) {
  print "ERROR You must provide at least one LPAR2min server hostname\n";
  exit(1);
}
( my $host, my $port ) = split( ":", $ARGV[0] );
if ( $host eq "" ) {
  print "ERROR bad LPAR2min server hostname provided\n";
  exit(1);
}

# values are then tested before sending

# Globals
# my $host, my $port
my $port_standard          = "8162";                                                   # IANA registered port for LPAR2min project
my $max_threads = 5;
my $num_per_thread = 200;
my $base_dir               = "/var/tmp";
my $semaphore = Thread::Semaphore->new($max_threads);
my $user_name              = getpwuid($<);
my $store_not_confirm_file = "$base_dir/lpar2min-server-$host-$user_name.txt";
my $timestamp_file         = "$base_dir/lpar2min-server-$host-$user_name.stamp";
my $timestamp_file_send    = "$base_dir/lpar2min-server-$host-$user_name.stamp-send";     # UNIX timestamp of latest confirmed saved record on the daemon side
my $trimlogs_run           = "$base_dir/lpar2min-server-$host-$user_name.stamp-trimlogs";
my $RUN_TIME               = 300;                                                        # send out data every 5 minutes and when random() returns 1
my $MAX_RANDOM_TIME        = 1200;                                                       # maximum time when data is sent to the server (sending is randomized, this is just maximum)
my $protocol_version       = "4.0";
my $error_log              = "$base_dir/lpar2min-server-$host-$user_name.err";
my $act_time_u             = time();
my $act_time               = localtime($act_time_u);
my $last_ok_time           = 0;                                                         # must be global one due to alarm()
my $first_new_pgs_file     = "$base_dir/lpar2min-server-pgs.cfg";                        #send paging1 'U' 'U' when creating this file - paging 64kB too
my $iostat_data_file       = "$base_dir/lpar2min-server-iostat-$act_time_u.txt";

#
# Trim logs
#
sub trim_logs{
	while(1){
		print "start trim log.\n";
		my $trim_file_time_diff = file_time_diff("$trimlogs_run");
		if ( !-f "$trimlogs_run" || $trim_file_time_diff > 86400 ) { # once per day
		  trimlog("$store_not_confirm_file","43000");                # limit = 43000 lines
		  trimlog("$error_log","1000");                              # limit =  1000 lines
		
		  # trim nmon logs if exists
		  my $agent_nmon_file_for_trim = "$base_dir/lpar2min-server-nmon-$host-$user_name.txt";
		  my $nmon_error_log_for_trim  = "$base_dir/lpar2min-server-nmon-$host-$user_name.err";
		  if ( -f "$agent_nmon_file_for_trim" ) {
		    trimlog("$agent_nmon_file_for_trim","43000");
		  }
		  if ( -f "$nmon_error_log_for_trim" ) {
		    trimlog("$nmon_error_log_for_trim","1000");
		  }
		
		  my $ret = `touch $trimlogs_run`;                           # to keep same routine for all timestamp files
		  if ($ret) {
		    error( "$ret " . __FILE__ . ":" . __LINE__ );
		  }
		}
		sleep(60*60);
	}
}
my $log_trim=threads ->create("trim_logs");
$log_trim ->detach();
#
# Check if is not running more than 10 agent instances
# If so then exit to do not harm the agent hosted OS
#
my $PROC_RUN_LIMIT = 20;         # to support WPARs where hosted OS see all processes of the WPAR
my @ps             = `ps -ef`;

if ( process_limits( $0, $PROC_RUN_LIMIT, \@ps ) == 1 ) {
  error("Exiting as more than $PROC_RUN_LIMIT is running");
  exit 1;
}

error_log_wipe( $error_log, 1024000 );

# enhance PATH environment, ifconfig on Linux can be in /sbin
my $path = $ENV{PATH};
$path .= ":/sbin";
$ENV{PATH} = "$path";

# 60 seconds is default step, it could be changed via env variable STEP
my $STEP = 60;
if ( defined $ENV{STEP} && isdigit( $ENV{STEP} ) ) {

  # STEP variable can change step here (vmstat timeout mainly)
  $STEP = $ENV{STEP};
}

#
#-- test if NMON agent
#
my $nmon_data = "";
# if  -n nmon_data_path
# use alert here to be sure that it does not hang
if ($opt_n) {
  my $ret     = 0;
  eval {
    local $SIG{ALRM} = sub { die "died in SIG ALRM : agent"; };
    my $ps_n_count = 0;
    my @ps         = `ps -ef|grep $0|grep -v grep|grep -v "sh -c"`;
    foreach my $ps_line (@ps) {
      if ( $ps_line =~ /\s\-n/ && $ps_line =~ /$host/ ) {
        $ps_n_count++;
      }
    } ## end foreach my $ps_line (@ps)

    if ( $ps_n_count > 1 ) {
      $error_log = "$base_dir/lpar2min-server-nmon-$host-$user_name.err";
      error( "Exiting as two NMON agents cant run " . __FILE__ . ":" . __LINE__ );
      exit 1;
    }
    if ( !-d $opt_n ) {
      $error_log = "$base_dir/lpar2min-server-nmon-$host-$user_name.err";
      error( "NMON_dir: $opt_n does not exist " . __FILE__ . ":" . __LINE__ );
      exit 1;
    }
    print "NMON_dir set to $opt_n\n";
    $nmon_data = $opt_n;
    $ret       = send_nmon_data();
	
  };
  exit(0);
} ## end if ($opt_n)



sub connect_server {
  # contact the server
  my $F;
  if ( open_TCP( *F, $host, $port ) == 1 ) {

    # it does not go here, it crash in above 'eval' and prints its own message
    #error("Error connecting to server at $host:$port: $! ".__FILE__.":".__LINE__);
    # --> no error here, it is already printed in open_TCP
    # in Linux eg.:Bad arg length for Socket::pack_sockaddr_in, length is 0, should be 4 at ...
    return 1;
  } ## end if ( open_TCP( *F, $host...))

  # send version
  print F "test:$protocol_version\n";
  my $data_recv = <F>;
#  print "data_recv is: $data_recv \n";
  return $F;
} ## end sub connect_server

sub receive_data {
  my $F                      = shift;
  my $message                = shift;
  print F "$message\n";
  my $data_recv = <F>;
  return 1;
} ## end sub receive_data

sub send_data{
  my $F                      = shift;
  my $message                = shift;
#  print "$message\n";
  print F "$message\n";
  my $data_recv = <F>;
#  print "data_recv:$data_recv\n";
}
sub open_TCP {

  # get parameters
  my ( $FS, $dest, $port ) = @_;

  my $proto = getprotobyname('tcp');
  socket( $FS, PF_INET, SOCK_STREAM, $proto ) || error( "socket error $dest:$port : $! " . __FILE__ . ":" . __LINE__ ) && return 1;
  my $sin = sockaddr_in( $port, inet_aton($dest) ) || error( "sockaddr_in error $dest:$port : $! " . __FILE__ . ":" . __LINE__ ) && return 1;
  connect( $FS, $sin ) || error( "Connect error $dest:$port : $! " . __FILE__ . ":" . __LINE__ ) && return 1;

  my $old_fh = select($FS);
  $| = 1;    # don't buffer output
  select($old_fh);
  return 0;
} ## end sub open_TCP


sub store_for_later_transfer {
  my $message                = shift;
  my $store_not_confirm_file = shift;

  print "$store_not_confirm_file\n $message\n";
  open( FS, ">> $store_not_confirm_file" ) || error( "Can't open $store_not_confirm_file: $! " . __FILE__ . ":" . __LINE__ );
  print FS "$message\n";
  close(FS);
  return 1;
} ## end sub store_for_later_transfer

#
# run every $RUN_TIME and in case random() return 0 to spread agent load from many lpars across time
#
sub run_now {
  my $act_time_u     = shift;
  my $timestamp_file = shift;
  my $run_time       = shift;

  if ( $run_time == 1 ) {
    my $ret = `touch $timestamp_file`;    # first run after the upgrade
    if ($ret) {
      error( "$ret" . __FILE__ . ":" . __LINE__ );
    }
    print "Agent send     : yes : forced by -d \n";

    # debug run with option -w means "now"
    return 1;
  } ## end if ( $run_time == 1 )

  if ( !-f $timestamp_file ) {
    my $ret = `touch $timestamp_file`;    # first run after the upgrade
    print "Agent send     : no : initial\n";
    if ($ret) {
      error( "$ret" . __FILE__ . ":" . __LINE__ );
    }
    return 0;
  } ## end if ( !-f $timestamp_file)
  else {
    my $last_send_time = ( stat("$timestamp_file") )[9];
    my $random = substr( int( rand(10) ), 0, 1 );    # substr just to be sure
    if ( isdigit($random) == 0 ) {
      $random = 1;
    }
    my $next_time = $last_send_time + $run_time;
    if ( $next_time > $act_time_u || $random != 1 ) {
      if ( ( $act_time_u - $last_send_time ) > $MAX_RANDOM_TIME ) {

        # send it out after 20 minutes the latest _ 1200 secs
        print "Agent send 20m : sending data now (act_time=$act_time_u, last_send_time=$last_send_time, next_time=$next_time, random=$random)\n";
        my $ret = `touch $timestamp_file`;
        if ($ret) {
          error( "$ret" . __FILE__ . ":" . __LINE__ );
        }
        return 1;
      } ## end if ( ( $act_time_u - $last_send_time...))
      else {
        print "Agent send     : not sending data this time (act_time=$act_time_u, last_send_time=$last_send_time, next_time=$next_time, random=$random)\n";
        return 0;
      }
    } ## end if ( $next_time > $act_time_u...)
    else {
      print "Agent send     : sending data now (act_time=$act_time_u, last_send_time=$last_send_time, next_time=$next_time, random=$random)\n";
      my $ret = `touch $timestamp_file`;
      if ($ret) {
        error( "$ret" . __FILE__ . ":" . __LINE__ );
      }
      return 1;
    } ## end else [ if ( $next_time > $act_time_u...)]
  } ## end else [ if ( !-f $timestamp_file)]
} ## end sub run_now

# error handling
sub error {
  my $text     = shift;
  my $act_time = localtime();

  if ( $text =~ m/remote host did not respond within the timeout period/ ) {
    $text .= " : firewall issue??";
  }
  if ( $text =~ m/ A remote host refused an attempted connect/ ) {
    $text .= " : LPAR2min daemon does not seem to be running??";
  }

  #print "ERROR          : $text : $!\n";
  print STDERR "$act_time: $text\n";

  open( FE, ">> $error_log" ) || return 1;    # ignore error here
  print FE "$act_time: $text\n";

  #chmod 0777, "$error_log";

  return 0;
} ## end sub error

sub isdigit {
  my $digit = shift;
  my $text  = shift;

  my $digit_work = $digit;
  $digit_work =~ s/[0-9]//g;
  $digit_work =~ s/\.//;
  $digit_work =~ s/-//;
  $digit_work =~ s/\+//;

  if ( length($digit_work) == 0 ) {

    # is a number
    return 1;
  }

  #if (($digit * 1) eq $digit){
  #  # is a number
  #  return 1;
  #}

  # NOT a number
  return 0;
} ## end sub isdigit

# It saves or reads the last saved record from the server side
sub keep_time {
  if ( length $nmon_data > 0 ) { return 0 }    # nothing for NMON

  my $saved_time = shift;
  my $read_write = shift;
  print "keep_time  read_write $read_write ";
  if ( $read_write =~ m/read/ ) {
    if ( -f $timestamp_file_send ) {
      open( FS, "< $timestamp_file_send" ) || error( "Can't open $timestamp_file_send: $! " . __FILE__ . ":" . __LINE__ ) && return 0;
      my @lines = <FS>;
      close(FS);
      my $stime = 0;
      foreach my $line (@lines) {

        #print "001 $line";
        $stime = $line;
        chomp($stime);
        last;
      } ## end foreach my $line (@lines)
      if ( !$stime eq '' && isdigit($stime) ) {
        return $stime;
      }
      else {
        return 0;    # something wrong
      }
    } ## end if ( -f $timestamp_file_send)
    else {
      return 0;      # not yet saved time
    }
  } ## end if ( $read_write =~ m/read/)
  else {

    if ( $saved_time == 0 ) {
      return 0;      # skip it when it is 0
    }
    open( FS, "> $timestamp_file_send" ) || error( "Can't open $timestamp_file_send: $! " . __FILE__ . ":" . __LINE__ ) && return 0;
    print FS "$saved_time";
    close(FS);
  } ## end else [ if ( $read_write =~ m/read/)]

  return 1;
} ## end sub keep_time

#
#---- NMON analyse passage
#

my $signal_file;
my $agent_nmon_file;    #same as $store_not_confirm_file
my $semaphore_file;
my @files;
my $interval;
my $print_line;


# $nmon_data is a directory, where user can copy/has
#   historical and also today`s up to date nmon files
#
# -- algorithm
#
#  read files from directory $nmon_data
#  empty dir ? -> exit
#
#  make list of files
#  omit these : *.gz, *.Z, *.bz2 and not nmon files
#
#  sort according 'server-lpar-firsttime-file_name'
#  there is a signal file
#  containing lines 'server-lpar-lastsenttime-file_name'
#  if not -> create signal file
#
# LOOP:
#    take ( next - 1st ) file from files = 'orig'
#    is this SRV & LPR in signal file?
#    NO send it (1st time for this SRV&LPR)
#    |  YES: is orig time < signal time
#    |       NO  send it (not sent yet, probably new day)
#    |       | YES: look ahead next file:
#    |       |     same SRV & LPR ?
#    |       |     NO send it (maybe today up to date file)
#    |       |     |   YES: look ahead orig time < signal time --- Yes LOOP old files to skip
#    |       |     |   NO send it
#    send it & save 'server-lpar-lastsenttime-file_name'
#    prepare to send new items from orig starting from signal time
#              ( it also could be nothing new ! )
#  End LOOP
#
#  calls sub to send after each file during the run
#

sub send_nmon_data {

  $print_line         = "\n";
  my $numArgs = $#ARGV + 1;

  # print "thanks, you gave me $numArgs command-line arguments:$print_line";
  my $ret = 0;

  foreach my $argnum ( 0 .. $#ARGV ) {

    print "NMON working for server: $ARGV[$argnum] $print_line";
    ( $host, $port ) = split( ":", $ARGV[$argnum] );
    if ( !defined $port ) {
      $port = $port_standard;
    }
    if ( ( !isdigit($port) ) || ( $port < 1000 ) ) {
      error( "error setting port $port " . __FILE__ . ":" . __LINE__ );
      $ret = 1;
      next;
    }

    # print "\$port is $port $print_line";
    $signal_file     = "$base_dir/lpar2min-server-nmon-$host-$user_name-time_file.txt";
    $agent_nmon_file = "$base_dir/lpar2min-server-nmon-$host-$user_name.txt";
    $error_log       = "$base_dir/lpar2min-server-nmon-$host-$user_name.err";
	while(1){
		if(${$semaphore} == $max_threads){
		    my $start_time = time();
#		    print "starttime : $start_time\n";
		    $ret = send_nmon_data_for_one_server();
#			my $end_time = time();
#			print "end time : $end_time\n";
		}
	    sleep(10);
	}
  } ## end foreach my $argnum ( 0 .. $#ARGV)
  return $ret;
} ## end sub send_nmon_data

sub send_nmon_data_for_one_server {
	   
  #my  $DEBUG=3;
  #    $DEBUG=0;

  if ( !-f $signal_file ) {
    print "created file $signal_file " . __FILE__ . ":" . __LINE__ . "\n";
    my $output = `touch "$signal_file" 2>&1`;
    if ($output) {
      error( "$output " . __FILE__ . ":" . __LINE__ );
      return 1;
    }
  } ## end if ( !-f $signal_file )

  opendir( DIR, $nmon_data ) || error( "can't opendir $nmon_data: $!" . __FILE__ . ":" . __LINE__ ) && return 1;
  @files = grep { !/^\./ && /\.gz/ && -f "$nmon_data/$_" } readdir(DIR);
  closedir DIR;

  if ( !defined $files[0] ) {    # nothing to send
    return 0;
  }
  open( DF_IN, "< $signal_file" ) || error( "Cant open for reading $signal_file: $!" . __FILE__ . ":" . __LINE__ ) && return 1;
  my @signal_lines = <DF_IN>;
  close DF_IN;
  
  my $files_size = @files;
#  print "files_size :$files_size\n";
  my $slicing_p =0;
  my $slicing_p_end =0;
  while( $slicing_p < $files_size){
  	$semaphore -> down();
  	if($files_size - $slicing_p > $num_per_thread){
  		$slicing_p_end = $num_per_thread;
  	}else{
  		$slicing_p_end = $files_size - $slicing_p;
  	}
  	my @files_tmp = @files[$slicing_p .. $slicing_p+$slicing_p_end-1];
  	$slicing_p = $slicing_p+$slicing_p_end;
  	my $files_tmp_size = @files_tmp;
#  	print "files_tmp_size :$files_tmp_size\n";
#  	print "semaphore :${$semaphore} \n";
  	my $t=threads ->create("excute_thread",@files_tmp);
  	$t ->detach();
  }
#  my $F = connect_server();
#  # LOOP:
#  for my $i ( 0 .. $#files ) {
#  	my $mmtime  = (stat "$nmon_data/$files[$i]")[9];
##  	my $result = prepare_nmon_file( "$nmon_data/$files[$i]" ,$F);
#  }    # end of cycle for
#  my $revive= <F>;
#  print "revive $revive\n";
#  close(F);
  return 0;
} ## end sub send_nmon_data_for_one_server
sub excute_thread(){
	my @file_tem= @_;
	my $F = connect_server();
	# LOOP:
  for my $i ( 0 .. $#file_tem ) {
  	my $result = prepare_nmon_file( "$nmon_data/$file_tem[$i]" ,$F);
	unlink("$nmon_data/$file_tem[$i]");
  }    # end of cycle for
  my $revive= <F>;
#  print "revive $revive\n";
  shutdown(F,2) if $F;
  close(F) if $F;
  $semaphore -> up();
}
sub prepare_nmon_file{
	
	my $file_to_proces  = shift;
	my $F  = shift;
	my $F_I  = shift;
	my $mmtime  = (stat "$file_to_proces")[9];
#	print "mmtime :$mmtime\n";
	my $message;
	my $server;
	my $lpar;
	my $lpar_id;
	my $paging_space;
	my $paging_percent;
	my $proc_clock;
	my @ent;
	my @ent_inx;
	my @fcs;
	my @fcs_inx;
	my @lfiles;
	my $entitled_proc;
	my $zzzz_this;
	my $last_zzzz_this;
	my @part1;
	my $os_type;
	my $os_version;
	my $nmon_external_time;
	my @fcf;
	my @fcf_inx;
	my @sea_info;
	my @sea_inx;
	my @sea;
	my @phys_log_eth_sea;
	my $read_first_part =sub {
	  my $yestime        = shift;    # if 'yestime' then only for test
	  my $file_to_proces = shift;
	  my $D_IN = shift;
	  #  my $DEBUG = 0;
	
	  $interval         = 60;
	  $server           = "";
	  $lpar             = "";
	  $lpar_id          = "0";
	  $paging_space     = "false";
	  $paging_percent   = "";
	  $proc_clock       = "";
	  @ent              = ();
	  @ent_inx          = ();
	  @lfiles 			= ();
	  @fcs              = ();
	  @fcs_inx          = ();
	  @part1            = ();
	  @fcf              = ();
	  @fcf_inx          = ();
	  @sea              = ();
	  @sea_inx          = ();
	  @phys_log_eth_sea = ();
	
	  my $lpar_n       = "";
	  my $lpar_runname = "";    #for AIX 5.3.
	
	  # AAA,SerialNumber,65383FP
	  # AAA,LPARNumberName,5,BSRV21LPAR5-pavel
	  # AAA,MachineType,IBM,8233-E8B
	
	  # BBBP,001,lsconf,"System Model: IBM,8233-E8B"
	  # BBBP,002,lsconf,"Machine Serial Number: 65383FP"
	
	  # BBBP,1092,lsconf,"Modčle de systčme : IBM,9119-595"
	  # BBBP,1093,lsconf,"Numéro de sé/LPARrie de la machine : 8323EAD"
	
	  # BBBP,007,lsconf,"Processor Clock Speed: 3000 MHz"
	  # BBBP,1098,lsconf,"Fréquence d'horloge du processeur : 2102 MHz"
	
	  # BBBP,010,lsconf,"LPAR Info: 5 BSRV21LPAR5-pavel"
	  # BBBP,1101,lsconf,"Infos LPAR : 27 P127-751"
	
	  # BBBP,027,lsconf,"Paging Space Information"
	  # BBBP,028,lsconf,"       Total Paging Space: 4096MB"
	  # BBBP,029,lsconf,"       Percent Used: 12%"
	
	  # BBBP,1119,lsconf,"	Espace de pagination total : 6112MB"
	  # BBBP,1120,lsconf,"	Pourcentage utilisé : 1%"
	
	  # BBBN,001,en2,1500,2047,Standard Ethernet Network Interface
	  # BBBN,002,en4,1500,1024,Standard Ethernet Network Interface
	
	  # BBBP,536,lsattr -El sys0,"ent_capacity    1.00    Entitled processor capacity   False"
	  my $line;
	  while ( $line = <$D_IN> ) {
	    $line =~ s/\r[\n]*/\n/gm;    # all platforms Unix, Windows, Mac
	    if($line =~ /^BBBP,\d{2,4},(no|vmo|ioo|schedo|ipcs|WLMclasses|WLMrules|WLMlimits|oslevel)/){
	    	next;
	    }
	    chomp($line);
	    push @part1, $line;
	    if ( @part1 > 2000 ) {
	      error("err reading first part of NMON file (more than 2000000 lines) $file_to_proces ");
	      return ( "", "", 0 );
	    }
	    last if $line =~ "ZZZZ,T";
	  } ## end while ( $line = <DF_IN> )
	  if ( $line !~ "ZZZZ,T" ) {
	    error("unable reading first part of NMON file (didnt find ZZZZ,T) $file_to_proces ");
	    return ( "", "", 0 );
	  }
	  $zzzz_this      = $line;
	  $last_zzzz_this = $line;
	
	  # all systems checks
	  my $lines_read = @part1;
#	  print "part1 lines read $lines_read until $last_zzzz_this\n";
	
	  #  CPU_ALL,CPU Total bsrpdev0035,User%,Sys%,Wait%,Idle%,Busy%,CPUs#
	  my @matches = grep {/^CPU_ALL/} @part1;
	  my $match_count = scalar @matches;
	  if ( $match_count != 1 ) {
	    if ( !( ( $match_count == 2 ) && ( $matches[0] eq $matches[1] ) ) ) {
	      error("cant recognize CPU_ALL ($match_count matches) in NMON file $file_to_proces");
	      return ( "", "", 0 );
	    }
	  } ## end if ( $match_count != 1)
	  ( undef, undef, my $rest ) = split( ",", $matches[0], 3 );
	  if ( $rest !~ /^User%,Sys%,Wait%/ ) {
	    error("cant recognize CPU_ALL in NMON line $matches[0] in file $file_to_proces");
	    return ( "", "", 0 );
	  }
	
	  @matches = grep {/AAA,interval/} @part1;
	  if ( @matches != 1 ) {
	    error("cant recognize AAA,interval in NMON file $file_to_proces ");
	    return ( "", "", 0 );
	  }
	  ( undef, undef, my $part ) = split( /,/, $matches[0] );
	  $interval = $part;
	  if ( $interval != ( $interval * 1 ) ) {
	    error("cant recognize interval in NMON line $matches[0] in file $file_to_proces");
	    return ( "", "", 0 );
	  }
	
	  # try to find out which system & lpar name
	
	  @matches = grep { /AIX/ && !/lscfg/ } @part1;
	
	  if ( @matches > 0 ) {    # working for AIX
	    $os_type = "AIX";
		
		@matches = grep {/AAA,AIX/} @part1;
		
		if(@matches == 1){
			(undef,undef,$os_version)  = split(/,/,$matches[0]);
#			print "os_version:$os_version\n";
		}
		
	    $server = "1165-J4K";                                      # fake name when there are no definition lines BBB
	    @matches = grep { /System Model/ || /de syst/ } @part1;    #/System Model/ ||
	    if ( @matches != 1 ) {
	
	      # error ("cant recognize System Model: in NMON file $file_to_proces ");
	      # return ("","",0);
	    }
	    else {
	      ( undef, my $part ) = split( /:/, $matches[0] );
	      ( undef, $server ) = split( /,/, $part );
	      $server =~ s/\"//g;
	      $server .= "*";
	    } ## end else [ if ( @matches != 1 ) ]
	    if ( $server =~ /1165-J4K/ ) {
	      @matches = grep {/AAA,MachineType/} @part1;
	      if ( @matches != 1 ) {
	        error("cant recognize System Model: in NMON file $file_to_proces ");
	        return ( "", "", 0 );
	      }
	      else {
	        ( undef, undef, undef, my $server ) = split( /,/, $matches[0] );
	        $server =~ s/\"//g;
	        $server .= "*";
	      }
	    } ## end if ( $server =~ /1165-J4K/)
	
	    $part = "00X0X0X";
	    @matches = grep { /Machine Serial Number/ || /e de la machine/ } @part1;
	    if ( @matches != 1 ) {
	
	      # error ("cant recognize Machine Serial Number: in NMON file $file_to_proces ");
	      # return ("","",0);
	    }
	    else {
	      if ( $matches[0] !~ 'Not Available' ) {
	        ( undef, $part ) = split( /:/, $matches[0] );
	        $part =~ s/ //g;
	        $part =~ s/\"//g;
	        $server .= $part;
	      } ## end if ( $matches[0] !~ 'Not Available')
	    } ## end else [ if ( @matches != 1 ) ]
	    if ( $part eq "00X0X0X" ) {
	      @matches = grep {/AAA,SerialNumber/} @part1;
	      if ( @matches != 1 ) {
	        error("cant recognize Machine Serial Number: in NMON file $file_to_proces ");
	        return ( "", "", 0 );
	      }
	      else {
	        ( undef, undef, $part ) = split( /,/, $matches[0] );
	        $part =~ s/ //g;
	        $part =~ s/\"//g;
	        $server .= $part;
	      } ## end else [ if ( @matches != 1 ) ]
	    } ## end if ( $part eq "00X0X0X")
	
	    if ( $yestime ne 'yestime' ) {
	      $server =~ s/:/=====double-colon=====/g;
	    }
	
	    @matches = grep {/,lparname,/} @part1;
	    if ( @matches != 1 ) {
	
	      # error ("cant recognize lparname in NMON file $file_to_proces ");
	    }
	    else {
	      ( undef, undef, undef, my $part ) = split( /,/, $matches[0] );
	      $part =~ s/\"//g;
	      $lpar = $part;
	    }
	    @matches = grep {/AAA,LPARNumberName/} @part1;
	    if ( @matches != 1 ) {
	
	      # error ("cant recognize AAA,LPARNumberName in NMON file $file_to_proces ");
	    }
	    else {
	      ( undef, undef, $lpar_id, my $part ) = split( /,/, $matches[0] );
	      $part =~ s/\"//g;
	      $lpar_n = $part;
	    }
	    @matches = grep {/AAA,runname,/} @part1;
	    if ( @matches != 1 ) {
	
	      # error ("cant recognize AAA,runname, in NMON file $file_to_proces for $os_type");
	    }
	    else {
	      ( undef, undef, my $part ) = split( /,/, $matches[0] );
	      $part =~ s/\"//g;
	      $lpar_runname = $part;
	    }
	
	    if ( length($lpar_n) > length($lpar) ) {
	      $lpar = $lpar_n;
	    }
	    if ( length($lpar) == 0 ) {
	      $lpar = $lpar_runname;
	    }
	    my $blade_lpar = "";
	    if ( defined $ENV{LPAR2RRD_HOSTNAME_PREFER} && $ENV{LPAR2RRD_HOSTNAME_PREFER} == 1 ) {
	
	      # special solution for blade server - lpar > prefare host name
	      @matches = grep {/AAA,host,/} @part1;
	      if ( @matches > 0 ) {
	        ( undef, $blade_lpar ) = split( ',host,', $matches[0] );
	      }
	    } ## end if ( defined $ENV{LPAR2RRD_HOSTNAME_PREFER...})
	
	    if ( $blade_lpar ne "" ) {
	      $lpar = $blade_lpar;
	    }
	
	    if ( length($lpar) == 0 ) {
	      error("no valid lpar-name in $file_to_proces ");
	      return ( "", "", 0 );
	    }
	
	    if ( $yestime ne 'yestime' ) {
	      $lpar =~ s/:/=====double-colon=====/g;
	    }
	
	    @matches = grep {/ZZZZ,T/} @part1;
	    if ( @matches != 1 ) {
	      error("cant recognize ZZZ time in NMON file $file_to_proces ");
	      return ( "", "", 0 );
	    }
	    my $time_stamp_unix = prepare_time( $matches[0] );
	
	    if ( $yestime eq 'yestime' ) {
	      return ( $server, $lpar, $time_stamp_unix );
	    }
	
	    @matches = grep {/Entitled processor capacity/} @part1;
	    if ( @matches != 1 ) {
	      error("cant recognize Entitled processor capacity in NMON file $file_to_proces ");
	    }
	    else {
	      ( undef, undef, undef, $part ) = split( /,/, $matches[0] );
	      $part =~ s/\"ent_capacity//g;
	      ( $part, undef ) = split( /Entitled/, $part );
	      $part =~ s/ //g;
	      $entitled_proc = $part;
	    } ## end else [ if ( @matches != 1 ) ]
	
	    @matches = grep {/Processor Clock Speed/} @part1;    #::
	    if ( @matches != 1 ) {
	      error("cant recognize Processor Clock Speed: in NMON file $file_to_proces ");
	    }
	    ( undef, $part ) = split( /:/, $matches[0] );
	    $part =~ s/ //g;
	    $part =~ s/\"//g;
	    $part =~ s/MHz//g;
	    $proc_clock = $part;
	
	    @matches = grep { /Total Paging Space/ || /Espace de pagination total/ } @part1;    #::
	    if ( @matches != 1 ) {
	      print "cant recognize Total Paging Space: in NMON file $file_to_proces ";
	    }
	    else {
	      ( undef, $part ) = split( /:/, $matches[0] );
	      $part =~ s/ //g;
	      $part =~ s/MB//g;
	      $part =~ s/\"//g;
	      $paging_space = $part;
	
	      @matches = grep { /Percent Used/ || /Pourcentage utili/ } @part1;                 #::
	      if ( @matches != 1 ) {
	        error("cant recognize Percent Used: in NMON file $file_to_proces ");
	      }
	      ( undef, $part ) = split( /:/, $matches[0] );
	      $part =~ s/ //g;
	      $part =~ s/\%//g;
	      $part =~ s/\"//g;
	      $paging_percent = $part;
	    } ## end else [ if ( @matches != 1 ) ]
	
	    # NET,Network I/O asrv11lpar7,en2-read-KB/s,en3-read-KB/s,en4-read-KB/s,lo0-read-KB/s,en2-write-KB/s,en3-write-KB/s,en4-write-KB/s,lo0-write-KB/s
	    # NETPACKET,Network Packets asrv11lpar7,en2-reads/s,en3-reads/s,en4-reads/s,lo0-reads/s,en2-writes/s,en3-writes/s,en4-writes/s,lo0-writes/s
	    # NETSIZE,Network Size asrv11lpar7,en2-readsize,en3-readsize,en4-readsize,lo0-readsize,en2-writesize,en3-writesize,en4-writesize,lo0-writesize
	    # NETERROR,Network Errors asrv11lpar7,en2-ierrs,en3-ierrs,en4-ierrs,lo0-ierrs,en2-oerrs,en3-oerrs,en4-oerrs,lo0-oerrs,en2-collisions,en3-collisions,en4-collisions,lo0-collisions
	
	    my @refs = &prepare_net( "NET,Network", $file_to_proces,@part1 );
	    @ent= @{$refs[0]};
	    @ent_inx = @{$refs[1]};
		@lfiles = prepare_lfiles( "JFSFILE,", $file_to_proces ,@part1);
	    #FCREAD,Fibre Channel Read KB/s,fcs0,fcs1,fcs2,fcs3
	    #FCWRITE,Fibre Channel Write KB/s,fcs0,fcs1,fcs2,fcs3
	    #FCXFERIN,Fibre Channel Tranfers In/s,fcs0,fcs1,fcs2,fcs3
	    #FCXFEROUT,Fibre Channel Tranfers Out/s,fcs0,fcs1,fcs2,fcs3
	
	    #FCREAD,T0001,0.0,0.0,0.0,0.0
	    #FCWRITE,T0001,0.0,0.0,0.0,0.0
	    #FCXFERIN,T0001,0.0,0.0,0.0,0.0
	    #FCXFEROUT,T0001,0.0,0.0,0.0,0.0
	
	    @refs = &prepare_sea_stats(@part1);
#	    print "prepare_sea_stats @refs\n";
	    if(@refs){
		    @phys_log_eth_sea= @{$refs[0]};
		    @sea = @{$refs[1]};
	    }
	    
		@refs = &prepare_fcread(@part1);
		if(@refs){
		    @fcf= @{$refs[0]};
		    @fcf_inx = @{$refs[1]};
	    }
	    # IOADAPT,T1440,0.0,0.0,0.0,0.0,0.0,0.0,1.1,43.2,10.2  9 cisel
	    # IOADAPT,Disk Adapter sse11,fcs0_read-KB/s,fcs0_write-KB/s,fcs0_xfer-tps,fcs1_read-KB/s,fcs1_write-KB/s,fcs1_xfer-tps
	    # IOADAPT,T0001,0.0,0.0,0.0,352.4,68.1,26.4            6 cisel
	    # IOADAPT,Disk Adapter sse12,fcs1_read-KB/s,fcs1_write-KB/s,fcs1_xfer-tps,fcs0_read-KB/s,fcs0_write-KB/s,fcs0_xfer-tps
	    #IOADAPT,Disk Adapter bsrv21lpar3,fcs0_read-KB/s,fcs0_write-KB/s,fcs0_xfer-tps,fcs1_read-KB/s,fcs1_write-KB/s,fcs1_xfer-tps
	    #IOADAPT,Disk Adapter bsrv21lpar4,fcs1_read-KB/s,fcs1_write-KB/s,fcs1_xfer-tps,fcs0_read-KB/s,fcs0_write-KB/s,fcs0_xfer-tps
	    #IOADAPT,Disk Adapter CBCFCBSDEVT,sissas1_read-KB/s,sissas1_write-KB/s,sissas1_xfer-tps,sissas0_read-KB/s,sissas0_write-KB/s,sissas0_xfer-tps
	
	    @matches = grep {/IOADAPT,Disk/} @part1;
	    if ( @matches != 1 ) {
	      error("cant recognize IOADAPT,Disk in NMON file $file_to_proces ");
	    }
	    else {
	      my @linea = split( ",", $matches[0] );
	
	      # print "\@linea (IOADAPT) @linea\n";
	      # my @match_read = grep { /fcs[0-9]{1,2}_read/ } @linea;
	      my @match_read = grep {/_read/} @linea;
	
	      # print "match_read fcs @match_read\n";
	      # my @match_write =  grep { /fcs[0-9]{1,2}_write/} @linea;
	      my @match_write = grep {/_write/} @linea;
	      if ( ( @match_read != @match_write ) || ( ( @match_read + @match_write ) < 2 ) || ( $match_read[0] =~ /not available/ ) ) {
	        error("not same reads as writes (or zero) number in fcs line or not available");
	      }
	      else {
	        # my @match_xfer = grep { /fcs[0-9]{1,2}_xfer/ } @linea;
	        my @match_xfer = grep {/_xfer/} @linea;
	        if ( @match_read != @match_xfer ) {
	          error("not same reads as xfer number in fcs line");
	        }
	        for ( my $i = 0; $i < @match_read; $i++ ) {
	          ( $fcs[$i], undef ) = split( "_", $match_read[$i] );
	          ( $fcs_inx[ 4 * $i ] )     = grep { $linea[$_] =~ /$fcs[$i]/ } 0 .. $#linea;
	          ( $fcs_inx[ 4 * $i + 1 ] ) = grep { $linea[$_] =~ /$fcs[$i]_write/ } 0 .. $#linea;
	          ( $fcs_inx[ 4 * $i + 2 ] ) = grep { $linea[$_] =~ /$fcs[$i]_xfer/ } 0 .. $#linea;
	          $fcs_inx[ 4 * $i + 3 ] = -1;
	        } ## end for ( my $i = 0; $i < @match_read...)
	      } ## end else [ if ( ( @match_read != ...))]
	    } ## end else [ if ( @matches != 1 ) ]
	    return ( $server, $lpar, $lpar_id, $paging_space, $paging_percent, $proc_clock );
	  } ## end if ( @matches > 0 )
	
	  @matches = grep {/Linux/} @part1;
	  $os_type = "OS-like-Linux";
	
	  if ( @matches > 0 ) {    # working for Linux - will you differ by flavours?
	
	    @matches = grep {/Red Hat/} @part1;
	    if ( @matches > 0 ) {
	      $os_type = "LINUX-RedHat";
	    }
	    @matches = grep {/Arch Linux/} @part1;
	    if ( @matches > 0 ) {
	      $os_type = "LINUX-Arch";
	    }
	
	    @matches = grep {/Solaris/} @part1;
	    if ( @matches > 0 ) {
	      $os_type = "UX-Solaris";
	    }
	
	    @matches = grep {/Ubuntu/} @part1;
	    if ( @matches > 0 ) {
	      $os_type = "Ubuntu";
	    }
	
	    print "working for $os_type $print_line";
	    $server = $os_type;
	
	    @matches = grep {/AAA,host/} @part1;
	    if ( @matches != 1 ) {
	      error("cant recognize AAA,host: in NMON file $file_to_proces ");
	      return ( "", "", 0 );
	    }
	    ( undef, undef, my $part ) = split( /,/, $matches[0] );
	    $part =~ s/ //g;
	    my $lpar_n = $part;
	
	    @matches = grep {/AAA,runname/} @part1;
	    if ( @matches != 1 ) {
	      error("cant recognize AAA,runname in NMON file $file_to_proces ");
	    }
	    else {
	      ( undef, undef, my $part ) = split( /,/, $matches[0] );
	      $lpar = $part;
	    }
	    if ( length($lpar_n) > length($lpar) ) {
	      $lpar = $lpar_n;
	    }
	    if ( $yestime ne 'yestime' ) {
	      $lpar =~ s/:/=====double-colon=====/g;
	    }
	
	    @matches = grep {/ZZZZ,T/} @part1;
	    if ( @matches != 1 ) {
	      error("cant recognize ZZZ time in NMON file $file_to_proces ");
	      return ( "", "", 0 );
	    }
	    my $time_stamp_unix = prepare_time( $matches[0] );
	
	    if ( $yestime eq 'yestime' ) {
	      return ( $server, $lpar, $time_stamp_unix );
	    }
		my @refs = &prepare_net( "NET,Network", $file_to_proces,@part1 );
	    @ent= @{$refs[0]};
	    @ent_inx = @{$refs[1]};
	
	    return ( $server, $lpar, $lpar_id, "", "", "" );
	  } ## end if ( @matches > 0 )
	
	  error("cant recognize OS from NMON file $file_to_proces ");
	  return ( "", "", 0 );
	};    # end of sub read_first_part
	
	
		my $data_collect = sub {
			my $test = ",lsconf,";
			my @matches = ();
			my $message_head = "{'s':'$server','l':'$lpar','l_id':$lpar_id,'v':'$version','device_type':'conf','os':'$os_type','conf':[";
			
			if ( $os_type =~ m/AIX/ ) {
				  
				  $test = "AAA,";
				  @matches = grep {/$test/} @part1;
				  if ( @matches < 1 ) {
					    error("cant recognize AAA, in NMON _to_proces ");
				  }
				  else {
					  	foreach $a (@matches) {  
						    $message_head .= "'$a',";  
						}
				  } ## end else [ if ( @matches != 1 ) ]
					  
				  $test = "BBBB,";
				  @matches = grep {/$test/} @part1;
				  if ( @matches < 1 ) {
					    error("cant recognize BBBB, in NMON _to_proces ");
				  }
				  else {
					  	foreach $a (@matches) {  
						    $message_head .= "'$a',";  
						}
				  } ## end else [ if ( @matches != 1 ) ]
				  
				  $test = ",lsconf,";
				  @matches = grep {/$test/} @part1;
				  if ( @matches < 1 ) {
				    error("cant recognize lsconf in NMON _to_proces ");
				  }
				  else {
				  	foreach $a (@matches) {  
					    $message_head .= "'$a',";  
					}
				  } ## end else [ if ( @matches != 1 ) ]
					  $test = ",ifconfig,";
					  @matches = grep {/$test/} @part1;
					  if ( @matches < 1 ) {
					    error("cant recognize ifconfig in NMON _to_proces ");
					  }
					  else {
					  	foreach $a (@matches) {  
						    $message_head .= "'$a',";  
						}
					  } ## end else [ if ( @matches != 1 ) ]
					  
					  
			  } 
			  else 
			  {
				  if ( $os_type =~ m/Linux/ ) {
				  	  
				  	  $test = ",ifconfig,";
					  @matches = grep {/$test/} @part1;
					  if ( @matches < 1 ) {
					    error("cant recognize ifconfig in NMON _to_proces ");
					  }
					  else {
					  	foreach $a (@matches) {  
						    $message_head .= "'$a',";  
						}
					  } ## end else [ if ( @matches != 1 ) ]
					  
					  $test = ",fdisk-l,";
					  @matches = grep {/$test/} @part1;
					  if ( @matches < 1 ) {
					    error("cant recognize fdisk-l in NMON _to_proces ");
					  }
					  else {
					  	foreach $a (@matches) {  
						    $message_head .= "'$a',";  
						}
					  } ## end else [ if ( @matches != 1 ) ]
					  
					  $test = ",lsblk,";
					  @matches = grep {/$test/} @part1;
					  if ( @matches < 1 ) {
					    error("cant recognize lsblk in NMON _to_proces ");
					  }
					  else {
					  	foreach $a (@matches) {  
						    $message_head .= "'$a',";  
						}
					  } ## end else [ if ( @matches != 1 ) ]
				  }
			  }
			$message_head .= "]}";
#			print "message_head : $message_head\n";
			send_data(*F,$message_head);
			return $message_head;
	}; ## end sub data_collect

	
	my  $read_one_run = sub {
	  my $start_time     = shift;
	  my $file_to_proces = shift;
	  my $D_IN = shift;
	  #  my $DEBUG = 0;
	  #     $DEBUG = 3;
	  my $mem             = "";
	  my $memnew          = "";
	  my $page            = "";
	  my $lpar_data       = "";
	  my $lpar_data_cpu   = "";
	  my $net_data        = "";
	  my $net_packet      = "";
	  my $net_error_packet      = "";
	  my $lfiles_data        = "";
	  my $fcsnet_data     = "";
	  my $seanet_data     = "";
	  my $zzzz            = "";
	  my $line            = "";
	  my $indx            = 0;
	  my $time_stamp_unix = 0;
	
	  if ( $zzzz_this !~ "ZZZZ,T" ) {
#	    print "didnt find ZZZZ,T for read_one_run, probably end of file $file_to_proces\n$last_zzzz_this";
	    return 0;
	  }
	
	  #  print " date $zzzz_this\n";
	
	  $time_stamp_unix = prepare_time($zzzz_this);
	
	  my $act_time    = localtime($time_stamp_unix);
	  my @arr_one_run = ();
	  while ( ( defined( $line = <$D_IN> ) ) && ( $line !~ "ZZZZ,T" ) ) {
	    $line =~ s/\r[\n]*/\n/gm;    # all platforms Unix, Windows, Mac
	    chomp($line);
	    push @arr_one_run, $line;    # read lines from one run
	  }
	  if ( !defined($line) ) {
	    $zzzz_this = "";
	  }
	  else {
	    $zzzz_this      = $line;
	    $last_zzzz_this = $line;
	  }
	
	  # working out memory characteristics
	  # AIX
	  # MEM,Memory sse21,Real Free %,Virtual free %,Real free(MB),Virtual free(MB),Real total(MB),Virtual total(MB)
	
	  my ( $free, $size, $inuse ) = ( 0, 0, 0 );
	  my $pin         = 0;
	  my $in_use_clnt = 0;
	  my $in_use_work = 0;
	  my ( $user_proc, $free_proc );
	
	  my $test_item = "MEM,";
	  my @matches   = grep {/^$test_item/} @arr_one_run;
	  my $count_m   = @matches;
	  if ( $count_m ne 1 ) {
#	    error("$count_m items for $test_item in \@arr_one_run not possible")
	     return $time_stamp_unix;
	  }
	  if ( $count_m == 1 ) {
	    $mem = $matches[0];
	    if ( $os_type eq "AIX" ) {
	      ( undef, undef, undef, undef, $free, undef, $size, undef ) = split( /,/, $mem );
	      $size *= 1024;
	      $free *= 1024;
	      $inuse = $size - $free;
	
	      $test_item = "MEMNEW,";
	      @matches   = grep {/^$test_item/} @arr_one_run;
	      $count_m   = @matches;
	      if ( $count_m > 1 ) {
	        error("$count_m items for $test_item in \@arr_one_run not possible");
	      }
	      if ( $count_m == 0 ) {
	        $memnew = "";
	      }
	      else {
	        $memnew = $matches[0];
	
	        #MEMNEW,Memory New sse21,Process%,FScache%,System%,Free%,Pinned%,User%
	
	        if ( $memnew ne "" ) {
	          ( undef, undef, my $proces, my $in_use_clnt_proc, my $syst_proc, $free_proc, $pin, $user_proc ) = split( /,/, $memnew );
	          $in_use_clnt = $in_use_clnt_proc * $size / 100;
	          $pin         = $pin * $size / 100;
	          $in_use_work = ( $proces + $syst_proc ) * $size / 100;
	          @matches     = grep {/^MEMAMS/} @arr_one_run;
	          if ( @matches == 1 ) {
	            $inuse = ( $syst_proc + $user_proc ) * $size / 100 + $in_use_clnt;
	            $free  = $size - $inuse;
	            if ( ( ( $user_proc + $free_proc + $syst_proc ) * $size / 100 ) > ( $size - $in_use_clnt ) ) {
	              $free  = $free_proc * $size / 100;
	              $inuse = $size - $free;
	            }
	          } ## end if ( @matches == 1 )
	        } ## end if ( $memnew ne "" )
	      } ## end else [ if ( $count_m == 0 ) ]
	    } ## end if ( $os_type eq "AIX")
	
	    # Red Hat or Arch
	    # MEM,Memory MB bsrpmgt0007,memtotal,hightotal,lowtotal,swaptotal,memfree,highfree,lowfree,
	    #                           swapfree,memshared,cached,active,bigfree,buffers,swapcached,inactive
	    # Total= memtotal
	    # FS cache = cached
	    # Free = memfres
	    # Mem used = memtotal – memfree
	
	    if ( $os_type =~ "LINUX-RedHat" || $os_type =~ "LINUX-Arch" || $os_type =~ "Ubuntu" || $os_type =~ "OS-like-Linux" ) {
	      ( undef, undef, $size, undef, undef, undef, $free, undef, undef, undef, undef, $in_use_clnt, undef ) = split( /,/, $mem );
	      $size        *= 1024;
	      $free        *= 1024;
	      $in_use_clnt *= 1024;    # FS cache
	      $inuse = $size - $free;
	
	      #print "\$size $size \$free $free \$in_use_clnt $in_use_clnt, \$inuse $inuse\n $mem\n";
	    } ## end if ( $os_type =~ "LINUX-RedHat"...)
	    #
	    #Solaris
	    #
	    if ( $os_type eq "UX-Solaris" ) {
	
	      #  MEM,Memory MB bsrpdev0035,memtotal,NA1,NA2,swaptotal,memfree,NA3,NA4,swapfree,swapused
	      ( undef, undef, $size, undef, undef, $paging_space, $free, undef, undef, undef, my $val_a ) = split( /,/, $mem );
	      $size *= 1024;
	      $free *= 1024;
	
	      #$in_use_clnt *= 1024; # FS cache
	      $inuse = $size - $free;
	      my $paging_percenta = "";
	      if ( $paging_space == 0 ) {
	        $paging_percenta = $paging_space;
	      }
	      else {
	        $paging_percenta = $val_a / $paging_space;
	      }
	      $paging_percent = $paging_percenta * 100;
	
	      #print "\$size $size \$free $free \$in_use_clnt $in_use_clnt, \$inuse $inuse\n $mem\n";
	    } ## end if ( $os_type eq "UX-Solaris")
	  } ## end if ( $count_m == 1 )
	
	  $test_item = "PAGE,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  if ( @matches == 0 ) {
	    $page = "";
	  }
	  else {
	    $page = $matches[0];
	  }
	
	  $test_item = "LPAR,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  if ( @matches == 1 ) {
	    $lpar_data = $matches[0];
	  }
	  else {
	    $lpar_data = "";
	  }
	
	  $test_item = "CPU_ALL,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $lpar_data_cpu = $matches[0];
	  $test_item = "NET,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $net_data = $matches[0];
	  
	  $test_item = "JFSFILE,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $lfiles_data = $matches[0];
	
	  $test_item = "NETPACKET,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $net_packet = $matches[0];
	#  print "net_packet is : $net_packet\n";
	  
	  $test_item = "NETERROR,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $net_error_packet = $matches[0];
	#  print "NETERROR is : $net_error_packet\n";
	  
	  $test_item = "IOADAPT,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $fcsnet_data = $matches[0];
	
	  $test_item = "SEA,";
	  @matches = grep {/^$test_item/} @arr_one_run;
	  if ( @matches > 1 ) {
	    error("More items $test_item in \@arr_one_run not possible");
	  }
	  $seanet_data = $matches[0];
	
	  #  print "$line\n"  if $DEBUG == 3;
	
	  my $page_in  = 0;
	  my $page_out = 0;
	
	  # PAGE,Paging sse21,faults,pgin,pgout,pgsin,pgsout,reclaims,scans,cycles
	
	  # 39 items
	  # MEMPAGES4KB,MemoryPages,numframes,numfrb,numclient,numcompress,numperm,numvpages,
	  # minfree,maxfree,numpout,numremote,numwseguse,numpseguse,numclseguse,numwsegpin,
	  # numpsegpin,numclsegpin,numpgsp_pgs,numralloc,pfrsvdblks,pfavail,pfpinavail,numpermio,
	  # system_pgs,nonsys_pgs,pgexct,pgrclm,pageins,pageouts,
	  #
	  # pgspgins,pgspgouts, # this is interesting items 31 and 32
	  #
	  # numsios,numiodone,zerofills,exfills,scans,cycles,pgsteals
	
	  # same for MEMPAGES64KB
	
	  # since 4.69
	  # page_in = pgsin * interval / 4.096     translate to 4 kB blocks
	  #  my $page_const = $interval/4.096;
	  #  no it is the same as pi and po in vmstat - 4k blocks / sec
	  #  my $page_const = 1;
	
	  if ( $page ne "" ) {
	    $test_item = "MEMPAGES64KB,";
	    @matches = grep {/^$test_item/} @arr_one_run;
	    if ( @matches > 0 ) {    # means there is 64 KB
	      my @arr    = split( /,/, $matches[0] );
	      my $pgsin  = $arr[30] * 16;
	      my $pgsout = $arr[31] * 16;
	      $test_item = "MEMPAGES4KB,";
	      @matches = grep {/^$test_item/} @arr_one_run;
	      if ( @matches > 0 ) {    # means there is 4 KB
	        @arr = split( /,/, $matches[0] );
	        $pgsin  += $arr[30];
	        $pgsout += $arr[31];
	      }
	      $pgsin  /= $interval;
	      $pgsout /= $interval;
	      $page_in  = $pgsin;
	      $page_out = $pgsout;
	
	      # print "yes 64 $pgsin $pgsout\n";
	    } ## end if ( @matches > 0 )
	    else {
	      ( undef, undef, undef, undef, undef, my $pgsin, my $pgsout ) = split( /,/, $page );
	      $page_in  = $pgsin;
	      $page_out = $pgsout;
	      #print "no 64 $pgsin $pgsout\n";
	    } ## end else [ if ( @matches > 0 ) ]
	  } ## end if ( $page ne "" )
	
	  # prepare cpu
	  # LPAR,Logical Partition sse21,PhysicalCPU,virtualCPUs,logicalCPUs,poolCPUs,entitled,weight,PoolIdle,usedAllCPU%,usedPoolCPU%,SharedCPU,Capped,EC_User%,EC_Sys%,EC_Wait%,EC_Idle%,VP_User%,VP_Sys%,VP_Wait%,VP_Idle%,Folded,Pool_id
	  # LPAR,T1440,0.100,3,12,15,0.30,128,11.66,0.63,0.67,1,0,14.16,7.34,0.00,11.90,1.42,0.73,0.00,1.19,0
	  # for both types of lpars entitled_proc in first_part
	  # BBBP,536,lsattr -El sys0,"ent_capacity    1.00    Entitled processor capacity   False"
	
	  my $lpar_message = "";
	  my $cpu_us       = "";
	  my $cpu_sy       = 0;
	  my $cpu_wa       = 0;
	  my $entitled     = 0;
	  my $physical_cpu = 0;
	
	  # CPU_ALL,T1440,10.4,7.4,0.1,82.2,,12
	  # These lines show %usr, %sys, %wait and %idle by time of day for logical processors
	
	  #test if message contains CPU & MEM
	  if ( ( !defined $lpar_data_cpu ) && $lpar_data eq "" && $count_m != 1 ) {
	    print "not complete message left out before $zzzz_this";
	    return $time_stamp_unix;
	  }
	
	  $entitled = $entitled_proc if defined($entitled_proc);
	  if ( ( !defined $lpar_data_cpu ) && $lpar_data eq "" ) {
	    error("no info for CPU_ALL in file $file_to_proces");
	    $lpar_message = ":lpar:::$entitled:U\::::";
	  }
	  else {
	    if ( $lpar_data_cpu ne "" ) {
	      ( undef, undef, $cpu_us, $cpu_sy, $cpu_wa ) = split( /,/, $lpar_data_cpu );
	    }
	    if ( $lpar_data ne "" ) {
	      if ( $cpu_us eq "" ) {
	        ( undef, undef, $physical_cpu, undef, undef, undef, $entitled, undef, undef, undef, undef, undef, undef, $cpu_us, $cpu_sy, $cpu_wa ) = split( /,/, $lpar_data );
	      }
	      else {
	        ( undef, undef, $physical_cpu, undef, undef, undef, $entitled ) = split( /,/, $lpar_data );
	      }
	      $lpar_message = ":lpar:::$entitled:$physical_cpu\::::";
	    } ## end if ( $lpar_data ne "" )
	  } ## end else [ if ( ( !defined $lpar_data_cpu...))]
	
	  # prepare ethernet adapter
	  # NET,Network I/O sse21,en2-read-KB/s,en4-read-KB/s,lo0-read-KB/s,en2-write-KB/s,en4-write-KB/s,lo0-write-KB/s
	  # NET,T1440,0.1,1.2,0.0,0.0,0.5,0.0
	
	  my $lan_message = "";
	
	  if ( defined $ent[0] && defined $net_data && $net_data ne "" ) {
	
	    # print "net_data, $net_data \$net_packet $net_packet\n"; # if $DEBUG == 3;
	    my @temparr = split( /,/, $net_data );
	    my @temparr_packet = split( /,/, $net_packet ) if $net_packet ne "";
	    my @temparr_error_packet = split( /,/, $net_error_packet ) if $net_error_packet ne "";
	    my $adapters = @ent;
	
#	    print "number of items in net_data, @ent ".@temparr."\n" ;
	    for ( my $i = 0; $i < $adapters; $i++ ) {
	      next if ( $ent[$i] =~ /^lo/ );
	      my $read      = $temparr[ $ent_inx[ 4 * $i ] ] * 1024;
	      my $write     = $temparr[ $ent_inx[ 4 * $i + 1 ] ] * 1024;
	      my $xfer_read = $temparr[ $ent_inx[ 4 * $i + 2 ] ];
	      my $ierrs = 0;
	      if ( $ent_inx[ 4 * $i + 2 ] == -1 ) {
	        if ( $net_packet ne "" ) {
	          $xfer_read = $temparr_packet[ $ent_inx[ 4 * $i ] ];
	        }
	        else {
	          $xfer_read = 0;
	        }
	        if($net_error_packet ne ""){
	        	$ierrs = $temparr_error_packet[ $ent_inx[ 4 * $i ] ];
	        }
	      } ## end if ( $ent_inx[ 4 * $i ...])
	      my $xfer_write = $temparr[ $ent_inx[ 4 * $i + 3 ] ];
	      my $oerrs = 0;
	      if ( $ent_inx[ 4 * $i + 3 ] == -1 ) {
	        if ( $net_packet ne "" ) {
	          $xfer_write = $temparr_packet[ $ent_inx[ 4 * $i + 1 ] ];
	        }
	        else {
	          $xfer_write = 0;
	        }
	        if($net_error_packet ne ""){
	        	$oerrs = $temparr_error_packet[ $ent_inx[ 4 * $i +1 ] ];
	        }
	      } ## end if ( $ent_inx[ 4 * $i ...])
	#      $lan_message .= ":lan:$ent[$i]:nmonip:$write:$read:$xfer_write:$xfer_read\::";
		  my $error = $oerrs + $ierrs;
		  my $droppedPackets_used = $error*100/($xfer_write + $xfer_read);
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'droppedPackets_used','value':'$droppedPackets_used'}");
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'write','value':'$write'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'write','value':'$write'}\n";
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'read','value':'$read'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'read','value':'$read'}\n";
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'xfer_write','value':'$xfer_write'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'xfer_write','value':'$xfer_write'}\n";
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'xfer_read','value':'$xfer_read'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'xfer_read','value':'$xfer_read'}\n";
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'oerrs','value':'$oerrs'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'oerrs','value':'$oerrs'}\n";
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'ierrs','value':'$ierrs'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'ierrs','value':'$ierrs'}\n";
		  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'error','value':'$error'}");
#		  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'lan','a_id':'$ent[$i]','tag':'error','value':'$error'}\n";
		  
	#       print "\$lan_message $lan_message\n";
	    } ## end for ( my $i = 0; $i < $adapters...)
	  } ## end if ( defined $ent[0] &&...)
	  
	  
	  if ( defined $lfiles[0] && defined $lfiles_data && $lfiles_data ne "" ) {
	
	    my @temparr = split( /,/, $lfiles_data );
	    my $mount = @lfiles;
	
	    # print "number of items in net_data, $adapters ".@temparr."\n" ;
	    my $file_message = "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'file','c':[";
	    for ( my $i = 2; $i < $mount; $i++ ) {
		  $file_message .= "{'a_id':'$lfiles[$i]','tag':'u_p','value':'$temparr[$i]'},";
	    } ## end for ( my $i = 0; $i < $adapters...)
	    $file_message .= "]}";
	    send_data(*F,$file_message);
#	    print  "$file_message\n"";
	  } ## end if ( defined $lfiles_data &&...)
	
	  # prepare fcsi adapter see sub read_first_part
	  # FCREAD,T0001,0.0
	  # FCWRITE,T0001,0.0
	  # FCXFERIN,T0001,0.0
	  # FCXFEROUT,T0001,0.0
	
	  my @refs = &prepare_fcread(@arr_one_run);
	  if(@refs){
		  @fcf= @{$refs[0]};
		  @fcf_inx = @{$refs[1]};
	  }
	  
	  my $fclan_message = "";
	  if ( defined $fcf[0] ) {
	    my @match_fcread    = grep {/^FCREAD,T/} @arr_one_run;
	    my @match_fcwrite   = grep {/^FCWRITE,T/} @arr_one_run;
	    my @match_fcxferin  = grep {/^FCXFERIN,T/} @arr_one_run;
	    my @match_fcxferout = grep {/^FCXFEROUT,T/} @arr_one_run;
	    my $fc_sum          = @match_fcread + @match_fcwrite + @match_fcxferin + @match_fcxferout;
	
	    if ( ( $fc_sum > 3 ) && ( ( $fc_sum % 4 ) == 0 ) ) {
	      my @fcread_arr    = split( /,/, $match_fcread[0] );
	      my @fcwrite_arr   = split( /,/, $match_fcwrite[0] );
	      my @fcxferin_arr  = split( /,/, $match_fcxferin[0] );
	      my @fcxferout_arr = split( /,/, $match_fcxferout[0] );
	
	      my $fc_full = "full";    # signal for daemon to touch signal for detail-graph-cgi.pl to graph xin/xout separately
	      for ( my $i = 0; $i < @fcf; $i++ ) {
	        my $read       = $fcread_arr[ $fcf_inx[$i] ] * 1024;
	        my $write      = $fcwrite_arr[ $fcf_inx[$i] ] * 1024;
	        my $xfer_read  = $fcxferin_arr[ $fcf_inx[$i] ] + $fcxferout_arr[ $fcf_inx[$i] ];
	        my $xfer_write = $fcxferout_arr[ $fcf_inx[$i] ];
#	        $fclan_message .= ":san:$fcf[$i]:nmonip:$read:$write:$xfer_read:$xfer_write:$fc_full\:";
	#        print "fclan_message : $fclan_message\n";
			send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'read','value':'$read'}");
#		    print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'read','value':'$read'}\n";
		    send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'write','value':'$write'}");
#		    print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'write','value':'$write'}\n";
		    send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'xfer_read','value':'$xfer_read'}");
#		    print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'xfer_read','value':'$xfer_read'}\n";
		    send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'xfer_write','value':'$xfer_write'}");
#		    print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'xfer_write','value':'$xfer_write'}\n";
		    send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'fc_full','value':'$fc_full'}");
#		    print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$fcf[$i]','tag':'fc_full','value':'$fc_full'}\n";
	      } ## end for ( my $i = 0; $i < @fcf...)
	    } ## end if ( ( $fc_sum > 3 ) &&...)
	  } ## end if ( defined $fcf[0] )
	
	  # in case defined FCREAD WRITE do not do this
	  # prepare fcsi adapter see sub read_first_part
	  # @fcs - fcs names eg fcs0, fcs1
	  # @fcs_inx - pointers to fcs data line for fcs-read & write
	  
	  if ( ( defined $fcs[0] ) && ( !defined $fcf[0] ) && ( defined $fcsnet_data ) ) {
	    $fclan_message = "";
	    if ( $fcsnet_data ne "" ) {
	
	      # print "fcsnet_data, $fcsnet_data\n" if $DEBUG == 3;
	      my @temparr = split( /,/, $fcsnet_data );
	      my $adapters = @fcs;
	
	      # print "number of items in fcs net_data, $adapters ".@temparr."\n" if $DEBUG == 3;
	      for ( my $i = 0; $i < $adapters; $i++ ) {
	        my $read       = $temparr[ $fcs_inx[ 4 * $i ] ] * 1024;
	        my $write      = $temparr[ $fcs_inx[ 4 * $i + 1 ] ] * 1024;
	        my $xfer_read  = $temparr[ $fcs_inx[ 4 * $i + 2 ] ];
	        my $xfer_write = $temparr[ $fcs_inx[ 4 * $i + 3 ] ];
	        $xfer_write = 0 if $fcs_inx[ 4 * $i + 3 ] == -1;
	        my $a_id= $fcs[$i];
	#        print "a_id :$a_id\n";
	        if ( $fcs[$i] !~ /available/ ) {
#	          $fclan_message .= ":san:$fcs[$i]:nmonip:$read:$write:$xfer_read:$xfer_write\::";
	          send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'read','value':'$read'}");
#	          print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'read','value':'$read'}\n";
#			  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'write','value':'$write'}\n";
			  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'write','value':'$write'}");
			  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'xfer_read','value':'$xfer_read'}");
#			  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'xfer_read','value':'$xfer_read'}\n";
			  send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'xfer_write','value':'$xfer_write'}");
#			  print  "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'san','a_id':'$a_id','tag':'xfer_write','value':'$xfer_write'}\n";
	        }
	      } ## end for ( my $i = 0; $i < $adapters...)
	    } ## end if ( $fcsnet_data ne "")
	  } ## end if ( ( defined $fcs[0]...))
	
	  # prepare SEA adapter see sub read_first_part
	  # @sea array names (starting 0) ent28-write-KB/s ent29-write-KB/s ent30-write-KB/s ...
	  # @sea_inx array (starting 0) 11 12 13 14 15 16 17 18 19 ...
	  # @phys_log_eth_sea   ent28,ent1 ent29,ent2 ent30,ent3 ent31,ent4 ... actually log,phys
	
	  my $sea_message = "";
	  if ( ( defined $sea[0] ) && ( defined $seanet_data ) ) {
	    if ( $seanet_data ne "" ) {
	
	      # print "seanet_data, $seanet_data\n";
	      my @temparr = split( /,/, $seanet_data );
	      my $adapters = @sea;
	
	      # print "number of items in sea net_data, $adapters and data items ".@temparr."\n";
	      for ( my $i = 0; $i < $adapters; $i++ ) {
	        ( my $et_name, my $read_inx, my $write_inx, my $phys_name ) = split( ' XORUX ', $sea[$i] );
	        my $read  = int( $temparr[$read_inx] * 1024 );
	        my $write = int( $temparr[$write_inx] * 1024 );
	        if ( $sea[$i] !~ /available/ ) {
	          $sea_message .= ":sea:$phys_name:$et_name:$write:$read\::::";
	        }
	      } ## end for ( my $i = 0; $i < $adapters...)
	    } ## end if ( $seanet_data ne "")
	
	    # print "\$sea_message $sea_message\n";
	  } ## end if ( ( defined $sea[0]...))
	
	  if ( $cpu_us eq "" ) { $cpu_us = 0 }
	  # {}
	  	my $mem_used = 100-($free*100)/$size;
	  #  if (($size + $inuse + $free + $pin + $in_use_work + $in_use_clnt) != 0) {
	#  $message .= ":mem:::$size:$inuse:$free:$pin:$in_use_work:$in_use_clnt";
		send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'used','value':'$mem_used'}");
		send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'size','value':'$size'}");
#		print F "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'size','value':'$size'}\n";
		send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'free','value':'$free'}");
#		print F "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'free','value':'$free'}\n";
		send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'inuse','value':'$inuse'}");
#		print F "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'inuse','value':'$inuse'}\n";
		send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'in_use_work','value':'$in_use_work'}");
#		print F "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'in_use_work','value':'$in_use_work'}\n";
		send_data(*F,"{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'in_use_clnt','value':'$in_use_clnt'}");
#		print F "{'s':'$server','l':'$lpar','l_id':$lpar_id,'t':$time_stamp_unix,'r_t':$mmtime,'v':'$version','device_type':'mem','tag':'in_use_clnt','value':'$in_use_clnt'}\n";
	  #  }
	
	#  $message .= ":pgs:::$page_in:$page_out:$paging_space:$paging_percent\::" if $paging_space ne "";
	
	  #  if (($cpu_sy + $cpu_us + $cpu_wa) > 0) {
	#  $message .= ":cpu:::$entitled:$cpu_sy:$cpu_us:$cpu_wa\::";
	
	  #  }
	
	  if ( index( $nmon_data, "ext_nmon_" ) != -1 ) {    # external NMON
	  }
	
	  #print " $message\n";
	
	  #   testing slash in server name
	  # if ($message =~ "Red") {
	  #   $message =~ s/Red/R\/ed/;
	  # }
	
	#  print FFA "$message\n";
	
	  return $time_stamp_unix;
	}; ## end sub read_one_run
	
	
		  
		  my $unix_time_start = prepare_time($zzzz_this);
		  $message = "";
		  my $nmon_unix_sent_time = 0;
		  my $o = 123;
		  open  (my $D_IN, "gzip -dc $file_to_proces |")  || error( "Cant open for reading $file_to_proces: $!" . __FILE__ . ":" . __LINE__ ) && return 0;
		  ( $server, $lpar, $lpar_id, $paging_space, $paging_percent, $proc_clock ) = $read_first_part -> ( 'notime', $file_to_proces,$D_IN);
#		  $read_one_run->($file_to_proces,$D_IN);
		  $data_collect ->();
		  while ($unix_time_start) {
		    $unix_time_start = $read_one_run->($unix_time_start,$file_to_proces,$D_IN);
		    if ( $unix_time_start > 0 ) {
		      $nmon_unix_sent_time = $unix_time_start;
		    }
		  } ## end while ($unix_time_start)
		  close $D_IN;
		  return $nmon_unix_sent_time;
};

sub prepare_fcread {
  my (@part1) = @_;
  my @fcf;
  my @fcf_inx;
  my @matches = grep {/FCREAD,Fibre/} @part1;
  if ( @matches != 1 ) {

    #  error ("cant recognize FCREAD,Fibre in NMON file $file_to_proces ");
  }
  else {
    my @linea = split( ",", $matches[0] );
    my @match_read = grep {/fcs[0-9]{1,2}/} @linea;
    print "match_read FCREAD fcs @match_read\n";

    @matches = grep {/FCWRITE,Fibre/} @part1;
    if ( @matches != 1 ) {
      error("cant recognize FCWRITE,Fibre after FCREADin NMON file ");
    }
    else {
      my @linea = split( ",", $matches[0] );
      my @match_write = grep {/fcs[0-9]{1,2}/} @linea;
      print "match_write FCWRITE fcs @match_write\n";
      if ( ( @match_read != @match_write ) || ( ( @match_read + @match_write ) < 2 ) ) {
        error("not same FCREADs as FCWRITEs (or zero) number in fcs line");
      }
      for ( my $i = 0; $i < @match_read; $i++ ) {
        $fcf[$i] = $match_write[$i];
        ( $fcf_inx[$i] ) = grep { $linea[$_] =~ /$fcf[$i]/ } 0 .. $#linea;

        # ($fcf_inx[4*$i+1]) = grep { $linea[$_] =~ /$fcf[$i]/ } 0..$#linea;
        # ($fcf_inx[4*$i+2]) = grep { $linea[$_] =~ /$fcf[$i]/ } 0..$#linea;
        # $fcf_inx[4*$i+3] = grep { $linea[$_] =~ /$fcf[$i]/ } 0..$#linea;
#        print "$i, fcf @fcf fcf_inx @fcf_inx\n";    #
      } ## end for ( my $i = 0; $i < @match_read...)
    } ## end else [ if ( @matches != 1 ) ]
    return (\@fcf,\@fcf_inx);
  } ## end else [ if ( @matches != 1 ) ]
} ## end sub prepare_fcread

# BBBS,000,Shared Ethernet Adapter stats,SEAs found,9
# BBBS,001,SEA1,ent28
# BBBS,002,SEA1,ent28,Naccounting,ctl_chan,gvrp,ha_mode,jumbo_frames,large_receive,largesend,lldpsvc,netaddr,pvid,pvid_adapter,qos_mode,real_adapter,thread,virt_adapters
# BBBS,003,SEA1,ent28,disabled,ent18,no,auto,no,no,1,no,0,1,ent9,disabled,ent1,1,ent9
# BBBS,004,SEA2,ent29
# BBBS,005,SEA2,ent29,Naccounting,ctl_chan,gvrp,ha_mode,jumbo_frames,large_receive,largesend,lldpsvc,netaddr,pvid,pvid_adapter,qos_mode,real_adapter,thread,virt_adapters
# BBBS,006,SEA2,ent29,disabled,ent19,no,auto,no,no,1,no,0,2,ent10,disabled,ent2,1,ent10
# . . .
# SEA,Shared Ethernet Adapter bsrv22vios2,ent28-read-KB/s,ent29-read-KB/s,ent30-read-KB/s,ent31-read-KB/s,ent32-read-KB/s,ent33-read-KB/s,ent34-read-KB/s,ent35-read-KB/s,ent36-read-KB/s,ent28-write-KB/s,ent29-write-KB/s,ent30-write-KB/s,ent31-write-KB/s,ent32-write-KB/s,ent33-write-KB/s,ent34-write-KB/s,ent35-write-KB/s,ent36-write-KB/s
#
# SEA,T0002,0.6,0.6,3903.3,15.6,950.0,1781.8,2.0,16.2,0.4,0.6,0.6,3903.3,15.6,950.0,1781.8,1.9,16.2,0.7
#
#           $message .= ":sea:$back_en:$en:$transb:$recb\::::";
#

sub prepare_sea_stats {
  my (@part1) = @_;
  my @phys_log_eth_sea;
  my @sea;
  my @matches = grep {/Shared Ethernet Adapter stats/} @part1;
#  print "SEA : @matches\n";
  if ( scalar @matches == 0 ) {
    return;
  }
  ( undef, undef, undef, undef, my $eth_tot ) = split( ',', $matches[0] );

  # print "SEA after having \$eth_tot $eth_tot\n";
  if ( !isdigit($eth_tot) ) {
    error("cannot get number of SEA ethernet stats ,$eth_tot, or more than one stats");
    return;
  }
  @matches = grep {/BBBS,.*SEA.*ent[0-9]+,.*/} @part1;
  my $info_line_num = scalar @matches;
  if ( $info_line_num != ( 2 * $eth_tot ) ) {
    error("not 2 times ,$eth_tot, info lines for SEA!, it is ,$info_line_num,");
  }
  my @sorted_eth = sort @matches;

  # print "SEA \@sorted_eth @sorted_eth\n";
  my $text_line;
  my $value_line;
  while ( scalar(@sorted_eth) != 0 ) {
    $text_line = shift(@sorted_eth);
    if ( $text_line =~ /real_adapter/ ) {
      $value_line = shift(@sorted_eth);
    }
    else {
      $value_line = $text_line;
      $text_line  = shift(@sorted_eth);
    }
    my @name_array = split( ',', $text_line );
    my $index = 0;
    ++$index until $name_array[$index] eq 'real_adapter' or $index > $#name_array;
    if ( $index > $#name_array ) {
      error("cannot find real_adapter item for SEA");
      return;
    }
    my @value_array = split( ',', $value_line );
    my $eth_value   = $value_array[$index];
    my $eth_to_push = "$name_array[3],$eth_value";
    push @phys_log_eth_sea, $eth_to_push;
  } ## end while ( scalar(@sorted_eth...))
  print "@phys_log_eth_sea\n";

  #  analyse data info line - it is one line, prepare table for read_one_run
  #  SEA,Shared Ethernet Adapter bsrv22vios2,
  #  ent28-read-KB/s,ent29-read-KB/s,ent30-read-KB/s,ent31-read-KB/s,ent32-read-KB/s,
  #  ent33-read-KB/s,ent34-read-KB/s,ent35-read-KB/s,ent36-read-KB/s,
  #  ent28-write-KB/s,ent29-write-KB/s,ent30-write-KB/s,ent31-write-KB/s,ent32-write-KB/s,
  #  ent33-write-KB/s,ent34-write-KB/s,ent35-write-KB/s,ent36-write-KB/s

  @matches = grep {/SEA,Shared Ethernet Adapter /} @part1;
  if ( @matches != 1 ) {

    # error ("cant recognize SEA,Shared Ethernet Adapter in NMON file $file_to_proces ");
  }
  else {
    my @linea = split( ",", $matches[0] );
    my @match_read = grep {/ent[0-9]{1,2}-read/} @linea;
    print "match_read SEA ent @match_read\n";

    my @match_write = grep {/ent[0-9]{1,2}-write/} @linea;
    print "match_write SEA ent @match_write\n";
    if ( ( @match_read != @match_write ) || ( ( @match_read + @match_write ) < 2 ) ) {
      error("not same SEA reads as writes (or zero) number in SEA line");
    }
    for ( my $i = 0; $i < @match_read; $i++ ) {
      ( my $et_name, undef ) = split( "-", $match_write[$i] );    # no matter read or write
      my ($phy_log_inx) = grep { $phys_log_eth_sea[$_] =~ /$et_name/ } 0 .. $#phys_log_eth_sea;
      my $phy_log_item = $phys_log_eth_sea[$phy_log_inx];
      print "found item phy_log ,$phy_log_item,\n";
      ( undef, my $phys_name ) = split( ',', $phy_log_item );

      #print "\$et_name $et_name $match_write[$i]\n";
      my ($read_inx)  = grep { $linea[$_] =~ /$et_name-read/ } 0 .. $#linea;    #index
      my ($write_inx) = grep { $linea[$_] =~ /$et_name-write/ } 0 .. $#linea;
      $sea[$i] = "$et_name XORUX $read_inx XORUX $write_inx XORUX $phys_name";
#      print "$i, SEA @sea \n";
    } ## end for ( my $i = 0; $i < @match_read...)
  } ## end else [ if ( @matches != 1 ) ]
  return (\@phys_log_eth_sea,\@sea);
}    # end of sub prepare_sea_stats

sub prepare_time {

  my $line = shift;

  # example:  ZZZZ,T1440,hh:mm:ss,27-MAR-2014  prepare timestamp

  ( undef, $line ) = split( /ZZZ,/, $line );    # if not in start of line

  # print "3328 line $line\n";

  ( undef, my $time_stamp_text, my $date_day, undef ) = split( /,/, $line );
  my %mon2num = qw(
    jan 0  feb 1  mar 2  apr 3  may 4  jun 5
    jul 6  aug 7  sep 8  oct 9  nov 10  dec 11
  );
  ( my $day, my $month, my $year ) = split( '-', $date_day );
  if ( $day < 1 || $day > 31 ) { $day = 1 }
  if ( length $month != 3 ) { $month = "JAN" }
  if ( $year < 2000 )       { $year  = 2000 }
  my $monum = $mon2num{ lc substr( $month, 0, 3 ) };
  ( my $hourd, my $mind, my $secd ) = split( ':', $time_stamp_text );
  return timelocal( $secd, $mind, $hourd, $day, $monum, $year );
} ## end sub prepare_time

sub prepare_net {
  my $test           = shift;
  my $file_to_proces = shift;
  my @part1 = @_;
  my @ent;
  my @ent_inx;
  my @matches = grep {/$test/} @part1;
  if ( @matches != 1 ) {
    error("cant recognize $test in NMON file $file_to_proces ");
  }
  else {
    my @linea = split( ",", $matches[0] );
    my @match_read = grep {/[A-Za-z]+[0-9]{1,2}-read/} @linea;
#    print "match_read en @match_read\n";
    my @match_write = grep {/[A-Za-z]+[0-9]{1,2}-write/} @linea;
    if ( @match_read != @match_write ) {
      error("not same reads as writes number in line $matches[0]");
    }
    if ( @match_read == 0 ) {
      print "zero reads number in en $test line $matches[0] in file $file_to_proces\n";
    }
    else {
      for ( my $i = 0; $i < @match_read; $i++ ) {
        ( $ent[$i], undef ) = split( "-", $match_read[$i] );
        ( $ent_inx[ 4 * $i ] ) = grep { $linea[$_] =~ /$ent[$i]-read/ } 0 .. $#linea;
        ( $ent_inx[ 4 * $i + 1 ] ) = grep { $linea[$_] =~ /$ent[$i]-write/ } 0 .. $#linea;
        $ent_inx[ 4 * $i + 2 ] = -1;    # same look as fcs
        $ent_inx[ 4 * $i + 3 ] = -1;
#        print "$i, en @ent ent_inx @ent_inx\n";
      } ## end for ( my $i = 0; $i < @match_read...)
    } ## end else [ if ( @match_read == 0 )]
  } ## end else [ if ( @matches != 1 ) ]
 return (\@ent,\@ent_inx);
} ## end sub prepare_net
sub prepare_lfiles {
  my $test           = shift;
  my $file_to_proces = shift;
  my @part1 = @_;
  my @matches = grep {/$test/} @part1;
  my @lfiles;
  if ( @matches != 1 ) {
    error("cant recognize $test in NMON file $file_to_proces ");
  }
  else {
    my @linea = split( ",", $matches[0] );
    for (my $i=2 ; $i < @linea;  $i++){
    	push( @lfiles ,  $linea[$i]);
    }
  } ## end else [ if ( @matches != 1 ) ]
	return @lfiles;
} ## end sub prepare_lfiles



sub data_collect {} ## end sub data_collect

sub process_limits {
  my ( $cmd, $limit, $ps_all_tmp ) = @_;
  my @ps_all   = @{$ps_all_tmp};
  my $ps_count = 0;

  foreach my $ps_line (@ps_all) {
    if ( $ps_line =~ m/$cmd/ && $ps_line !~ m/grep/ ) {

      #print "$ps_line";
      $ps_count++;
    }
  } ## end foreach my $ps_line (@ps_all)

  if ( $ps_count > $limit ) {
    return 1;
  }
  return 0;
} ## end sub process_limits

sub my_handler {
  print STDERR "The OS agent has crashed, no core on purpose\n";
  if ( -f $iostat_data_file ) {
    unlink($iostat_data_file);    # temporary iostat file
  }
  exit(1);
} ## end sub my_handler

#Clean error log if it is too big (1MB usually)
sub error_log_wipe {
  my $file     = shift;
  my $max_size = shift;
  if ( -e "$file" ) {
    if ( -r "$file" ) {

      #  print "file can read \n";
      my $size = ( stat $file )[7];
      if ( $size <= $max_size ) {

        #  print "file has not been deleted\n";
      }
      else {
        print "Cleaning the error log: $file ($size>=$max_size)\n";
        unlink($file) or print "file $file could not been deleted $!\n";
      }
    } ## end if ( -r "$file" )
  } ## end if ( -e "$file" )
  return 1;
} ## end sub error_log_wipe

sub get_smt {
  my ( $bindproc, $lsdev_proc_tmp ) = @_;
  my @lsdev_proc  = @{$lsdev_proc_tmp};
  my $cpu_logical = 0;
  my $cpu_smt     = 0;

  foreach my $line (@lsdev_proc) {
    chomp($line);
    if ( $line =~ m/Available/ ) {
      $cpu_logical++;
    }
  } ## end foreach my $line (@lsdev_proc)

  $bindproc =~ s/^.*: //;
  $bindproc =~ s/^ +//g;
  foreach my $line ( split( / /, $bindproc ) ) {
    $cpu_smt++;
  }

  if ( $cpu_smt == 0 || $cpu_logical == 0 ) {
    return "";
  }

  my $smt = $cpu_smt / $cpu_logical;

  if ( $smt != 0 && $smt != 2 && $smt != 4 && $smt != 8 && $smt != 16 && $smt != 32 && $smt != 64 ) {
    return "";
  }

  return $smt;

} ## end sub get_smt

sub ishexa {
  my $digit = shift;

  if ( !defined($digit) || $digit eq '' ) {
    return 0;
  }

  my $digit_work = $digit;
  $digit_work =~ s/^0x//;
  $digit_work =~ s/^0X//;
  $digit_work =~ s/[0-9]//g;
  $digit_work =~ s/\.//;
  $digit_work =~ s/^-//;
  $digit_work =~ s/e//;
  $digit_work =~ s/\+//;

  # hexa filter
  $digit_work =~ s/[a|b|c|d|e|f|A|B|C|D|E|F]//g;

  if ( length($digit_work) == 0 ) {

    # is a number
    return 1;
  }

  return 0;
} ## end sub ishexa

sub read_ps_aeo {
  my $os         = shift;
  my $result_ref = shift;

  #test OS-
  if ( $os =~ m/Linux/ ) {
    @$result_ref = `ps -aeo pid,user,time,vsize,rssize,args`;
  }
  elsif ( $os =~ m/SunOS/ ) {
    @$result_ref = `ps -aeo pid,user,time,vsz,rss,args`;
  }
  elsif ( $os =~ m/AIX/ ) {

    #print "PS-JOB:::This is AIX\n";
    @$result_ref = `ps -aeo pid,user,time,vsize,rssize,args`;

    #my $size_job=scalar @ps_job_old;-
    #print "PS-JOB-ARRAY:::@ps_job_old\n";
  } ## end elsif ( $os =~ m/AIX/ )
  else {
    print "PS-JOB: UNKNOWN OS\n";
  }
} ## end sub read_ps_aeo

sub write_ps_aeo {
  my $ps_job_config = shift;
  my $time_write    = shift;
  my $time_unix     = shift;
  my $ps_job_ref    = shift;

  #write new ps to file
  open( my $CF, "> $ps_job_config" ) or print ("PS-JOB: Cannot write $ps_job_config: $!" . __FILE__ . ":" . __LINE__) && return 1;
  print $CF "$time_write UNIX:$time_unix \n";
  foreach (@$ps_job_ref) {
    my $line_old = $_;

    #example:'  230 00:00:00 114644   680 root     /usr/bin/rsync --daemon --no-detach'
    chomp $line_old;
    $line_old =~ s/^\s+//;    #remove leading spaces
    ( my $pid, my $user, my $time_2,, my $vzs, my $rss, my $command ) = split( / +/, $line_old, 6 );

    # attn: comma not possible
    $command =~ s/,/---comma---/g;
    print $CF "$pid,$user,$command,$time_2,$vzs,$rss\n";
  } ## end foreach (@$ps_job_ref)
  close($CF);

  return 0;
} ## end sub write_ps_aeo

sub prepare_job_time {
  my $time_1 = shift;

  my $time_1_sec = 0;

  # prepare unix time from 'ps' time format
  my $count_time_1 = ( $time_1 =~ tr/:// );
  if ( $count_time_1 == 0 ) { return $time_1_sec }
  ;    # some trash

  # print "2112 \$count_time_1 $count_time_1 \$command $command\n";
  if ( $count_time_1 == "1" ) {
    ( my $min_new, my $sec_new ) = split( /:/, $time_1 );
    $time_1_sec = $min_new * 60 + $sec_new;
  }
  elsif ( $count_time_1 == "2" ) {

    # print "2118 \$count_time_1 $count_time_1 \$command $command\n";
    my $count_dash_1 = grep( /-/, $time_1 );

    #print "$count_dash_1\n";
    if ( $count_dash_1 == "0" ) {
      ( my $hour_new, my $min_new, my $sec_new ) = split( /:/, $time_1 );
      $time_1_sec = $hour_new * 3600 + $min_new * 60 + $sec_new;
    }
    else {
      ( my $hour_dash_1, my $min_new, my $sec_new ) = split( /:/, $time_1 );
      ( my $days_new, my $hour_new ) = split( /-/, $hour_dash_1 );
      $time_1_sec = $days_new * 86400 + $hour_new * 3600 + $min_new * 60 + $sec_new;
    }
  } ## end elsif ( $count_time_1 == ...)
  else {
    print "PS-JOB: UNKNOWN TIME FORMAT\n";
  }
  return $time_1_sec;
} ## end sub prepare_job_time


sub trimlog {
  my $file  = shift;
  my $limit = shift;

  my $check_limit = $limit + ( $limit * 0.1 );
  my $wcs         = `wc -l $file 2>/dev/null`;

  my ( $size, $filename ) = split ' ', $wcs;

  if ( $filename ne "total" && $size > $check_limit ) {
    print "trim logs      : file $filename contains $size lines, it will be trimmed to $limit lines\n";
    error("trim logs      : file $filename contains $size lines, it will be trimmed to $limit lines");

    my $keepfrom     = $size - $limit;
    my $filename_tmp = "$filename-tmp";

    open( IN,  "< $filename" )     || error( "Couldn't open file $filename $!" . __FILE__ . ":" . __LINE__ )     && exit;
    open( OUT, "> $filename_tmp" ) || error( "Couldn't open file $filename_tmp $!" . __FILE__ . ":" . __LINE__ ) && exit;

    my $count = 0;
    while ( my $iline = <IN> ) {
      chomp $iline;
      $count++;
      if ( $count > $keepfrom ) {
        print OUT "$iline\n";
      }
    } ## end while ( my $iline = <IN> )
    close IN;
    close OUT;

    rename "$filename_tmp", "$filename";
  } ## end if ( $filename ne "total"...)

  return 1;
}

sub file_time_diff {
  my $file = shift;

  my $act_time  = time();
  my $file_time = $act_time;
  my $time_diff = 0;

  if ( -f $file ) {
    $file_time = ( stat($file) )[9];
    $time_diff = $act_time - $file_time;
  }

  return ($time_diff);
} ## end sub file_time_diff

