#!/usr/bin/perl -w

# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

##############################################################################
# $Id: vmware.pm 1953 2008-12-12 14:23:17Z arkurth $
##############################################################################

=head1 NAME

VCL::Provisioning::esx - VCL module to support the vmware esx provisioning engine

=head1 SYNOPSIS

 Needs to be written

=head1 DESCRIPTION

 This module provides VCL support for vmware server
 http://www.vmware.com

=cut

##############################################################################
package VCL::Module::Provisioning::esx;

# Include File Copying for Perl
use File::Copy;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../../..";

# Configure inheritance
use base qw(VCL::Module::Provisioning);

# Specify the version of this module
our $VERSION = '1.00';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;

use VCL::utils;
use Fcntl qw(:DEFAULT :flock);

# Used to query for the MAC address once a host has been registered
use VMware::VIRuntime;
use VMware::VILib;



##############################################################################

=head1 CLASS ATTRIBUTES

=cut

=head2 %VMWARE_CONFIG

 Data type   : hash
 Description : %VMWARE_CONFIG is a hash containing the general VMWARE configuration
               for the management node this code is running on. Since the data is
					the same for every instance of the VMWARE class, a class attribute
					is used and the hash is shared among all instances. This also
					means that the data only needs to be retrieved from the database
					once.

=cut

#my %VMWARE_CONFIG;

# Class attributes to store VMWWARE configuration details
# This data also resides in the %VMWARE_CONFIG hash
# Extract hash data to scalars for ease of use
my $IMAGE_LIB_ENABLE  = $IMAGELIBENABLE;
my $IMAGE_LIB_USER    = $IMAGELIBUSER;
my $IMAGE_LIB_KEY     = $IMAGELIBKEY;
my $IMAGE_LIB_SERVERS = $IMAGESERVERS;

##############################################################################

=head1 OBJECT METHODS

=cut

#/////////////////////////////////////////////////////////////////////////////

=head2 initialize

 Parameters  :
 Returns     :
 Description :

=cut

