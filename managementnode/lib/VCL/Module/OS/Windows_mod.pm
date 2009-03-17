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
# $Id$
##############################################################################

=head1 NAME

VCL::Module::OS::Windows::Desktop

=head1 SYNOPSIS

 Needs to be written

=head1 DESCRIPTION

 This module provides...

=cut

##############################################################################
package VCL::Module::OS::Windows_mod;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../../..";

# Configure inheritance
#use base qw(VCL::Module::OS::Windows);
use base qw(VCL::Module::OS);

# Specify the version of this module
our $VERSION = '2.00';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;

use VCL::utils;
use File::Basename;

# Use Data::Dumper to print variables
use Data::Dumper;
$Data::Dumper::Indent = 0;
$Data::Dumper::Terse  = 1;
$Data::Dumper::Pair   = "=>";


##############################################################################

=head1 CLASS VARIABLES

=cut

=head2 $SOURCE_CONFIGURATION_DIRECTORY

 Data type   : Scalar
 Description : Location on management node of script/utilty/configuration
               files needed to configure the OS. This is normally the
					directory under the 'tools' directory specific to this OS.

=cut

our $SOURCE_CONFIGURATION_DIRECTORY = "$TOOLS/Windows";


=head2 $NODE_CONFIGURATION_DIRECTORY

 Data type   : Scalar
 Description : Destination location on computer of
               script/utilty/configuration files needed to configure the OS.

=cut

our $NODE_CONFIGURATION_DIRECTORY = 'C:/Cygwin/home/root/VCL';

##############################################################################

=head1 INTERFACE OBJECT METHODS

=cut

#/////////////////////////////////////////////////////////////////////////////

=head2 pre_capture

 Parameters  : None, but must be called as an object method
 Returns     : 1 if successful, 0 if failed
 Description : Performs the steps necessary to prepare a Windows OS to be captured.
               Called by provisioning module's capture() subroutine.

=over 3

=cut

sub pre_capture {
	my $self = shift;
	my $args = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $computer_node_name = $self->data->get_computer_node_name();

	notify($ERRORS{'OK'}, 0, "beginning Windows image capture preparation tasks on $computer_node_name, end state: $self->{end_state}");
	
=item 1

Log off all currently logged in users

=cut

	if (!$self->logoff_users()) {
		notify($ERRORS{'WARNING'}, 0, "unable to log off all currently logged in users on $computer_node_name");
		return 0;
	}

=item *

Set root account password to known value

=cut

	if (!$self->set_password('root', $WINDOWS_ROOT_PASSWORD)) {
		notify($ERRORS{'WARNING'}, 0, "unable to set root password");
		return 0;
	}

=item *

Delete the users assigned to this reservation

=cut

	if (!$self->delete_users()) {
		notify($ERRORS{'WARNING'}, 0, "unable to delete users");
		return 0;
	}

=item *

Disable all RDP access by removing firewall exceptions

=cut

	if (!$self->firewall_disable_rdp()) {
		notify($ERRORS{'WARNING'}, 0, "unable to disable RDP");
		return 0;
	}

=item *

Enable RDP access from private IP addresses by adding a firewall exception

=cut

	if (!$self->firewall_enable_rdp('10.0.0.0/8')) {
		notify($ERRORS{'WARNING'}, 0, "unable to enable RDP from private IP addresses");
		return 0;
	}

=item *

Enable SSH access from private IP addresses by adding a firewall exception

=cut

	if (!$self->firewall_enable_ssh_private()) {
		notify($ERRORS{'WARNING'}, 0, "unable to enable SSH from private IP addresses");
		return 0;
	}

=item *

Enable ping access from private IP addresses by adding a firewall exception

=cut

	if (!$self->firewall_enable_ping_private()) {
		notify($ERRORS{'WARNING'}, 0, "unable to enable ping from private IP addresses");
		return 0;
	}

=item *

Delete existing capture configuration files from the computer (scripts, utilities, drivers...)

=cut

	if (!$self->delete_capture_configuration_files()) {
		notify($ERRORS{'WARNING'}, 0, "unable to delete existing capture configuration files to $computer_node_name");
		return 0;
	}

=item *

Copy the capture configuration files to the computer (scripts, utilities, drivers...)

=cut

	if (!$self->copy_capture_configuration_files($SOURCE_CONFIGURATION_DIRECTORY)) {
		notify($ERRORS{'WARNING'}, 0, "unable to copy general Windows capture configuration files to $computer_node_name");
		return 0;
	}

=item *

Disable autoadminlogon before disabling the pagefile and rebooting

=cut

	if (!$self->disable_autoadminlogon()) {
		notify($ERRORS{'WARNING'}, 0, "unable to disable autoadminlogon");
		return 0;
	}

=item *

Disable IPv6

=cut

	if (!$self->disable_ipv6()) {
		notify($ERRORS{'WARNING'}, 0, "unable to disable IPv6");
	}

=item *

Disable dynamic DNS

=cut

	if (!$self->disable_dynamic_dns()) {
		notify($ERRORS{'WARNING'}, 0, "unable to disable dynamic dns");
	}

=item *

Call script to clean up the hard drive

=cut

	if (!$self->clean_hard_drive()) {
		notify($ERRORS{'WARNING'}, 0, "unable to clean unnecessary files the hard drive");
	}
	
=item *

Delete the 'VCL Startup Script' scheduled task

=cut
	
	# This task must be deleted because it will conflict with the vcl_first_boot.cmd Run command that is added
	# It also may cause problems after the reboot that occurs when the pagefile is disabled
	# SSH commands may fail while the networking and Cygwin scripts are running
	if (!$self->delete_scheduled_task('VCL Startup Script')) {
		notify($ERRORS{'WARNING'}, 0, "unable to delete 'VCL Startup Script' scheduled task");
		return 0;
	}
	
=item *

Delete 'VCL First Boot' Run registry key

=cut
	
	if (!$self->delete_hklm_run_registry_key('VCL First Boot')) {
		notify($ERRORS{'WARNING'}, 0, "unable to delete 'VCL First Boot' run registry key");
		return 0;
	}
	
=item *

Disable the pagefile

 ********* node reboots *********

=item *

Disable the pagefile, reboot, and delete pagefile.sys

=cut

	# This will set the registry key to disable the pagefile, reboot, then delete pagefile.sys
	# Calls the reboot() subroutine, which makes sure ssh service is set to auto and firewall is open for ssh
	if (!$self->disable_pagefile()) {
		notify($ERRORS{'WARNING'}, 0, "unable to disable pagefile");
		return 0;
	}

=item *

Use netsh to set the public NIC to use DHCP

=cut

	if (!$self->enable_dhcp('public')) {
		notify($ERRORS{'WARNING'}, 0, "unable to enable DHCP on the public interface");
		return 0;
	}

=item *

Reenable the pagefile, this will take effect when the saved image boots

=cut

	if (!$self->enable_pagefile()) {
		notify($ERRORS{'WARNING'}, 0, "unable to reenable pagefile");
		return 0;
	}

=item *

Enable autoadminlogon

=cut

	if (!$self->enable_autoadminlogon()) {
		notify($ERRORS{'WARNING'}, 0, "unable to enable autoadminlogon");
		return 0;
	}

=item *

Create HKLM run vcl_first_boot.cmd registry key

=cut
	
	# Wrap entire command in cmd.exe /c start so command window has a title letting onlooker know what is running
	if (!$self->add_hklm_run_registry_key('VCL First Boot', 'cmd.exe /c start "vcl_first_boot.cmd" cmd.exe /c "' . $NODE_CONFIGURATION_DIRECTORY . '/Scripts/vcl_first_boot.cmd  >> ' . $NODE_CONFIGURATION_DIRECTORY . '/Logs/vcl_first_boot.log 2>&1"')) {
		notify($ERRORS{'WARNING'}, 0, "unable to add run vcl_first_boot.cmd key");
		return 0;
	}

=item *

Set sshd service startup mode to manual

=cut

	if (!$self->set_service_startup_mode('sshd', 'manual')) {
		notify($ERRORS{'WARNING'}, 0, "unable to set sshd service startup mode to manual");
		return 0;
	}

=back

=cut

	notify($ERRORS{'OK'}, 0, "returning 1");
	return 1;

} ## end sub pre_capture

#/////////////////////////////////////////////////////////////////////////////

=head2 post_load

 Parameters  : reference to an object of this class
 Returns     : 1 if successful, 0 if failed
 Description : Performs the steps necessary to configure a Windows OS after an image has been loaded.
               Called by provisioning module's load() subroutine.

=over 3

=cut

sub post_load {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $imagemeta_postoption = $self->data->get_imagemeta_postoption();

	notify($ERRORS{'OK'}, 0, "beginning Windows post-load tasks");

=item 1

Set the "My Computer" description to the image pretty name

=cut

	if (!$self->set_my_computer_name()) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, unable to rename my computer");
		return 0;
	}

=item *

Disable NetBIOS

=cut

	if (!$self->disable_netbios()) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to disable NetBIOS");
		return 0;
	}

=item *

Disable dynamic DNS

=cut

	if (!$self->disable_dynamic_dns()) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to disable dynamic DNS");
		return 0;
	}

=item *

Disable RDP firewall exceptions from all addresses

=cut

	if (!$self->firewall_disable_rdp()) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to disable RDP");
		return 0;
	}

=item *

Randomize root password

=cut

	my $root_random_password = getpw();
	if (!$self->set_password('root', $root_random_password)) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to set random root password");
		return 0;
	}

=item *

Randomize Administrator password

=cut

	my $administrator_random_password = getpw();
	if (!$self->set_password('Administrator', $administrator_random_password)) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to set random Administrator password");
		return 0;
	}
	
=item *

Create scheduled task to run script at computer startup

=cut

	if (!$self->create_startup_scheduled_task('VCL Startup Script', 'cmd.exe /c start "vcl_startup.cmd" /MIN ' . $NODE_CONFIGURATION_DIRECTORY . '/Scripts/vcl_startup.cmd  >> ' . $NODE_CONFIGURATION_DIRECTORY . '/Logs/vcl_startup.log 2>&1', 'root', $root_random_password)) {
		notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to create scheduled task to run vcl_startup.cmd at computer startup");
		return 0;
	}

=item *

Check if imagemeta postoption is set to reboot

=cut

	if ($imagemeta_postoption =~ /reboot/i) {
		notify($ERRORS{'OK'}, 0, "imagemeta postoption reboot is set for image, rebooting computer");
		if (!$self->reboot()) {
			notify($ERRORS{'WARNING'}, 0, "Windows post-load failed, failed to reboot the computer");
			return 0;
		}
	}

=back

=cut

	notify($ERRORS{'OK'}, 0, "returning 1");
	return 1;
} ## end sub post_load

#/////////////////////////////////////////////////////////////////////////////

=head2 reserve

 Parameters  :
 Returns     :
 Description :

=cut

sub reserve {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $request_forimaging   = $self->data->get_request_forimaging();
	my $reservation_password = $self->data->get_reservation_password();

	notify($ERRORS{'OK'}, 0, "beginning Windows reserve tasks");

	# Check if this is an imaging request or not
	if ($request_forimaging) {
		# Imaging request, don't create account, set the Administrator password
		if (!$self->set_password('Administrator', $reservation_password)) {
			notify($ERRORS{'WARNING'}, 0, "unable to set password for Administrator account");
			return 0;
		}
	}
	else {
		# Add the users to the computer
		# The add_users() subroutine will add the primary reservation user and any imagemeta group users
		if (!$self->add_users()) {
			notify($ERRORS{'WARNING'}, 0, "unable to add users");
			return 0;
		}
	}

	notify($ERRORS{'OK'}, 0, "returning 1");
	return 1;
} ## end sub reserve

#/////////////////////////////////////////////////////////////////////////////

=head2 sanitize

 Parameters  :
 Returns     :
 Description :

=cut

sub sanitize {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $computer_node_name = $self->data->get_computer_node_name();

	# Revoke access
	if (!$self->revoke_access()) {
		notify($ERRORS{'WARNING'}, 0, "failed to revoke access to $computer_node_name");
		return 0;
	}

	# Delete all users associated with the reservation
	# This includes the primary reservation user and users listed in imagemeta group if it's configured
	if ($self->delete_users()) {
		notify($ERRORS{'OK'}, 0, "users have been deleted from $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to delete users from $computer_node_name");
		return 0;
	}

	notify($ERRORS{'OK'}, 0, "$computer_node_name has been sanitized");
	return 1;
} ## end sub sanitize

##############################################################################

=head1 AUXILIARY OBJECT METHODS

=cut

#/////////////////////////////////////////////////////////////////////////////

=head2 create_directory

 Parameters  :
 Returns     :
 Description :

=cut

sub create_directory {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my @paths;

	# Get 1 or more paths from the subroutine arguments
	while (my $path = shift) {
		push @paths, $path;
	}

	# Make sure at least 1 path was specified
	if (!@paths) {
		notify($ERRORS{'WARNING'}, 0, "directory path was not specified as an argument");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "attempting to create " . scalar @paths . " directories:\n" . join("\n", @paths));

	# Keep a count of paths which couldn't be deleted
	my $directories_not_created = 0;

	# Loop through the paths
	for my $path (@paths) {
		notify($ERRORS{'DEBUG'}, 0, "attempting to create directory: $path");

		# Assemble the Windows shell mkdir command and execute it
		my $mkdir_command = '$SYSTEMROOT/System32/cmd.exe /c "mkdir \\"' . $path . '\\""';
		my ($mkdir_exit_status, $mkdir_output) = run_ssh_command($computer_node_name, $management_node_keys, $mkdir_command, '', '', 1);
		if (defined($mkdir_exit_status) && $mkdir_exit_status == 0) {
			notify($ERRORS{'OK'}, 0, "directory created on $computer_node_name: $path, output:\n@{$mkdir_output}");
		}
		elsif (defined($mkdir_exit_status) && $mkdir_exit_status == 1 && grep(/already exists/i, @{$mkdir_output})) {
			notify($ERRORS{'OK'}, 0, "directory already exists on $computer_node_name: $path, exit status: $mkdir_exit_status, output:\n@{$mkdir_output}");
		}
		elsif (defined($mkdir_exit_status)) {
			notify($ERRORS{'WARNING'}, 0, "failed to create directory on $computer_node_name: $path, exit status: $mkdir_exit_status, output:\n@{$mkdir_output}");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to delete file on $computer_node_name: $path");
			$directories_not_created++;
			next;
		}

		# Make sure directory was created
		if (!$self->filesystem_entry_exists($path)) {
			notify($ERRORS{'WARNING'}, 0, "filesystem entry does not exist on $computer_node_name: $path");
			$directories_not_created++;
			next;
		}
		else {
			notify($ERRORS{'DEBUG'}, 0, "verified that filesystem entry exists on $computer_node_name: $path");
		}
	} ## end for my $path (@paths)

	# Check if any paths couldn't be created
	if ($directories_not_created) {
		notify($ERRORS{'WARNING'}, 0, "some paths could not be created");
		return 0;
	}
	else {
		return 1;
	}
} ## end sub create_directory

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_filesystem_entry

 Parameters  :
 Returns     :
 Description :

=cut

