#!/usr/bin/env perl
# LPAR2min agent

# SYNOPSIS
#  lpar2min-agent.pl [-d] [-c] [-n __NMON_DIR__] __LPAR2min-SERVER__[:__PORT__]
#
#  -d  forces sending out data immediately to check communication channel (DEBUG purposes)
#  -c  agent collects
#  -n  agent sends only NMON data from NMON directory __NMON_DIR__
#
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
# crontab usage: run it either every 10 minutes to process new data collected by nmon or once a day to get all day in once
# 0,10,20,30,40,50 * * * * /usr/bin/perl /opt/lpar2min-agent/lpar2min-agent.pl -n __NMON_DIR__ __LPAR2min-SERVER__  > /var/tmp/lpar2min-agent-nmon.out 2>&1
#  -n option disables normal agent data collection, only NMON data is collected.
# Use 2 separate crontab lines to get standard OS agent data & NMON data load
#

my $version = "5.05-2";
print "LPAR2min agent version:$version\n" . (localtime) . "\n";
use strict;
use Time::Local;

#use warnings;
use File::Copy;
use Getopt::Std;
use FileHandle;
use Encode;
#use Net::FTP;

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
	print "ERROR You must provide at least one LPAR2min remark\n";
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
my $u ="admin";
my $p = "Huawei\@123";
my $ftp_dir = "upload";
my $inteval                = 60;
my $max_delay              = time() - 60 * 5;
my $nmon_remain_days       = 7;
my $user_name              = getpwuid($<);
my $base_dir               = "/var/tmp";
my $store_not_confirm_file = "$base_dir/lpar2min-agent-$host-$user_name.txt";
my $timestamp_file         = "$base_dir/lpar2min-agent-$host-$user_name.stamp";
my $timestamp_file_send = "$base_dir/lpar2min-agent-$host-$user_name.stamp-send"
  ;    # UNIX timestamp of latest confirmed saved record on the daemon side
my $trimlogs_run = "$base_dir/lpar2min-agent-$host-$user_name.stamp-trimlogs";
my $RUN_TIME = 300;  # send out data every 5 minutes and when random() returns 1
my $MAX_RANDOM_TIME = 1200
  ; # maximum time when data is sent to the server (sending is randomized, this is just maximum)
my $protocol_version = "4.0";
my $error_log        = "$base_dir/lpar2min-agent-$host-$user_name.err";
my $act_time_u       = time();
my $act_time         = localtime($act_time_u);
my $act_time_nmon    = $act_time_u - $nmon_remain_days * 24 * 60 * 60;
my $last_ok_time = 0;    # must be global one due to alarm()
my $first_new_pgs_file = "$base_dir/lpar2min-agent-pgs.cfg"
  ;    #send paging1 'U' 'U' when creating this file - paging 64kB too
my $iostat_data_file = "$base_dir/lpar2min-agent-iostat-$act_time_u.txt";
my $UNAME            = "uname";
my $os               = `$UNAME 2>>$error_log`;
chomp($os);

my $rand_sleep = int(rand($inteval * 4));
print "sleep  $rand_sleep,then send\n";
sleep($rand_sleep);
#my $rand_sleep = int( rand( $inteval * 4 ) );
#print "sleep  $rand_sleep,then send\n";
#sleep($rand_sleep);
#
# Trim logs
#
my $trim_file_time_diff = file_time_diff("$trimlogs_run");
if ( !-f "$trimlogs_run" || $trim_file_time_diff > 86400 ) {    # once per day
	trimlog( "$store_not_confirm_file", "43000" );    # limit = 43000 lines
	trimlog( "$error_log",              "1000" );     # limit =  1000 lines

	# trim nmon logs if exists
	my $agent_nmon_file_for_trim =
	  "$base_dir/lpar2min-agent-nmon-$host-$user_name.txt";
	my $nmon_error_log_for_trim =
	  "$base_dir/lpar2min-agent-nmon-$host-$user_name.err";
	if ( -f "$agent_nmon_file_for_trim" ) {
		trimlog( "$agent_nmon_file_for_trim", "43000" );
	}
	if ( -f "$nmon_error_log_for_trim" ) {
		trimlog( "$nmon_error_log_for_trim", "1000" );
	}

	my $ret =
	  `touch $trimlogs_run`;    # to keep same routine for all timestamp files
	if ($ret) {
		error( "$ret " . __FILE__ . ":" . __LINE__ );
	}
}

