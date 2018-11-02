package LedgerSMB::Report::MTD_VAT::Obligations;

=head1 NAME

LedgerSMB::Report::MTD_VAT::Obligations - Display HMRC VAT Filing Obligations

=head1 SYNPOSIS

  my $report = LedgerSMB::Report::MTD_VAT::Obligations->new(
      vrn => $numeric_vat_registration,
      date_from => 'YYYY-MM-DD',
      date_to => 'YYYY-MM-DD',
      filing_status => 'O',
  );
  $report->render($request);

=head1 DESCRIPTION

This modules queries the UK HMRC Making Tax Digital api to retrieve and
display VAT return filing obligations.

=head1 INHERITS

=over

=item L<LedgerSMB::Report>

=back

=cut

use LedgerSMB::MooseTypes;
use Moose;
use namespace::autoclean;
use WebService::HMRC::Authenticate;
use WebService::HMRC::VAT;
extends 'LedgerSMB::Report';


=head1 PROPERTIES

=head2 vrn

VAT Registration number being queried. Required attribute. Read-only.

May include country code and formatting spaces for display purposes.
Non-numeric content will be stripped before submission to HMRC. The
unmodified value will be displayed in the report heading.

=cut

has 'vrn' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

=head2 date_from

Query liabilities from this date, specified as 'YYYY-MM-DD'. Required
attribute.

=cut

has 'date_from' => (
    is => 'ro',
    isa => 'LedgerSMB::Moose::ISO_date',
    required => 1,
);

=head2 date_to

Query liabilities up to this date, specified as 'YYYY-MM-DD'. Required
attribute.

=cut

has 'date_to' => (
    is => 'ro',
    isa => 'LedgerSMB::Moose::ISO_date',
    required => 1,
);

=head2 filing_status

Optional parameter. Filters results according to their filing status. May
be either C<O> for "Open" returns still to be filed, or C<F> for "Fulfilled"
returns which have been filed.

=cut

has 'filing_status' => (
    is => 'ro',
    isa => 'Maybe[LedgerSMB::Moose::MTD_VAT_filing_status]',
    required => 0,
    default => undef,
);

=head2 access_token

Access token for authentication with the HMRC Making Tax Digital api.
Must be enabled for the scopes C<read:vat> and (for submitting returns)
C<write:vat>.

=cut

has access_token => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

=head2 test_mode

Parameter used only for testing with HMRC sandbox API. In conjuction with
special date ranges, this will retrieve test data. Cannot be used with
production endpoints. If set, must be one of the following values:

    * QUARTERLY_NONE_MET
    * QUARTERLY_ONE_MET
    * QUARTERLY_TWO_MET
    * QUARTERLY_THREE_MET
    * QUARTERLY_FOUR_MET
    * MONTHLY_NONE_MET
    * MONTHLY_ONE_MET
    * MONTHLY_TWO_MET
    * MONTHLY_THREE_MET
    * NOT_FOUND

See the L<HMRC API documentation|https://developer.service.hmrc.gov.uk/api-documentation/docs/api/service/vat-api/1.0#_retrieve-vat-obligations_get_accordion>
for more information.

=cut

has test_mode => (
    is => 'ro',
    isa => 'Maybe[LedgerSMB::Moose::MTD_VAT_obligation_test_mode]',
    default => undef,
);

=head1 METHODS

=head2 name

Returns the localized template name.

=cut

sub name {
    my ($self) = @_;
    return $self->_locale->text('HMRC VAT Return Obligations');
}


=head2 header_lines

Returns the heading lines to display on the report, in addition to the
default 'Report Name' and 'Company Name'.

=cut

sub header_lines {
    my $self = shift;
    return [
        {
            name => 'vrn',
            text => $self->_locale->text('VAT Number'),
        },
        {
            name => 'date_from',
            text => $self->_locale->text('Date From'),
        },
        {
            name => 'date_to',
            text => $self->_locale->text('Date To'),
        },
        {
            name => 'filing_status',
            text => $self->_locale->text('Filing Status'),
        },
    ];
}


=head2 columns()

Read-only accessor, returns a list of columns.

=cut

sub columns {
    my $self = shift;
    return [
        {
            col_id => 'due',
            name => $self->_locale->text('Due Date'),
            type => 'text',
        },
        {
            col_id => 'periodKey',
            name => $self->_locale->text('HMRC Period ID'),
            type => 'text',
        },
        {
            col_id => 'start',
            name => $self->_locale->text('Tax Period From'),
            type => 'text',
        },
        {
            col_id => 'end',
            name => $self->_locale->text('Tax Period To'),
            type => 'text',
        },
        {
            col_id => 'is_fulfilled',
            name => $self->_locale->text('Filed'),
            type => 'boolean_checkmark',
        },
        {
            col_id => 'received',
            name => $self->_locale->text('Received Date'),
            type => 'text',
        },
        {
            col_id => 'action',
            name => '',
            type => 'href',
        },
    ];
}


=head2 run_report()

Calls C<get_rows> method to query database for batches
matching our filter properties, then populate C<rows> and C<buttons>
properties.

=cut

sub run_report{
    my $self = shift;

    my $auth = WebService::HMRC::Authenticate->new({
        access_token => $self->access_token,
    });

    my $vat = WebService::HMRC::VAT->new({
        vrn => $self->numeric_vrn,
        auth => $auth,
    });

    my $result = $vat->obligations({
        from => $self->date_from,
        to => $self->date_to,
        status => $self->filing_status,
        test_mode => $self->test_mode,
    });
    $result->is_success or die 'ERROR: ', $result->data->{message};
    $self->rows($result->data->{obligations});

    # Polish data rows for presentation
    foreach my $row (@{$self->rows}) {

        # Create boolean for fulfilled (filed) status
        $row->{is_fulfilled} = ($row->{status} eq 'F');

        # `received` is only present in result if a return is fulfilled
        $row->{received} //= '';

        if($row->{is_fulfilled}) {
            $row->{action} = 'view';
        }
        else {
            $row->{action} = 'file';
        }
    }

    return;
}


=head2 numeric_vrn()

Accessor method returning the value of the vrn property, after stripping any
non-numeric characters (such as country code or formatting spaces).

Dies if the resulting string does not contain 9 digits, as expected for a UK
VAT registration number. It's considered better to trap this now, rather
than receive a cryptic failure message from the HMRC api.

=cut

sub numeric_vrn {

    my $self = shift;
    my $vrn = $self->vrn;

    # Strip non-digit components, such as country code or formatting spaces
    $vrn =~ s/\D//g;

    # Remainder should be 9 digits for a UK VAT number
    $vrn =~ m/^\d{9}$/ or die 'VAT Registration number is invalid - '.
                              'a UK VAT number should contain 9 digits';

    return $vrn;
}


=head1 LICENSE AND COPYRIGHT

Copyright (C) 2018 The LedgerSMB Core Team

This file is licensed under the GNU General Public License version 2, or at your
option any later version.  A copy of the license should have been included with
your software.

=cut

__PACKAGE__->meta->make_immutable;

1;