sub delete_filesystem_entry {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my @paths;

	# Get 1 or more paths from the subroutine arguments
	while (my $path = shift) {
		push @paths, $path;
	}

	# Make sure at least 1 path was specified
	if (!@paths) {
		notify($ERRORS{'WARNING'}, 0, "filesystem path was not specified as an argument");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "attempting to delete " . scalar @paths . " paths:\n" . join("\n", @paths));

	# Keep a count of paths which couldn't be deleted
	my $paths_not_deleted = 0;

	# Loop through the paths
	for my $path (@paths) {
		notify($ERRORS{'DEBUG'}, 0, "attempting to delete: $path");

		# Assemble the Windows shell del command and execute it
		my $del_command = '$SYSTEMROOT/System32/cmd.exe /c "del /s /q /f /a \\"' . $path . '\\""';
		my ($del_exit_status, $del_output) = run_ssh_command($computer_node_name, $management_node_keys, $del_command, '', '', 1);
		if (defined($del_exit_status) && $del_exit_status == 0) {
			notify($ERRORS{'DEBUG'}, 0, "file either deleted or does not exist on $computer_node_name: $path, output:\n@{$del_output}");
		}
		elsif ($del_exit_status) {
			notify($ERRORS{'WARNING'}, 0, "failed to delete file on $computer_node_name: $path, exit status: $del_exit_status, output:\n@{$del_output}");
			$paths_not_deleted++;
			next;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to delete file on $computer_node_name: $path");
			$paths_not_deleted++;
			next;
		}

		# Assemble the Windows shell rmdir command and execute it
		my $rmdir_command = '$SYSTEMROOT/System32/cmd.exe /c "rmdir /s /q \\"' . $path . '\\""';
		my ($rmdir_exit_status, $rmdir_output) = run_ssh_command($computer_node_name, $management_node_keys, $rmdir_command, '', '', 1);
		if (defined($rmdir_exit_status) && $rmdir_exit_status == 0) {
			notify($ERRORS{'DEBUG'}, 0, "directory deleted on $computer_node_name: $path, output:\n@{$rmdir_output}");
		}
		elsif (defined($rmdir_output) && grep(/cannot find the/, @{$rmdir_output})) {
			# Exit status 2 should mean the directory was not found
			notify($ERRORS{'DEBUG'}, 0, "directory to be deleted was not found on $computer_node_name: $path, exit status: $rmdir_exit_status, output:\n@{$rmdir_output}");
		}
		elsif ($rmdir_exit_status) {
			notify($ERRORS{'WARNING'}, 0, "failed to delete directory on $computer_node_name: $path, exit status: $rmdir_exit_status, output:\n@{$rmdir_output}");
			$paths_not_deleted++;
			next;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to delete directory on $computer_node_name: $path");
			$paths_not_deleted++;
			next;
		}

		# Make sure directory was deleted
		if ($self->filesystem_entry_exists($path)) {
			notify($ERRORS{'WARNING'}, 0, "filesystem entry still exists on $computer_node_name: $path");
			$paths_not_deleted++;
			next;
		}
		else {
			notify($ERRORS{'OK'}, 0, "file or directory has been deleted: $path");
		}
	} ## end for my $path (@paths)

	# Check if any paths couldn't be deleted
	if ($paths_not_deleted) {
		notify($ERRORS{'WARNING'}, 0, "some paths could not be deleted");
		return 0;
	}
	else {
		return 1;
	}
} ## end sub delete_filesystem_entry

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_directory_contents

 Parameters  :
 Returns     :
 Description :

=cut

sub delete_files_by_pattern {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $base_directory = shift;
	my $pattern        = shift;

	# Make sure base directory and pattern were specified
	if (!($base_directory && $pattern)) {
		notify($ERRORS{'WARNING'}, 0, "base directory and pattern must be specified as arguments");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "attempting to delete files under $base_directory matching pattern $pattern");


	# Assemble command
	my $command = "/bin/find.exe \"$base_directory\" -mindepth 1 -iregex \"$pattern\" -print0 | xargs -0 rm -rvf";
	my ($exit_status, $output) = run_ssh_command($computer_node_name, $management_node_keys, $command, '', '', 0);
	if (defined($exit_status) && $exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "files have been deleted under '$base_directory' matching pattern '$pattern'");
	}
	elsif ($exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete files under $base_directory matching pattern $pattern, exit status: $exit_status, output:\n@{$output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to delete files under $base_directory matching pattern $pattern");
		return;
	}

	return 1;
} ## end sub delete_files_by_pattern

#/////////////////////////////////////////////////////////////////////////////

=head2 filesystem_entry_exists

 Parameters  :
 Returns     :
 Description :

=cut

sub filesystem_entry_exists {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Get the path from the subroutine arguments and make sure it was passed
	my $path = shift;
	if (!$path) {
		notify($ERRORS{'WARNING'}, 0, "unable to detmine if file exists, path was not specified as an argument");
		return;
	}

	# Assemble the ls command and execute it
	my $ls_command = "ls -la '$path'";
	my ($ls_exit_status, $ls_output) = run_ssh_command($computer_node_name, $management_node_keys, $ls_command, '', '', 1);
	if (defined($ls_exit_status) && $ls_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "filesystem entry exists on $computer_node_name: $path");
		return 1;
	}
	elsif (defined($ls_exit_status) && $ls_exit_status == 2) {
		notify($ERRORS{'DEBUG'}, 0, "filesystem entry does NOT exist on $computer_node_name: $path");
		return 0;
	}
	elsif ($ls_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to determine if filesystem entry exists on $computer_node_name: $path, exit status: $ls_exit_status, output:\n@{$ls_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to determine if filesystem entry exists on $computer_node_name: $path");
		return;
	}
} ## end sub filesystem_entry_exists

#/////////////////////////////////////////////////////////////////////////////

=head2 logoff_users

 Parameters  :
 Returns     :
 Description :

=cut

sub logoff_users {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my ($exit_status, $output) = run_ssh_command($computer_node_name, $management_node_keys, "qwinsta.exe");
	if ($exit_status > 0) {
		notify($ERRORS{'WARNING'}, 0, "failed to run qwinsta.exe on $computer_node_name, exit status: $exit_status, output:\n@{$output}");
		return;
	}
	elsif (!defined($exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run qwinsta.exe SSH command on $computer_node_name");
		return;
	}

	my @active_user_lines = grep(/Active/, @{$output});

	return 1 if !@active_user_lines;

	notify($ERRORS{'OK'}, 0, "users are currently logged in on $computer_node_name:\n@active_user_lines");
	#>rdp-tcp#1 root 0 Active rdpwd
	foreach my $active_user_line (@active_user_lines) {
		$active_user_line =~ /[\s>]*(\S+)\s+(.*\w)\s*(\d+)\s+Active.*/;
		my $session_name = $1;
		my $username     = $2;
		my $session_id   = $3;

		notify($ERRORS{'DEBUG'}, 0, "user logged in: $username, session name: $session_name, session id: $session_id");
		#$ logoff /?
		#Terminates a session.
		#LOGOFF [sessionname | sessionid] [/SERVER:servername] [/V]
		#  sessionname         The name of the session.
		#  sessionid           The ID of the session.
		#  /SERVER:servername  Specifies the Terminal server containing the user
		#							 session to log off (default is current).
		#  /V                  Displays information about the actions performed.

		# Call logoff.exe, pass it the session name
		# Session ID fails if the ID is 0
		my ($logoff_exit_status, $logoff_output) = run_ssh_command($computer_node_name, $management_node_keys, "logoff.exe $session_name /V");
		if ($logoff_exit_status == 0) {
			notify($ERRORS{'OK'}, 0, "logged off user: $username");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to log off user: $username, exit status: $logoff_exit_status, output:\n@{$logoff_output}");
		}
	} ## end foreach my $active_user_line (@active_user_lines)
	return 1;
} ## end sub logoff_users

#/////////////////////////////////////////////////////////////////////////////

=head2 add_users

 Parameters  : 
 Returns     : 
 Description : 

=cut

sub add_users {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the user array from the arguments
	# If no argument was supplied, use the users specified in the DataStructure
	my $user_array_ref = shift;
	my @users;
	if ($user_array_ref) {
		$user_array_ref = $self->data->get_imagemeta_usergroupmembers();
		@users          = @{$user_array_ref};
	}
	else {
		# User list was not specified as an argument
		# Use the imagemeta group members and the primary reservation user
		my $user_login_id      = $self->data->get_user_login_id();
		my $user_group_members = $self->data->get_imagemeta_usergroupmembers();

		push @users, $user_login_id;

		foreach my $user_group_member_uid (keys(%{$user_group_members})) {
			my $user_group_member_login_id = $user_group_members->{$user_group_member_uid};
			push @users, $user_group_member_login_id;
		}

		# Remove duplicate users
		@users = keys %{{map {$_, 1} @users}};
	} ## end else [ if ($user_array_ref)

	notify($ERRORS{'DEBUG'}, 0, "attempting to add " . scalar @users . " users to $computer_node_name: " . join(", ", @users));

	# Attempt to get the password from the arguments
	# If no argument was supplied, use the password specified in the DataStructure
	my $password = shift;
	if (!$password) {
		$password = $self->data->get_reservation_password();
	}

	# Loop through the users in the imagemeta group and attempt to add them
	for my $username (@users) {
		if (!$self->create_user($username, $password)) {
			notify($ERRORS{'WARNING'}, 0, "failed to add users to $computer_node_name");
			return 0;
		}
	}

	notify($ERRORS{'OK'}, 0, "added " . scalar @users . " users to $computer_node_name");
	return 1;
} ## end sub add_users

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_users

 Parameters  : 
 Returns     : 
 Description : 

=cut

sub delete_users {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the user array from the arguments
	# If no argument was supplied, use the users specified in the DataStructure
	my $user_array_ref = shift;
	my @users;
	if ($user_array_ref) {
		$user_array_ref = $self->data->get_imagemeta_usergroupmembers();
		@users          = @{$user_array_ref};
	}
	else {
		# User list was not specified as an argument
		# Use the imagemeta group members and the primary reservation user
		my $user_login_id      = $self->data->get_user_login_id();
		my $user_group_members = $self->data->get_imagemeta_usergroupmembers();

		push @users, $user_login_id;

		foreach my $user_group_member_uid (keys(%{$user_group_members})) {
			my $user_group_member_login_id = $user_group_members->{$user_group_member_uid};
			push @users, $user_group_member_login_id;
		}

		# Remove duplicate users
		@users = keys %{{map {$_, 1} @users}};
	} ## end else [ if ($user_array_ref)

	# Loop through the users and attempt to delete them
	for my $username (@users) {
		if (!$self->delete_user($username)) {
			notify($ERRORS{'WARNING'}, 0, "failed to delete user $username from $computer_node_name");
			return 0;
		}
	}

	notify($ERRORS{'OK'}, 0, "deleted " . scalar @users . " users from $computer_node_name");
	return 1;
} ## end sub delete_users

#/////////////////////////////////////////////////////////////////////////////

=head2 user_exists

 Parameters  : 
 Returns     : 
 Description : 

=cut

sub user_exists {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	# If no argument was supplied, use the user specified in the DataStructure
	my $username = shift;
	if (!$username) {
		$username = $self->data->get_user_login_id();
	}

	notify($ERRORS{'DEBUG'}, 0, "checking if user $username exists on $computer_node_name");

	# Attempt to query the user account
	my $query_user_command = "net user \"$username\"";
	my ($query_user_exit_status, $query_user_output) = run_ssh_command($computer_node_name, $management_node_keys, $query_user_command);
	if (defined($query_user_exit_status) && $query_user_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "user $username exists on $computer_node_name");
		return 1;
	}
	elsif (defined($query_user_exit_status) && $query_user_exit_status == 2) {
		notify($ERRORS{'DEBUG'}, 0, "user $username does not exist on $computer_node_name");
		return 0;
	}
	elsif (defined($query_user_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to determine if user $username exists on $computer_node_name, exit status: $query_user_exit_status, output:\n@{$query_user_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to determine if user $username exists on $computer_node_name");
		return;
	}
} ## end sub user_exists

#/////////////////////////////////////////////////////////////////////////////

=head2 create_user

 Parameters  : 
 Returns     : 
 Description : 

=cut

sub create_user {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	# If no argument was supplied, use the user specified in the DataStructure
	my $username = shift;
	my $password = shift;
	if (!$username) {
		$username = $self->data->get_user_login_id();
	}
	if (!$password) {
		$password = $self->data->get_user_password();
	}

	# Check if user already exists
	if ($self->user_exists($username)) {
		notify($ERRORS{'OK'}, 0, "user $username already exists on $computer_node_name, attempting to delete user");

		# Attempt to delete the user
		if (!$self->delete_user($username)) {
			notify($ERRORS{'WARNING'}, 0, "failed to add user $username to $computer_node_name, user already exists and could not be deleted");
			return 0;
		}
	}

	notify($ERRORS{'DEBUG'}, 0, "attempting to add user $username to $computer_node_name ($password)");

	# Attempt to add the user account
	my $add_user_command = "net user \"$username\" \"$password\" /ADD  /EXPIRES:NEVER /COMMENT:\"Account created by VCL\"";
	$add_user_command .= " && net localgroup \"Administrators\" \"$username\" /ADD";
	$add_user_command .= " && net localgroup \"Remote Desktop Users\" \"$username\" /ADD";

	my ($add_user_exit_status, $add_user_output) = run_ssh_command($computer_node_name, $management_node_keys, $add_user_command);
	if (defined($add_user_exit_status) && $add_user_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "added user $username ($password) to $computer_node_name");
	}
	elsif (defined($add_user_exit_status) && $add_user_exit_status == 2) {
		notify($ERRORS{'OK'}, 0, "user $username was not added, user already exists");
		return 1;
	}
	elsif (defined($add_user_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to add user $username to $computer_node_name, exit status: $add_user_exit_status, output:\n@{$add_user_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command add user $username to $computer_node_name");
		return;
	}

	return 1;
} ## end sub create_user

#/////////////////////////////////////////////////////////////////////////////

=head2 add_user_to_group

 Parameters  : 
 Returns     : 
 Description : 

=cut

sub add_user_to_group {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	# If no argument was supplied, use the user specified in the DataStructure
	my $username = shift;
	my $group    = shift;
	if (!$username || !$group) {
		notify($ERRORS{'WARNING'}, 0, "unable to add user to group, arguments were not passed correctly");
		return;
	}

	# Attempt to add the user to the group using net localgroup
	my $localgroup_user_command = "net localgroup \"$group\" $username /ADD";
	my ($localgroup_user_exit_status, $localgroup_user_output) = run_ssh_command($computer_node_name, $management_node_keys, $localgroup_user_command);
	if (defined($localgroup_user_exit_status) && $localgroup_user_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "added user $username to \"$group\" group on $computer_node_name");
	}
	elsif (defined($localgroup_user_exit_status) && $localgroup_user_exit_status == 2) {
		# Exit status is 2, this could mean the user is already a member or that the group doesn't exist
		# Check the output to determine what happened
		if (grep(/error 1378/, @{$localgroup_user_output})) {
			# System error 1378 has occurred.
			# The specified account name is already a member of the group.
			notify($ERRORS{'OK'}, 0, "user $username was not added to $group group because user already a member");
			return 1;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to add user $username to $group group on $computer_node_name, exit status: $localgroup_user_exit_status, output:\n@{$localgroup_user_output}");
			return 0;
		}
	} ## end elsif (defined($localgroup_user_exit_status) ... [ if (defined($localgroup_user_exit_status) ...
	elsif (defined($localgroup_user_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to add user $username to $group group on $computer_node_name, exit status: $localgroup_user_exit_status, output:\n@{$localgroup_user_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to add user $username to $group group on $computer_node_name");
		return;
	}

	return 1;
} ## end sub add_user_to_group

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_user

 Parameters  : $node, $user, $type, $osname
 Returns     : 1 success 0 failure
 Description : removes user account and profile directory from specificed node

=cut

sub delete_user {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	# If no argument was supplied, use the user specified in the DataStructure
	my $username = shift;
	if (!(defined($username))) {
		$username = $self->data->get_user_login_id();
	}

	notify($ERRORS{'OK'}, 0, "attempting to delete user $username from $computer_node_name");

	# Attempt to delete the user account
	my $delete_user_command = "net user $username /DELETE";
	my ($delete_user_exit_status, $delete_user_output) = run_ssh_command($computer_node_name, $management_node_keys, $delete_user_command);
	if (defined($delete_user_exit_status) && $delete_user_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "deleted user $username from $computer_node_name");
	}
	elsif (defined($delete_user_exit_status) && $delete_user_exit_status == 2) {
		notify($ERRORS{'OK'}, 0, "user $username was not deleted because user does not exist");
	}
	elsif (defined($delete_user_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete user $username from $computer_node_name, exit status: $delete_user_exit_status, output:\n@{$delete_user_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command delete user $username from $computer_node_name");
		return;
	}

	# Delete the user's home directory
	if ($self->delete_filesystem_entry("C:/Documents and Settings/$username")) {
		notify($ERRORS{'OK'}, 0, "deleted profile for user $username from $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to delete profile for user $username from $computer_node_name");
		return 0;
	}

	return 1;
} ## end sub delete_user

#/////////////////////////////////////////////////////////////////////////////

=head2 set_password

 Parameters  : $username, $password
 Returns     : 
 Description : 

=cut

sub set_password {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	my $username = shift;
	my $password = shift;

	# If no argument was supplied, use the user specified in the DataStructure
	if (!defined($username)) {
		$username = $self->data->get_user_logon_id();
	}
	if (!defined($password)) {
		$password = $self->data->get_reservation_password();
	}

	# Make sure both the username and password were determined
	if (!defined($username) || !defined($password)) {
		notify($ERRORS{'WARNING'}, 0, "username and password could not be determined");
		return 0;
	}

	# Attempt to set the password
	notify($ERRORS{'DEBUG'}, 0, "setting password of $username to $password on $computer_node_name");
	my ($set_password_exit_status, $set_password_output) = run_ssh_command($computer_node_name, $management_node_keys, "net user $username '$password'");
	if ($set_password_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "password changed to '$password' for user '$username' on $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to change password to '$password' for user '$username' on $computer_node_name, exit status: $set_password_exit_status, output:\n@{$set_password_output}");
		return 0;
	}

	# Check if root user, must set sshd service password too
	if ($username eq 'root') {
		notify($ERRORS{'DEBUG'}, 0, "root account password changed, must also change sshd service credentials");
		if (!$self->set_service_credentials('sshd', $username, $password)) {
			notify($ERRORS{'WARNING'}, 0, "failed to set sshd service credentials to $username ($password)");
			return 0;
		}
	}

	# Attempt to change scheduled task passwords
	notify($ERRORS{'DEBUG'}, 0, "changing passwords for scheduled tasks");
	my ($schtasks_query_exit_status, $schtasks_query_output) = run_ssh_command($computer_node_name, $management_node_keys, "schtasks.exe /Query /V /FO LIST");
	if (defined($schtasks_query_exit_status) && $schtasks_query_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "queried scheduled tasks on $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to query scheduled tasks on $computer_node_name, exit status: $schtasks_query_exit_status, output:\n@{$schtasks_query_output}");
		return 0;
	}

	# Find scheduled tasks configured to run as this user
	my $task_name;
	my @task_names_to_update;
	for my $schtasks_output_line (@{$schtasks_query_output}) {
		if ($schtasks_output_line =~ /TaskName:\s+([ \S]+)/i) {
			$task_name = $1;
			notify($ERRORS{'DEBUG'}, 0, "found task: " . string_to_ascii($task_name));
		}
		if ($schtasks_output_line =~ /Run As User.*\\$username/i) {
			notify($ERRORS{'DEBUG'}, 0, "password needs to be updated for scheduled task: $task_name\n$schtasks_output_line");
			push @task_names_to_update, $task_name;
		}
	} ## end for my $schtasks_output_line (@{$schtasks_query_output...

	# Loop through the scheduled tasks configured to run as the user, update the password
	for my $task_name_to_update (@task_names_to_update) {
		my ($schtasks_change_exit_status, $schtasks_change_output) = run_ssh_command($computer_node_name, $management_node_keys, "schtasks.exe /Change /RP \"$password\" /TN \"$task_name_to_update\"");
		if (defined($schtasks_change_exit_status) && $schtasks_change_exit_status == 0) {
			notify($ERRORS{'OK'}, 0, "changed password for scheduled task: $task_name_to_update");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to change password for scheduled task: $task_name_to_update, exit status: $schtasks_change_exit_status, output:\n@{$schtasks_change_output}");
			return 0;
		}
	} ## end for my $task_name_to_update (@task_names_to_update)

	return 1;
} ## end sub set_password

#/////////////////////////////////////////////////////////////////////////////

=head2 enable_user

 Parameters  : $username (optional
 Returns     : 
 Description : 

=cut

sub enable_user {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	my $username = shift;

	# If no argument was supplied, use the user specified in the DataStructure
	if (!defined($username)) {
		$username = $self->data->get_user_logon_id();
	}

	# Make sure the username was determined
	if (!defined($username)) {
		notify($ERRORS{'WARNING'}, 0, "username could not be determined");
		return 0;
	}

	# Attempt to enable the user account (set ACTIVE=YES)
	notify($ERRORS{'DEBUG'}, 0, "enabling user $username on $computer_node_name");
	my ($enable_exit_status, $enable_output) = run_ssh_command($computer_node_name, $management_node_keys, "net user $username /ACTIVE:YES");
	if ($enable_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "user $username enabled on $computer_node_name");
	}
	elsif ($enable_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to enable user $username on $computer_node_name, exit status: $enable_exit_status, output:\n@{$enable_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to enable user $username on $computer_node_name");
		return 0;
	}

	return 1;
} ## end sub enable_user

#/////////////////////////////////////////////////////////////////////////////

=head2 disable_pagefile

 Parameters  :
 Returns     :
 Description :

=cut

sub disable_pagefile {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string .= <<"EOF";
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management]
"PagingFiles"=""
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "set the registry key to disable the pagefile");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set the registry key to disable the pagefile");
		return 0;
	}

	# Attempt to reboot the computer in order to delete the pagefile
	if ($self->reboot()) {
		notify($ERRORS{'DEBUG'}, 0, "computer was rebooted after disabling pagefile in the registry");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to reboot computer after disabling pagefile");
		return;
	}

	# Attempt to delete the pagefile
	if (!$self->delete_filesystem_entry("C:/pagefile.sys")) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete pagefile.sys");
		return;
	}

	return 1;
} ## end sub disable_pagefile

