#
#
# cyclone    -    This scripts follow up the whole path for given IP and VLAN and
#                 tries to identify loops within the path.
#
# Author            Emre Erkunt
#                   (emre.erkunt@superonline.net)
#
# History :
# -----------------------------------------------------------------------------------------------
# Version               Editor          Date            Description
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
# 0.0.1_AR              EErkunt         20150109        Initial ALPHA Release
# 0.0.2                 EErkunt         20150112        Increased index on nw_rt discovery
# 0.0.3                 EErkunt         20150112        nw_rt index logic change
#                                                       Added last topology change output on exit
# 0.0.4                 EErkunt         20150112        Added some minor color coding
# 0.0.5                 EErkunt         20150113        Added password masquearing via STDIN
# 0.0.6                 EErkunt         20150113        Added HUAWEI vendor capability
# 0.0.7                 EErkunt         20150113        Showing flap logs at exit if captured any
# 0.0.8                 EErkunt         20150115        Fixed password problem, shows w/out stars
# 0.0.9                 EErkunt         20150126        Color scheme standardized
#                                                       Fixed a problem about the end report
# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
#
# Needed Libraries
#
use Getopt::Std;
use Net::Telnet;
use Graph::Easy;
use LWP::UserAgent;
use HTTP::Headers;
use LWP::Simple;
use LWP::UserAgent;
use Win32::Console::ANSI;
use Term::ANSIColor;
use Net::SNMP qw( :snmp DEBUG_ALL ENDOFMIBVIEW );
use IO::Prompter;
use Term::ReadPassword::Win32;

my $version     = "0.0.9";
my $arguments   = "u:i:o:p:hvgnq";
my $MAXTHREADS	= 15;
our %opt;
getopts( $arguments, \%opt ) or usage();
$| = 1;
print color "bold yellow";
print "cyclone ";
print color 'bold white';
print "v".$version;
print color 'reset';
usage() if ( !$opt{u} );
usage() if (!$opt{i} or !$opt{u});
$opt{o} = "OUT_".$opt{i} unless ($opt{o});
$opt{t} = 2 unless $opt{t};
if ($opt{v}) { $opt{v} = 0; } else { $opt{v} = 1; }
$opt{debug} = 1 if ($opt{q});

$SIG{INT} = \&interrupt;
$SIG{TERM} = \&interrupt;

my $time = time();

my $svnrepourl  = ""; 												# Your private SVN Repository (should be served via HTTP). Do not forget the last /
my $SVNUsername = "";													# Your SVN Username
my $SVNPassword = "";													# Your SVN Password
my $SVNScriptName = "cyclone.pl";
my $SVNFinalEXEName = "cyclone";
our $SNMPVersion = "2";
our $SNMPCommunity = '';											# SNMP Community

unlink('upgrade'.$SVNFinalEXEName.'.bat');

$ua = new LWP::UserAgent;
my $req = HTTP::Headers->new;