sub initialize {
	notify($ERRORS{'DEBUG'}, 0, "vmware ESX module initialized");
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 provision

 Parameters  : hash
 Returns     : 1(success) or 0(failure)
 Description : loads virtual machine with requested image

=cut

sub load {
	my $self = shift;

	#check to make sure this call is for the esx module
	if (ref($self) !~ /esx/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	my $request_data = shift;
	my ($package, $filename, $line, $sub) = caller(0);
	notify($ERRORS{'DEBUG'}, 0, "****************************************************");

	# get various useful vars from the database
	my $request_id     = $self->data->get_request_id;
	my $reservation_id = $self->data->get_reservation_id;
	my $vmhost_hostname           = $self->data->get_vmhost_hostname;
	my $image_name     = $self->data->get_image_name;
	my $computer_shortname  = $self->data->get_computer_short_name;
	my $vmclient_computerid = $self->data->get_computer_id;
	my $vmclient_imageminram      = $self->data->get_image_minram;
	my $image_os_name  = $self->data->get_image_os_name;
	my $image_os_type  = $self->data->get_image_os_type;
	my $image_identity = $self->data->get_image_identity;

	my $virtualswitch0    = $self->data->get_vmhost_profile_virtualswitch0;
	my $virtualswitch1    = $self->data->get_vmhost_profile_virtualswitch1;
	my $vmclient_eth0MAC          = $self->data->get_computer_eth0_mac_address;
	my $vmclient_eth1MAC          = $self->data->get_computer_eth1_mac_address;
	my $vmclient_OSname           = $self->data->get_image_os_name;

	#eventually get these from a config file or database
	
        my $vmhost_username = "";
        my $vmhost_password = "";
        my $datastore_ip = "";

	notify($ERRORS{'OK'}, 0, "Entered ESX module, loading $image_name on $computer_shortname (on $vmhost_hostname) for reservation $reservation_id");

	my $datastorepath4vmx = "/mnt/vcl/inuse/$computer_shortname";

	# query the host to see if the vm currently exists
	my $vminfo_command = "/usr/lib/vmware-viperl/apps/vm/vminfo.pl";
	$vminfo_command .= " --server '$vmhost_hostname'";
	$vminfo_command .= " --vmname $computer_shortname";
	$vminfo_command .= " --username $vmhost_username";
	$vminfo_command .= " --password '$vmhost_password'";
	notify($ERRORS{'DEBUG'},0,"VM info command: $vminfo_command");
	my $vminfo_output;
	$vminfo_output = `$vminfo_command`;
	notify($ERRORS{'DEBUG'},0,"VM info output: $vminfo_output");

	# parse the results from the host and determine if we need to remove an old vm
	if ($vminfo_output =~ /^Information of Virtual Machine $computer_shortname/m) {
		# Turn new vm on
		my $poweroff_command = "/usr/lib/vmware-viperl/apps/vm/vmcontrol.pl";
		$poweroff_command .= " --server '$vmhost_hostname'";
		$poweroff_command .= " --vmname $computer_shortname";
		$poweroff_command .= " --operation poweroff";
		$poweroff_command .= " --username $vmhost_username";
		$poweroff_command .= " --password '$vmhost_password'";
		notify($ERRORS{'DEBUG'},0,"Power off command: $poweroff_command");
		my $poweroff_output;
		$poweroff_output = `$poweroff_command`;
		notify($ERRORS{'DEBUG'},0,"Powered off: $poweroff_output");

		# unregister old vm from host
		my $unregister_command = "/usr/lib/vmware-viperl/apps/vm/vmregister.pl";
		$unregister_command .= " --server '$vmhost_hostname'";
		$unregister_command .= " --username $vmhost_username";
		$unregister_command .= " --password '$vmhost_password'";
		$unregister_command .= " --vmxpath '[VCL]/inuse/$computer_shortname/$image_name.vmx'";
		$unregister_command .= " --operation unregister";
		$unregister_command .= " --vmname $computer_shortname";
		$unregister_command .= " --pool Resources";
		$unregister_command .= " --hostname '$vmhost_hostname'";
		$unregister_command .= " --datacenter 'ha-datacenter'";
		my $unregister_output;
		$unregister_output = `$unregister_command`;
		notify($ERRORS{'DEBUG'}, 0, "Un-Registered: $unregister_output");

		my $remove_vm_output = `rm -rf $datastorepath4vmx`;
		notify($ERRORS{'DEBUG'}, 0, "Output from remove command is: $remove_vm_output");
	}

	# copy appropriate vmdk file
	my $newdir = $datastorepath4vmx;
	if (!mkdir($newdir)) {
		notify($ERRORS{'CRITICAL'}, 0, "Could not create new directory: $!");
		return 0;
	}
	my $from = "/mnt/vcl/golden/$image_name/$image_name.vmdk";
	my $to = "$datastorepath4vmx/$image_name.vmdk";
	if (!copy($from, $to)) {
		notify($ERRORS{'CRITICAL'}, 0, "Could not copy VMDK file! $!");
		# insert load log here perhaps
		return 0;
	}
	notify($ERRORS{'DEBUG'}, 0, "COPIED VMDK SUCCESSFULLY");


	# Copy the (large) -flat.vmdk file
	# This uses ssh to do the copy locally on the nfs server.
	$from = "/mnt/export/golden/$image_name/$image_name-flat.vmdk";
	$to = "/mnt/export/inuse/$computer_shortname/$image_name-flat.vmdk";
	my @copy_command = ("ssh", $datastore_ip, "-i", $image_identity, "-o", "BatchMode yes", "cp $from $to");
	notify($ERRORS{'OK'}, 0, "SSHing to copy vmdk-flat file");
	if (system(@copy_command) >> 8) {
		notify($ERRORS{'CRITICAL'}, 0, "Could not copy VMDK-flat file! $!");
		# insert load log here perhaps
		return 0;
	}

	# Author new VMX file
	my @vmxfile;
	my $vmxpath = "$datastorepath4vmx/$image_name.vmx";

	my $guestOS = "other";
	$guestOS = "linux"   if ($image_os_name =~ /(fc|centos)/i);
	# FIXME Should add some more entries here

	# determine adapter type by looking at vmdk file
	my $adapter = "lsilogic"; # default
	if (open(RE, "grep adapterType $datastorepath4vmx/$image_name.vmdk 2>&1 |")) {
		my @LIST = <RE>;
		close(RE);
		foreach my $a (@LIST) {
			if ($a =~ /(ide|buslogic|lsilogic)/) {
				$adapter = $1;
				notify($ERRORS{'OK'}, 0, "adapter= $1 ");
			}
		}
	} ## end if (open(RE, "grep adapterType $VMWAREREPOSITORY/$image_name/$image_name.vmdk 2>&1 |"...

	push(@vmxfile, "#!/usr/bin/vmware\n");
	push(@vmxfile, "config.version = \"8\"\n");
	push(@vmxfile, "virtualHW.version = \"4\"\n");
	push(@vmxfile, "memsize = \"$vmclient_imageminram\"\n");
	push(@vmxfile, "displayName = \"$computer_shortname\"\n");
	push(@vmxfile, "guestOS = \"$guestOS\"\n");
	push(@vmxfile, "uuid.action = \"create\"\n");
	push(@vmxfile, "Ethernet0.present = \"TRUE\"\n");
	push(@vmxfile, "Ethernet1.present = \"TRUE\"\n");

	push(@vmxfile, "Ethernet0.networkName = \"$virtualswitch0\"\n");
	push(@vmxfile, "Ethernet1.networkName = \"$virtualswitch1\"\n");
	push(@vmxfile, "ethernet0.wakeOnPcktRcv = \"false\"\n");
	push(@vmxfile, "ethernet1.wakeOnPcktRcv = \"false\"\n");

	#push(@vmxfile, "ethernet0.address = \"$vmclient_eth0MAC\"\n");
	#push(@vmxfile, "ethernet1.address = \"$vmclient_eth1MAC\"\n");
	push(@vmxfile, "ethernet0.addressType = \"generated\"\n");
	push(@vmxfile, "ethernet1.addressType = \"generated\"\n");
	push(@vmxfile, "gui.exitOnCLIHLT = \"FALSE\"\n");
	push(@vmxfile, "snapshot.disabled = \"TRUE\"\n");
	push(@vmxfile, "floppy0.present = \"FALSE\"\n");
	push(@vmxfile, "priority.grabbed = \"normal\"\n");
	push(@vmxfile, "priority.ungrabbed = \"normal\"\n");
	push(@vmxfile, "checkpoint.vmState = \"\"\n");

	push(@vmxfile, "scsi0.present = \"TRUE\"\n");
	push(@vmxfile, "scsi0.sharedBus = \"none\"\n");
	push(@vmxfile, "scsi0.virtualDev = \"$adapter\"\n");
	push(@vmxfile, "scsi0:0.present = \"TRUE\"\n");
	push(@vmxfile, "scsi0:0.deviceType = \"scsi-hardDisk\"\n");
	push(@vmxfile, "scsi0:0.fileName =\"$image_name.vmdk\"\n");

	#write to tmpfile
	if (open(TMP, ">$vmxpath")) {
		print TMP @vmxfile;
		close(TMP);
		notify($ERRORS{'OK'}, 0, "wrote vmxarray to $vmxpath");
	}
	else {
		notify($ERRORS{'CRITICAL'}, 0, "could not write vmxarray to $vmxpath");
		insertloadlog($reservation_id, $vmclient_computerid, "failed", "could not write vmx file to local tmp file");
		return 0;
	}

	# Register new vm on host
	my $register_command = "/usr/lib/vmware-viperl/apps/vm/vmregister.pl";
	$register_command .= " --server '$vmhost_hostname'";
	$register_command .= " --username $vmhost_username";
	$register_command .= " --password '$vmhost_password'";
	$register_command .= " --vmxpath '[VCL]/inuse/$computer_shortname/$image_name.vmx'";
	$register_command .= " --operation register";
	$register_command .= " --vmname $computer_shortname";
	$register_command .= " --pool Resources";
	$register_command .= " --hostname '$vmhost_hostname'";
	$register_command .= " --datacenter 'ha-datacenter'";
	my $register_output;
	$register_output = `$register_command`;
	notify($ERRORS{'DEBUG'}, 0, "Registered: $register_output");

	# Turn new vm on
	my $poweron_command = "/usr/lib/vmware-viperl/apps/vm/vmcontrol.pl";
	$poweron_command .= " --server '$vmhost_hostname'";
	$poweron_command .= " --vmname $computer_shortname";
	$poweron_command .= " --operation poweron";
	$poweron_command .= " --username $vmhost_username";
	$poweron_command .= " --password '$vmhost_password'";
	notify($ERRORS{'DEBUG'},0,"Power on command: $poweron_command");
	my $poweron_output;
	$poweron_output = `$poweron_command`;
	notify($ERRORS{'DEBUG'},0,"Powered on: $poweron_output");


	# Query the VI Perl toolkit for the mac address of our newly registered
	# machine
	Vim::login(service_url => "https://$vmhost_hostname/sdk", user_name => $vmhost_username, password => $vmhost_password);
	my $vm_view = Vim::find_entity_view(view_type => 'VirtualMachine', filter => {'config.name' => "$computer_shortname"});
	if (!$vm_view) {
		notify($ERRORS{'CRITICAL'}, 0, "Could not query for VM in VI PERL API");
		Vim::logout();
		return 0;
	}
	my $devices = $vm_view->config->hardware->device;
	my $mac_addr;
	foreach my $dev (@$devices) {
		next unless ($dev->isa ("VirtualEthernetCard"));
		notify($ERRORS{'DEBUG'}, 0, "deviceinfo->summary: $dev->deviceinfo->summary");
		notify($ERRORS{'DEBUG'}, 0, "virtualswitch0: $virtualswitch0");
		if ($dev->deviceInfo->summary eq $virtualswitch0) {
			$mac_addr = $dev->macAddress;
		}
	}
	Vim::logout();
	if (!$mac_addr) {
		notify($ERRORS{'CRITICAL'}, 0, "Failed to find MAC address");
		return 0;
	}
	notify($ERRORS{'OK'}, 0, "Queried MAC address is $mac_addr");

	# Query ARP table for $mac_addr to find the IP (waiting for machine to come up if necessary)
	# The DHCP negotiation should add the appropriate ARP entry for us
	my $arpstatus = 0;
	my $wait_loops = 0;
	my $client_ip;
	while (!$arpstatus) {
		my $arpoutput = `arp -n`;
		if ($arpoutput =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*?$mac_addr/mi) {
			$client_ip = $1;
			$arpstatus = 1;
			notify($ERRORS{'OK'}, 0, "$computer_shortname now has ip $client_ip");
		}
		else {
			if ($wait_loops > 24) {
				notify($ERRORS{'CRITICAL'}, 0, "waited acceptable amount of time for dhcp, please check $computer_shortname on $vmhost_hostname");
				return 0;
			}
			else {
				$wait_loops++;
				notify($ERRORS{'OK'}, 0, "going to sleep 5 seconds, waiting for computer to DHCP. Try $wait_loops");
				sleep 5;
			}
		}
	}


	notify($ERRORS{'OK'}, 0, "Found IP address $client_ip");

	# Delete existing entry for $computer_shortname in /etc/hosts (if any)
	notify($ERRORS{'OK'}, 0, "Removing old hosts entry");
	my $sedoutput = `sed -i "/.*\\b$computer_shortname\$/d" /etc/hosts`;
	notify($ERRORS{'DEBUG'}, 0, $sedoutput);
	
	# Add new entry to /etc/hosts for $computer_shortname
	`echo -e "$client_ip\t$computer_shortname" >> /etc/hosts`;

	# Start waiting for SSH to come up
	my $sshdstatus = 0;
	$wait_loops = 0;
	my $sshd_status = "off";
	notify($ERRORS{'DEBUG'}, 0, "Waiting for ssh to come up on $computer_shortname");
	while (!$sshdstatus) {
		my $sshd_status = _sshd_status($computer_shortname, $image_name);
		if ($sshd_status eq "on") {
			$sshdstatus = 1;
			notify($ERRORS{'OK'}, 0, "$computer_shortname now has active sshd running");
		}
		else {
			#either sshd is off or N/A, we wait
			if ($wait_loops > 24) {
					notify($ERRORS{'CRITICAL'}, 0, "waited acceptable amount of time for sshd to become active, please check $computer_shortname on $vmhost_hostname");
					#need to check power, maybe reboot it. for now fail it
					return 0;
			}
			else {
				$wait_loops++;
				# to give post config a chance
				notify($ERRORS{'OK'}, 0, "going to sleep 5 seconds, waiting for computer to start SSH. Try $wait_loops");
				sleep 5;
			}
		}    # else
	}    #while

	# Set IP info
	if ($IPCONFIGURATION ne "manualDHCP") {
		#not default setting
		if ($IPCONFIGURATION eq "dynamicDHCP") {
			insertloadlog($reservation_id, $vmclient_computerid, "dynamicDHCPaddress", "collecting dynamic IP address for node");
			notify($ERRORS{'DEBUG'}, 0, "Attempting to query vmclient for its public IP...");
			my $assignedIPaddress = getdynamicaddress($computer_shortname, $vmclient_OSname,$image_os_type);
			if ($assignedIPaddress) {
				#update computer table
				notify($ERRORS{'DEBUG'}, 0, " Got dynamic address from vmclient, attempting to update database");
				if (update_computer_address($vmclient_computerid, $assignedIPaddress)) {
					notify($ERRORS{'DEBUG'}, 0, " succesfully updated IPaddress of node $computer_shortname");
				}
				else {
					notify($ERRORS{'CRITICAL'}, 0, "could not update dynamic address $assignedIPaddress for $computer_shortname $image_name");
					return 0;
				}
			} ## end if ($assignedIPaddress)
			else {
				notify($ERRORS{'CRITICAL'}, 0, "could not fetch dynamic address from $computer_shortname $image_name");
				insertloadlog($reservation_id, $vmclient_computerid, "failed", "could not collect dynamic IP address for node");
				return 0;
			}
		} ## end if ($IPCONFIGURATION eq "dynamicDHCP")
		elsif ($IPCONFIGURATION eq "static") {
			notify($ERRORS{'CRITICAL'}, 0, "STATIC ASSIGNMENT NOT SUPPORTED. See vcld.conf");
			return 0;
			#insertloadlog($reservation_id, $vmclient_computerid, "staticIPaddress", "setting static IP address for node");
			#if (setstaticaddress($computer_shortname, $vmclient_OSname, $vmclient_publicIPaddress)) {
			#	# good set static address
			#}
		}
	} ## end if ($IPCONFIGURATION ne "manualDHCP")
	return 1;

} ## end sub load

#/////////////////////////////////////////////////////////////////////////////

=head2 capture

 Parameters  : $request_data_hash_reference
 Returns     : 1 if sucessful, 0 if failed
 Description : Creates a new vmware image.

=cut

sub capture {
	notify($ERRORS{'OK'}, 0, "Hello world, I am capturing an image now");
	return 1;
} ## end sub capture


#/////////////////////////////////////////////////////////////////////////
=head2 node_status

 Parameters  : $nodename, $log
 Returns     : array of related status checks
 Description : checks on sshd, currentimage

=cut

sub node_status {
	my $self = shift;

	# Check if subroutine was called as a class method
	if (ref($self) !~ /esx/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	#my ($vmhash) = shift;

	my ($package, $filename, $line, $sub) = caller(0);

	# try to contact vm
	# $self->data->get_request_data;
	# get state of vm
	my $vmpath             = $self->data->get_vmhost_profile_vmpath;
	my $datastorepath      = $self->data->get_vmhost_profile_datastore_path;
	my $requestedimagename = $self->data->get_image_name;
	my $vmhost_type        = $self->data->get_vmhost_type;
	my $vmhost_hostname    = $self->data->get_vmhost_hostname;
	my $vmhost_imagename   = $self->data->get_vmhost_image_name;
	my $vmclient_shortname = $self->data->get_computer_short_name;
	my $request_forimaging              = $self->data->get_request_forimaging();

	notify($ERRORS{'OK'}, 0, "Entering node_status, checking status of $vmclient_shortname");
	notify($ERRORS{'DEBUG'}, 0, "request_for_imaging: $request_forimaging");
	notify($ERRORS{'DEBUG'}, 0, "requeseted image name: $requestedimagename");

	my ($hostnode, $identity);

	# Create a hash to store status components
	my %status;

	# Initialize all hash keys here to make sure they're defined
	$status{status}       = 0;
	$status{currentimage} = 0;
	$status{ping}         = 0;
	$status{ssh}          = 0;
	$status{vmstate}      = 0;    #on or off
	$status{image_match}  = 0;

	if ($vmhost_type eq "blade") {
		$hostnode = $1 if ($vmhost_hostname =~ /([-_a-zA-Z0-9]*)(\.?)/);
		$identity = $IDENTITY_bladerhel;    #if($vm{vmhost}{imagename} =~ /^(rhel|rh3image|rh4image|fc|rhfc)/);
	}
	else {
		#using FQHN
		$hostnode = $vmhost_hostname;
		$identity = $IDENTITY_linux_lab if ($vmhost_imagename =~ /^(realmrhel)/);
	}

	if (!$identity) {
		notify($ERRORS{'CRITICAL'}, 0, "could not set ssh identity variable for image $vmhost_imagename type= $vmhost_type host= $vmhost_hostname");
	}

	# Check if node is pingable
	notify($ERRORS{'DEBUG'}, 0, "checking if $vmclient_shortname is pingable");
	if (_pingnode($vmclient_shortname)) {
		$status{ping} = 1;
		notify($ERRORS{'OK'}, 0, "$vmclient_shortname is pingable ($status{ping})");
	}
	else {
		notify($ERRORS{'OK'}, 0, "$vmclient_shortname is not pingable ($status{ping})");
		$status{status} = 'RELOAD';
		return $status{status};
	}

	#
	#my $vmx_directory = "$requestedimagename$vmclient_shortname";
	#my $myvmx         = "$vmpath/$requestedimagename$vmclient_shortname/$requestedimagename$vmclient_shortname.vmx";
	#my $mybasedirname = $requestedimagename;
	#my $myimagename   = $requestedimagename;

	notify($ERRORS{'DEBUG'}, 0, "Trying to ssh...");

	#can I ssh into it
	my $sshd = _sshd_status($vmclient_shortname, $requestedimagename);


	#is it running the requested image
	if ($sshd eq "on") {

		notify($ERRORS{'DEBUG'}, 0, "SSH good, trying to query image name");

		$status{ssh}          = 1;
		my $identity = $IDENTITY_bladerhel;
		my @sshcmd = run_ssh_command($vmclient_shortname, $identity, "cat currentimage.txt");
		$status{currentimage} = $sshcmd[1][0];

		notify($ERRORS{'DEBUG'}, 0, "Image name: $status{currentimage}");

		if ($status{currentimage}) {
			chomp($status{currentimage});
			if ($status{currentimage} =~ /$requestedimagename/) {
				$status{image_match} = 1;
				notify($ERRORS{'OK'}, 0, "$vmclient_shortname is loaded with requestedimagename $requestedimagename");
			}
			else {
				notify($ERRORS{'OK'}, 0, "$vmclient_shortname reports current image is currentimage= $status{currentimage} requestedimagename= $requestedimagename");
			}
		} ## end if ($status{currentimage})
	} ## end if ($sshd eq "on")

	# Determine the overall machine status based on the individual status results
	if ($status{ssh} && $status{image_match}) {
		$status{status} = 'READY';
	}
	else {
		$status{status} = 'RELOAD';
	}

	notify($ERRORS{'DEBUG'}, 0, "status set to $status{status}");


	if($request_forimaging){
		$status{status} = 'RELOAD';
		notify($ERRORS{'OK'}, 0, "request_forimaging set, setting status to RELOAD");
	}

	notify($ERRORS{'DEBUG'}, 0, "returning node status hash reference (\$node_status->{status}=$status{status})");
	return \%status;

} ## end sub node_status

sub does_image_exist {
	my $self = shift;
	if (ref($self) !~ /esx/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return 0;
	}

	my $image_name = $self->data->get_image_name();
	if (!$image_name) {
		notify($ERRORS{'CRITICAL'}, 0, "unable to determine if image exists, unable to determine image name");
		return 0;
	}

	my $IMAGEREPOSITORY = "/mnt/vcl/golden";

	if (open(IMAGES, "/bin/ls -1 $IMAGEREPOSITORY 2>&1 |")) {
		my @images = <IMAGES>;
		close(IMAGES);
		foreach my $i (@images) {
			if ($i =~ /$image_name/) {
				notify($ERRORS{'OK'}, 0, "image $image_name exists");
				return 1;
			}
		}
	} ## end if (open(IMAGES, "/bin/ls -1 $IMAGEREPOSITORY 2>&1 |"...

	notify($ERRORS{'WARNING'}, 0, "image $IMAGEREPOSITORY/$image_name does NOT exists");
	return 0;

} ## end sub does_image_exist

initialize();
1;
__END__

=head1 BUGS and LIMITATIONS

 There are no known bugs in this module.
 Please report problems to the VCL team (vcl_help@ncsu.edu).

=head1 AUTHOR

 Andrew Brown <ambrown4@ncsu.edu>
 Brian Bouterse <bmbouter@ncsu.edu>

=head1 SEE ALSO

L<http://vcl.ncsu.edu>

=cut