#/////////////////////////////////////////////////////////////////////////////

=head2 enable_pagefile

 Parameters  :
 Returns     :
 Description :

=cut

sub enable_pagefile {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string .= <<'EOF';
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Memory Management]
"PagingFiles"="?:\\\\pagefile.sys"
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "set registry key to enable the pagefile");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set registry key to enable the pagefile");
		return 0;
	}

	return 1;
} ## end sub enable_pagefile

#/////////////////////////////////////////////////////////////////////////////

=head2 disable_ipv6

 Parameters  :
 Returns     :
 Description :

=cut

sub disable_ipv6 {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string .= <<'EOF';
Windows Registry Editor Version 5.00

; This registry file contains the entries to disable all IPv6 components 
; http://support.microsoft.com/kb/929852

[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters]
"DisabledComponents"=dword:ffffffff
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "set registry keys to disable IPv6");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set the registry keys to disable IPv6");
		return 0;
	}

	return 1;
} ## end sub disable_ipv6

#/////////////////////////////////////////////////////////////////////////////

=head2 import_registry_file

 Parameters  :
 Returns     :
 Description :

=cut

sub import_registry_file {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_file_path = shift;
	if (!defined($registry_file_path) || !$registry_file_path) {
		notify($ERRORS{'WARNING'}, 0, "registry file path was not passed correctly as an argument");
		return;
	}

	my $registry_file_contents = `cat $registry_file_path`;
	notify($ERRORS{'DEBUG'}, 0, "registry file contents:\n$registry_file_contents");

	$registry_file_contents =~ s/([\"])/\\$1/gs;
	$registry_file_contents =~ s/\\+"/\\"/gs;

	# Specify where on the node the temporary registry file will reside
	my $temp_registry_file_path = 'C:/Cygwin/tmp/vcl_import.reg';

	# Echo the registry string to a file on the node
	my $echo_registry_command = "/usr/bin/echo.exe -E \"$registry_file_contents\" > " . $temp_registry_file_path;
	my ($echo_registry_exit_status, $echo_registry_output) = run_ssh_command($computer_node_name, $management_node_keys, $echo_registry_command, '', '', 1);
	if (defined($echo_registry_exit_status) && $echo_registry_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "registry file contents echoed to $temp_registry_file_path");
	}
	elsif ($echo_registry_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to echo registry file contents to $temp_registry_file_path, exit status: $echo_registry_exit_status, output:\n@{$echo_registry_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to echo registry file contents to $temp_registry_file_path");
		return;
	}

	# Run reg.exe IMPORT
	my $import_registry_command .= '"$SYSTEMROOT/System32/reg.exe" IMPORT ' . $temp_registry_file_path;
	my ($import_registry_exit_status, $import_registry_output) = run_ssh_command($computer_node_name, $management_node_keys, $import_registry_command, '', '', 1);
	if (defined($import_registry_exit_status) && $import_registry_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "registry file contents imported from $temp_registry_file_path");
	}
	elsif ($import_registry_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to import registry file contents from $temp_registry_file_path, exit status: $import_registry_exit_status, output:\n@{$import_registry_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to import registry file contents from $temp_registry_file_path");
		return;
	}

	return 1;
} ## end sub import_registry_file

#/////////////////////////////////////////////////////////////////////////////

=head2 import_registry_string

 Parameters  :
 Returns     :
 Description :

=cut

sub import_registry_string {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string = shift;
	if (!defined($registry_string) || !$registry_string) {
		notify($ERRORS{'WARNING'}, 0, "registry file path was not passed correctly as an argument");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "registry string:\n" . $registry_string);

	# Escape special characters with a backslash:
	# \
	# "
	#notify($ERRORS{'DEBUG'}, 0, "registry string:\n$registry_string");
	#$registry_string =~ s/\\+/\\\\\\\\/gs;
	$registry_string =~ s/\\/\\\\/gs;
	$registry_string =~ s/"/\\"/gs;

	# Replace \\" with \"
	#$registry_string =~ s/\\+(")/\\\\$1/gs;

	# Replace regular newlines with Windows newlines
	$registry_string =~ s/\r?\n/\r\n/gs;

	# Specify where on the node the temporary registry file will reside
	my $temp_registry_file_path = 'C:/Cygwin/tmp/vcl_import.reg';

	# Echo the registry string to a file on the node
	my $echo_registry_command = "/usr/bin/echo.exe -E \"$registry_string\" > " . $temp_registry_file_path;
	my ($echo_registry_exit_status, $echo_registry_output) = run_ssh_command($computer_node_name, $management_node_keys, $echo_registry_command, '', '', 1);
	if (defined($echo_registry_exit_status) && $echo_registry_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "registry string contents echoed to $temp_registry_file_path");
	}
	elsif ($echo_registry_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to echo registry string contents to $temp_registry_file_path, exit status: $echo_registry_exit_status, output:\n@{$echo_registry_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to echo registry string contents to $temp_registry_file_path");
		return;
	}

	# Run reg.exe IMPORT
	my $import_registry_command .= '"$SYSTEMROOT/System32/reg.exe" IMPORT ' . $temp_registry_file_path;
	my ($import_registry_exit_status, $import_registry_output) = run_ssh_command($computer_node_name, $management_node_keys, $import_registry_command, '', '', 1);
	if (defined($import_registry_exit_status) && $import_registry_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "registry string contents imported from $temp_registry_file_path");
	}
	elsif ($import_registry_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to import registry string contents from $temp_registry_file_path, exit status: $import_registry_exit_status, output:\n@{$import_registry_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to import registry string contents from $temp_registry_file_path");
		return;
	}

	return 1;
} ## end sub import_registry_string

#/////////////////////////////////////////////////////////////////////////////

=head2 add_hklm_run_registry_key

 Parameters  :
 Returns     :
 Description :

=cut

sub add_hklm_run_registry_key {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $command_name = shift;
	my $command      = shift;

	notify($ERRORS{'DEBUG'}, 0, "command name: " . $command_name);
	notify($ERRORS{'DEBUG'}, 0, "command: " . $command);

	# Replace forward slashes with backslashes, unless a space precedes the forward slash
	$command =~ s/([^ ])\//$1\\/g;
	notify($ERRORS{'DEBUG'}, 0, "forward to backslash: " . $command);

	# Escape backslashes, can never have enough...
	$command =~ s/\\/\\\\/g;
	notify($ERRORS{'DEBUG'}, 0, "escape backslashes: " . $command);

	# Escape quotes
	$command =~ s/"/\\"/g;
	notify($ERRORS{'DEBUG'}, 0, "escaped quotes: " . $command);

	# Make sure arguments were supplied
	if (!defined($command_name) && !defined($command)) {
		notify($ERRORS{'WARNING'}, 0, "HKLM run registry key not added, arguments were not passed correctly");
		return 0;
	}

	my $registry_string .= <<"EOF";
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run]
"$command_name"="$command"
EOF

	notify($ERRORS{'DEBUG'}, 0, "registry string:\n" . $registry_string);

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "added HKLM run registry value, name: $command_name, command: $command");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to add HKLM run registry value, name: $command_name, command: $command");
		return 0;
	}
	
	# Attempt to query the registry key to make sure it was added
	my $reg_query_command = '$SYSTEMROOT/System32/reg.exe query "HKLM\\SOFTWARE\\Microsoft\Windows\\\CurrentVersion\\Run" /v "' . $command_name . '"';
	my ($reg_query_exit_status, $reg_query_output) = run_ssh_command($computer_node_name, $management_node_keys, $reg_query_command, '', '', 1);
	if (defined($reg_query_exit_status) && $reg_query_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "queried '$command_name' registry key:\n" . join("\n", @{$reg_query_output}));
	}
	elsif (defined($reg_query_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to query '$command_name' registry key, exit status: $reg_query_exit_status, output:\n@{$reg_query_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to query '$command_name' registry key");
		return;
	}
	
	return 1;
} ## end sub add_hklm_run_registry_key

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_hklm_run_registry_value

 Parameters  :
 Returns     :
 Description :

=cut

sub delete_hklm_run_registry_key {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $key_name = shift;
	
	# Make sure argument was supplied
	if (!defined($key_name) && !defined($key_name)) {
		notify($ERRORS{'WARNING'}, 0, "HKLM run registry key not deleted, argument was not passed correctly");
		return 0;
	}
	
	# Attempt to query the registry key to make sure it was added
	my $reg_delete_command = '$SYSTEMROOT/System32/reg.exe delete "HKLM\\SOFTWARE\\Microsoft\Windows\\\CurrentVersion\\Run" /v "' . $key_name . '" /F';
	my ($reg_delete_exit_status, $reg_delete_output) = run_ssh_command($computer_node_name, $management_node_keys, $reg_delete_command, '', '', 1);
	if (defined($reg_delete_exit_status) && $reg_delete_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "deleted '$key_name' run registry key:\n" . join("\n", @{$reg_delete_output}));
	}
	elsif (defined($reg_delete_output) && grep(/unable to find/i, @{$reg_delete_output})) {
		notify($ERRORS{'OK'}, 0, "'$key_name' run registry key was not deleted, it does not exist");
	}
	elsif (defined($reg_delete_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete '$key_name' run registry key, exit status: $reg_delete_exit_status, output:\n@{$reg_delete_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to delete '$key_name' run registry key");
		return;
	}
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_scheduled_task

 Parameters  :
 Returns     :
 Description :

=cut

sub delete_scheduled_task {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $task_name     = shift;
	
	# Run schtasks.exe to delete any existing task
	my $delete_task_command = 'schtasks.exe /Delete /F /TN "' . $task_name . '"';
	my ($delete_task_exit_status, $delete_task_output) = run_ssh_command($computer_node_name, $management_node_keys, $delete_task_command);
	if (defined($delete_task_exit_status) && $delete_task_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "deleted existing scheduled task '$task_name' on $computer_node_name");
	}
	elsif (defined($delete_task_output) && grep(/task.*does not exist/i, @{$delete_task_output})) {
		notify($ERRORS{'DEBUG'}, 0, "scheduled task '$task_name' does not already exist on $computer_node_name");
	}
	elsif (defined($delete_task_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to deleted existing scheduled task '$task_name' on $computer_node_name, exit status: $delete_task_exit_status, output:\n@{$delete_task_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to execute ssh command deleted existing scheduled task '$task_name' on $computer_node_name");
		return;
	}
	
	return 1;
}

#/////////////////////////////////////////////////////////////////////////////

=head2 create_startup_scheduled_task

 Parameters  :
 Returns     :
 Description :

=cut

sub create_startup_scheduled_task {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $task_name     = shift;
	my $task_command  = shift;
	my $task_user     = shift;
	my $task_password = shift;

	# Escape backslashes, can never have enough...
	$task_command =~ s/\\/\\\\/g;

	# Replace forward slashes with backslashes
	$task_command =~ s/([^\s])\//$1\\\\/g;
	
	# Escape quote characters
	$task_command =~ s/"/\\"/g;

	# Make sure arguments were supplied
	if (!defined($task_name) || !defined($task_command) || !defined($task_user) || !defined($task_password)) {
		notify($ERRORS{'WARNING'}, 0, "startup scheduled task not added, arguments were not passed correctly");
		return;
	}

	# You cannot create a task if one with the same name already exists
	# Vista's version of schtasks.exe has a /F which forces a new task to be created if one with the same name already exists
	# This option isn't supported with XP and other older versions of Windows
	if (!$self->delete_scheduled_task($task_name)) {
		notify($ERRORS{'WARNING'}, 0, "unable to delete existing scheduled task '$task_name' on $computer_node_name");
	}
	
	# Run schtasks.exe to add the task
	# Occasionally see this error even though it schtasks.exe returns exit status 0:
	# WARNING: The Scheduled task "VCL Startup Script" has been created, but may not run because the account information could not be set.
	my $create_task_command = "schtasks.exe /Create /RU \"$task_user\" /RP \"$task_password\" /SC ONSTART /TN \"$task_name\" /TR \"$task_command\"";
	my ($create_task_exit_status, $create_task_output) = run_ssh_command($computer_node_name, $management_node_keys, $create_task_command);
	if (defined($create_task_output) && grep(/could not be set/i, @{$create_task_output})) {
		notify($ERRORS{'WARNING'}, 0, "created scheduled task '$task_name' on $computer_node_name but error occurred: " . join("\n", @{$create_task_output}));
		return 0;
	}
	elsif (defined($create_task_exit_status) && $create_task_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "created scheduled task '$task_name' on $computer_node_name");
	}
	elsif (defined($create_task_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to create scheduled task '$task_name' on $computer_node_name, exit status: $create_task_exit_status, output:\n@{$create_task_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to execute ssh command created scheduled task '$task_name' on $computer_node_name");
		return;
	}

	return 1;
} ## end sub create_startup_scheduled_task

#/////////////////////////////////////////////////////////////////////////////

=head2 enable_autoadminlogon

 Parameters  :
 Returns     :
 Description :

=cut

sub enable_autoadminlogon {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string .= <<"EOF";
Windows Registry Editor Version 5.00

; This file enables autoadminlogon for the root account

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="root"
"DefaultPassword"= "$WINDOWS_ROOT_PASSWORD"

EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "enabled autoadminlogon");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to enable autoadminlogon");
		return 0;
	}
} ## end sub enable_autoadminlogon

#/////////////////////////////////////////////////////////////////////////////

=head2 disable_autoadminlogon

 Parameters  :
 Returns     :
 Description :

=cut

sub disable_autoadminlogon {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string .= <<EOF;
Windows Registry Editor Version 5.00

; This file disables autoadminlogon for the root account

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon]
"AutoAdminLogon"="0"
"AutoLogonCount"="0"
"DefaultPassword"= ""
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "disabled autoadminlogon");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to disable autoadminlogon");
		return 0;
	}
} ## end sub disable_autoadminlogon

