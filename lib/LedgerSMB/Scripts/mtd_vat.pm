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
use LedgerSMB::Report::MTD_VAT::Liabilities;
use LedgerSMB::Report::MTD_VAT::Obligations;
use LedgerSMB::Report::MTD_VAT::Payments;
use LedgerSMB::Sysconfig;
use LedgerSMB::Template::UI;
use Time::Piece;
use Time::Seconds;
use WebService::HMRC::VAT;
use WebService::HMRC::Authenticate 0.02;


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

    return authorisation_status($request);
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

    return authorisation_status($request);
}


=head2 renew_access_token

Requests an updated access token from HMRC to replace the specified existing
token. Updates the database, then displays the authorisation status screen.

The request must contain the following parameters:

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

    return authorisation_status($request);
}


=head2 filter_liabilties

Presents filter screen allowing user to specify a date range before querying
VAT liabilities.

No request parameters are required.

=cut

sub filter_liabilities {

    my $request = shift;
    my $template = LedgerSMB::Template::UI->new_UI;

    my $defaults = {
        date_from => gmtime->add_years(-1)->ymd,
        date_to   => ((gmtime) - ONE_DAY)->ymd,
    };

    return $template->render(
        $request,
        'Reports/filters/mtd_vat/liabilities',
        {defaults => $defaults},
    );
}


=head2 query_liabilities

Queries the HMRC MTD VAT api for liabilities - money HMRC think is due in
respect of VAT.

The request must contain the following parameters:

  * date_from
  * date_to
  * dbh

The C<date_from> parameter must be before today's date.

The request may optionally contain a C<test_mode> parameter. This is only
valid when used against the HMRC sandbox API and, if present, must be set to
one of the values specified in the
L<HMRC API documentation|https://developer.service.hmrc.gov.uk/api-documentation/docs/api/service/vat-api/1.0#_retrieve-vat-liabilities_get_accordion>.

=cut

sub query_liabilities {

    my $request = shift;
    my $token = _get_user_token($request->{dbh});

    my $report = LedgerSMB::Report::MTD_VAT::Liabilities->new(
        vrn => $request->setting->get('company_sales_tax_id'),
        date_from => $request->{date_from},
        date_to => $request->{date_to},
        access_token => $token->{access_token},
        test_mode => $request->{test_mode},
    );

    return $report->render($request);
}


=head2 filter_payments

Presents filter screen allowing user to specify a date range before querying
VAT payments.

No request parameters are required.

=cut

sub filter_payments {

    my $request = shift;
    my $template = LedgerSMB::Template::UI->new_UI;

    my $defaults = {
        date_from => gmtime->add_years(-1)->ymd,
        date_to   => ((gmtime) - ONE_DAY)->ymd,
    };

    return $template->render(
        $request,
        'Reports/filters/mtd_vat/payments',
        {defaults => $defaults},
    );
}


=head2 query_payments

Queries the HMRC MTD VAT api for payments - money that HMRC has received.

The request must contain the following parameters:

  * date_from
  * date_to
  * dbh

The C<date_from> parameter must be before today's date.

The request may optionally contain a C<test_mode> parameter. This is only
valid when used against the HMRC sandbox API and, if present, must be set to
one of the values specified in the
L<HMRC API documentation|https://developer.service.hmrc.gov.uk/api-documentation/docs/api/service/vat-api/1.0#_retrieve-vat-payments_get_accordion>.

=cut

sub query_payments {

    my $request = shift;
    my $token = _get_user_token($request->{dbh});

    my $report = LedgerSMB::Report::MTD_VAT::Payments->new(
        vrn => $request->setting->get('company_sales_tax_id'),
        date_from => $request->{date_from},
        date_to => $request->{date_to},
        access_token => $token->{access_token},
        test_mode => $request->{test_mode},
    );

    return $report->render($request);
}


=head2 filter_obligations