unless ($opt{n}) {
	#
	# New version checking for upgrade
	#
	$req = HTTP::Request->new( GET => $svnrepourl.$SVNScriptName );
	$req->authorization_basic( $SVNUsername, $SVNPassword );
	my $response = $ua->request($req);
	my $publicVersion;
	my $changelog = "";
	my $fetchChangelog = 0;
	my @responseLines = split(/\n/, $response->content);
	foreach $line (@responseLines) {
		if ( $line =~ /^# Needed Libraries/ ) { $fetchChangelog = 0; }
		if ( $line =~ /^my \$version     = "(.*)";/ ) {
			$publicVersion = $1;
		} elsif ( $line =~ /^# $version                 \w+\s+/g ) {
			$fetchChangelog = 1;
		}
		if ( $fetchChangelog eq 1 ) { $changelog .= $line."\n"; }
	}
	if ( $version ne $publicVersion and length($publicVersion)) {		# SELF UPDATE INITIATION
		print color 'reset';
		print "\nSelf Updating to ";
		print color 'bold white';
		print "v".$publicVersion;
		print ".";
		$req = HTTP::Request->new( GET => $svnrepourl.$SVNFinalEXEName.'.exe' );
		$req->authorization_basic( $SVNUsername, $SVNPassword );
		if($ua->request( $req, $SVNFinalEXEName.".tmp" )->is_success) {
			print "\n# DELTA CHANGELOG :\n";
			print color 'magenta';
			print "# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
			print "# Version               Editor          Date            Description\n";
			print "# -=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-\n";
			print color 'reset';
			print $changelog;
			open(BATCH, "> upgrade".$SVNFinalEXEName.".bat");
			print BATCH "\@ECHO OFF\n";
			print BATCH "echo Upgrading started. Ignore process termination errors.\n";
			print BATCH "sleep 1\n";
			print BATCH "taskkill /F /IM ".$SVNFinalEXEName.".exe > NULL 2>&1\n";
			print BATCH "sleep 1\n";
			print BATCH "ren ".$SVNFinalEXEName.".exe ".$SVNFinalEXEName."_to_be_deleted  > NULL 2>&1\n";
			print BATCH "copy /Y ".$SVNFinalEXEName.".tmp ".$SVNFinalEXEName.".exe > NULL 2>&1\n";
			print BATCH "del ".$SVNFinalEXEName.".tmp > NULL 2>&1\n";
			print BATCH "del ".$SVNFinalEXEName."_to_be_deleted > NULL 2>&1\n";
			print BATCH "del NULL\n";
			print BATCH "echo All done. Please run the ".$SVNFinalEXEName." command once again.\n\n";
			close(BATCH);
			print "Initiating upgrade..\n";
			sleep 1;
			exec('cmd /C upgrade'.$SVNFinalEXEName.'.bat');
			exit;
		} else {
			print "Can not retrieve file. Try again later. You can use -n to skip updating\n";
			exit;
		}
	} else {
		print color 'bold green';
		print " ( up-to-date )\n";
	}
} else {
	print color 'red';
	print " ( no version check )\n";
}

print color 'reset';
print "Verbose mode ";
print color 'green';
print "ON\n" if ($opt{v});
print color 'reset';

#
# Main Loop
#
# Beware, dragons beneath here! Go away.
#

my $IP, $VLAN;
our %nodes, %edges, $obj, @hunted, $index, %tcs, $nwrtIndex, %flapDB;

if ( $opt{i} =~ /(\d*\.\d*\.\d*\.\d*):(\d*)/ ) {
	$IP = $1; $VLAN = $2;
} else {
	print color "bold red";
	print "ERROR: ";
	print color "reset";
	print "It seems that you forget to use IP:VLAN format on -i parameter\n\n";
	sleep 1;
	usage();
	exit 0;
}

# Get the Password from STDIN
#
$opt{p} = read_password('Enter your password : ') unless ($opt{p});


print "Hunting for Cyclones..\n" if ($opt{v});
huntForCyclones( $IP, $VLAN );

print "\nAll done."; # and saved on $opt{o} ";
#print "and $graphFilename." if ($opt{g});
print "\n";
print "Process took ".(time()-$time)." seconds.\n"   if($opt{v});

if ( scalar(keys(%flapDB)) ) {
	print "\nIt seems that I captured some flap logs from NEs.";

	my $selection = 1;
	my $question = 'Would you like to see them ?';

	while ( $selection ne 0 ) {
		$selection
			= prompt $question,
				-menu => {
					'Yes, let me pick the IP.' => [ keys(%flapDB) ],
					"No, I don't want to see." => 0,
			  }, '>';

		print "\n";
		if ( $selection ) {
			print color 'bold yellow';
			print "-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~\n";
			print color 'bold green';
			print $flapDB{$selection};
			print color 'bold yellow';
			print "-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~-~\n\n";
			print color 'reset';
			$question = 'Would you like to see more ?'
		}
	}
}

#
# Related Functions
#
sub huntForCyclones() {
	my $IP = shift;
	my $VLAN = shift;

	push(@hunted, $IP);	$index++;

	#
	# Initiate SNMP Object first
	my ($session, $error) = Net::SNMP->session(
                          -hostname      => $IP,
						  -version		 => $SNMPVersion,
                          -timeout       => 7,
                          -retries       => 2,
                          -community     => $SNMPCommunity,
                          -translate     => [-octetstring => 0],
                        );

	if ( !defined($session) ) {
		print color "bold red";
		print "ERROR: ";
		print color "reset";
		print "SNMP connection failed to $IP. (ErrCode: ".$session->error.")\n";
		return 0;
	}
	#

	my $STDOUT, @cmdSet, @regex;

	#
	# Identify Vendor and CI Name of Remote host
	my $vendorName = getSnmpOID( $session, '1.3.6.1.2.1.1.1.0' );
	if ( $vendorName =~ /huawei/gi ) {
		$vendorName = "huawei";
		$STDOUT = "";
		$cmdSet[0] = 'display stp topology-change | i Topology change initiator';
		$regex[0] = '\s*Topology change initiator\(notified\)\s*:(.*)';
		$cmdSet[10] = 'display interface _INTERFACE_';
		$regex[10] = '(GigabitEthernet\d*\/\d*\/\d*)\s*UP\s*\d*';
		$cmdSet[1] = '';
		$regex[1] = '';
		$cmdSet[11] = 'display lldp neighbor int _INTERFACE_ | i Management add';
		$regex[11] = 'Management address\s*: (\d*\.\d*\.\d*.\d*)';
		$cmdSet[2] = '';
		$regex[2] = '';
		$cmdSet[3] = 'display stp topology-change | i Time since last topology change';
		$regex[3] = '\s*Time since last topology change\s*:(.*)';
	} elsif ( $vendorName =~ /cisco/gi ) {
		$vendorName = "cisco";
		$STDOUT = "";
		$cmdSet[0] = 'sh spanning-tree vlan '.$VLAN.' detail | i from';
		$regex[0] = '\s*from\s*(.*)';
		$cmdSet[10] = 'sh interfaces _INTERFACE_ | i Members';
		$regex[10] = '\s*Members in this channel: (\w+\d*\/\d*)\s.*';
		$cmdSet[1] = 'sh cdp neighbors _INTERFACE_ detail | i IP add';
		$regex[1] = '\s*IP address: (\d*\.\d*\.\d*.\d*)';
		$cmdSet[11] = 'sh lldp neighbors _INTERFACE_ detail | i IP';
		$regex[11] = '\s*IP: (\d*\.\d*\.\d*\.\d*)';
		$cmdSet[2] = 'sh log | i flap';
		$regex[2] = '.*: (.*)';
		$cmdSet[3] = 'sh spanning-tree vlan 103 det | i last change occurred';
		$regex[3] = 'Number of topology changes \d* last change occurred (.*) ago';
	} elsif ( $vendorName =~ /alcatel-lucent/gi ) {
		$vendorName = "alcatel-lucent";
		$STDOUT = "ALU is NOT implemented!";
	} elsif ( $vendorName =~ /juniper/gi ) {
		$vendorName = "juniper";
		$STDOUT = "Juniper is NOT implemented!";
	} elsif ( $vendorName =~ /ericsson/gi ) {
		$vendorName = "ericsson";
		$STDOUT = "Ericsson is NOT implemented!";
	} elsif ( $vendorName =~ /nec/gi ) {
		$vendorName = "nec";
		$STDOUT = "NEC is NOT implemented!";
	} elsif ( $vendorName =~ /paloalto/gi ) {
		$vendorName = "paloalto";
		$STDOUT = "PALOALTO is NOT implemented!";
	}
	print "[$IP:$VLAN] Vendor is $vendorName\n" if ($opt{debug});
	my $ciName = getSnmpOID( $session, '1.3.6.1.2.1.1.5.0');
	print color "bold white";
	print "[$IP]"; # ($vendorName)";# \t$ciName";
	print color "reset";
	if ( $ciName =~ /nw_rt.*/ ) { $nwrtIndex++; }

	if ( $index > 2 and $ciName =~ /nw_rt.*/ and $nwrtIndex > 1 ) {
		print color 'bold green';
		print " <-- ";
		print color 'bold white';
		print "Reached backbone!\n";
		return 1;
	}

	my @tcKeys = keys (%tcs);
	if ( in_array(@tcKeys, $IP) ) {
		print color 'bold red';
		print " <-- WARNING : ";
		print color 'bold white';
		print "Seems like we're having an infinite loop! I'll quit.\n";
		return 1;
	}
	# print "Array : ";
	# print Dumper(%tcs);
	# print "( ".in_array(@tcKeys, $IP).", ".scalar(@tcKeys)." ".$tcKeys[scalar(@tcKeys)-1]." ) ";
	#

	my $prompt = authenticate($IP, $vendorName);
	if ( $prompt ) {
		print "[$IP:$VLAN] Authenticated!\n" if ( $opt{debug} );

		# Grab the flapping log first.
		print "[$IP:$VLAN] Running CMD : $cmdSet[2] with prompt $prompt ( filter with : $regex[2] )\n"  if ( $opt{debug} );
		my @return = $obj{$IP}->cmd(String => $cmdSet[2], Prompt => $prompt) or die($object->errmsg);
		my @flaps;
		my $flapRegex = $regex[2];
		foreach my $line (@return) {
			# print "RETURN LINE : $line";
			if ( $line =~ /$flapRegex/ ) {
				print "[$IP:$VLAN] Match Regex : $1\n" if ( $opt{debug} );
				push(@flaps, $line);
			}
		}
		print "[$IP:$VLAN] Grabbed ".scalar(@flaps)." line of non-unique flap alarms.\n" if ($opt{debug});
		if ( scalar(@flaps)) {
			foreach my $flap (@flaps) {
				print "[$IP:$VLAN] FLAP LOG : $flap\n" if ($opt{debug});
				$flapDB{$IP} .= $flap;
			}
		}
		@flaps = uniq(@flaps);
		print "[$IP:$VLAN] Grabbed ".scalar(@flaps)." line of unique flap alarms.\n" if ($opt{debug});
		if ( scalar(@flaps)) {
			foreach my $flap (@flaps) {
				print "[$IP:$VLAN] UNIQUE FLAP LOG : $flap\n" if ($opt{debug});
			}
		}

		# Grab the last topology change duration
		my $lastTCString = runRemoteCommand($obj{$IP}, $cmdSet[3], $prompt, $regex[3]);
		my $lastTCSeconds = stringToSeconds($lastTCString);
		if ( $lastTCSeconds < 0 or $lastTCSeconds > 10 ) {
			print "[$IP:$VLAN] Topology change has a normal duration : $lastTCString ( $lastTCSeconds )\n" if ($opt{debug});
			$tcs{$IP} = -1;
		} else {
			print "[$IP:$VLAN] Too short duration for topology change : $lastTCSeconds seconds.\n" if ($opt{debug});
			$STDOUT .= "[! TC $lastTCSeconds secs !] ";
			$tcs{$IP} = $lastTCSeconds;
		}

		# Lets find the related interface first ;
		my $STPItf = runRemoteCommand($obj{$IP}, $cmdSet[0], $prompt, $regex[0]);
		if ( $STPItf ) {
			if ( $STPItf =~ /^Port\-channel\d*/ ) {
				$cmdSet[10] =~ s/_INTERFACE_/$STPItf/g;
				$STPItf = runRemoteCommand($obj{$IP}, $cmdSet[10], $prompt, $regex[10]);
			} elsif ( $STPItf =~ /^Eth\-Trunk\d*/ ) {
				$cmdSet[10] =~ s/_INTERFACE_/$STPItf/g;
				$STPItf = runRemoteCommand($obj{$IP}, $cmdSet[10], $prompt, $regex[10]);
			}
			print "[$IP:$VLAN] Found Interface as $STPItf\n" if ($opt{debug});
			my $changedSTPItf = $STPItf;
			$changedSTPItf =~ s/GigabitEthernet/Gi/g;
			$STDOUT .= color "yellow";
			$STDOUT .= "$changedSTPItf)";
			$STDOUT .= color "reset";

			$cmdSet[1] =~ s/_INTERFACE_/$STPItf/g;
			my $neighBourIP = runRemoteCommand($obj{$IP}, $cmdSet[1], $prompt, $regex[1]);
			if (!$neighBourIP) {
				print "[$IP:$VLAN] Could not find any neighbourhood via CDP, trying LLDP.\n" if ($opt{debug});
				$cmdSet[11] =~ s/_INTERFACE_/$STPItf/g;
				$neighBourIP = runRemoteCommand($obj{$IP}, $cmdSet[11], $prompt, $regex[11]);
				$STDOUT .= color "bold yellow";
				$STDOUT .= " <==LLDP==> ";
				$STDOUT .= color "reset";
			} else {
				$STDOUT .= color "green";
				$STDOUT .= " <==CDP==> ";
				$STDOUT .= color "reset";
			}
			if ( $neighBourIP ) {
				print " ".$STDOUT;
				print "[$IP:$VLAN] Hunted Index: $index, Previous Node: ".$hunted[($index-2)]." [".scalar(@hunted)."])\n" if($opt{debug});
				if ( $hunted[($index-2)] eq $neighBourIP ) {
					print "Checking for hunted list (".scalar(keys(%tcs)).").\n"  if($opt{debug});
					my @hostsToBeChecked;
					foreach my $tcKey ( keys %tcs ) {
						print "Checking $tcKey ( $tcs{$tcKey} ) for hunted list.\n"  if($opt{debug});
						if ( $tcs{$tcKey} > 0 ) {
							push(@hostsToBeChecked, $tcKey);
							print "Added $tcKey to checklist.\n"  if($opt{debug});
						}
					}
					print "[".$hunted[($index-2)]."]";
					if ( scalar(@hostsToBeChecked) ) {
						print color "bold red";
						print " <-- WARNING: ";
						print color "reset";
						print "Might be a loop ! Check for topology changes on ";
						print join(", ", @hostsToBeChecked);
						print "! ( Last TC was $lastTCString ago. )\n";
					} else {
						print color "bold green";
						print " <-- ";
						print color "reset";
						print "Seems like a false positive to me. Go on! ( Last TC was $lastTCString ago. )\n";
					}
				} else {
					huntForCyclones( $neighBourIP, $VLAN );
				}
				return 1;
			} else {
				$STDOUT .= " (Can not find neighbour IP on interface ".$STPItf.")";
			}
		} else {
			$STDOUT .= " (Can not find STP Interface on VLAN ".$VLAN.")";
		}
	} else {
		$STDOUT .= " (Username/Password Problem)";
	}

	print " ".$STDOUT."\n";
}

sub runRemoteCommand( $ $ $ $ ) {
	my $object = shift;
	my $cmd = shift;
	my $prompt = shift;
	my $regex = shift;

	print "Running CMD : $cmd with prompt $prompt ( filter with : $regex )\n"  if ( $opt{debug} );
	my @return = $object->cmd(String => $cmd, Prompt => $prompt) or die($object->errmsg);
	foreach my $line (@return) {
		# print "RETURN LINE : $line";
		if ( $line =~ /$regex/ ) {
			print "Match Regex : $1\n" if ( $opt{debug} );
			return $1;
		}
	}
}

sub authenticate() {
	my $targetIP = shift;
	my $vendorName = shift;

	my @initialCommands, @prompt, $loginPrompt;
	my $timeOut = 5;

	$obj{$targetIP} = new Net::Telnet ( Timeout => 20 );
	$obj{$targetIP}->open($targetIP);

	if ( $vendorName eq "huawei" ) {
		$initialCommands[0] = "system-view";
		$prompt[0] = '/]$/';
		$initialCommands[1] = "screen-width 512";
		$prompt[1] = '/]:$/';
		$initialCommands[2] = "Y";
		$prompt[2] = '/]$/';
		$initialCommands[3] = "quit";
		$prompt[3] = '/<.*>$/';
		$initialCommands[4] = "screen-length 0 temporary";
		$prompt[4] = '/<.*>$/';
		$loginPrompt = '/<.*>$/';

		#
		# RFC 1037 Hack for stupid Huawei Telnet Service forcing us to use 80 chars width
		$obj{$targetIP}->option_callback(sub { return; });
        $obj{$targetIP}->option_accept(Do => 31);

		$obj{$targetIP}->telnetmode(0);
        $obj{$targetIP}->put(pack("C9",
		              255,					# TELNET_IAC
		              250,					# TELNET_SB
		              31, 0, 500, 0, 0,		# TELOPT_NAWS
		              255,					# TELNET_IAC
		              240));				# TELNET_SE
        $obj{$targetIP}->telnetmode(1);
		# idiots..
		#
	} elsif ( $vendorName eq "cisco" ) {
		$initialCommands[0] = "terminal length 0";
		$prompt[0] = '/#$/';
		$loginPrompt = '/#$/';
	}

	if ($obj{$targetIP}->login( Name => $opt{u}, Password => $opt{p}, Prompt => $loginPrompt, Timeout => $timeOut )) {

		# Fixing screen buffering problems
		for(my $i=0;$i < scalar(@initialCommands);$i++) {
			print "Running '$initialCommands[$i]' with prompt $prompt[$i] : " if ($opt{debug});
			$obj{$targetIP}->cmd(String => $initialCommands[$i], Prompt => $prompt[$i]);
			print "Ok!\n" if ($opt{debug});
		}

		return $loginPrompt;
	} else {
		return 0;
	}
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

sub in_array {
     my ($arr,$search_for) = @_;
     my %items = map {$_ => 1} @$arr;
     return (exists($items{$search_for}))?1:0;
}

sub getSnmpOID ( $ $ ) {
	my $session = shift;
	my $OID = shift;

	print "[".$session->hostname()."] Querying $OID : " if ($opt{debug});
	my $result = $session->get_request(-varbindlist => [ $OID ],);

	if (!defined $result and $opt{debug}) {
		printf "ERROR: %s.\n", $session->error();
		return 0;
	}

	print $result->{$OID}."\n"  if ($opt{debug});
	return $result->{$OID};
}

sub stringToSeconds {
	my $string = shift;
	my $output = -1;

	if ( $string =~ /(\d+) days (\d+)h:(\d+)m:(\d+)s/ ) {
		$output = (($1*86400)+($2*3600)+($3*60)+$4);
	} elsif ( $string =~ /(\d+):(\d+):(\d+)/) {
		$output = (($1*3600)+($2*60)+$3);
	}
	return $output;
}

sub usage {
		my $usageText = << 'EOF';

This scripts follow up the whole path for given IP and VLAN and tries to identify loops within the path

Author            Emre Erkunt
                  (emre.erkunt@superonline.net)

Usage : findLoops [-i IP:VLAN] [-v] [-o OUTPUT FILE] [-u USERNAME] [-p PASSWORD] [-g] [-n]

 Parameter Descriptions :
 -i [IP:VLAN]           First node IP and related VLAN that will be followed up for the whole path discovery
 -o [OUTPUT FILE]       Output file about results
 -u [USERNAME]          Given Username to connect NEs
 -p [PASSWORD]          Given Password to connect NEs
 -n                     Skip self-updating
 -g                     Generate network graph                             ( Default OFF )
 -v                     Disable verbose                                    ( Default ON )

EOF
		print $usageText;
		exit;
}   # usage()

sub interrupt {
	print color "reset";
	print "\nStopped by user-interaction!\n";
	exit 0;
}