#/////////////////////////////////////////////////////////////////////////////

=head2 create_eventlog_entry

 Parameters  :
 Returns     :
 Description :

=cut

sub create_eventlog_entry {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $message = shift;

	# Make sure the message was passed as an argument
	if (!defined($message)) {
		notify($ERRORS{'WARNING'}, 0, "failed to create eventlog entry, message was passed as an argument");
		return 0;
	}

	# Run eventcreate.exe to create an event log entry
	my $eventcreate_command = '$SYSTEMROOT/System32/eventcreate.exe /T INFORMATION /L APPLICATION /SO VCL /ID 555 /D "' . $message . '"';
	my ($eventcreate_exit_status, $eventcreate_output) = run_ssh_command($computer_node_name, $management_node_keys, $eventcreate_command);
	if (defined($eventcreate_exit_status) && $eventcreate_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "created event log entry on $computer_node_name: $message");
	}
	elsif (defined($eventcreate_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to create event log entry on $computer_node_name: $message, exit status: $eventcreate_exit_status, output:\n@{$eventcreate_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to create event log entry on $computer_node_name: $message");
		return;
	}

	return 1;
} ## end sub create_eventlog_entry

#/////////////////////////////////////////////////////////////////////////////

=head2 reboot

 Parameters  : $wait_for_reboot
 Returns     : 
 Description : 

=cut

sub reboot {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Check if an argument was supplied
	my $wait_for_reboot = shift;
	if (!defined($wait_for_reboot) || $wait_for_reboot !~ /0/) {
		notify($ERRORS{'DEBUG'}, 0, "rebooting $computer_node_name and waiting for ssh to become active");
		$wait_for_reboot = 1;
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "rebooting $computer_node_name and NOT waiting");
		$wait_for_reboot = 0;
	}

	my $reboot_start_time = time();
	notify($ERRORS{'DEBUG'}, 0, "reboot will be attempted on $computer_node_name");

	# Check if computer responds to ssh before preparing for reboot
	if ($self->wait_for_ssh(0)) {
		# Make sure SSH access is enabled from private IP addresses
		if (!$self->firewall_enable_ssh_private()) {
			notify($ERRORS{'WARNING'}, 0, "reboot not attempted, failed to enable ssh from private IP addresses");
			return 0;
		}

		# Set sshd service startup mode to auto
		if (!$self->set_service_startup_mode('sshd', 'auto')) {
			notify($ERRORS{'WARNING'}, 0, "reboot not attempted, unable to set sshd service startup mode to auto");
			return 0;
		}

		# Make sure ping access is enabled from private IP addresses
		if (!$self->firewall_enable_ping_private()) {
			notify($ERRORS{'WARNING'}, 0, "reboot not attempted, failed to enable ping from private IP addresses");
			return 0;
		}

		# Initiate the shutdown.exe command to reboot the computer
		my $shutdown_command = "C:/Windows/system32/shutdown.exe -r -t 0 -f";
		my ($shutdown_exit_status, $shutdown_output) = run_ssh_command($computer_node_name, $management_node_keys, $shutdown_command);
		if (defined($shutdown_exit_status) && $shutdown_exit_status == 0) {
			notify($ERRORS{'OK'}, 0, "executed reboot command on $computer_node_name");
		}
		elsif (defined($shutdown_exit_status)) {
			notify($ERRORS{'WARNING'}, 0, "failed to execute reboot command on $computer_node_name, exit status: $shutdown_exit_status, output:\n@{$shutdown_output}");
			return 0;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to execute ssh command to reboot $computer_node_name");
			return;
		}
	} ## end if ($self->wait_for_ssh(0))
	else {
		# Computer did not respond to ssh
		notify($ERRORS{'WARNING'}, 0, "$computer_node_name did not respond to ssh, graceful reboot cannot be performed, attempting hard reset");

		# Call provisioning module's power_reset() subroutine
		if ($self->provisioner->power_reset()) {
			notify($ERRORS{'OK'}, 0, "initiated power reset on $computer_node_name");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "reboot failed, failed to initiate power reset on $computer_node_name");
			return 0;
		}
	} ## end else [ if ($self->wait_for_ssh(0))

	# Check if wait for reboot is set
	if (!$wait_for_reboot) {
		return 1;
	}

	# Wait for reboot is true
	notify($ERRORS{'OK'}, 0, "sleeping for 30 seconds while $computer_node_name begins to boot");
	sleep 30;

	# Make multiple attempts to wait for the reboot to complete
	my $wait_attempt_limit = 2;
	WAIT_ATTEMPT:
	for (my $wait_attempt = 1; $wait_attempt <= $wait_attempt_limit; $wait_attempt++) {
		if ($wait_attempt > 1) {
			# Computer did not become fully responsive on previous wait attempt
			notify($ERRORS{'OK'}, 0, "$computer_node_name reboot failed to complete on previous attempt, attempting hard power reset");

			# Call provisioning module's power_reset() subroutine
			if ($self->provisioner->power_reset()) {
				notify($ERRORS{'OK'}, 0, "reboot attempt $wait_attempt/$wait_attempt_limit: initiated power reset on $computer_node_name");
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "reboot failed, failed to initiate power reset on $computer_node_name");
				return 0;
			}
		} ## end if ($wait_attempt > 1)

		# Wait maximum of 2 minutes for the computer to become unresponsive
		if (!$self->wait_for_no_ping(2)) {
			# Computer never stopped responding to ping
			notify($ERRORS{'WARNING'}, 0, "$computer_node_name never became unresponsive to ping");
			next WAIT_ATTEMPT;
		}

		# Computer is unresponsive, reboot has begun
		# Wait for 30 seconds before beginning to check if computer is back online
		notify($ERRORS{'DEBUG'}, 0, "$computer_node_name reboot has begun, sleeping for 30 seconds");
		sleep 30;

		# Wait maximum of 4 minutes for the computer to come back up
		if (!$self->wait_for_ping(4)) {
			# Check if the computer was ever offline, it should have been or else reboot never happened
			notify($ERRORS{'WARNING'}, 0, "$computer_node_name never responded to ping");
			next WAIT_ATTEMPT;
		}

		notify($ERRORS{'DEBUG'}, 0, "$computer_node_name is pingable, waiting for ssh to respond");

		# Wait maximum of 3 minutes for ssh to respond
		if (!$self->wait_for_ssh(3)) {
			notify($ERRORS{'WARNING'}, 0, "ssh never responded on $computer_node_name");
			next WAIT_ATTEMPT;
		}

		# Wait then check ssh again in case initialization scripts are running
		# ssh may be available when the computer first boots, then network configuration scripts may automatically run
		# Make sure ssh is available a short time after it's first available
		notify($ERRORS{'DEBUG'}, 0, "$computer_node_name responded to ssh, sleeping for 20 seconds then checking ssh again");
		sleep 20;

		# Wait maximum of 2 minutes for ssh to respond
		if (!$self->wait_for_ssh(2)) {
			notify($ERRORS{'WARNING'}, 0, "ssh responded then stopped responding on $computer_node_name");
			next WAIT_ATTEMPT;
		}

		# Reboot was successful, calculate how long reboot took
		my $reboot_end_time = time();
		my $reboot_duration = ($reboot_end_time - $reboot_start_time);
		notify($ERRORS{'OK'}, 0, "reboot complete on $computer_node_name, took $reboot_duration seconds");
		return 1;
	} ## end for (my $wait_attempt = 1; $wait_attempt <=...

	# If loop completed, maximum number of reboot attempts was reached
	notify($ERRORS{'WARNING'}, 0, "reboot failed on $computer_node_name, made $wait_attempt_limit attempts");
	return 0;
} ## end sub reboot

#/////////////////////////////////////////////////////////////////////////////

=head2 wait_for_ping

 Parameters  : Maximum number of minutes to wait (optional)
 Returns     : 1 if computer is pingable, 0 otherwise
 Description : Attempts to ping the computer specified in the DataStructure
               for the current reservation. It will wait up to a maximum number
					of minutes. This can be specified by passing the subroutine an
					integer value or the default value of 5 minutes will be used.

=cut

sub wait_for_ping {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $computer_node_name = $self->data->get_computer_node_name();

	# Attempt to get the total number of minutes to wait from the command line
	my $total_wait_minutes = shift;
	if (!defined($total_wait_minutes) || $total_wait_minutes !~ /^\d+$/) {
		$total_wait_minutes = 5;
	}

	# Looping configuration variables
	# Seconds to wait in between loop attempts
	my $attempt_delay = 15;
	# Total loop attempts made
	# Add 1 to the number of attempts because if you're waiting for x intervals, you check x+1 times including at 0
	my $attempts = ($total_wait_minutes * 4) + 1;

	notify($ERRORS{'OK'}, 0, "waiting for $computer_node_name to respond to ping, maximum of $total_wait_minutes minutes");

	# Loop until computer is pingable
	for (my $attempt = 1; $attempt <= $attempts; $attempt++) {
		if ($attempt > 1) {
			notify($ERRORS{'OK'}, 0, "attempt " . ($attempt - 1) . "/" . ($attempts - 1) . ": $computer_node_name is not pingable, sleeping for $attempt_delay seconds");
			sleep $attempt_delay;
		}

		if (_pingnode($computer_node_name)) {
			notify($ERRORS{'OK'}, 0, "$computer_node_name is pingable");
			return 1;
		}
	} ## end for (my $attempt = 1; $attempt <= $attempts...

	# Calculate how long this waited
	my $total_wait = ($attempts * $attempt_delay);
	notify($ERRORS{'WARNING'}, 0, "$computer_node_name is NOT pingable after waiting for $total_wait seconds");
	return 0;
} ## end sub wait_for_ping

#/////////////////////////////////////////////////////////////////////////////

=head2 wait_for_no_ping

 Parameters  : Maximum number of minutes to wait (optional)
 Returns     : 1 if computer is not pingable, 0 otherwise
 Description : Attempts to ping the computer specified in the DataStructure
               for the current reservation. It will wait up to a maximum number
					of minutes for ping to fail.

=cut

sub wait_for_no_ping {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $computer_node_name = $self->data->get_computer_node_name();

	# Attempt to get the total number of minutes to wait from the command line
	my $total_wait_minutes = shift;
	if (!defined($total_wait_minutes) || $total_wait_minutes !~ /^\d+$/) {
		$total_wait_minutes = 5;
	}

	# Looping configuration variables
	# Seconds to wait in between loop attempts
	my $attempt_delay = 15;
	# Total loop attempts made
	# Add 1 to the number of attempts because if you're waiting for x intervals, you check x+1 times including at 0
	my $attempts = ($total_wait_minutes * 4) + 1;

	notify($ERRORS{'OK'}, 0, "waiting for $computer_node_name to become unresponsive, maximum of $total_wait_minutes minutes");

	# Loop until computer is offline
	for (my $attempt = 1; $attempt <= $attempts; $attempt++) {
		if ($attempt > 1) {
			notify($ERRORS{'OK'}, 0, "attempt " . ($attempt - 1) . "/" . ($attempts - 1) . ": $computer_node_name is still pingable, sleeping for $attempt_delay seconds");
			sleep $attempt_delay;
		}

		if (!_pingnode($computer_node_name)) {
			notify($ERRORS{'OK'}, 0, "$computer_node_name is not pingable, returning 1");
			return 1;
		}
	} ## end for (my $attempt = 1; $attempt <= $attempts...

	# Calculate how long this waited
	my $total_wait = ($attempts * $attempt_delay);
	notify($ERRORS{'WARNING'}, 0, "$computer_node_name is still pingable after waiting for $total_wait seconds");
	return 0;
} ## end sub wait_for_no_ping

#/////////////////////////////////////////////////////////////////////////////

=head2 wait_for_ssh

 Parameters  : Maximum number of minutes to wait (optional)
 Returns     : 1 if ssh succeeded to computer, 0 otherwise
 Description : Attempts to communicate to the computer specified in the
               DataStructure for the current reservation via SSH. It will wait
					up to a maximum number of minutes. This can be specified by
					passing the subroutine an integer value or the default value
					of 5 minutes will be used.

=cut

sub wait_for_ssh {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the total number of minutes to wait from the arguments
	# If not specified, use default value
	my $total_wait_minutes = shift;
	if (!defined($total_wait_minutes) || $total_wait_minutes !~ /^\d+$/) {
		$total_wait_minutes = 5;
	}

	# Looping configuration variables
	# Seconds to wait in between loop attempts
	my $attempt_delay = 15;
	# Total loop attempts made
	# Add 1 to the number of attempts because if you're waiting for x intervals, you check x+1 times including at 0
	my $attempts = ($total_wait_minutes * 4) + 1;

	notify($ERRORS{'OK'}, 0, "waiting for $computer_node_name to respond to ssh, maximum of $total_wait_minutes minutes");

	# Loop until ssh is available
	my $ssh_result = 0;
	for (my $attempt = 1; $attempt <= $attempts; $attempt++) {
		if ($attempt > 1) {
			notify($ERRORS{'OK'}, 0, "attempt " . ($attempt - 1) . "/" . ($attempts - 1) . ": $computer_node_name did not respond to ssh, sleeping for $attempt_delay seconds");
			sleep $attempt_delay;
		}

		# Try nmap to see if any of the ssh ports are open before attempting to run a test command
		if (!nmap_port($computer_node_name, 22) && !nmap_port($computer_node_name, 24)) {
			notify($ERRORS{'DEBUG'}, 0, "ports 22 and 24 are closed on $computer_node_name according to nmap");
			next;
		}

		# Run a test SSH command
		my ($exit_status, $output) = run_ssh_command($computer_node_name, $management_node_keys, "echo testing ssh on $computer_node_name", '', '', 1);

		# The exit status will be 0 if the command succeeded
		if (defined($exit_status) && $exit_status == 0) {
			notify($ERRORS{'OK'}, 0, "$computer_node_name is responding to ssh");
			return 1;
		}
	} ## end for (my $attempt = 1; $attempt <= $attempts...

	notify($ERRORS{'WARNING'}, 0, "$computer_node_name is not available via ssh");
	return 0;
} ## end sub wait_for_ssh

#/////////////////////////////////////////////////////////////////////////////

=head2 set_service_startup_mode

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub set_service_startup_mode {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $service_name = shift;
	my $startup_mode = shift;

	# Make sure both arguments were supplied
	if (!defined($service_name) && !defined($startup_mode)) {
		notify($ERRORS{'WARNING'}, 0, "set service startup mode failed, service name and startup mode arguments were not passed correctly");
		return 0;
	}

	# Make sure the startup mode is valid
	if ($startup_mode !~ /boot|system|auto|demand|disabled|delayed-auto|manual/i) {
		notify($ERRORS{'WARNING'}, 0, "set service startup mode failed, invalid startup mode: $startup_mode");
		return 0;
	}

	# Set the mode to demand if manual was specified, specific to sc command
	$startup_mode = "demand" if ($startup_mode eq "manual");

	# Use sc.exe to change the start mode
	my $service_startup_command = '"$SYSTEMROOT/System32/sc.exe" config ' . "$service_name start= $startup_mode";
	my ($service_startup_exit_status, $service_startup_output) = run_ssh_command($computer_node_name, $management_node_keys, $service_startup_command);
	if (defined($service_startup_exit_status) && $service_startup_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "$service_name service startup mode set to $startup_mode");
	}
	elsif ($service_startup_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to set $service_name service startup mode to $startup_mode, exit status: $service_startup_exit_status, output:\n@{$service_startup_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set $service_name service startup mode to $startup_mode, exit status: $service_startup_exit_status, output:\n@{$service_startup_output}");
		return;
	}

	return 1;
} ## end sub set_service_startup_mode