#
# Check if is not running more than 10 agent instances
# If so then exit to do not harm the agent hosted OS
#
my $PROC_RUN_LIMIT =20;    # to support WPARs where hosted OS see all processes of the WPAR
my @ps = `ps -ef`;

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

if ( $os =~ m/SunOS/ ) {
	$ENV{LANG} = "C"
	  ; # also must be due to parsing of cmd's outputs;# also must be due to parsing of cmd's outputs
}
else {
	$ENV{LANG} = "en_US";    # also must be due to parsing of cmd's outputs
}

if ($opt_d) {                # forces sending out data immediately
	$RUN_TIME = 1;
	$STEP     = 5;    # fast up vmstat --> but also faster time out in alarm!!!
}

#
#-- test if NMON agent
#
my $nmon_data = "";

# if  -n nmon_data_path
# use alert here to be sure that it does not hang
if ($opt_n) {
	my $timeout = 36000
	  ; # 10hours, necessary to have here a long timeout to be sure data is loaded for many nmon files!!!
	my $ret = 0;
	eval {
		local $SIG{ALRM} = sub { die "died in SIG ALRM : agent"; };
		alarm($timeout);
		my @nmonps = `ps -ef|grep m$opt_n|grep -v grep|grep -v "sh -c"`;
		if ( !@nmonps ) {
			$error_log = "$base_dir/lpar2min-agent-nmon-$host-$user_name.err";
			error(  "NMON is not running.start to run nmon "
				  . __FILE__ . ":"
				  . __LINE__ );
			my ( $sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst )
			  = localtime;
			my $end = timelocal( 0, 0, 0, $mday + 1, $mon, $year );
			my $count = int( ( $end - time() ) / $inteval );
			`/usr/bin/nmon -f -t -V -E -s$inteval -c$count -m'$opt_n'`;
			exit(1);
		}
		else {
			if ( @nmonps > 1 ) {
				foreach my $ps_line (@nmonps) {
					my @pls = split( /\s+/, $ps_line );
					my @ts  = split( /:/,   $pls[5] );
					my $ts_len = @ts;
					if ( @ts != 3 ) {
						`kill -9 $pls[2]`;
					}

				}
			}
		}
		my $ps_n_count = 0;
		my @ps         = `ps -ef|grep $0|grep -v grep|grep -v "sh -c"`;
		foreach my $ps_line (@ps) {
			print "$ps_line\n";
			if ( $ps_line =~ /\s\-n/ && $ps_line =~ /$host/ ) {
				$ps_n_count++;
			}
		} ## end foreach my $ps_line (@ps)

		if ( $ps_n_count > 1 ) {
			$error_log = "$base_dir/lpar2min-agent-nmon-$host-$user_name.err";
			error(  "Exiting as two NMON agents cant run "
				  . __FILE__ . ":"
				  . __LINE__ );
			exit 1;
		}
		if ( !-d $opt_n ) {
			$error_log = "$base_dir/lpar2min-agent-nmon-$host-$user_name.err";
			error(  "NMON_dir: $opt_n does not exist "
				  . __FILE__ . ":"
				  . __LINE__ );
			exit 1;
		}
		print "NMON_dir set to $opt_n\n";
		$nmon_data = $opt_n;
		$ret       = send_nmon_data();
		alarm(0);
	};

	if ($@) {
		chomp($@);
		if ( $@ =~ /died in SIG ALRM/ ) {
			error(  "NMON agent timed out after : $timeout seconds "
				  . __FILE__ . ":"
				  . __LINE__ );
		}
		else {
			error( "NMON agent failed : $@ " . __FILE__ . ":" . __LINE__ );
		}
		exit(1);
	} ## end if ($@)
	exit($ret);
} ## end if ($opt_n)



