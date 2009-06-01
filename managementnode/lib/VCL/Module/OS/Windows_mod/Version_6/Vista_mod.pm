#!/usr/bin/perl -w
###############################################################################
# $Id: XP_mod.pm 774457 2009-05-13 18:12:08Z arkurth $
###############################################################################
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
###############################################################################

=head1 NAME

VCL::Module::OS::Windows_mod::Version_6::Vista_mod.pm - VCL module to support Windows Vista operating system

=head1 SYNOPSIS

 Needs to be written

=head1 DESCRIPTION

 This module provides VCL support for Windows Vista.

=cut

##############################################################################
package VCL::Module::OS::Windows_mod::Version_6::Vista_mod;

# Specify the lib path using FindBin
use FindBin;
use lib "$FindBin::Bin/../../../../..";

# Configure inheritance
use base qw(VCL::Module::OS::Windows_mod::Version_6);

# Specify the version of this module
our $VERSION = '2.00';

# Specify the version of Perl to use
use 5.008000;

use strict;
use warnings;
use diagnostics;

use VCL::utils;
use File::Basename;

##############################################################################

=head1 CLASS VARIABLES

=cut

=head2 $SOURCE_CONFIGURATION_DIRECTORY

 Data type   : Scalar
 Description : Location on management node of script/utilty/configuration
               files needed to configure the OS. This is normally the
					directory under the 'tools' directory specific to this OS.

=cut

our $SOURCE_CONFIGURATION_DIRECTORY = "$TOOLS/Windows_Vista";

##############################################################################

=head1 OBJECT METHODS

=cut

#/////////////////////////////////////////////////////////////////////////////

=head2 pre_capture

 Parameters  :
 Returns     :
 Description :

=cut

sub pre_capture {
	my $self = shift;
	my $args = shift;
	if (ref($self) !~ /windows/i) {
		notify($ERRORS{'CRITICAL'}, 0, "subroutine was called as a function, it must be called as a class method");
		return;
	}
	
	# Get the node configuration directory
	my $node_configuration_directory = $self->get_node_configuration_directory();
	unless ($node_configuration_directory) {
		notify($ERRORS{'WARNING'}, 0, "node configuration directory could not be determined");
		return;
	}
	
	notify($ERRORS{'OK'}, 0, "beginning Windows Vista image capture preparation tasks");
	
	# Call parent class's pre_capture() subroutine
	notify($ERRORS{'OK'}, 0, "calling parent class pre_capture() subroutine");
	if ($self->SUPER::pre_capture($args)) {
		notify($ERRORS{'OK'}, 0, "successfully executed parent class pre_capture() subroutine");
	}
	else {
		notify($ERRORS{'WARNING'}, 0, "failed to execute parent class pre_capture() subroutine");
		return 0;
	}
	
	# Add HKLM run key to call run_newsid.cmd after the image comes up
	if (!$self->add_hklm_run_registry_key('run_newsid.cmd', $node_configuration_directory . '/Scripts/run_newsid.cmd  >> ' . $node_configuration_directory . '/Logs/run_newsid.log')) {
		notify($ERRORS{'WARNING'}, 0, "unable to create run key to call run_newsid.cmd");
		return;
	}

	#Shut down computer unless end_state argument was passed with a value other than 'off'
	my $end_state = $self->{end_state} || 'off';
	if ($end_state eq 'off') {
		unless ($self->shutdown()) {
			notify($ERRORS{'WARNING'}, 0, "failed to shut down computer");
			return;
		}
	}
	
	notify($ERRORS{'OK'}, 0, "returning 1");
	return 1;
} ## end sub pre_capture

#/////////////////////////////////////////////////////////////////////////////

1;
__END__

=head1 AUTHOR

 Aaron Peeler <aaron_peeler@ncsu.edu>
 Andy Kurth <andy_kurth@ncsu.edu>

=head1 COPYRIGHT

 Apache VCL incubator project
 Copyright 2009 The Apache Software Foundation
 
 This product includes software developed at
 The Apache Software Foundation (http://www.apache.org/).

=head1 SEE ALSO

L<http://cwiki.apache.org/VCL/>

=cut