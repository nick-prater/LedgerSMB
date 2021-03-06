
package LedgerSMB::Scripts::login;

=head1 NAME

LedgerSMB:Scripts::login - web entry points for session creation/termination

=head1 DESCRIPTION

This script contains the request handlers for logging in and out of LedgerSMB.

=head1 METHODS

=over

=cut

use strict;
use warnings;

use HTTP::Status qw( HTTP_OK ) ;
use Try::Tiny;

use LedgerSMB::Locale;
use LedgerSMB::PSGI::Util;
use LedgerSMB::Scripts::menu;
use LedgerSMB::Sysconfig;
use LedgerSMB::Template::UI;
use LedgerSMB::User;

our $VERSION = 1.0;

=item no_db_actions

Returns an array of actions which should not receive
a request object /not/ connected to the database.

=cut

sub no_db_actions {
    return qw(__default logout_js);
}

=item dbonly_actions

Returns an array of actions which should not receive
a request object /not/ connected to the database.

=cut

sub dbonly_actions {
    return qw(logout authenticate);
}


=item clear_session_actions

Returns an array of actions which should have the session
(cookie) cleared before verifying the session and being
dispatched to.

=cut

sub clear_session_actions {
    return qw(__default authenticate);
}

=item __default (no action specified, do this)

Displays the login screen.

=cut

sub __default {
    my ($request) = @_;

    $request->{stylesheet} = 'ledgersmb.css';
    $request->{titlebar} = "LedgerSMB $request->{version}";
    my $template = LedgerSMB::Template::UI->new_UI;
    return $template->render($request, 'login', $request);
}

=item authenticate

This routine checks for the authentication information and if successful
sends either a HTTP_FOUND redirect or a HTTP_OK successful response.

If unsuccessful sends a HTTP_UNAUTHORIZED if the username/password is bad,
or a HTTP_454 error if the database does not exist.

=cut

sub authenticate {
    my ($request) = @_;

    $request->{company} ||= $LedgerSMB::Sysconfig::default_db;


    if (!$request->{dbonly}
        && ! $request->{_create_session}->()) {
        return LedgerSMB::PSGI::Util::unauthorized();
    }

    return [ HTTP_OK,
             [ 'Content-Type' => 'text/plain; charset=utf-8' ],
             [ 'Success' ] ];
}

=item login

Logs in the user and displays the root document.

=cut

sub login {
    my ($request) = @_;

    if (!$request->{_user}){
        return __default($request);
    }

    $request->{title} = "LedgerSMB $request->{version} -- ".
    "$request->{login} -- $request->{company}";

    my $template = LedgerSMB::Template::UI->new_UI;
    return $template->render($request, 'main', $request);
}

=item logout

Logs the user out.  Handling of HTTP browser credentials is browser-specific.

Firefox, Opera, and Internet Explorer are all supported.  Not sure about Chrome

=cut

sub logout {
    my ($request) = @_;
    $request->{callback}   = '';

    $request->{_logout}->();
    my $template = LedgerSMB::Template::UI->new_UI;
    return $template->render($request, 'logout', $request);
}

=item logout_js

This is a stub for a js logout feature.  It allows javascript to log out by
requiring only bogus credentials (logout:logout).

=cut

sub logout_js {
    my $request = shift @_;
    my $creds = $request->{_auth}->get_credentials;
    return LedgerSMB::PSGI::Util::unauthorized()
        unless (($creds->{password} eq 'logout')
                and ($creds->{login} eq 'logout'));
    return logout($request);
}


{
    local ($!, $@) = ( undef, undef);
    my $do_ = 'scripts/custom/login.pl';
    if ( -e $do_ ) {
        unless ( do $do_ ) {
            if ($! or $@) {
                warn "\nFailed to execute $do_ ($!): $@\n";
                die (  "Status: 500 Internal server error (login.pm)\n\n" );
            }
        }
    }
};

=back

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2009-2017 The LedgerSMB Core Team

This file is licensed under the GNU General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut


1;