Presents filter screen allowing user to specify a date range and fulfilment
status before querying VAT filing obligations.

No request parameters are required.

=cut

sub filter_obligations {

    my $request = shift;
    my $template = LedgerSMB::Template::UI->new_UI;

    my $defaults = {
        date_from => gmtime->add_years(-1)->ymd,
        date_to   => ((gmtime) - ONE_DAY)->ymd,
    };

    return $template->render(
        $request,
        'Reports/filters/mtd_vat/obligations',
        {defaults => $defaults},
    );
}


=head2 query_obligations

Queries the HMRC MTD VAT api for obligations - VAT returns that are, or
were, due for filing.

The request must contain the following parameters:

  * date_from
  * date_to
  * dbh

The C<date_from> parameter must be before today's date.

The request may optionally contain:

  * filing_status

The C<filing_status> parameter, if specified, must be C<O> or C<F>, indicating
I<open> or I<fulfilled> respectively.

The C<test_mode> parameter is only valid when used against the HMRC sandbox
API and, if present, must be set to one of the values specified in the
L<HMRC API documentation|https://developer.service.hmrc.gov.uk/api-documentation/docs/api/service/vat-api/1.0#_retrieve-vat-payments_get_accordion>.

=cut

sub query_obligations {

    my $request = shift;
    my $token = _get_user_token($request->{dbh});

    my $report = LedgerSMB::Report::MTD_VAT::Obligations->new(
        vrn => $request->setting->get('company_sales_tax_id'),
        date_from => $request->{date_from},
        date_to => $request->{date_to},
        filing_status => $request->{filing_status},
        access_token => $token->{access_token},
        test_mode => $request->{test_mode},
    );

    return $report->render($request);
}


=head2 view_return

Retrieves the specified VAT return from HMRC and displays it.

The request must contain the following parameters:

  * periodKey
  * dbh

Optionally, the request may contain the following parameters which will
be used to populate report headers `Tax Period From` and `Tax Period To`,
but otherwise serve no purpose:

  * from
  * to

=cut

sub view_return {

    my $request = shift;
    my $token = _get_user_token($request->{dbh});
    my $template = LedgerSMB::Template::UI->new_UI;
    my $vrn = $request->setting->get('company_sales_tax_id');

    my $auth = WebService::HMRC::Authenticate->new({
        access_token => $token->{access_token},
    });

    my $vat = WebService::HMRC::VAT->new({
        vrn => _numeric_vrn($vrn),
        auth => $auth,
    });

    my $result = $vat->get_return({
        period_key => $request->{period_key},
    });

    $result->is_success or die 'ERROR: ', $result->data->{message};

    my $vat_data = $result->{data};
    $vat_data->{start} = $request->{start};
    $vat_data->{end} = $request->{end};

    return $template->render(
        $request,
        'mtd_vat/vat_return',
        {
            vat_data => $vat_data,
            vrn => $vrn,
            company => $request->{company},
            is_fulfilled => 1,
        },
    );
}


=head2 file_return

Extracts VAT figures for the specified period and presents them to the user
for approval and submission.

  * dbh
  * periodKey
  * start (YYYY-MM-DD)
  * end (YYYY-MM-DD)

=cut

sub file_return {

    my $request = shift;
    my $template = LedgerSMB::Template::UI->new_UI;
    my $vrn = $request->setting->get('company_sales_tax_id');

    my $vat_data = _extract_vat_data_from_books();
    $vat_data->{periodKey} = $request->{period_key};
    $vat_data->{start} = $request->{start};
    $vat_data->{end} = $request->{end};

    return $template->render(
        $request,
        'mtd_vat/vat_return',
        {
            vat_data => $vat_data,
            vrn => $vrn,
            company => $request->{company},
        },
    );
}


=head2 submit_return

Accepts vat return figures from the confirmation form, submits them to HMRC,
then displays a status page.