#/////////////////////////////////////////////////////////////////////////////

=head2 defragment_hard_drive

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub defragment_hard_drive {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Defragment the hard drive
	notify($ERRORS{'OK'}, 0, "beginning to defragment the hard drive on $computer_node_name");
	my ($defrag_exit_status, $defrag_output) = run_ssh_command($computer_node_name, $management_node_keys, '$SYSTEMROOT/System32/defrag.exe $SYSTEMDRIVE -v');
	if (defined($defrag_exit_status) && $defrag_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "hard drive defragmentation complete on $computer_node_name");
		return 1;
	}
	elsif (defined($defrag_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to defragment the hard drive, exit status: $defrag_exit_status, output:\n@{$defrag_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run the SSH command to defragment the hard drive");
		return;
	}
} ## end sub defragment_hard_drive

#/////////////////////////////////////////////////////////////////////////////

=head2 run_newsid

 Parameters  : 
 Returns     : 1 success 0 failure
 Description : 

=cut

sub run_newsid {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $reservation_id       = $self->data->get_reservation_id();
	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();
	my $computer_id          = $self->data->get_computer_id();

	# Attempt to get the computer name from the arguments
	# If no argument was supplied, use the name specified in the DataStructure
	my $computer_name = shift;
	if (!(defined($computer_name))) {
		my $image_id            = $self->data->get_image_id();
		my $computer_short_name = $self->data->get_computer_short_name();
		$computer_name = "$computer_short_name-$image_id";
	}

	my $registry_string .= <<'EOF';
Windows Registry Editor Version 5.00

; This registry file contains the entries to bypass the license agreement when newsid.exe is run

[HKEY_CURRENT_USER\\Software\\Sysinternals\\NewSID]
"EulaAccepted"=dword:00000001
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'DEBUG'}, 0, "added newsid eulaaccepted registry string");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to add newsid eulaaccepted registry string");
		return 0;
	}

	# Attempt to run newsid.exe
	# newsid.exe should automatically reboot the computer
	# It isn't done when the process exits, newsid.exe starts working and immediately returns
	# NewSid.exe [/a[[/n]|[/d <reboot delay (in seconds)>]]][<new computer name>]
	# /a - run without prompts
	# /n - Don't reboot after automatic run
	my $newsid_command               = "\"$NODE_CONFIGURATION_DIRECTORY/Utilities/newsid.exe\" /a \"$computer_name\"";
	my $newsid_start_processing_time = time();
	my ($newsid_exit_status, $newsid_output) = run_ssh_command($computer_node_name, $management_node_keys, $newsid_command);
	if (defined($newsid_exit_status) && $newsid_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "newsid.exe has been started on $computer_node_name, new computer name: $computer_name");
	}
	elsif (defined($newsid_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to start newsid.exe on $computer_node_name, exit status: $newsid_exit_status, output:\n@{$newsid_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to start newsid.exe on $computer_node_name");
		return;
	}

	my $newsid_end_processing_time = time();
	my $newsid_processing_duration = ($newsid_end_processing_time - $newsid_start_processing_time);
	notify($ERRORS{'OK'}, 0, "newsid.exe complete, newsid.exe took $newsid_processing_duration seconds");
	insertloadlog($reservation_id, $computer_id, "info", "newsid.exe processing took $newsid_processing_duration seconds");

	# After launching newsid.exe, wait for machine to become unresponsive
	if (!$self->wait_for_no_ping(10)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run newsid.exe, $computer_node_name never rebooted after waiting 10 minutes");
		return 0;
	}

	my $newsid_shutdown_time = time();
	notify($ERRORS{'OK'}, 0, "newsid.exe initiated reboot, $computer_node_name is unresponsive, reboot initialization took " . ($newsid_shutdown_time - $newsid_end_processing_time) . " seconds");

	# Wait maximum of 6 minutes for the computer to come back up
	if (!$self->wait_for_ping(6)) {
		notify($ERRORS{'WARNING'}, 0, "$computer_node_name never responded to ping, it never came back up");
		return 0;
	}

	my $newsid_ping_respond_time = time();
	notify($ERRORS{'OK'}, 0, "reboot nearly complete on $computer_node_name after running newsid.exe, ping response took " . ($newsid_ping_respond_time - $newsid_shutdown_time) . " seconds");

	# Ping successful, try ssh
	notify($ERRORS{'OK'}, 0, "waiting for ssh to respond on $computer_node_name");
	if (!$self->wait_for_ssh(3)) {
		notify($ERRORS{'WARNING'}, 0, "newsid.exe failed, $computer_node_name rebooted but ssh never became available");
		return 0;
	}

	my $newsid_ssh_respond_time = time();
	my $newsid_entire_duration  = ($newsid_ssh_respond_time - $newsid_start_processing_time);
	notify($ERRORS{'OK'}, 0, "newsid.exe succeeded on $computer_node_name, entire process took $newsid_entire_duration seconds");
	insertloadlog($reservation_id, $computer_id, "info", "entire newsid.exe process took $newsid_entire_duration seconds");

	return 1;
} ## end sub run_newsid

#/////////////////////////////////////////////////////////////////////////////

=head2 set_service_credentials

 Parameters  : $service_name, $username, $password
 Returns     : 
 Description : 

=cut

sub set_service_credentials {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the username from the arguments
	my $service_name = shift;
	my $username     = shift;
	my $password     = shift;

	# Make sure arguments were supplied
	if (!$service_name || !$username || !$password) {
		notify($ERRORS{'WARNING'}, 0, "set service logon failed, service name, username, and password arguments were not passed correctly");
		return 0;
	}

	# Attempt to set the service logon user name and password
	my $service_logon_command = '$SYSTEMROOT/System32/sc.exe config ' . $service_name . ' obj= ".\\' . $username . '" password= "' . $password . '"';
	my ($service_logon_exit_status, $service_logon_output) = run_ssh_command($computer_node_name, $management_node_keys, $service_logon_command);
	if (defined($service_logon_exit_status) && $service_logon_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "changed logon credentials for '$service_name' service to $username ($password) on $computer_node_name");
	}
	elsif (defined($service_logon_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to change $service_name service logon credentials to $username ($password) on $computer_node_name, exit status: $service_logon_exit_status, output:\n@{$service_logon_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to change $service_name service logon credentials to $username ($password) on $computer_node_name");
		return;
	}

	return 1;
} ## end sub set_service_credentials

#/////////////////////////////////////////////////////////////////////////////

=head2 get_service_list

 Parameters  : $service_name, $username, $password
 Returns     : 
 Description : 

=cut

sub get_service_list {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to delete the user account
	my $sc_query_command = "\$SYSTEMROOT/System32/sc.exe query | grep SERVICE_NAME | cut --fields=2 --delimiter=' '";
	my ($sc_query_exit_status, $sc_query_output) = run_ssh_command($computer_node_name, $management_node_keys, $sc_query_command);
	if (defined($sc_query_exit_status) && $sc_query_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "retrieved service list on $computer_node_name");
	}
	elsif (defined($sc_query_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to retrieve service list from $computer_node_name, exit status: $sc_query_exit_status, output:\n@{$sc_query_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to failed to retrieve service list from $computer_node_name");
		return;
	}

	my @service_name_array = split("\n", $sc_query_output);
	notify($ERRORS{'DEBUG'}, 0, "found " . @service_name_array . " services on $computer_node_name");
	return @service_name_array;
} ## end sub get_service_list

#/////////////////////////////////////////////////////////////////////////////

=head2 get_service_login_ids

 Parameters  : 
 Returns     : 
 Description : 

=cut

sub get_services_using_login_id {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $login_id = shift;
	if (!$login_id) {
		notify($ERRORS{'WARNING'}, 0, "unable to get services using login id, login id argument was not passed correctly");
		return;
	}

	# Get a list of the services on the node
	my @service_list = $self->get_service_list();
	if (!@service_list) {
		notify($ERRORS{'WARNING'}, 0, "unable to get service logon ids, failed to retrieve service name list from $computer_node_name, service credentials cannot be changed");
		return 0;
	}

	my @services_using_login_id;
	for my $service_name (@service_list) {
		# Attempt to get the service start name using sc.exe qc
		my $sc_qc_command = "\$SYSTEMROOT/System32/sc.exe qc $service_name | grep SERVICE_START_NAME | cut --fields=2 --delimiter='\\'";
		my ($sc_qc_exit_status, $sc_qc_output) = run_ssh_command($computer_node_name, $management_node_keys, $sc_qc_command);
		if (defined($sc_qc_exit_status) && $sc_qc_exit_status == 0) {
			notify($ERRORS{'OK'}, 0, "retrieved $service_name service start name from $computer_node_name");
		}
		elsif (defined($sc_qc_exit_status)) {
			notify($ERRORS{'WARNING'}, 0, "failed to retrieve $service_name service start name from $computer_node_name, exit status: $sc_qc_exit_status, output:\n@{$sc_qc_output}");
			return 0;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to failed to retrieve $service_name service start name from $computer_node_name");
			return;
		}

		my $service_logon_id = @{$sc_qc_output}[0];
		if ($service_logon_id =~ /^$login_id$/i) {
			push @services_using_login_id, $service_logon_id;
		}
	} ## end for my $service_name (@service_list)

	return @services_using_login_id;
} ## end sub get_services_using_login_id

#/////////////////////////////////////////////////////////////////////////////

=head2 disable_scheduled_task

 Parameters  : 
 Returns     : 1 success 0 failure
 Description : 

=cut

sub disable_scheduled_task {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the task name from the arguments
	my $task_name = shift;
	if (!$task_name) {
		notify($ERRORS{'OK'}, 0, "failed to disable scheduled task, task name argument was not correctly passed");
		return;
	}

	# Attempt to delete the user account
	my $schtasks_command = '$SYSTEMROOT/System32/schtasks.exe /Change /DISABLE /TN "' . $task_name . '"';
	my ($schtasks_exit_status, $schtasks_output) = run_ssh_command($computer_node_name, $management_node_keys, $schtasks_command);
	if (defined($schtasks_exit_status) && $schtasks_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "$task_name scheduled task disabled on $computer_node_name");
	}
	elsif (defined($schtasks_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to disable $task_name scheduled task on $computer_node_name, exit status: $schtasks_exit_status, output:\n@{$schtasks_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to disable $task_name scheduled task on $computer_node_name");
		return;
	}

	return 1;
} ## end sub disable_scheduled_task

#/////////////////////////////////////////////////////////////////////////////

=head2 disable_dynamic_dns

 Parameters  :
 Returns     :
 Description :

=cut

sub disable_dynamic_dns {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $registry_string .= <<"EOF";
Windows Registry Editor Version 5.00

; This file disables dynamic DNS updates

[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters]
"DisableDynamicUpdate"=dword:00000001

[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters]
"DisableReverseAddressRegistrations"=dword:00000001
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "disabled dynamic dns");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to disable dynamic dns");
		return 0;
	}

	# Get the network configuration
	my $network_configuration = $self->get_network_configuration();
	if (!$network_configuration) {
		notify($ERRORS{'WARNING'}, 0, "unable to retrieve network configuration");
		return 0;
	}

	return 1;
} ## end sub disable_dynamic_dns

#/////////////////////////////////////////////////////////////////////////////

=head2 disable_netbios

 Parameters  :
 Returns     :
 Description :

=cut

sub disable_netbios {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to query the registry for the NetBT service parameters
	my $reg_query_command = '$SYSTEMROOT/System32/reg.exe query "HKLM\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces" /s';
	my ($reg_query_exit_status, $reg_query_output) = run_ssh_command($computer_node_name, $management_node_keys, $reg_query_command, '', '', 1);
	if (defined($reg_query_exit_status) && $reg_query_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "queried NetBT parameters registry keys");
	}
	elsif (defined($reg_query_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to query NetBT parameters registry keys, exit status: $reg_query_exit_status, output:\n@{$reg_query_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to query NetBT parameters registry keys");
		return;
	}

	# Loop through the interfaces found, disable NetBIOS for any interface which has a NetbiosOptions key
	my $interface_key;
	for my $query_line (@{$reg_query_output}) {
		# Check if line is an interface key
		if ($query_line =~ /^(HKEY.*Tcpip.*})/i) {
			$interface_key = $1;
			next;
		}

		if ($query_line =~ /NetbiosOptions/i) {
			# Attempt to set the NetbiosOptions key
			my $reg_add_command = '$SYSTEMROOT/System32/reg.exe add "' . $interface_key . '" /v NetbiosOptions /d 2 /t REG_DWORD /f';
			my ($reg_add_exit_status, $reg_add_output) = run_ssh_command($computer_node_name, $management_node_keys, $reg_add_command, '', '', 1);
			if (defined($reg_add_exit_status) && $reg_add_exit_status == 0) {
				notify($ERRORS{'OK'}, 0, "disabled NetBIOS under: $interface_key");
			}
			elsif (defined($reg_add_exit_status)) {
				notify($ERRORS{'WARNING'}, 0, "failed to disable NetBIOS under: $interface_key, exit status: $reg_add_exit_status, output:\n@{$reg_add_output}");
				return 0;
			}
			else {
				notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to disable NetBIOS under: $interface_key");
				return;
			}
		} ## end if ($query_line =~ /NetbiosOptions/i)
	} ## end for my $query_line (@{$reg_query_output})

	# Attempt to stop the TCP/IP NetBIOS Helper service
	if ($self->stop_service('LmHosts')) {
		notify($ERRORS{'OK'}, 0, "TCP/IP NetBIOS Helper (LmHosts) service is stopped");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to stop the TCP/IP NetBIOS Helper (LmHosts) service");
	}

	# Attempt to disable the TCP/IP NetBIOS Helper service
	if ($self->set_service_startup_mode('LmHosts', 'disabled')) {
		notify($ERRORS{'OK'}, 0, "TCP/IP NetBIOS Helper (LmHosts) service is disabled");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to disable the TCP/IP NetBIOS Helper (LmHosts) service");
	}

	return 1;
} ## end sub disable_netbios

#/////////////////////////////////////////////////////////////////////////////

=head2 set_computer_description

 Parameters  :
 Returns     :
 Description :

=cut

sub set_computer_description {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to get the description from the arguments
	my $description = shift;
	if (!$description) {
		my $image_name       = $self->data->get_image_name();
		my $image_prettyname = $self->data->get_image_prettyname();
		$description = "$image_prettyname ($image_name)";
	}

	my $registry_string .= <<"EOF";
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Parameters]
"srvcomment"="$description"
EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'OK'}, 0, "set computer description to '$description'");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set computer description to '$description'");
		return 0;
	}
} ## end sub set_computer_description

#/////////////////////////////////////////////////////////////////////////////

=head2 set_my_computer_name

 Parameters  :
 Returns     :
 Description :

=cut

sub set_my_computer_name {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();
	my $image_prettyname     = $self->data->get_image_prettyname();

	my $value = shift;
	$value = $image_prettyname if !$value;

	my $add_registry_command .= "\"\$SYSTEMROOT/System32/reg.exe\" add \"HKCR\\CLSID\\{20D04FE0-3AEA-1069-A2D8-08002B30309D}\" /v LocalizedString /t REG_EXPAND_SZ /d \"$value\" /f";
	my ($add_registry_exit_status, $add_registry_output) = run_ssh_command($computer_node_name, $management_node_keys, $add_registry_command, '', '', 1);
	if (defined($add_registry_exit_status) && $add_registry_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "my computer name changed to '$value'");
	}
	elsif ($add_registry_exit_status) {
		notify($ERRORS{'WARNING'}, 0, "failed to change my computer name to '$value', exit status: $add_registry_exit_status, output:\n@{$add_registry_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run SSH command to change my computer name to '$value'");
		return;
	}

	return 1;
} ## end sub set_my_computer_name

#/////////////////////////////////////////////////////////////////////////////

=head2 grant_access

 Parameters  :
 Returns     :
 Description :

=cut

