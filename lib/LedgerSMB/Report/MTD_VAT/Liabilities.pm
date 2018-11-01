package LedgerSMB::Report::MTD_VAT::Liabilities;

=head1 NAME

LedgerSMB::Report::MTD_VAT::Liabiltiies - Display UK HMRC VAT Liabilities

=head1 SYNPOSIS

  my $report = LedgerSMB::Report::MTD_VAT::Liabilities->new(
      vrn => $numeric_vat_registration,
      date_from => 'YYYY-MM-DD',
      date_to => 'YYYY-MM-DD',
  );
  $report->render($request);

=head1 DESCRIPTION

This modules queries the UK HMRC Making Tax Digital api to retrieve and
display VAT liabilities - amounts that HMRC consider are due.

=head1 INHERITS

=over

=item L<LedgerSMB::Report>

=back

=cut

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
    isa => 'Str',
    where => { $_ =~ m/^\d{4}-\d{2}-\d{2}$/ },
    required => 1,
);

=head2 date_to

Query liabilities up to this date, specified as 'YYYY-MM-DD'. Required
attribute.

=cut

has 'date_to' => (
    is => 'ro',
    isa => 'Str',
    where => { $_ =~ m/^\d{4}-\d{2}-\d{2}$/ },
    required => 1,
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

    * SINGLE_LIABILITY
    * MULTIPLE_LIABILITIES

See the L<HMRC API documentation|https://developer.service.hmrc.gov.uk/api-documentation/docs/api/service/vat-api/1.0#_retrieve-vat-liabilities_get_accordion>
for more information.

=cut

has test_mode => (
    is => 'ro',
    isa => 'Maybe[Str]',
    where => { $_ =~ m/^(SINGLE_LIABILITY|MULTIPLE_LIABILITIES)$/ },
    default => undef,
);

=head1 METHODS

=head2 name

Returns the localized template name.

=cut

sub name {
    my ($self) = @_;
    return $self->_locale->text('HMRC VAT Liabilities');
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
            col_id => 'type',
            name => $self->_locale->text('Type'),
            type => 'text',
        },
        {
            col_id => 'tax_period_from',
            name => $self->_locale->text('Tax Period From'),
            type => 'text',
        },
        {
            col_id => 'tax_period_to',
            name => $self->_locale->text('Tax Period To'),
            type => 'text',
        },
        {
            col_id => 'originalAmount',
            name => $self->_locale->text('Original Amount'),
            type => 'text',
        },
        {
            col_id => 'outstandingAmount',
            name => $self->_locale->text('Outstanding Amount'),
            type => 'text',
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

    my $result = $vat->liabilities({
        from => $self->date_from,
        to => $self->date_to,
        test_mode => $self->test_mode,
    });
    $result->is_success or die 'ERROR: ', $result->data->{message};
    $self->rows($result->data->{liabilities});

    # Flatten and polish data rows for presentation
    foreach my $row (@{$self->rows}) {

        # Each liability typically covers a specific tax period, but
        # this information is 'optional'.
        if (exists $row->{taxPeriod}) {
            $row->{tax_period_from} = $row->{taxPeriod}->{from};
            $row->{tax_period_to} = $row->{taxPeriod}->{to};
            delete $row->{taxPeriod};
        }
        else {
            $row->{tax_period_from} = '';
            $row->{tax_period_to} = '';
        }

        # `outstandingAmount` and `due` are only provided by the api if 
        # there is a balance due. If not, we want to display zero.
        $row->{outstandingAmount} //= 0;
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