The request must contain the following parameters:

  * dbh
  * periodKey
  * vatDueSales
  * vatDueAcquisitions
  * totalVatDue
  * vatReclaimedCurrPeriod
  * netVatDue
  * totalValueSalesExVAT
  * totalValuePurchasesExVAT
  * totalValueGoodsSuppliedExVAT
  * totalAcquisitionsExVAT
  * finalised (user declaration, must be true)

=cut

sub submit_return {

    my $request = shift;
    my $vat_data = _extract_vat_data_from_request($request);
    my $token = _get_user_token($request->{dbh});
    my $template = LedgerSMB::Template::UI->new_UI;
    my $vrn = $request->setting->get('company_sales_tax_id');

    my $auth = WebService::HMRC::Authenticate->new({
        access_token => $token->{access_token},
    });

    my $vat = WebService::HMRC::VAT->new({
        vrn => _numeric_vrn($vrn),
        auth => $auth,
    });

    my $result = $vat->submit_return($vat_data);
    $result->is_success or die 'ERROR: ', $result->data->{message};

    my $submission = $result->{data};
    $submission->{receiptId} = $result->header('Receipt-ID');
    $submission->{receiptTimestamp} = $result->header('Receipt-Timestamp');
    $submission->{correlationId} = $result->header('X-CorrelationId');

    return $template->render(
        $request,
        'mtd_vat/submission_result',
        {
            submission => $submission,
            vrn => $vrn,
            company => $request->{company},
        },
    );
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


# _numeric_vrn($vrn)
#
# strips non-digit characters from the supplied input string and returns the
# result. Dies if the result does not comprise 9 digits, which is expected for
# a UK VAT Registrstion Number.

sub _numeric_vrn {

    my $vrn = shift;

    # Strip non-digit components, such as country code or formatting spaces
    $vrn =~ s/\D//g;

    # Remainder should be 9 digits for a UK VAT number
    $vrn =~ m/^\d{9}$/ or die 'VAT Registration number is invalid - '.
                              'a UK VAT number should contain 9 digits';

    return $vrn;
}


# _extract_vat_data_from_books
#
# Dummy stub function returning VAT data to be submitted. Will be replaced by
# code to extract real numbers from the books.

sub _extract_vat_data_from_books {

    return {
        vatDueSales => "100.00",
        vatDueAcquisitions => 0.00,
        totalVatDue => 100.00,
        vatReclaimedCurrPeriod => 50.00,
        netVatDue => 50,
        totalValueSalesExVAT => 500,
        totalValuePurchasesExVAT => 250,
        totalValueGoodsSuppliedExVAT => 0,
        totalAcquisitionsExVAT => 0,
    };
};


# _extract_vat_data_from_request
#
# Returns VAT data to be submitted from the supplied request object.
# Validates that `finalised` flag is true and that numeric fields
# look like plain numbers (no thousands separator). Dies if validation
# fails.

sub _extract_vat_data_from_request {

    my $request = shift;
    my $vat_data = {};

    foreach my $field (qw(
        periodKey
        vatDueSales
        vatDueAcquisitions
        totalVatDue
        vatReclaimedCurrPeriod
        netVatDue
        totalValueSalesExVAT
        totalValuePurchasesExVAT
        totalValueGoodsSuppliedExVAT
        totalAcquisitionsExVAT
        finalised
    )) {
        $vat_data->{$field} = $request->{$field};

        # Validation for different field types
        if($field eq 'finalised') {
            $vat_data->{finalised}
                or die 'finalised flag is not set true';
        }
        elsif($field eq 'periodKey') {
            $vat_data->{periodKey} =~ m/^[\w#]{4}$/
                or die 'periodKey is invalid';
        }
        else {
            $vat_data->{$field} =~ m/^-?\d*\.?\d{0,2}$/
                or die "$field is not a valid number";
        }
    }

    return $vat_data;
};


=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018 The LedgerSMB Core Team

This file is licensed under the GNU General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut


1;