sub grant_access {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();
	my $remote_ip            = $self->data->get_reservation_remote_ip();
	my $multiple_users       = $self->data->get_imagemeta_usergroupmembercount();
	my $request_forimaging   = $self->data->get_request_forimaging();

	# Check to make sure remote IP is defined
	my $remote_ip_range;
	if (!$remote_ip) {
		notify($ERRORS{'WARNING'}, 0, "reservation remote IP address is not set in the data structure, opening RDP to any address");
		$remote_ip_range = '0.0.0.0/32';
	}
	elsif ($multiple_users) {
		notify($ERRORS{'OK'}, 0, "reservation has multiple users, opening RDP to any address");
		$remote_ip_range = '0.0.0.0/32';
	}
	elsif ($remote_ip !~ /^(\d{1,3}\.?){4}$/) {
		notify($ERRORS{'WARNING'}, 0, "reservation remote IP address format is invalid: $remote_ip, opening RDP to any address");
		$remote_ip_range = '0.0.0.0/32';
	}
	else {
		# Assemble the IP range string in CIDR notation
		$remote_ip_range = "$remote_ip/16";
		notify($ERRORS{'OK'}, 0, "RDP will be allowed from $remote_ip_range on $computer_node_name");
	}


	# Allow RDP connections
	if ($self->firewall_enable_rdp($remote_ip_range)) {
		notify($ERRORS{'OK'}, 0, "firewall was configured to allow RDP access from $remote_ip_range on $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "firewall could not be configured to grant RDP access from $remote_ip_range on $computer_node_name");
		return 0;
	}

	# If this is an imaging request, make sure the Administrator account is enabled
	if ($request_forimaging) {
		notify($ERRORS{'DEBUG'}, 0, "imaging request, making sure Administrator account is enabled");
		if ($self->enable_user('Administrator')) {
			notify($ERRORS{'OK'}, 0, "Administrator account is enabled for imaging request");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to enable Administrator account for imaging request");
			return 0;
		}
	} ## end if ($request_forimaging)

	notify($ERRORS{'OK'}, 0, "access has been granted for reservation on $computer_node_name");
	return 1;
} ## end sub grant_access

#/////////////////////////////////////////////////////////////////////////////

=head2 revoke_access

 Parameters  :
 Returns     :
 Description :

=cut

sub revoke_access {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Disallow RDP connections
	if ($self->firewall_disable_rdp()) {
		notify($ERRORS{'OK'}, 0, "firewall was configured to deny RDP access on $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "firewall could not be configured to deny RDP access on $computer_node_name");
		return 0;
	}

	notify($ERRORS{'OK'}, 0, "access has been revoked to $computer_node_name");
	return 1;
} ## end sub revoke_access

#/////////////////////////////////////////////////////////////////////////////

=head2 get_currentimage_txt_contents

 Parameters  : 
 Returns     : array containing lines in currentimage.txt
 Description : 

=cut

sub get_currentimage_txt_contents {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to retrieve the contents of currentimage.txt
	my $cat_command = "cat ~/currentimage.txt";
	my ($cat_exit_status, $cat_output) = run_ssh_command($computer_node_name, $management_node_keys, $cat_command);
	if (defined($cat_exit_status) && $cat_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "retrieved currentimage.txt from $computer_node_name");
	}
	elsif (defined($cat_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to retrieve currentimage.txt from $computer_node_name, exit status: $cat_exit_status, output:\n@{$cat_output}");
		return ();
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to failed to retrieve currentimage.txt from $computer_node_name");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "found " . @{$cat_output} . " lines in currentimage.txt on $computer_node_name");

	return @{$cat_output};
} ## end sub get_currentimage_txt_contents

#/////////////////////////////////////////////////////////////////////////////

=head2 get_current_image_name

 Parameters  : 
 Returns     : string containing image name loaded on computer
 Description : 

=cut

sub get_current_image_name {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $computer_node_name = $self->data->get_computer_node_name();

	# Get the contents of the currentimage.txt file
	my @current_image_txt_contents;
	if (@current_image_txt_contents = $self->get_currentimage_txt_contents()) {
		notify($ERRORS{'DEBUG'}, 0, "retrieved currentimage.txt contents from $computer_node_name");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to retrieve currentimage.txt contents from $computer_node_name");
		return;
	}

	# Make sure an empty array wasn't returned
	if (defined $current_image_txt_contents[0]) {
		my $current_image_name = $current_image_txt_contents[0];

		# Remove any line break characters
		$current_image_name =~ s/[\r\n]*//g;

		notify($ERRORS{'DEBUG'}, 0, "returning name of image currently loaded on $computer_node_name: $current_image_name");
		return $current_image_name;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "empty array was returned when currentimage.txt contents were retrieved from $computer_node_name");
		return;
	}
} ## end sub get_current_image_name


#/////////////////////////////////////////////////////////////////////////////

=head2 firewall_configure

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub firewall_configure {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Check the arguments
	my $firewall_parameters = shift;
	if (!defined($firewall_parameters) || !$firewall_parameters) {
		notify($ERRORS{'WARNING'}, 0, "failed to open firewall on $computer_node_name, parameters hash reference was not passed");
		return;
	}
	if ((!defined($firewall_parameters->{port}) || !$firewall_parameters->{port}) && (!defined($firewall_parameters->{type}) || !$firewall_parameters->{type})) {
		notify($ERRORS{'WARNING'}, 0, "failed to open firewall on $computer_node_name, 'port' or 'type' hash key was not passed");
		return;
	}
	if (!defined($firewall_parameters->{protocol}) || !$firewall_parameters->{protocol}) {
		notify($ERRORS{'WARNING'}, 0, "failed to open firewall on $computer_node_name, 'protocol' hash key was not passed");
		return;
	}

	# Add quotes around anything with a space in the parameters hash which isn't already enclosed in quotes
	foreach my $rule_property (sort keys(%{$firewall_parameters})) {
		$firewall_parameters->{$rule_property} =~ s/^(.*\s.*)$/\"$1\"/g;
		#notify($ERRORS{'DEBUG'}, 0, "enclosing property in quotes: $firewall_parameters->{$rule_property}");
	}

	#	netsh firewall set portopening
	# [ protocol = ] TCP|UDP|ALL
	# [ port = ] 1-65535
	# [ [ name = ] name (optional)
	# [ mode = ] ENABLE (default)|DISABLE (optional)
	# [ scope = ] ALL|SUBNET|CUSTOM (optional)
	# [ addresses = ] addresses (optional)
	# [ profile = ] CURRENT (default)|DOMAIN|STANDARD|ALL (optional)
	# [ interface = ] name ] (optional)
	#  Remarks: 'profile' and 'interface' may not be specified together.
	#           'scope' and 'interface' may not be specified together.
	#           'scope' must be 'CUSTOM' to specify 'addresses'.

	# netsh firewall set icmpsetting
	# [ type = ] 2-5|8-9|11-13|17|ALL
	# [ [ mode = ] ENABLE (default)|DISABLE (optional)
	# [ profile = ] CURRENT (default)|DOMAIN|STANDARD|ALL (optional)
	# [ interface = ] name ] (optional)
	# type - ICMP type.
	#	2   - Allow outbound packet too big.
	#	3   - Allow outbound destination unreachable.
	#	4   - Allow outbound source quench.
	#	5   - Allow redirect.
	#	8   - Allow inbound echo request.
	#	9   - Allow inbound router request.
	#	11  - Allow outbound time exceeded.
	#	12  - Allow outbound parameter problem.
	#	13  - Allow inbound timestamp request.
	#	17  - Allow inbound mask request.
	#	ALL - All types.
	# Remarks: 'profile' and 'interface' may not be specified together.
	#		  'type' 2 and 'interface' may not be specified together.

	# Assemble the command based on the keys populated in the hash
	my $set_portopening_command;
	if ($firewall_parameters->{protocol} =~ /icmp/i) {
		$set_portopening_command = "netsh.exe firewall set icmpsetting";

		foreach my $rule_property (sort keys(%{$firewall_parameters})) {
			next if $rule_property !~ /^type|mode|profile|interface$/;
			$set_portopening_command .= " $rule_property=$firewall_parameters->{$rule_property}";
		}
	}
	else {
		$set_portopening_command = "netsh.exe firewall set portopening";

		foreach my $rule_property (sort keys(%{$firewall_parameters})) {
			next if $rule_property !~ /^protocol|port|name|mode|scope|addresses|profile|interface$/;
			$set_portopening_command .= " $rule_property=$firewall_parameters->{$rule_property}";
		}
	}

	my ($set_portopening_exit_status, $set_portopening_output) = run_ssh_command($computer_node_name, $management_node_keys, $set_portopening_command);
	if (defined($set_portopening_exit_status) && $set_portopening_exit_status == 0) {
		notify($ERRORS{'OK'}, 0, "set firewall portopening: " . Dumper($firewall_parameters));
	}
	elsif (defined($set_portopening_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to set firewall portopening on $computer_node_name: " . Dumper($firewall_parameters) . ", exit status: $set_portopening_exit_status, output:\n@{$set_portopening_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set firewall portopening on $computer_node_name: " . Dumper($firewall_parameters));
		return;
	}

	return 1;
} ## end sub firewall_configure

#/////////////////////////////////////////////////////////////////////////////

=head2 firewall_close

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub firewall_close {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Make sure firewall parameters hash was passed
	my $firewall_parameters = shift;
	if (!defined($firewall_parameters) || !$firewall_parameters) {
		notify($ERRORS{'WARNING'}, 0, "failed to close firewall on $computer_node_name, parameters hash reference was not passed");
		return;
	}

	# Add quotes around anything with a space in the parameters hash which isn't already enclosed in quotes
	foreach my $rule_property (sort keys(%{$firewall_parameters})) {
		$firewall_parameters->{$rule_property} =~ s/^(.*\s.*)$/\"$1\"/g;
		#notify($ERRORS{'DEBUG'}, 0, "enclosing '$rule_property' property in quotes: $firewall_parameters->{$rule_property}");
	}

	#	delete portopening
	#
	#      [ protocol = ] TCP|UDP|ALL
	#      [ port = ] 1-65535
	#      [ [ profile = ] CURRENT|DOMAIN|STANDARD|ALL (optional)
	#      [ interface = ] name ] (optional)
	#  Remarks: 'profile' and 'interface' may not be specified together.

	# Assemble the command based on the keys populated in the hash
	my $delete_portopening_command = "netsh.exe firewall delete portopening";
	foreach my $rule_property (sort keys(%{$firewall_parameters})) {
		next if $rule_property !~ /^protocol|port|profile|interface$/;
		$delete_portopening_command .= " $rule_property=$firewall_parameters->{$rule_property}";
	}

	# Attempt to delete existing portopenings
	notify($ERRORS{'DEBUG'}, 0, "attempting to delete matching firewall portopenings on $computer_node_name, command:\n$delete_portopening_command");
	my ($delete_portopening_exit_status, $delete_portopening_output) = run_ssh_command($computer_node_name, $management_node_keys, $delete_portopening_command);
	if (defined($delete_portopening_exit_status) && ($delete_portopening_exit_status == 0)) {
		notify($ERRORS{'OK'}, 0, "deleted matching firewall portopenings: " . Dumper($firewall_parameters));
		return 1;
	}
	elsif (defined($delete_portopening_exit_status) && ($delete_portopening_exit_status == 1)) {
		notify($ERRORS{'OK'}, 0, "unable to delete matching firewall portopenings because none exist: " . Dumper($firewall_parameters));
		return 1;
	}
	elsif (defined($delete_portopening_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to delete matching firewall portopenings on $computer_node_name: " . Dumper($firewall_parameters) . ", exit status: $delete_portopening_exit_status, output:\n@{$delete_portopening_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to delete matching firewall portopenings on $computer_node_name: " . Dumper($firewall_parameters));
		return 0;
	}
} ## end sub firewall_close

#/////////////////////////////////////////////////////////////////////////////

=head2 firewall_enable_ping_private

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub firewall_enable_ping_private {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my @private_interface_names = $self->get_private_interface_names();
	if (!@private_interface_names) {
		notify($ERRORS{'WARNING'}, 0, "private interface name could not be determined");
	}

	for my $private_interface_name (@private_interface_names) {
		my %firewall_parameters = (protocol  => 'icmp',
											type      => 8,
											interface => $private_interface_name,
											mode      => 'ENABLE',);

		# Call the configure firewall subroutine, pass it the necessary parameters
		if ($self->firewall_configure(\%firewall_parameters)) {
			notify($ERRORS{'OK'}, 0, "opened firewall for incoming ping on private network");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to open firewall for incoming ping on private network");
			return 0;
		}
	} ## end for my $private_interface_name (@private_interface_names)
	return 1;
} ## end sub firewall_enable_ping_private

#/////////////////////////////////////////////////////////////////////////////

=head2 firewall_enable_ssh_private

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub firewall_enable_ssh_private {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my @private_interface_names = $self->get_private_interface_names();
	if (!@private_interface_names) {
		notify($ERRORS{'WARNING'}, 0, "private interface name could not be determined");
	}

	for my $private_interface_name (@private_interface_names) {
		my %firewall_parameters = (name      => 'SSHD',
											protocol  => 'TCP',
											port      => '22',
											interface => $private_interface_name,
											mode      => 'ENABLE',);

		# Call the configure firewall subroutine, pass it the necessary parameters
		if ($self->firewall_configure(\%firewall_parameters)) {
			notify($ERRORS{'OK'}, 0, "opened firewall for incoming ssh via TCP port 22 on private interface");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "failed to open firewall for incoming ssh via TCP port 22 on private interface");
			return 0;
		}
	} ## end for my $private_interface_name (@private_interface_names)
	return 1;
} ## end sub firewall_enable_ssh_private

#/////////////////////////////////////////////////////////////////////////////

=head2 firewall_enable_rdp

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub firewall_enable_rdp {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my %firewall_parameters = (name     => 'Remote Desktop',
										protocol => 'TCP',
										port     => '3389',
										mode     => 'ENABLE',
										profile  => 'ALL',);

	# Check if the remote IP was passed correctly as an argument
	my $remote_ip = shift;
	if (!defined($remote_ip) || $remote_ip !~ /[\d\.\/]/) {
		$firewall_parameters{scope} = 'ALL';
	}
	else {
		$firewall_parameters{scope}     = 'CUSTOM';
		$firewall_parameters{addresses} = $remote_ip;
	}

	# Call the configure firewall subroutine, pass it the necessary parameters
	if ($self->firewall_configure(\%firewall_parameters)) {
		notify($ERRORS{'OK'}, 0, "opened firewall for incoming RDP via TCP port 3389");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to open firewall for incoming RDP via TCP port 3389");
		return 0;
	}
} ## end sub firewall_enable_rdp

#/////////////////////////////////////////////////////////////////////////////

=head2 firewall_disable_rdp

 Parameters  : 
 Returns     : 1 if succeeded, 0 otherwise
 Description : 

=cut

sub firewall_disable_rdp {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my %firewall_parameters = (protocol => 'TCP',
										port     => '3389',
										profile  => 'ALL',);

	# Call the configure firewall subroutine, pass it the necessary parameters
	if ($self->firewall_close(\%firewall_parameters)) {
		notify($ERRORS{'OK'}, 0, "closed firewall for incoming RDP via TCP port 3389");
		return 1;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to close firewall for incoming RDP via TCP port 3389");
		return 0;
	}
} ## end sub firewall_disable_rdp

#/////////////////////////////////////////////////////////////////////////////

=head2 get_network_configuration

 Parameters  : 
 Returns     :
 Description : Retrieves the network configuration from the computer. Returns
               a hash. The hash keys are the interface names:
					$hash{<interface name>}{dhcp_enabled}
					$hash{<interface name>}{description}
					$hash{<interface name>}{ip_address}
					$hash{<interface name>}{subnet_mask}
					$hash{<interface name>}{default_gateway}
					
					The hash also contains 2 keys containing the names of the
					public and private interfaces:
					$hash{public_name}
					$hash{private_name}

=cut

sub get_network_configuration {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my ($exit_status, $output) = run_ssh_command($computer_node_name, $management_node_keys, '$SYSTEMROOT/System32/ipconfig.exe /all', '', '', 1);
	if (defined($exit_status) && $exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "ran ipconfig");
	}
	elsif (defined($exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run ipconfig, exit status: $exit_status, output:\n@{$output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run the SSH command to run ipconfig");
		return;
	}

	my %interfaces;
	my $interface_name;
	my $previous_dns = 0;
	for my $line (@{$output}) {
		# Find beginning of interface section
		if ($line =~ /ethernet adapter (.*):/i) {
			# Get the interface name
			$interface_name = $1;

			# Initialize hash values
			$interfaces{$interface_name}{dhcp_enabled}    = '';
			$interfaces{$interface_name}{description}     = '';
			$interfaces{$interface_name}{ip_address}      = '';
			$interfaces{$interface_name}{subnet_mask}     = '';
			$interfaces{$interface_name}{default_gateway} = '';
			$interfaces{$interface_name}{dns_servers}     = ();
		} ## end if ($line =~ /ethernet adapter (.*):/i)

		# Check lines, see if they contain information to be saved
		$interfaces{$interface_name}{dhcp_enabled}    = $1 if ($line =~ /dhcp enabled[\s\.:]*(.*)/i);
		$interfaces{$interface_name}{description}     = $1 if ($line =~ /description[\s\.:]*(.*)/i);
		$interfaces{$interface_name}{ip_address}      = $1 if ($line =~ /ip address[\s\.:]*([\d\.]*)/i);
		$interfaces{$interface_name}{subnet_mask}     = $1 if ($line =~ /subnet mask[\s\.:]*([\d\.]*)/i);
		$interfaces{$interface_name}{default_gateway} = $1 if ($line =~ /default gateway[\s\.:]*([\d\.]*)/i);
		if ($line =~ /dns servers[\s\.:]*(.*)/i || ($previous_dns && $line =~ /^\s+([\d\.]+)/)) {
			push(@{$interfaces{$interface_name}{dns_servers}}, $1);
			$previous_dns = 1;
		}
		else {
			$previous_dns = 0;
		}
	} ## end for my $line (@{$output})

	return \%interfaces;
} ## end sub get_network_configuration

#/////////////////////////////////////////////////////////////////////////////

=head2 get_private_interface_names

 Parameters  : 
 Returns     : array containing names of private interfaces
 Description : 

=cut

sub get_private_interface_names {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $network_configuration = $self->get_network_configuration();

	# Make sure network configuration was retrieved
	if (!$network_configuration) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine private adapter name, failed to retrieve network configuration");
		return;
	}

	my @private_interface_names;

	# Loop through all of the network interfaces
	foreach my $interface_name (sort keys %{$network_configuration}) {
		my $ip_address  = $network_configuration->{$interface_name}{ip_address};
		my $description = $network_configuration->{$interface_name}{description};
		$description = '' if !$description;

		# Make sure an IP address was found
		if (!$ip_address) {
			notify($ERRORS{'DEBUG'}, 0, "interface does not have an ip address: $interface_name");
			next;
		}

		# Split the ip address up
		my @octets = split(/\./, $ip_address);

		# Figure out if this is a private or public address

		# Private: 10.0.0.0 10.255.255.255 16,777,216
		if (($interface_name . $description) =~ /loopback|virtual|pseudo|vmware|afs/i) {
			next;
		}
		elsif ($octets[0] == 10) {
			# Check if a matching interface was already found
			if (@private_interface_names) {
				notify($ERRORS{'WARNING'}, 0, "multiple interfaces found with private IP address");
			}

			push(@private_interface_names, $interface_name);
		}
	} ## end foreach my $interface_name (sort keys %{$network_configuration...

	# Check if a matching interface was found
	if (!@private_interface_names) {
		notify($ERRORS{'WARNING'}, 0, "private interface was not found");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "returning private interface array: " . join(", ", @private_interface_names));
	return @private_interface_names;
} ## end sub get_private_interface_names

#/////////////////////////////////////////////////////////////////////////////

=head2 get_public_interface_names

 Parameters  : 
 Returns     : array containing names of public interfaces
 Description : 

=cut

sub get_public_interface_names {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $network_configuration = $self->get_network_configuration();

	# Make sure network configuration was retrieved
	if (!$network_configuration) {
		notify($ERRORS{'WARNING'}, 0, "unable to determine public adapter name, failed to retrieve network configuration");
		return;
	}

	my @public_interface_names;

	# Loop through all of the network interfaces
	foreach my $interface_name (sort keys %{$network_configuration}) {
		my $ip_address  = $network_configuration->{$interface_name}{ip_address};
		my $description = $network_configuration->{$interface_name}{description};
		$description = '' if !$description;

		# Make sure an IP address was found
		if (!$ip_address) {
			notify($ERRORS{'DEBUG'}, 0, "interface does not have an ip address: $interface_name");
			next;
		}

		# Split the ip address up
		my @octets = split(/\./, $ip_address);

		# Figure out if this is a public or public address
		# Igore loopback and other interface names
		if (($interface_name . $description) =~ /loopback|virtual|pseudo|vmware|afs/i) {
			next;
		}
		# Private: 10.0.0.0 10.255.255.255 16,777,216
		elsif ($octets[0] == 10) {
			next;
		}
		# Private: 172.16.0.0 - 172.31.255.255
		elsif ($octets[0] != 172 && ($octets[1] >= 16 && $octets[1] <= 31)) {
			next;
		}
		# Private: 192.168.0.0 - 192.168.255.255
		elsif ($octets[0] == 192 && $octets[1] == 168) {
			next;
		}
		# Loopback: 127.0.0.0 to 127.255.255.255
		elsif ($octets[0] == 127) {
			next;
		}
		else {
			# Check if a matching interface was already found
			if (@public_interface_names) {
				notify($ERRORS{'WARNING'}, 0, "multiple interfaces found with public IP address");
			}

			push(@public_interface_names, $interface_name);
		}
	} ## end foreach my $interface_name (sort keys %{$network_configuration...

	# Check if a matching interface was found
	if (!@public_interface_names) {
		notify($ERRORS{'WARNING'}, 0, "public interface was not found");
		return;
	}

	notify($ERRORS{'DEBUG'}, 0, "returning public interface array: " . join(", ", @public_interface_names));
	return @public_interface_names;
} ## end sub get_public_interface_names

#/////////////////////////////////////////////////////////////////////////////

=head2 enable_dhcp

 Parameters  : 
 Returns     :
 Description : 

=cut

sub enable_dhcp {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $interface_name_argument = shift;
	my @interface_names;
	if (!$interface_name_argument) {
		push(@interface_names, $self->get_public_interface_names());
		push(@interface_names, $self->get_private_interface_names());
	}
	elsif ($interface_name_argument =~ /public/i) {
		push(@interface_names, $self->get_public_interface_names());
	}
	elsif ($interface_name_argument =~ /private/i) {
		push(@interface_names, $self->get_private_interface_names());
	}
	else {
		push(@interface_names, $interface_name_argument);
	}

	for my $interface_name (@interface_names) {
		# Use netsh to set the NIC to use DHCP
		my $set_dhcp_command = '$SYSTEMROOT/System32/netsh.exe interface ip set address name="' . $interface_name . '" source=dhcp';
		my ($set_dhcp_status, $set_dhcp_output) = run_ssh_command($computer_node_name, $management_node_keys, $set_dhcp_command);
		if (defined($set_dhcp_status) && $set_dhcp_status == 0) {
			notify($ERRORS{'OK'}, 0, "set interface '$interface_name' to use dhcp");
		}
		elsif (defined($set_dhcp_output) && grep(/dhcp is already enabled/i, @{$set_dhcp_output})) {
			notify($ERRORS{'OK'}, 0, "dhcp is already enabled on interface '$interface_name'");
		}
		elsif (defined($set_dhcp_status)) {
			notify($ERRORS{'OK'}, 0, "unable to set interface '$interface_name' to use dhcp, exit status: $set_dhcp_status, output:\n@{$set_dhcp_output}");
			return 0;
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to set interface '$interface_name' to use dhcp");
			return 0;
		}
	} ## end for my $interface_name (@interface_names)
	return 1;
} ## end sub enable_dhcp

#/////////////////////////////////////////////////////////////////////////////

=head2 delete_capture_configuration_files

 Parameters  : 
 Returns     :
 Description : Deletes the capture configuration directory.

=cut

sub delete_capture_configuration_files {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Remove old logon and logoff scripts
	$self->delete_files_by_pattern('$SYSTEMROOT/system32/GroupPolicy/User/Scripts', '.*VCL\(Prepare\|prepare\|Cleanup\|cleanup\).*');

	# Remove VCLprepare.cmd and VCLcleanup.cmd lines from scripts.ini file
	my $scripts_ini = '$SYSTEMROOT\\system32\\GroupPolicy\\User\\Scripts\\scripts.ini';
	my $sed_command = 'sed -i -r -e "s/[0-9]CmdLine=VCL(prepare|cleanup).*\.cmd//i" "' . $scripts_ini . '"';
	my ($sed_status, $sed_output) = run_ssh_command($computer_node_name, $management_node_keys, $sed_command);
	if (defined($sed_status) && $sed_status == 0) {
		notify($ERRORS{'OK'}, 0, "removed calls to VCLprepare.cmd and VCLcleanup.cmd from scripts.ini");
	}
	elsif (defined($sed_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to remove calls to VCLprepare.cmd and VCLcleanup.cmd from scripts.ini, exit status: $sed_status, output:\n@{$sed_output}");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to removed calls to VCLprepare.cmd and VCLcleanup.cmd from scripts.ini");
	}

	# Remove old root Application Data/VCL directory
	$self->delete_filesystem_entry('$SYSTEMDRIVE/Documents and Settings/root/Application Data/VCL');

	# Remove existing configuration files if they exist
	notify($ERRORS{'OK'}, 0, "attempting to remove old configuration directory if it exists: $NODE_CONFIGURATION_DIRECTORY");
	if (!$self->delete_filesystem_entry($NODE_CONFIGURATION_DIRECTORY)) {
		notify($ERRORS{'WARNING'}, 0, "unable to remove existing configuration directory: $NODE_CONFIGURATION_DIRECTORY");
		return 0;
	}

	return 1;
} ## end sub delete_capture_configuration_files

#/////////////////////////////////////////////////////////////////////////////

=head2 copy_capture_configuration_files

 Parameters  : $source_configuration_directory
 Returns     :
 Description : Copies all required configuration files to the computer,
               including scripts, utilities, drivers needed to capture an
				   image.

=cut

sub copy_capture_configuration_files {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Get the source configuration directory
	my $source_configuration_directory = shift;
	if (!$source_configuration_directory) {
		notify($ERRORS{'WARNING'}, 0, "source configuration directory was not specified as an argument");
		return 0;
	}

	# Attempt to create the node configuration directory if it doesn't already exist
	if (!$self->create_directory($NODE_CONFIGURATION_DIRECTORY)) {
		notify($ERRORS{'WARNING'}, 0, "unable to create directory on $computer_node_name: $NODE_CONFIGURATION_DIRECTORY");
		return 0;
	}

	# Copy configuration files
	notify($ERRORS{'OK'}, 0, "copying image capture configuration files from $source_configuration_directory to $computer_node_name");
	if (run_scp_command("$source_configuration_directory/*", "$computer_node_name:$NODE_CONFIGURATION_DIRECTORY", $management_node_keys)) {
		notify($ERRORS{'OK'}, 0, "copied $source_configuration_directory directory to $computer_node_name:$NODE_CONFIGURATION_DIRECTORY");

		notify($ERRORS{'DEBUG'}, 0, "attempting to set permissions on $computer_node_name:$NODE_CONFIGURATION_DIRECTORY");
		if (run_ssh_command($computer_node_name, $management_node_keys, "/usr/bin/chmod.exe -R 777 $NODE_CONFIGURATION_DIRECTORY")) {
			notify($ERRORS{'OK'}, 0, "chmoded -R 777 $computer_node_name:$NODE_CONFIGURATION_DIRECTORY");
		}
		else {
			notify($ERRORS{'WARNING'}, 0, "could not chmod -R 777 $computer_node_name:$NODE_CONFIGURATION_DIRECTORY");
		}
	} ## end if (run_scp_command("$source_configuration_directory/*"...
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to copy $source_configuration_directory to $computer_node_name");
		return 0;
	}

	return 1;
} ## end sub copy_capture_configuration_files

#/////////////////////////////////////////////////////////////////////////////

=head2 run_sysprep

 Parameters  : None
 Returns     : 1 if successful, 0 otherwise
 Description : -Calls subroutine to prepare the hardware drivers
               -Copies Sysprep files to C:\Sysprep
					-Clears out the setupapi.log file
					-Calls Sysprep.exe with the options to seal and shutdown the computer
					-Waits for computer to become unresponsive
					-Waits 3 additional minutes
					-Calls provisioning module's power_off() subroutine to make sure the computer is powered off

=cut

sub run_sysprep {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Remove old C:\Sysprep directory if it exists
	notify($ERRORS{'DEBUG'}, 0, "attempting to remove old C:/Sysprep directory if it exists");
	if (!$self->delete_filesystem_entry('C:/Sysprep')) {
		notify($ERRORS{'WARNING'}, 0, "unable to remove existing C:/Sysprep directory");
		return 0;
	}

	# Copy and scan drivers
	notify($ERRORS{'DEBUG'}, 0, "attempting to copy and scan drivers");
	if (!$self->prepare_drivers()) {
		notify($ERRORS{'WARNING'}, 0, "unable to copy and scan drivers");
		return 0;
	}

	# Fix the path, xcopy.exe requires backslashes
	(my $node_configuration_directory = $NODE_CONFIGURATION_DIRECTORY) =~ s/\//\\/g;

	# Copy Sysprep files to C:\Sysprep
	my $xcopy_command = "xcopy.exe /E /C /I /Q /H /K /O /Y \"$node_configuration_directory\\Utilities\\Sysprep\" \"C:\\Sysprep\"";
	my ($xcopy_status, $xcopy_output) = run_ssh_command($computer_node_name, $management_node_keys, $xcopy_command);
	if (defined($xcopy_status) && $xcopy_status == 0) {
		notify($ERRORS{'OK'}, 0, "copied Sysprep files to C:/Sysprep");
	}
	elsif (defined($xcopy_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to copy Sysprep files to C:/Sysprep, exit status: $xcopy_status, output:\n@{$xcopy_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to copy Sysprep files to C:/Sysprep");
		return 0;
	}

	# Clear out setupapi.log
	my $setupapi_command = "/bin/cat C:/Windows/setupapi.log >> C:/Windows/setupapi_save.log && /bin/cp /dev/null C:/Windows/setupapi.log";
	my ($setupapi_status, $setupapi_output) = run_ssh_command($computer_node_name, $management_node_keys, $setupapi_command);
	if (defined($setupapi_status) && $setupapi_status == 0) {
		notify($ERRORS{'OK'}, 0, "cleared out setupapi.log");
	}
	elsif (defined($setupapi_status)) {
		notify($ERRORS{'OK'}, 0, "failed to clear out setupapi.log, exit status: $setupapi_status, output:\n@{$setupapi_output}");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to clear out setupapi.log");
		return 0;
	}

	# Run Sysprep.exe, use cygstart to lauch the .exe and return immediately
	my $sysprep_command = '/bin/cygstart.exe C:/Sysprep/sysprep.exe /quiet /reseal /mini /forceshutdown';
	my ($sysprep_status, $sysprep_output) = run_ssh_command($computer_node_name, $management_node_keys, $sysprep_command);
	if (defined($sysprep_status) && $sysprep_status == 0) {
		notify($ERRORS{'OK'}, 0, "initiated Sysprep.exe, waiting for $computer_node_name to become unresponsive");
	}
	elsif (defined($sysprep_status)) {
		notify($ERRORS{'OK'}, 0, "failed to initiate Sysprep.exe, exit status: $sysprep_status, output:\n@{$sysprep_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to initiate Sysprep.exe");
		return 0;
	}

	# Wait maximum of 5 minutes for the computer to become unresponsive
	if (!$self->wait_for_no_ping(5)) {
		# Computer never stopped responding to ping
		notify($ERRORS{'WARNING'}, 0, "$computer_node_name never became unresponsive to ping");
		return 0;
	}

	# Wait for 3 minutes then call provisioning module's power_off() subroutine
	# Sysprep does not always shut down the computer when it is done
	notify($ERRORS{'OK'}, 0, "sleeping for 3 minutes to allow Sysprep.exe to finish");
	sleep 180;

	# Call power_off() to make sure computer is shut down
	if (!$self->provisioner->power_off()) {
		# Computer could not be shut off
		notify($ERRORS{'WARNING'}, 0, "unable to power off $computer_node_name");
		return 0;
	}

	return 1;
} ## end sub run_sysprep

#/////////////////////////////////////////////////////////////////////////////

=head2 prepare_drivers

 Parameters  : 
 Returns     :
 Description : 

=cut

sub prepare_drivers {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Remove old C:/Drivers directory if it exists
	notify($ERRORS{'DEBUG'}, 0, "attempting to remove old C:/Drivers directory if it exists");
	if (!$self->delete_filesystem_entry('C:/Drivers')) {
		notify($ERRORS{'WARNING'}, 0, "unable to remove existing C:/Drivers directory");
		return 0;
	}

	# Fix the path, xcopy.exe requires backslashes
	(my $node_configuration_directory = $NODE_CONFIGURATION_DIRECTORY) =~ s/\//\\/g;

	# Copy driver files to C:/Drivers
	my $xcopy_command = "xcopy.exe /E /C /I /Q /H /K /O /Y \"$node_configuration_directory\\Drivers\" \"C:\\Drivers\"";
	my ($xcopy_status, $xcopy_output) = run_ssh_command($computer_node_name, $management_node_keys, $xcopy_command);
	if (defined($xcopy_status) && $xcopy_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "copied driver files to C:/Drivers");
	}
	elsif (defined($xcopy_status)) {
		notify($ERRORS{'OK'}, 0, "failed to copy driver files to C:/Drivers, exit status: $xcopy_status, output:\n@{$xcopy_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to drivers files to C:/Drivers");
		return 0;
	}

	# Run spdrvscn.exe
	my $spdrvscn_command = $NODE_CONFIGURATION_DIRECTORY . '/Utilities/SPDrvScn/spdrvscn.exe /p "C:/Drivers" /e inf /f /a /s /q';
	my ($spdrvscn_status, $spdrvscn_output) = run_ssh_command($computer_node_name, $management_node_keys, $spdrvscn_command);
	if (defined($spdrvscn_status) && $spdrvscn_status == 0) {
		notify($ERRORS{'OK'}, 0, "executed spdrvscn.exe");
	}
	elsif (defined($spdrvscn_status)) {
		notify($ERRORS{'OK'}, 0, "failed to execute spdrvscn.exe, exit status: $spdrvscn_status, output:\n@{$spdrvscn_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to execute spdrvscn.exe");
		return 0;
	}

	return 1;
} ## end sub prepare_drivers

#/////////////////////////////////////////////////////////////////////////////

=head2 clean_hard_drive

 Parameters  : 
 Returns     :
 Description : Removed unnecessary files from the hard drive. This is done
               before capturing an image. Examples of unnecessary files:
					-temp files and temp directories
					-cache files
					-downloaded patch files

=cut

sub clean_hard_drive {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my @patterns_to_delete = ('$TEMP,.*', '$TMP,.*', '$SYSTEMDRIVE/Temp,.*', '$SYSTEMROOT/Temp,.*', '$SYSTEMROOT/ie7updates,.*', '$SYSTEMROOT/ServicePackFiles,.*', '$SYSTEMROOT/SoftwareDistribution/Download,.*', '$SYSTEMROOT/Minidump,.*', '$ALLUSERSPROFILE/Application Data/Microsoft/Dr Watson,.*', '$SYSTEMROOT,.*\\.tmp', '$SYSTEMROOT,.*\\$hf_mig\\$.*', '$SYSTEMROOT,.*\\$NtUninstall.*', '$SYSTEMROOT,.*\\$NtServicePackUninstall.*', '$SYSTEMROOT,.*\\$MSI.*Uninstall.*', '$SYSTEMROOT/inf,.*INFCACHE\\.1', '$SYSTEMROOT/inf,.*[\\\\\\/]oem.*\\..*', '$SYSTEMROOT,.*AFSCache', '$SYSTEMROOT,.*afsd_init\\.log', '$SYSTEMDRIVE/Documents and Settings,.*\\.log', '$SYSTEMDRIVE/Documents and Settings,.*Recent\\/.*', '$SYSTEMDRIVE/Documents and Settings,.*Cookies\\/.*', '$SYSTEMDRIVE/Documents and Settings,.*Temp\\/.*', '$SYSTEMDRIVE/Documents and Settings,.*Temporary Internet Files\\/Content.*\\/.*', '$SYSTEMDRIVE,.*pagefile\\.sys',);

	# Attempt to stop the AFS service, needed to delete AFS files
	$self->stop_service('TransarcAFSDaemon');

	# Loop through the directories to empty
	# Don't care if they aren't emptied
	for my $base_pattern (@patterns_to_delete) {
		my ($base_directory, $pattern) = split(',', $base_pattern);
		notify($ERRORS{'DEBUG'}, 0, "attempting to delete files under $base_directory matching pattern $pattern");
		$self->delete_files_by_pattern($base_directory, $pattern);
	}

	# Add the cleanmgr.exe settings to the registry
	my $registry_string .= <<"EOF";
Windows Registry Editor Version 5.00

; This registry file contains the entries to turn on all cleanmgr options 
; The state flags below are set to 1, so use the command: 'CLEANMGR /sagerun:1'

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches]

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Active Setup Temp Folders]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Content Indexer Cleaner]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Downloaded Program Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Hibernation File]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Internet Cache Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Memory Dump Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Offline Pages Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Old ChkDsk Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Previous Installations]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Recycle Bin]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Setup Log Files]
"StateFlags0001"=dword:00000000

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\System error memory dump files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\System error minidump files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Temporary Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Temporary Setup Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Temporary Sync Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Thumbnail Cache]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Upgrade Discarded Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Windows Error Reporting Archive Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Windows Error Reporting Queue Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Windows Error Reporting System Archive Files]
"StateFlags0001"=dword:00000002

