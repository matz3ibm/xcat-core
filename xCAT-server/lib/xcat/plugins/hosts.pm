# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
package xCAT_plugin::hosts;
use strict;
use warnings;
use xCAT::Table;
use xCAT::TableUtils;
use xCAT::NetworkUtils;
use Data::Dumper;
use File::Copy;
use Getopt::Long;
use Fcntl ':flock';

my @hosts;    #Hold /etc/hosts data to be written back
my $LONGNAME;
my $OTHERNAMESFIRST;
my $ADDNAMES;
my $MACTOLINKLOCAL;


#############   TODO - add return code checking !!!!!

my %usage =
  (makehosts =>
    "Usage: makehosts <noderange> [-d] [-n] [-l] [-a] [-o] [-m]\n       makehosts -h",
    );

sub handled_commands
{
    return {makehosts => "hosts",};
}

sub delnode
{
    my $node = shift;
    my $ip   = shift;

    unless ($node and $ip)
    {
        return;
    }    #bail if requested to do something that could zap /etc/hosts badly

    my $othernames = shift;
    my $domain     = shift;
    my $idx        = 0;

    while ($idx <= $#hosts)
    {
        if (($ip and $hosts[$idx] =~ /^${ip}\s/)
            or $hosts[$idx] =~ /^\d+\.\d+\.\d+\.\d+\s+${node}[\s\.r]/)
        {
            $hosts[$idx] = "";
        }
        $idx++;
    }
}

sub addnode
{
    my $node = shift;
    my $ip   = shift;

    unless ($node and $ip)
    {
        return;
    }    #bail if requested to do something that could zap /etc/hosts badly

    my $othernames = shift;
    my $domain     = shift;
	my $nics  	   = shift;
    my $idx        = 0;
    my $foundone   = 0;

	# if this ip was already added then just update the entry 
    while ($idx <= $#hosts)
    {

        if (   $hosts[$idx] =~ /^${ip}\s/
            or $hosts[$idx] =~ /^\d+\.\d+\.\d+\.\d+\s+${node}[\s\.r]/)
        {
            if ($foundone)
            {
                $hosts[$idx] = "";
            }
            else
            {
				# we found a matching entry in the hosts list
				if ($nics) {
					# we're processing the nics table and we found an
					#   existing entry for this ip so just add this
					#	node name as an alias for the existing entry
					my ($hip, $hnode, $hdom, $hother)= split(/ /, $hosts[$idx]);

					# at this point "othernames", if any is just a space
					#	delimited list - so just add the node name to the list
					$othernames .= " $node";
					$hosts[$idx] = build_line($ip, $hnode, $domain, $othernames);
				} else {
					# otherwise just try to completely update the existing
					#	entry
                	$hosts[$idx] = build_line($ip, $node, $domain, $othernames);
				}
            }
            $foundone = 1;
        }
        $idx++;
    }
    if ($foundone) { return; }

    my $line = build_line($ip, $node, $domain, $othernames);
    push @hosts, $line;
}

sub build_line
{
    my $ip         = shift;
    my $node       = shift;
    my $domain     = shift;
    my $othernames = shift;
    my @o_names    = ();
    my @n_names    = ();
    if (defined $othernames)
    {
		# the "hostnames" attribute can be a list delimited by 
		#	either a comma or a space
        @o_names = split(/,| /, $othernames);
    }
    my $longname;
    foreach (@o_names)
    {
        if (($_ eq $node) || ($domain && ($_ eq "$node.$domain")))
        {
            $longname = "$node.$domain";
            $_        = "";
        }
        elsif ($_ =~ /\./)
        {
            if (!$longname)
            {
                $longname = $_;
                $_        = "";
            }
        }
        elsif ($ADDNAMES)
        {
            unshift(@n_names, "$_.$domain");
        }
    }
    unshift(@o_names, @n_names);

    if ($node =~ m/\.$domain$/i)
    {
        $longname = $node;
        $node =~ s/\.$domain$//;
    }
    elsif ($domain && !$longname)
    {
        $longname = "$node.$domain";
    }

    $othernames = join(' ', @o_names);
    if    ($LONGNAME)        { return "$ip $longname $node $othernames\n"; }
    elsif ($OTHERNAMESFIRST) { return "$ip $othernames $longname $node\n"; }
    else { return "$ip $node $longname $othernames\n"; }
}

sub addotherinterfaces
{
    my $node            = shift;
    my $otherinterfaces = shift;
    my $domain          = shift;

    my @itf_pairs = split(/,/, $otherinterfaces);
    foreach (@itf_pairs)
    {
		my ($itf, $ip); 
		if ($_  =~ /!/) {
			($itf, $ip) = split(/!/, $_);
		} else {
        	($itf, $ip) = split(/:/, $_);
		}
        if ($ip && xCAT::NetworkUtils->isIpaddr($ip))
        {
            if ($itf =~ /^-/)
            {
                $itf = $node . $itf;
            }
            addnode $itf, $ip, '', $domain;
        }
    }
}

sub process_request
{
    Getopt::Long::Configure("bundling");
    $Getopt::Long::ignorecase = 0;
    Getopt::Long::Configure("no_pass_through");

    my $req      = shift;
    my $callback = shift;

    my $HELP;
    my $REMOVE;

    # parse the options
    if ($req && $req->{arg}) { @ARGV = @{$req->{arg}}; }
    else { @ARGV = (); }

    # print "argv=@ARGV\n";
    if (
        !GetOptions(
                    'h|help'                 => \$HELP,
                    'n'                      => \$REMOVE,
                    'd'                      => \$::DELNODE,
                    'o|othernamesfirst'      => \$OTHERNAMESFIRST,
                    'a|adddomaintohostnames' => \$ADDNAMES,
                    'm|mactolinklocal'       => \$MACTOLINKLOCAL,
                    'l|longnamefirst'        => \$LONGNAME,
        )
      )
    {
        $callback->({data => $usage{makehosts}});
        return;
    }

    # display the usage if -h
    if ($HELP)
    {
        $callback->({data => $usage{makehosts}});
        return;
    }

    my $hoststab = xCAT::Table->new('hosts');
    my $domain;
    my $lockh;

    @hosts = ();
    if ($REMOVE)
    {
        if (-e "/etc/hosts")
        {
            my $bakname = "/etc/hosts.xcatbak";
            rename("/etc/hosts", $bakname);

            # add the localhost entry if trying to create the /etc/hosts from scratch
            if ($^O =~ /^aix/i)
            {
                push @hosts, "127.0.0.1 loopback localhost\n";
            }
            else
            {
                push @hosts, "127.0.0.1 localhost\n";
            }
        }
    }
    else
    {
        if (-e "/etc/hosts")
        {
            my $bakname = "/etc/hosts.xcatbak";
            copy("/etc/hosts", $bakname);
        }


		#  the contents of the /etc/hosts file is saved in the @hosts array
		#	the @hosts elements are updated and used to re-create the 
		#	/etc/hosts file at the end by the writeout subroutine.
        open($lockh, ">", "/tmp/xcat/hostsfile.lock");
        flock($lockh, LOCK_EX);
        my $rconf;
        open($rconf, "/etc/hosts");    # Read file into memory
        if ($rconf)
        {
            while (<$rconf>)
            {
                push @hosts, $_;
            }
            close($rconf);
        }
    }

    if ($req->{node})
    {
        if ($MACTOLINKLOCAL)
        {
            my $mactab = xCAT::Table->new("mac");
            my $machash = $mactab->getNodesAttribs($req->{node}, ['mac']);
            foreach my $node (keys %{$machash})
            {

                my $mac = $machash->{$node}->[0]->{mac};
                if (!$mac)
                {
                    next;
                }
                my $linklocal = xCAT::NetworkUtils->linklocaladdr($mac);

				my $netn;
                ($domain, $netn) = &getIPdomain($linklocal, $callback);

                if ($::DELNODE)
                {
                    delnode $node, $linklocal, $node, $domain;
                }
                else
                {
                    addnode $node, $linklocal, $node, $domain;
                }
            }
        }
        else
        {
            my $hostscache =
              $hoststab->getNodesAttribs($req->{node},
                                       [qw(ip node hostnames otherinterfaces)]);
            foreach (@{$req->{node}})
            {

                my $ref = $hostscache->{$_}->[0];

				my $netn;
                ($domain, $netn) = &getIPdomain($ref->{ip}, $callback);

                if ($::DELNODE)
                {
                    delnode $ref->{node}, $ref->{ip}, $ref->{hostnames}, $domain;
                }
                else
                {
                    if (xCAT::NetworkUtils->isIpaddr($ref->{ip}))
                    {
                        addnode $ref->{node}, $ref->{ip}, $ref->{hostnames}, $domain;
                    }
                    if (defined($ref->{otherinterfaces}))
                    {
                        addotherinterfaces $ref->{node}, $ref->{otherinterfaces}, $domain;
                    }
                }
            }    #end foreach
        }    # end else

        # do the other node nics - if any
        &donics($req->{node}, $callback);
    }
    else
    {
        if ($::DELNODE)
        {
            return;
        }
        my @hostents =
          $hoststab->getAllNodeAttribs(
                                ['ip', 'node', 'hostnames', 'otherinterfaces']);

        my @allnodes;
        foreach (@hostents)
        {

            push @allnodes, $_->{node};

			my $netn;
           ($domain, $netn) = &getIPdomain($_->{ip});

            if (xCAT::NetworkUtils->isIpaddr($_->{ip}))
            {
                addnode $_->{node}, $_->{ip}, $_->{hostnames}, $domain;
            }
            if (defined($_->{otherinterfaces}))
            {
                addotherinterfaces $_->{node}, $_->{otherinterfaces}, $domain;
            }
        }

        # also do nics table
        &donics(\@allnodes, $callback);
    }

    writeout();

    if ($lockh)
    {
        flock($lockh, LOCK_UN);
    }
}

sub writeout
{
    my $targ;
    open($targ, '>', "/etc/hosts");
    foreach (@hosts)
    {
        print $targ $_;
    }
    close($targ);
}

#-------------------------------------------------------------------------------

=head3    donics

           Add the additional network interfaces for a list of nodes as 
				indicated in the nics table

        Arguments:
               node name
        Returns:
			0 - ok
			1 - error

        Globals:

        Example:
                my $rc = &donics(\@nodes, $callback);

        Comments:
                none
=cut

#-------------------------------------------------------------------------------
sub donics
{
    my $nodes    = shift;
    my $callback = shift;

    my @nodelist = @{$nodes};

    my $nicstab = xCAT::Table->new('nics');
    my $nettab  = xCAT::Table->new('networks');

    foreach my $node (@nodelist)
    {
		my $nich;
		my %nicindex;

        # get the nic info
        my $et =
          $nicstab->getNodeAttribs(
                                   $node,
                                   [
                                    'nicips', 'nichostnamesuffixes',
                                    'nicnetworks'
                                   ]
                                   );

        if (
            !(
                  $et->{nicips}
               && $et->{'nichostnamesuffixes'}
               && $et->{'nicnetworks'}
            )
          )
        {
            next;
        }

		# gather nics info
		# delimiter could be ":" or "!"  
		# new  $et->{nicips} looks like 
		#		"eth0!11.10.1.1,eth1!60.0.0.5|60.0.0.250..."
        my @nicandiplist = split(',', $et->{'nicips'});
        foreach (@nicandiplist)
        {
			my ($nicname, $nicip);

			# if it contains a "!" then split on "!"
			if ($_  =~ /!/) {
				($nicname, $nicip) = split('!', $_);
			} else {
            	($nicname, $nicip) = split(':', $_);
			}

			$nicindex{$nicname}=0;

			if (!$nicip) {
				next;
			}

			if ( $nicip =~ /\|/) {
				my @ips = split( /\|/, $nicip);
				foreach my $ip (@ips) {
					$nich->{$nicname}->{nicip}->[$nicindex{$nicname}] = $ip;
					$nicindex{$nicname}++;
				}
			} else {
				$nich->{$nicname}->{nicip}->[$nicindex{$nicname}] = $nicip;
				$nicindex{$nicname}++;
			}
		}

        my @nicandsufx = split(',', $et->{'nichostnamesuffixes'});
        foreach (@nicandsufx)
        {
			my ($nicname, $nicsufx);
			if ($_  =~ /!/) {
				($nicname, $nicsufx) = split('!', $_);
			} else {
            	($nicname, $nicsufx) = split(':', $_);
			}

            if (!$nicsufx) {
                next;
            }

            if ( $nicsufx =~ /\|/) {
                my @sufs = split( /\|/, $nicsufx);
				my $index=0;
                foreach my $suf (@sufs) {
                    $nich->{$nicname}->{nicsufx}->[$index] = $suf;
					$index++;
                }
            } else {
                $nich->{$nicname}->{nicsufx}->[0] = $nicsufx;
            }
        }

        my @nicandnetwrk = split(',', $et->{'nicnetworks'});
        foreach (@nicandnetwrk)
        {
			my ($nicname, $netwrk);
			if ($_  =~ /!/) {
				($nicname, $netwrk) = split('!', $_);
			} else {
            	($nicname, $netwrk) = split(':', $_);
			}
            if (!$netwrk) {
                next;
            }

            if ( $netwrk =~ /\|/) {
                my @nets = split( /\|/, $netwrk);
                my $index=0;
                foreach my $net (@nets) {
                    $nich->{$nicname}->{netwrk}->[$index] = $net;
                    $index++;
                }
            } else {
                $nich->{$nicname}->{netwrk}->[0] = $netwrk;
            }
        }
		# end gather nics info

		# add or delete nic entries in the hosts file
		foreach my $nic (keys %{$nich}) {
            # make sure we have the short hostname
            my $shorthost;
            ($shorthost = $node) =~ s/\..*$//;

			for (my $i = 0; $i < $nicindex{$nic}; $i++ ){

				my $nicip = $nich->{$nic}->{nicip}->[$i];
				my $nicsuffix = $nich->{$nic}->{nicsufx}->[$i];
				my $nicnetworks = $nich->{$nic}->{netwrk}->[$i];

				if (!$nicip) {
					next;
				}

            	# construct hostname for nic
            	my $nichostname = "$shorthost$nicsuffix";

            	# get domain from network def
				my $nt = $nettab->getAttribs({ netname => "nicnetworks"}, 'domain');

				# look up the domain as a check or if it's not provided
				my ($nicdomain, $netn) = &getIPdomain($nicip, $callback);
				if ($nt->{domain}) {
					if($nicnetworks ne $netn) {
						my $rsp;
						push @{$rsp->{data}}, "The xCAT network name listed for \'$nichostname\' is \'$nicnetworks\' however the nic IP address \'$nicip\' seems to be in the \'$netn\' network.\nIf there is an error then makes corrections to the database definitions and re-run this command.\n"; 
						xCAT::MsgUtils->message("W", $rsp, $callback);
					}
					$nicdomain = $nt->{domain};
				}

            	if ($::DELNODE)
            	{
                	delnode $nichostname, $nicip, '', $nicdomain;
            	}
            	else
            	{
                	addnode $nichostname, $nicip, '', $nicdomain, 1;
				}
            } # end for each index
        }    # end for each nic
    }    # end for each node

    $nettab->close;
    $nicstab->close;

    return 0;
}

#-------------------------------------------------------------------------------

=head3    getIPdomain

			Find the xCAT network definition match the IP and then return the
				domain value from that network def.

        Arguments:
               node IP
				callback
        Returns:
            domain and netname - ok
            1 - error

        Globals:

        Example:
                my $rc = &getIPdomain($nodeIP, $callback);

        Comments:
                none
=cut

#-------------------------------------------------------------------------------
sub getIPdomain
{
    my $nodeIP   = shift;
    my $callback = shift;

    # get the network defs
    my $nettab = xCAT::Table->new('networks');
    my @nets   = $nettab->getAllAttribs('netname', 'net', 'mask', 'domain');

    # foreach network def
    foreach my $enet (@nets)
    {
        my $NM  = $enet->{'mask'};
        my $net = $enet->{'net'};
        if (xCAT::NetworkUtils->ishostinsubnet($nodeIP, $NM, $net))
        {
            return ($enet->{'domain'}, $enet->{'netname'});
            last;
        }
    }

    # could not find the network domain for this IP address
    return 1;
}

1;