sub store_for_later_transfer {
	my $message                = shift;
	my $store_not_confirm_file = shift;

	print "$store_not_confirm_file\n $message\n";
	open( FS, ">> $store_not_confirm_file" )
	  || error(
		"Can't open $store_not_confirm_file: $! " . __FILE__ . ":" . __LINE__ );
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
		my $random = substr( int( rand(10) ), 0, 1 );   # substr just to be sure
		if ( isdigit($random) == 0 ) {
			$random = 1;
		}
		my $next_time = $last_send_time + $run_time;
		if ( $next_time > $act_time_u || $random != 1 ) {
			if ( ( $act_time_u - $last_send_time ) > $MAX_RANDOM_TIME ) {

				# send it out after 20 minutes the latest _ 1200 secs
				print
"Agent send 20m : sending data now (act_time=$act_time_u, last_send_time=$last_send_time, next_time=$next_time, random=$random)\n";
				my $ret = `touch $timestamp_file`;
				if ($ret) {
					error( "$ret" . __FILE__ . ":" . __LINE__ );
				}
				return 1;
			} ## end if ( ( $act_time_u - $last_send_time...))
			else {
				print
"Agent send     : not sending data this time (act_time=$act_time_u, last_send_time=$last_send_time, next_time=$next_time, random=$random)\n";
				return 0;
			}
		} ## end if ( $next_time > $act_time_u...)
		else {
			print
"Agent send     : sending data now (act_time=$act_time_u, last_send_time=$last_send_time, next_time=$next_time, random=$random)\n";
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

	return 1;
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
			open( FS, "< $timestamp_file_send" )
			  || error( "Can't open $timestamp_file_send: $! "
				  . __FILE__ . ":"
				  . __LINE__ )
			  && return 0;
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
			return 0;        # not yet saved time
		}
	} ## end if ( $read_write =~ m/read/)
	else {

		if ( $saved_time == 0 ) {
			return 0;        # skip it when it is 0
		}
		open( FS, "> $timestamp_file_send" )
		  || error(
			"Can't open $timestamp_file_send: $! " . __FILE__ . ":" . __LINE__ )
		  && return 0;
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
my @files_tmp;
my $interval;
my $server;
my $lpar;
my $lpar_id;
my $paging_space;
my $paging_percent;
my $message;
my $proc_clock;
my @lfiles;
my $zzzz_this;
my $last_zzzz_this;
my @part1;
my $os_type;
my $os_version;
my $print_line;
my $nmon_external_time;

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
	$nmon_external_time = "";
	if ( index( $nmon_data, "ext_nmon_" ) != -1 ) {    # external NMON
		$print_line = "<BR>";

# get nmon_external_time from e.g. '/tmp/ext_nmon_1402555094/external_nmon_file_name'
		( undef, $nmon_external_time ) = split( "ext_nmon_", $nmon_data );
		( $nmon_external_time, undef ) = split( "\/", $nmon_external_time );
		if (   ( !isdigit($nmon_external_time) )
			|| ( $nmon_external_time < 1400000000 ) )
		{
			error(  "error \$nmon_external_time $nmon_external_time "
				  . __FILE__ . ":"
				  . __LINE__ );
			$nmon_external_time = "1444555666";
		}
	} ## end if ( index( $nmon_data...))
	my $numArgs = $#ARGV + 1;

	# print "thanks, you gave me $numArgs command-line arguments:$print_line";
	my $ret = 0;

	foreach my $argnum ( 0 .. $#ARGV ) {

		print "NMON working for server: $ARGV[$argnum] $print_line";

		$signal_file =
		  "$base_dir/lpar2min-agent-nmon-$host-$user_name-time_file.txt";
		$agent_nmon_file = "$base_dir/lpar2min-agent-nmon-$host-$user_name.txt";
		$error_log       = "$base_dir/lpar2min-agent-nmon-$host-$user_name.err";

		$ret = send_nmon_data_for_one_server();
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

	opendir( DIR, $nmon_data )
	  || error( "can't opendir $nmon_data: $!" . __FILE__ . ":" . __LINE__ )
	  && return 1;
	@files_tmp =
	  grep { !/^\./ && !/\.gz|\.Z|\.bz2/ && -f "$nmon_data/$_" } readdir(DIR);
	closedir DIR;

	if ( !defined $files_tmp[0] ) { return 1 }

	print "files NMON read:\n", join( "\n", @files_tmp ), "\n";

	fill_files();    # create sorted list of NMON files

	print "NMON read sorted files:\n", join( "\n", @files ), "\n";

	if ( !defined $files[0] ) {    # nothing to send
		return 0;
	}
	open( DF_IN, "< $signal_file" )
	  || error(
		"Cant open for reading $signal_file: $!" . __FILE__ . ":" . __LINE__ )
	  && return 1;
	my @signal_lines = <DF_IN>;
	close DF_IN;

	# LOOP:
	for my $i ( 0 .. $#files ) {
		( my $data_origin_1, my $timefile ) = split( /_TIME_/, $files[$i] );
		my ( $orig_time, $orig_file ) = split( /_XOR_/, $timefile );
		my $sent_time = 0;

		my @matches = grep { /\Q$data_origin_1\E/ } @signal_lines;
		if ( @matches > 1 ) {
			error("Two items $data_origin_1 in \@signal_lines not possible");
		}
		my ($index) = grep { $signal_lines[$_] =~ /\Q$data_origin_1\E/ }
		  0 .. $#signal_lines;
		if ( !defined $index ) { $index = -1 }
		print "index in signal array for $data_origin_1 is $index\n";
		if ( $index != (-1) ) {    # exists
			( undef, $sent_time ) = split( /_TIME_/, $signal_lines[$index] );
			( $sent_time, undef ) = split( /_XOR_/, $sent_time );
			if ( $orig_time < $sent_time ) {    # if NO send it
				                                # look ahead file
				if ( defined $files[ $i + 1 ] ) {    # if NO send it
					( my $data_origin_2, my $timefile ) =
					  split( /_TIME_/, $files[ $i + 1 ] );
					if ( $data_origin_1 eq $data_origin_2 ) {    # if NO send it
						( my $look_ahead_orig_time, undef ) =
						  split( /_XOR_/, $timefile );
						if ( $look_ahead_orig_time < $sent_time ) {
							next

							  # skip old files
						}
					} ## end if ( $data_origin_1 eq...)
				} ## end if ( defined $files[ $i...])
			} ## end if ( $orig_time < $sent_time)
		} ## end if ( $index != (-1) )
		print "here all cases for send for $orig_file\n";

		my $result = prepare_nmon_file( "$nmon_data/$orig_file", $sent_time );

		# 0 - err, $nmon_unix_sent_time of last data

		print "final prepared data time $result\n";
		if ( $result == 0 ) {
			print "err preparing file to send $orig_file \n";
			return 1;
		}
		if ( call_agent_send($agent_nmon_file) == 1 ) {
			return 1;
		}

		# write signal to signal array
		my $new_signal = "$data_origin_1" . "_TIME_$result" . "_XOR_$orig_file";
		if ( $index == (-1) ) {
			push @signal_lines, $new_signal;
		}
		else {
			$signal_lines[$index] = $new_signal;
		}

		# save signal array to signal file after each successful sent file
		open( DF_OUT, "> $signal_file" )
		  || error( "Cant open for writing $signal_file: $!"
			  . __FILE__ . ":"
			  . __LINE__ )
		  && return 1;
		foreach (@signal_lines) {
			chomp($_);
			print DF_OUT "$_\n"; # save each entry from signal array to the file
		}
		close DF_OUT;

	}    # end of cycle for

	return 0;
} ## end sub send_nmon_data_for_one_server

sub call_agent_send {
	my $file_to_send = shift;

	#my  $DEBUG=3;
	#    $DEBUG=0;

	if ( !-f $file_to_send ) {
		error("call_agent_send: file to send does not exist");
		return 1;
	}
	my $file_len = -s $file_to_send;
	print "call_agent_send: file to send has $file_len length\n\n";
	return 0 if $file_len == 0;

	my $ret = send_data_for_one_server( $file_to_send, $protocol_version );

	return $ret;
} ## end sub call_agent_send

sub fill_files {

	# @files_tmp  is a list of files
	# if file is NMON file
	#  -> create name = "SRV_server_LPR_lpar_TIME_time_XOR_file-name"
	#  -> fill @files with these names
	#  sort @files

	#my  $DEBUG=3;
	#    $DEBUG=0;

	my @new_files;

	for my $file (@files_tmp) {
		my $server                 = "";
		my $lpar                   = "";
		my $unix_time_first_record = 0;

		open( DF_IN, "< $nmon_data/$file" )
		  || error(
			"Cant open for reading $file: $!" . __FILE__ . ":" . __LINE__ )
		  && return 0;
		( $server, $lpar, $unix_time_first_record ) =
		  read_first_part( 'yestime', "$nmon_data/$file" );
		print "$server,$lpar,$unix_time_first_record are from file $file\n";
		close DF_IN;

		if ( $lpar ne "" && $server ne "" && $unix_time_first_record != 0 ) {
			if ( $unix_time_first_record > $act_time_nmon ) {
				my $xstr =
				    "SRV_$server"
				  . "_LPR_$lpar"
				  . "_TIME_$unix_time_first_record"
				  . "_XOR_$file";
				print "push new name $xstr\n";
				push @new_files, $xstr;
			}
			else {
				print "remove $nmon_data/$file \n";
				`rm -f $nmon_data/$file`;
			}
		}
		else {
			print "not NMON file $file\n";    #if $DEBUG == 3;
		}
	} ## end for my $file (@files_tmp)
	@files = sort @new_files;
} ## end sub fill_files

sub prepare_nmon_file {
	my $file_to_proces  = shift;
	my $unix_time_start = shift;              # preparing from

	$message = "";
	my $nmon_unix_sent_time = 0;

	#my    $DEBUG=3;
	# my    $DEBUG=0;

	# prepares file to send to $agent_nmon_file
	# $agent_nmon_file    # contains filename for data sending to daemon
	# returns
	# 0 - err, nmon_unix_sent_time of last data

	print
"preparing data from $file_to_proces starting after time $unix_time_start\n"
	  ;    # if $DEBUG == 3;

	open( FFA, ">> $agent_nmon_file" )
	  || error( "Cant open for writing $agent_nmon_file: $!"
		  . __FILE__ . ":"
		  . __LINE__ )
	  && return 0;

	open( DF_IN, "< $file_to_proces" )
	  || error( "Cant open for reading $file_to_proces: $!"
		  . __FILE__ . ":"
		  . __LINE__ )
	  && return 0;
	( $server, $lpar, $lpar_id, $paging_space, $paging_percent, $proc_clock ) =
	  read_first_part( 'notime', $file_to_proces );

#  print "$server,$lpar,$lpar_id,$paging_space,$paging_percent,$proc_clock,$unix_time_start,\n" if $DEBUG == 3;
	if ($opt_c) {
		data_collect();
	}

	if ( $unix_time_start == 0 ) { $unix_time_start++ }
	;    # just for starting cycle
	while ($unix_time_start) {
		$unix_time_start = read_one_run( $unix_time_start, $file_to_proces );
		if ( $unix_time_start > 0 ) {
			$nmon_unix_sent_time = $unix_time_start;
		}
	} ## end while ($unix_time_start)

	close FFA;
	close DF_IN;
	return $nmon_unix_sent_time;
} ## end sub prepare_nmon_file

sub read_first_part {
	my $yestime        = shift;    # if 'yestime' then only for test
	my $file_to_proces = shift;

	#  my $DEBUG = 0;

	$interval       = 60;
	$server         = "";
	$lpar           = "";
	$lpar_id        = "0";
	$paging_space   = "false";
	$paging_percent = "";
	$proc_clock     = "";
	@lfiles         = ();
	@part1          = ();

	my $lpar_n       = "";
	my $lpar_runname = "";    #for AIX 5.3.

	my $line;

	while ( $line = <DF_IN> ) {
		$line =~ s/\r[\n]*/\n/gm;    # all platforms Unix, Windows, Mac
		chomp($line);
		push @part1, $line;
		if ( @part1 > 2000000 ) {
			error(
"err reading first part of NMON file (more than 2000000 lines) $file_to_proces "
			);
			return ( "", "", 0 );
		}
		last if $line =~ "ZZZZ,T";
	} ## end while ( $line = <DF_IN> )
	if ( $line !~ "ZZZZ,T" ) {
		error(
"unable reading first part of NMON file (didnt find ZZZZ,T) $file_to_proces "
		);
		return ( "", "", 0 );
	}
	$zzzz_this      = $line;
	$last_zzzz_this = $line;

	# all systems checks
	my $lines_read = @part1;
	print "part1 lines read $lines_read until $last_zzzz_this\n";

	#  CPU_ALL,CPU Total bsrpdev0035,User%,Sys%,Wait%,Idle%,Busy%,CPUs#

	my @matches = grep { /AAA,interval/ } @part1;
	if ( @matches != 1 ) {
		error("cant recognize AAA,interval in NMON file $file_to_proces ");
		return ( "", "", 0 );
	}
	( undef, undef, my $part ) = split( /,/, $matches[0] );
	$interval = $part;
	if ( $interval != ( $interval * 1 ) ) {
		error(
"cant recognize interval in NMON line $matches[0] in file $file_to_proces"
		);
		return ( "", "", 0 );
	}

	# try to find out which system & lpar name

	@matches = grep { /AIX/ && !/lscfg/ } @part1;

	if ( @matches > 0 ) {    # working for AIX
		$os_type = "AIX";

		@matches = grep { /AAA,AIX/ } @part1;

		if ( @matches == 1 ) {
			( undef, undef, $os_version ) = split( /,/, $matches[0] );
			print "os_version:$os_version\n";
		}

		$server = "1165-J4K"; # fake name when there are no definition lines BBB
		@matches =
		  grep { /System Model/ || /de syst/ } @part1;    #/System Model/ ||
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
			@matches = grep { /AAA,MachineType/ } @part1;
			if ( @matches != 1 ) {
				error(
					"cant recognize System Model: in NMON file $file_to_proces "
				);
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
			@matches = grep { /AAA,SerialNumber/ } @part1;
			if ( @matches != 1 ) {
				error(
"cant recognize Machine Serial Number: in NMON file $file_to_proces "
				);
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

		@matches = grep { /,lparname,/ } @part1;
		if ( @matches != 1 ) {

			# error ("cant recognize lparname in NMON file $file_to_proces ");
		}
		else {
			( undef, undef, undef, my $part ) = split( /,/, $matches[0] );
			$part =~ s/\"//g;
			$lpar = $part;
		}
		@matches = grep { /AAA,LPARNumberName/ } @part1;
		if ( @matches != 1 ) {

	# error ("cant recognize AAA,LPARNumberName in NMON file $file_to_proces ");
		}
		else {
			( undef, undef, $lpar_id, my $part ) = split( /,/, $matches[0] );
			$part =~ s/\"//g;
			$lpar_n = $part;
		}
		@matches = grep { /AAA,runname,/ } @part1;
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
		if ( defined $ENV{LPAR2RRD_HOSTNAME_PREFER}
			&& $ENV{LPAR2RRD_HOSTNAME_PREFER} == 1 )
		{

			# special solution for blade server - lpar > prefare host name
			@matches = grep { /AAA,host,/ } @part1;
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

		@matches = grep { /ZZZZ,T/ } @part1;
		if ( @matches != 1 ) {
			error("cant recognize ZZZ time in NMON file $file_to_proces ");
			return ( "", "", 0 );
		}
		my $time_stamp_unix = prepare_time( $matches[0] );

		if ( $yestime eq 'yestime' ) {
			return ( $server, $lpar, $time_stamp_unix );
		}

		@matches = grep { /Entitled processor capacity/ } @part1;
		if ( @matches != 1 ) {
			error(
"cant recognize Entitled processor capacity in NMON file $file_to_proces "
			);
		}
		else {
			( undef, undef, undef, $part ) = split( /,/, $matches[0] );
			$part =~ s/\"ent_capacity//g;
			( $part, undef ) = split( /Entitled/, $part );
			$part =~ s/ //g;
		} ## end else [ if ( @matches != 1 ) ]

		return ( $server, $lpar, $lpar_id, $paging_space, $paging_percent,
			$proc_clock );
	} ## end if ( @matches > 0 )

	@matches = grep { /Linux/ } @part1;
	$os_type = "OS-like-Linux";

	if ( @matches > 0 ) {    # working for Linux - will you differ by flavours?

		@matches = grep { /Red Hat/ } @part1;
		if ( @matches > 0 ) {
			$os_type = "LINUX-RedHat";
		}
		@matches = grep { /Arch Linux/ } @part1;
		if ( @matches > 0 ) {
			$os_type = "LINUX-Arch";
		}

		@matches = grep { /Solaris/ } @part1;
		if ( @matches > 0 ) {
			$os_type = "UX-Solaris";
		}

		@matches = grep { /Ubuntu/ } @part1;
		if ( @matches > 0 ) {
			$os_type = "Ubuntu";
		}

		print "working for $os_type $print_line";
		$server = $os_type;

		@matches = grep { /AAA,host/ } @part1;
		if ( @matches != 1 ) {
			error("cant recognize AAA,host: in NMON file $file_to_proces ");
			return ( "", "", 0 );
		}
		( undef, undef, my $part ) = split( /,/, $matches[0] );
		$part =~ s/ //g;
		my $lpar_n = $part;

		@matches = grep { /AAA,runname/ } @part1;
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

		@matches = grep { /ZZZZ,T/ } @part1;
		if ( @matches != 1 ) {
			error("cant recognize ZZZ time in NMON file $file_to_proces ");
			return ( "", "", 0 );
		}
		my $time_stamp_unix = prepare_time( $matches[0] );

		if ( $yestime eq 'yestime' ) {
			return ( $server, $lpar, $time_stamp_unix );
		}

		prepare_net( "NET,Network", $file_to_proces );

		return ( $server, $lpar, $lpar_id, "", "", "" );
	} ## end if ( @matches > 0 )

	error("cant recognize OS from NMON file $file_to_proces ");
	return ( "", "", 0 );
}    # end of sub read_first_part

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

sub prepare_lfiles {
	my $test           = shift;
	my $file_to_proces = shift;

	my @matches = grep { /$test/ } @part1;
	if ( @matches != 1 ) {
		error("cant recognize $test in NMON file $file_to_proces ");
	}
	else {
		my @linea = split( ",", $matches[0] );
		for ( my $i = 2 ; $i < @linea ; $i++ ) {
			push( @lfiles, $linea[$i] );
		}
	} ## end else [ if ( @matches != 1 ) ]

} ## end sub prepare_net

sub read_one_run {
	my $start_time     = shift;
	my $file_to_proces = shift;

	#  my $DEBUG = 0;
	#     $DEBUG = 3;
	my $zzzz            = "";
	my $line            = "";
	my $indx            = 0;
	my $time_stamp_unix = 0;

	if ( $zzzz_this !~ "ZZZZ,T" ) {
		print
"didnt find ZZZZ,T for read_one_run, probably end of file $file_to_proces\n$last_zzzz_this";
		return 0;
	}

	#  print " date $zzzz_this\n";

	$time_stamp_unix = prepare_time($zzzz_this);

	my $act_time    = localtime($time_stamp_unix);
	my @arr_one_run = ("$zzzz_this");

	while ( ( defined( $line = <DF_IN> ) ) && ( $line !~ "ZZZZ,T" ) ) {

		#		$line =~ s/\r[\n]*/\n/gm;    # all platforms Unix, Windows, Mac
		#		chomp($line);
		push @arr_one_run, $line;    # read lines from one run
	}
	if ( !defined($line) ) {
		$zzzz_this = "";
	}
	else {
		$zzzz_this      = $line;
		$last_zzzz_this = $line;
	}

	if ( $time_stamp_unix <= $start_time || $time_stamp_unix <= $max_delay )
	{                                #already sent
		return $start_time;
	}
	for my $a (@arr_one_run) {
		if ($a) {
			print FFA "$a";
		}
	}
	return $time_stamp_unix;
} ## end sub read_one_run

sub data_collect {
	foreach $a (@part1) {
		if ( $a !~ "ZZZZ,T" ) {
			print FFA "$a\n";
		}
	}
} ## end sub data_collect

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

	if (   $smt != 0
		&& $smt != 2
		&& $smt != 4
		&& $smt != 8
		&& $smt != 16
		&& $smt != 32
		&& $smt != 64 )
	{
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
	open( my $CF, "> $ps_job_config" )
	  or print(
		"PS-JOB: Cannot write $ps_job_config: $!" . __FILE__ . ":" . __LINE__ )
	  && return 1;
	print $CF "$time_write UNIX:$time_unix \n";
	foreach (@$ps_job_ref) {
		my $line_old = $_;

#example:'  230 00:00:00 114644   680 root     /usr/bin/rsync --daemon --no-detach'
		chomp $line_old;
		$line_old =~ s/^\s+//;    #remove leading spaces
		( my $pid, my $user, my $time_2,, my $vzs, my $rss, my $command ) =
		  split( / +/, $line_old, 6 );

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
			( my $hour_dash_1, my $min_new, my $sec_new ) =
			  split( /:/, $time_1 );
			( my $days_new, my $hour_new ) = split( /-/, $hour_dash_1 );
			$time_1_sec =
			  $days_new * 86400 + $hour_new * 3600 + $min_new * 60 + $sec_new;
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
	my $wcs = `wc -l $file 2>/dev/null`;

	my ( $size, $filename ) = split ' ', $wcs;

	if ( $filename ne "total" && $size > $check_limit ) {
		print
"trim logs      : file $filename contains $size lines, it will be trimmed to $limit lines\n";
		error(
"trim logs      : file $filename contains $size lines, it will be trimmed to $limit lines"
		);

		my $keepfrom     = $size - $limit;
		my $filename_tmp = "$filename-tmp";

		open( IN, "< $filename" )
		  || error(
			"Couldn't open file $filename $!" . __FILE__ . ":" . __LINE__ )
		  && exit;
		open( OUT, "> $filename_tmp" )
		  || error(
			"Couldn't open file $filename_tmp $!" . __FILE__ . ":" . __LINE__ )
		  && exit;

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

#BBBP,698,ifconfig
#BBBP,699,ifconfig,"en0: flags=1e084863,480<UP,BROADCAST,NOTRAILERS,RUNNING,SIMPLEX,MULTICAST,GROUPRT,64BIT,CHECKSUM_OFFLOAD(ACTIVE),CHAIN>"
#BBBP,700,ifconfig,"	inet 10.20.32.106 netmask 0xffffff00 broadcast 10.20.32.255"
#BBBP,701,ifconfig,"	 tcp_sendspace 262144 tcp_recvspace 262144 rfc1323 1"
#BBBP,702,ifconfig,"lo0: flags=e08084b,c0<UP,BROADCAST,LOOPBACK,RUNNING,SIMPLEX,MULTICAST,GROUPRT,64BIT,LARGESEND,CHAIN>"
#BBBP,703,ifconfig,"	inet 127.0.0.1 netmask 0xff000000 broadcast 127.255.255.255"
#BBBP,704,ifconfig,"	inet6 ::1%1/0"
#BBBP,705,ifconfig,"	 tcp_sendspace 131072 tcp_recvspace 131072 rfc1323 1"
sub ifconfig_excute() {
	my @tmps = `ifconfig -a`;

	my $i  = 1000;
	my @ms = ("BBBP,$i,ifconfig");
	for my $line (@tmps) {
		$i = $i + 1;
		chomp($line);
		push( @ms, "BBBP,$i,ifconfig,\"$line\"" );
	}
	return @ms;
}
sub send_data_for_one_server {
	my $store_file       = shift;
	my $protocol_version = shift;

	if ( !-f "$store_file" ) {
		error(  "Error: $store_file does not exist - nothing to re-send: $! "
			  . __FILE__ . ":"
			  . __LINE__ );
		return 0;    # nothing to re-send
	}
	open( FR, "< $store_file" )
	  || error( "Can't open $store_file: $! " . __FILE__ . ":" . __LINE__ )
	  && return 1;

	my $server_saved_time = keep_time( 0, "read" );

	my $counter         = 0;
	my $counter_err     = 0;
	my $store_file_indx = 0;
	my $line_refused    = "";

	close(FR);
	
	# save last OK record time
	keep_time( $last_ok_time, "write" );
	my $tg_file = "$server-$lpar-$act_time_u";
	my $store_file_name=$store_file;
	$store_file_name =~ s/$base_dir\// /g;
	print "store_file_name:$store_file_name\n";
	`cd $base_dir
	tar -cvf  $tg_file.tar $store_file_name
	gzip -f $tg_file.tar`;
#	my $ftp = Net::FTP->new($host,Port=>$port,BlockSize=>1024000) || die "create new ftp object failed !\n";
#	$ftp->login($u,$p)||die "can not login ftp $host\n",$ftp->message();
#	my $dir=$ftp->pwd();
#	my @items=$ftp->ls($dir);
#	print "ftp cur dir is :@items\n";
#	$ftp->cwd($ftp_dir)||die "can not change ftp dir to $ftp_dir\n",$ftp->message();
#	$ftp->binary();
#	$ftp->put("$base_dir/$tg_file.tar.gz")||die "put the file $tg_file.tar\n",$ftp->message();
#	$ftp->quit();
       system("
		expect <<EOD
		spawn  sftp -o Port=$port $u\@$host
		expect -timeout 2 \"(yes/no)?\" {send \"yes\r\"}
		expect	\"password\" {send \"$p\r\"}	
		expect	\"sftp>\"
		send \"cd $ftp_dir\r\"
		expect	\"sftp>\"
		send \"lcd $base_dir\r\"
		expect	\"sftp>\"
		send \"put $tg_file.tar.gz\r\"
		expect	\"sftp\" {send \"bye\r\"}
	");
#	`
#	lftp -u $u,$p sftp://$host:$port <<EOF
#	cd $ftp_dir
#	lcd $base_dir
#	put $tg_file.tar.gz
#	bye
#	EOF
#	`;
	`cd $base_dir
	rm -f $tg_file.tar.gz`;
	unlink("$store_file");

	if ( $counter_err > 0 ) {
		error("Number of errors in the input file: $counter_err");
	}
	if ( -f "$store_file-tmp" && $store_file_indx > 0 ) {

		#print "004\n";
		rename( "$store_file-tmp", "$store_file" );
		error(
"Error: Not all data has been sent out, refused line: $line_refused "
			  . __FILE__ . ":"
			  . __LINE__ );
		return 1;  # do not continue in sending actual one as there is a problem
	} ## end if ( -f "$store_file-tmp"...)

	return 0;
} ## end sub send_data_for_one_server