[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\explorer\\VolumeCaches\\Windows Error Reporting System Queue Files]
"StateFlags0001"=dword:00000002

EOF

	# Import the string into the registry
	if ($self->import_registry_string($registry_string)) {
		notify($ERRORS{'DEBUG'}, 0, "set registry settings to configure the disk cleanup utility");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to set registry settings to configure the disk cleanup utility");
	}

	# Run cleanmgr.exe
	my $command = '$SYSTEMROOT/System32/cleanmgr.exe /SAGERUN:01';
	my ($status_cleanmgr, $output_cleanmgr) = run_ssh_command($computer_node_name, $management_node_keys, $command);
	if (defined($status_cleanmgr) && $status_cleanmgr == 0) {
		notify($ERRORS{'OK'}, 0, "ran cleanmgr.exe");
	}
	elsif (defined($status_cleanmgr)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run cleanmgr.exe, exit status: $status_cleanmgr, output:\n@{$output_cleanmgr}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to run cleanmgr.exe");
		return 0;
	}

	return 1;
} ## end sub clean_hard_drive

#/////////////////////////////////////////////////////////////////////////////

=head2 start_service

 Parameters  : 
 Returns     :
 Description : 

=cut

sub start_service {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $service_name = shift;
	if (!$service_name) {
		notify($ERRORS{'WARNING'}, 0, "service name was not passed as an argument");
		return;
	}

	my $command = '$SYSTEMROOT/System32/net.exe start "' . $service_name . '"';
	my ($status, $output) = run_ssh_command($computer_node_name, $management_node_keys, $command);
	if (defined($status) && $status == 0) {
		notify($ERRORS{'OK'}, 0, "started service: $service_name");
	}
	elsif (defined($output) && grep(/already been started/i, @{$output})) {
		notify($ERRORS{'OK'}, 0, "service has already been started: $service_name");
	}
	elsif (defined($status)) {
		notify($ERRORS{'WARNING'}, 0, "unable to start service: $service_name, exit status: $status, output:\n@{$output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to to start service: $service_name");
		return 0;
	}

	return 1;
} ## end sub start_service

