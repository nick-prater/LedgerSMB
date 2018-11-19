package LedgerSMB::Scripts::mtd_vat;

=head1 NAME

LedgerSMB:Scripts::mtd_vat - web entry points for HMRC MRD VAT Submissions

=head1 DESCRIPTION

This module contains the workflows for filing and managing UK VAT returns
using the HMRC Making Tax Digital (MTD) api.

=cut

use strict;
use warnings;
use PGObject::Simple;
use LedgerSMB::Sysconfig;
use LedgerSMB::Template::UI;
use Time::Piece;
use WebService::HMRC::Authenticate;

=head1 METHODS

=head2 authorisation_status

Displays a page showing the authorisation status in respect of the HMRC MTD
API and offering the opportunity to renew, clear or authorise a new access
token,

The request must contain the following parameter:

  * dbh


=cut

sub authorisation_status {

    my $request = shift;
    my $db = PGObject::Simple->new(
        dbh => $request->{dbh}
    );
    my $template_data = {};

    $template_data->{mtd_token} = $db->call_procedure(
        funcname => 'mtd__get_user_token',
    );

    my $template = LedgerSMB::Template::UI->new_UI;
    return $template->render(
        $request,
        'mtd_vat/authorisation_status',
        $template_data,
    );
}


=head2 clear_access_token

Removes the specified mtd_token record from the database and displays
the authorisation status screen.

The request must contain the following parameters:

  * mtd_token_id 
  * dbh

=cut

sub clear_access_token {

    my $request = shift;

    _delete_token(
        $request->{dbh},
        $request->{mtd_token_id},
    );

    authorisation_status($request);
}


=head2 authorise

Prompts the user to obtain and enter an HMRC MTD authorisation code.

No request parameters are required.

=cut

sub authorise {

    my $request = shift;

    my $auth = WebService::HMRC::Authenticate->new({
        base_url => $LedgerSMB::Sysconfig::mtd_endpoint_uri,
        client_id => $LedgerSMB::Sysconfig::mtd_client_id,
        client_secret => $LedgerSMB::Sysconfig::mtd_client_secret,
    });

    my $url = $auth->authorisation_url({
        scopes => ['read:vat', 'write:vat'],
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
    });

    my $template = LedgerSMB::Template::UI->new_UI;
    return $template->render(
        $request,
        'mtd_vat/authorise',
        {authorisation_url => $url},
    );
}


=head2 generate_access_token

Requests an access token from HMRC based on the user-supplied authorisation
code, stores it in the database and displays the authorisation status screen.

The request must contain the following parameters:

  * authorisation_code
  * dbh

=cut

sub generate_access_token {

    my $request = shift;

    my $auth = WebService::HMRC::Authenticate->new({
        base_url => $LedgerSMB::Sysconfig::mtd_endpoint_uri,
        client_id => $LedgerSMB::Sysconfig::mtd_client_id,
        client_secret => $LedgerSMB::Sysconfig::mtd_client_secret,
    });

    # Exchange access code for an access token.
    my $result = $auth->get_access_token({
        authorisation_code => $request->{authorisation_code},
        redirect_uri => 'urn:ietf:wg:oauth:2.0:oob',
    });
    $result->is_success or die 'ERROR: ', $result->data->{message};

    _store_token(
        $request->{dbh},
        $auth
    );

    authorisation_status($request);
}


=head2 renew_access_token

Requests an updated access token from HMRC to replace the specified existing
token. Updates the database, then displays the authorisation status screen.

  * mtd_token_id 
  * dbh

=cut

sub renew_access_token {

    my $request = shift;

    my $token = _get_token_by_id(
        $request->{dbh},
        $request->{mtd_token_id},
    );
    unless($token && $token->{refresh_token}) {
        die 'Invalid MTD token';
    }

    my $auth = WebService::HMRC::Authenticate->new({
        base_url => $LedgerSMB::Sysconfig::mtd_endpoint_uri,
        client_id => $LedgerSMB::Sysconfig::mtd_client_id,
        client_secret => $LedgerSMB::Sysconfig::mtd_client_secret,
        access_token => $token->{access_token},
        refresh_token => $token->{refresh_token},
    });

    my $result = $auth->refresh_tokens;
    $result->is_success or die 'ERROR: ', $result->data->{message};

    _delete_token(
        $request->{dbh},
        $request->{mtd_token_id},
    );

    _store_token(
        $request->{dbh},
        $auth
    );

    authorisation_status($request);
}



# PRIVATE FUNCTIONS

# get_user_token($dbh)
#
# Retrieves the most recent mtd_token belonging to the current user.
# If no token exists for the current user, a record with null fields
# is returned.

sub _get_user_token {

    my $dbh = shift;
    my $db = PGObject::Simple->new(
        dbh => $dbh,
    );

    my $token = $db->call_procedure(
        funcname => 'mtd__get_user_token',
    );

    return $token;
}


# get_token_by_id($dbh, $mtd_token_id)
#
# Retrieves the mtd_token with the specified id. Only tokens belonging to
# the current user may be retrieved.

sub _get_token_by_id {

    my $dbh = shift;
    my $token_id = shift;
    my $db = PGObject::Simple->new(
        dbh => $dbh,
    );

    my $token = $db->call_procedure(
        funcname => 'mtd__get_token_by_id',
        args => [$token_id],
    );

    return $token;
}



# _store_token($dbh, $hmrc_auth)
#
# Extracts the token from a WebService::HMRC::Authenticate object
# and stores it in the database, associated with the current user

sub _store_token {

    my $dbh = shift;
    my $auth = shift;

    my $expiry = gmtime($auth->expires_epoch);

    my $db = PGObject::Simple->new(
        dbh => $dbh,
    );

    $db->call_procedure(
        funcname => 'mtd__store_user_token',
        args => [
            $auth->access_token,
            $auth->refresh_token,
            $expiry->strftime('%Y-%m-%dT%H:%M:%SZ'),
        ],
    );

    return;
}


# _delete_token($dbh, $mtd_token_id)
#
# Deletes the mtd_token with the specified id from the database. Only
# tokens belonging to the current user may be deleted.

sub _delete_token {

    my $dbh = shift;
    my $token_id = shift;

    my $db = PGObject::Simple->new(
        dbh => $dbh,
    );

    $db->call_procedure(
        funcname => 'mtd__delete_user_token',
        args => [$token_id],
    );
}


=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018 The LedgerSMB Core Team

This file is licensed under the GNU General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut


1;