#/////////////////////////////////////////////////////////////////////////////

=head2 stop_service

 Parameters  : 
 Returns     :
 Description : 

=cut

sub stop_service {
	my $self = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	my $service_name = shift;
	if (!$service_name) {
		notify($ERRORS{'WARNING'}, 0, "service name was not passed as an argument");
		return;
	}

	my $command = '$SYSTEMROOT/System32/net.exe stop "' . $service_name . '"';
	my ($status, $output) = run_ssh_command($computer_node_name, $management_node_keys, $command);
	if (defined($status) && $status == 0) {
		notify($ERRORS{'OK'}, 0, "stopped service: $service_name");
	}
	elsif (defined($output) && grep(/is not started/i, @{$output})) {
		notify($ERRORS{'OK'}, 0, "service is not started: $service_name");
	}
	elsif (defined($output) && grep(/does not exist/i, @{$output})) {
		notify($ERRORS{'WARNING'}, 0, "service does not exist: $service_name, exit status: $status, output:\n@{$output}");
		return 0;
	}
	elsif (defined($status)) {
		notify($ERRORS{'WARNING'}, 0, "unable to stop service: $service_name, exit status: $status, output:\n@{$output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "unable to run ssh command to to stop service: $service_name");
		return 0;
	}

	return 1;
} ## end sub stop_service

#/////////////////////////////////////////////////////////////////////////////

=head2 get_installed_applications

 Parameters  :
 Returns     :
 Description : Queries the registry for applications that are installed on the computer.
               Subkeys under the following key contain this information:
					HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall
					
					A reference to a hash is returned. The keys of this hash are the names of the subkeys under the Uninstall key.
					Each subkey contains additional data formatted as follows:
					my $installed_applications = $self->os->get_installed_applications();
					$installed_applications->{pdfFactory Pro}{DisplayName} = 'pdfFactory Pro'
               $installed_applications->{pdfFactory Pro}{UninstallString} = 'C:\WINDOWS\System32\spool\DRIVERS\W32X86\3\fppinst2.exe /uninstall'

=cut

sub get_installed_applications {
	my $self = shift;
	if (!ref($self)) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Get an optional regex filter string
	my $regex_filter = shift;
	if ($regex_filter) {
		notify($ERRORS{'DEBUG'}, 0, "attempting to retrieve applications installed on $computer_node_name matching filter: $regex_filter");
	}
	else {
		notify($ERRORS{'DEBUG'}, 0, "attempting to retrieve all applications installed on $computer_node_name");
	}

	# Attempt to query the registry for installed applications
	my $reg_query_command = '$SYSTEMROOT/System32/reg.exe QUERY "HKLM\Software\Microsoft\Windows\CurrentVersion\Uninstall" /s';
	my ($reg_query_exit_status, $reg_query_output) = run_ssh_command($computer_node_name, $management_node_keys, $reg_query_command, '', '', 1);
	if (defined($reg_query_exit_status) && $reg_query_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "queried Uninstall registry keys");
	}
	elsif (defined($reg_query_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to query Uninstall registry keys, exit status: $reg_query_exit_status, output:\n@{$reg_query_output}");
		return;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to query Uninstall registry keys");
		return;
	}

	# Make sure output was retrieved
	if (!$reg_query_output || scalar @{$reg_query_output} == 0) {
		notify($ERRORS{'WARNING'}, 0, "registry query did not product any output");
		return;
	}

	#notify($ERRORS{'DEBUG'}, 0, "reg.exe query output: " . join("\n", @{$reg_query_output}));

	# Loop through the lines of output
	my $product_key;
	my %installed_products;
	for my $query_output_line (@{$reg_query_output}) {
		#notify($ERRORS{'DEBUG'}, 0, "reg.exe query output line: '" . string_to_ascii($query_output_line) . "'");

		# Remove spaces from beginning and end of line
		$query_output_line =~ s/(^\s+)|(\s+$)//g;

		# Skip lines which don't contain a word character and lines starting with ! like this one:
		#    ! REG.EXE VERSION 3.0
		if ($query_output_line =~ /^!/ || $query_output_line !~ /\w/) {
			next;
		}

		# Check if line starts with HKEY, as in:
		#    HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall\ATI Display Driver
		if ($query_output_line =~ /^HKEY.*\\(.*)\s*/) {
			# Skip first line showing the base key that was searched for:
			#    HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Uninstall
			next if ($1 eq 'Uninstall');

			$product_key = $1;
			#notify($ERRORS{'DEBUG'}, 0, "found product key: '" . string_to_ascii($product_key) . "'");
			next;
		}

		# Line is a child key of one of the products, take apart the line, looks like this:
		#    <NO NAME>       REG_SZ
		#    DisplayName     REG_SZ  F-Secure SSH Client
		my ($info_key, $info_value) = ($query_output_line =~ /\s*([^\t]+)\s+\w+\s*([^\r\n]*)/);

		# Make sure the regex found the registry key name, if not, regex needs improvement
		if (!$info_key) {
			notify($ERRORS{'WARNING'}, 0, "regex didn't work correctly finding key name and value, line:\n" . string_to_ascii($query_output_line));
			next;
		}

		# Make sure the product key was found by this point, it should have been
		if (!$product_key) {
			notify($ERRORS{'WARNING'}, 0, "product key was not determined by the time the following line was processed, line:\n$query_output_line\nreg.exe query output: @{$reg_query_output}");
			next;
		}

		# Add the key and value to the hash
		$installed_products{$product_key}{$info_key} = $info_value;
	} ## end for my $query_output_line (@{$reg_query_output...

	# If filter was specified, remove keys not matching filter
	if ($regex_filter) {
		notify($ERRORS{'DEBUG'}, 0, "finding applications matching filter: $regex_filter");
		my %matching_products;
		foreach my $product_key (sort keys %installed_products) {
			#notify($ERRORS{'DEBUG'}, 0, "checking product key: $product_key");
			if (eval "\$product_key =~ $regex_filter") {
				notify($ERRORS{'DEBUG'}, 0, "found matching product key:\n$product_key");
				$matching_products{$product_key} = $installed_products{$product_key};
				next;
			}

			foreach my $info_key (sort keys %{$installed_products{$product_key}}) {
				my $info_value = $installed_products{$product_key}{$info_key};
				#notify($ERRORS{'DEBUG'}, 0, "checking value of {$info_key}: $info_value");
				if (eval "\$info_value =~ $regex_filter") {
					notify($ERRORS{'DEBUG'}, 0, "found matching value:\n{$product_key}{$info_key} = '$info_value'");
					$matching_products{$product_key} = $installed_products{$product_key};
					last;
				}
				else {
					next;
				}
			} ## end foreach my $info_key (sort keys %{$installed_products...
		} ## end foreach my $product_key (sort keys %installed_products)
		%installed_products = %matching_products;
	} ## end if ($regex_filter)

	if (%installed_products && $regex_filter) {
		notify($ERRORS{'DEBUG'}, 0, "found the following installed applications matching filter:\n$regex_filter\n" . format_data(\%installed_products));
		return \%installed_products;
	}
	elsif (%installed_products && !$regex_filter) {
		notify($ERRORS{'DEBUG'}, 0, "found the following installed applications:\n" . format_data(\%installed_products));
		return \%installed_products;
	}
	if (!%installed_products && $regex_filter) {
		notify($ERRORS{'DEBUG'}, 0, "did not find any installed applications matching filter:\n$regex_filter");
		return 0;
	}
	elsif (!%installed_products && !$regex_filter) {
		notify($ERRORS{'DEBUG'}, 0, "did not find any installed applications");
		return 0;
	}
} ## end sub get_installed_applications

#/////////////////////////////////////////////////////////////////////////////

=head2 get_task_list

 Parameters  : None, must be called as an object method ($self->os->get_task_list())
 Returns     : If successful: Reference to an array containing the lines of output generated by tasklist.exe
               If failed: false
 Description : Runs tasklist.exe and returns its output. Tasklist.exe displays a list of applications and associated tasks running on the computer.
               The following switches are used when tasklist.exe is executed:
               /NH - specifies the column header should not be displayed in the output
					/V  - specifies that verbose information should be displayed
					The output is formatted as follows (column header is not included):
					Image Name                   PID Session Name     Session#    Mem Usage Status          User Name                                              CPU Time Window Title                                                            
               System Idle Process            0 Console                 0         16 K Running         NT AUTHORITY\SYSTEM           

=cut

sub get_task_list {
	my $self = shift;
	if (!ref($self)) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}

	my $management_node_keys = $self->data->get_management_node_keys();
	my $computer_node_name   = $self->data->get_computer_node_name();

	# Attempt to run tasklist.exe with /NH for no header
	my $tasklist_command = '$SYSTEMROOT/System32/tasklist.exe /NH /V';
	my ($tasklist_exit_status, $tasklist_output) = run_ssh_command($computer_node_name, $management_node_keys, $tasklist_command, '', '', 1);
	if (defined($tasklist_exit_status) && $tasklist_exit_status == 0) {
		notify($ERRORS{'DEBUG'}, 0, "ran tasklist.exe");
	}
	elsif (defined($tasklist_exit_status)) {
		notify($ERRORS{'WARNING'}, 0, "failed to run tasklist.exe, exit status: $tasklist_exit_status, output:\n@{$tasklist_output}");
		return 0;
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to run ssh command to run tasklist.exe");
		return;
	}

	return $tasklist_output;
} ## end sub get_task_list

#/////////////////////////////////////////////////////////////////////////////

1;
__END__

=head1 BUGS and LIMITATIONS

 There are no known bugs in this module.
 Please report problems to the VCL team (vcl_help@ncsu.edu).

=head1 AUTHOR

 Aaron Peeler, aaron_peeler@ncsu.edu
 Andy Kurth, andy_kurth@ncsu.edu

=head1 SEE ALSO

L<http://vcl.ncsu.edu>


=cut