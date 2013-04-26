package Finance::Bank::Bankwest::Session;
# ABSTRACT: operate on an established Bankwest Online Banking session

=for stopwords
BSB instantiation logout mech

=head1 SYNOPSIS

    # prepare a WWW::Mechanize instance with the right cookies first
    # (Finance::Bank::Bankwest->login does this for you)
    my $mech = ...;

    my $session = Finance::Bank::Bankwest::Session->new($mech);
    for my $acct ($session->accounts) {
        printf(
            "Account %s has available balance %s\n",
            $acct->number,
            $acct->available_balance,
        );
        my @txns = $session->transactions(
            account     => $acct->number,
            from_date   => '31/12/2012',
        );
        for my $txn (@txns) {
            printf(
                "> Transaction: %s (%s)\n",
                $txn->narrative,
                $txn->amount,
            );
        }
    }
    $session->logout;

=head1 DESCRIPTION

This module provides the logic for operating on a Bankwest Online
Banking session once that session has been established.

Directly creating a usable instance of this module requires a
L<WWW::Mechanize> instance with the correct cookies.  Obtain a properly
established session using L<Finance::Bank::Bankwest/login>.

=head1 SEE ALSO

L<Finance::Bank::Bankwest/login>
L<Finance::Bank::Bankwest::Account>
L<Finance::Bank::Bankwest::Transaction>

=cut

## no critic (RequireUseStrict, RequireUseWarnings, RequireEndWithOne)
use MooseX::Declare;
class Finance::Bank::Bankwest::Session {

    use Finance::Bank::Bankwest::Parsers ();
    use MooseX::StrictConstructor;
    use MooseX::Types; # for "class_type"
    use TryCatch; # for "try" and "catch"
    use URI ();

    # Allow instantiation via ->new($mech).
    class_type 'WWW::Mechanize';
    with 'MooseX::OneArgNew' => {
        type        => 'WWW::Mechanize',
        init_arg    => 'mech',
    };

=attr accounts_uri

The location of the page holding a list of accounts and their balances.
Use the default value during normal operation.

=attr transactions_uri

The location of the resource that provides transaction information.
Use the default value during normal operation.

=attr logout_uri

The location of the resource that closes the Bankwest Online Banking
session on the remote server.  Use the default value during normal
operation.

=cut

    for (
        [ accounts      => 'AccountInformation/AI/Balances'             ],
        [ transactions  => 'AccountInformation/TS/TransactionSearch'    ],
        [ logout        => 'Logout'                                     ],
    ) {
        my ($attr, $uri_fragment) = @$_;
        my $uri = sprintf(
            'https://ibs.bankwest.com.au/CMWeb/%s.aspx',
            $uri_fragment,
        );
        has "${attr}_uri" => (
            is          => 'ro',
            isa         => 'URI',
            required    => 1,
            lazy        => 1,
            default     => sub { URI->new($uri) },
        );
    }

=attr mech

The L<WWW::Mechanize> instance used to communicate with the Bankwest
Online Banking server.  Needs to be pre-populated with the correct
cookies.  Required; use L<Finance::Bank::Bankwest/login> to obtain a
session object with the right one of these.

=cut

    has 'mech' => (
        is          => 'ro',
        isa         => 'WWW::Mechanize',
        required    => 1,
    );

=method accounts

    @accts = $session->accounts;

Returns a list of L<Finance::Bank::Bankwest::Account> objects, each
representing the details of an account.  The list is ordered according
to user-defined settings within the Bankwest Online Banking web
interface.

See L<Finance::Bank::Bankwest::Account> for further details on what
information is returned per account.

=cut

    method accounts {
        return Finance::Bank::Bankwest::Parsers->parse(
            $self->mech->get($self->accounts_uri),
            qw{ Accounts Login },
        );
    }

=method transactions
L<Finance::Bank::Bankwest::Error::ExportFailed>
    @txns = $session->transactions(
        account     => '303-111 0012345',   # required
        from_date   => '31/01/2013',        # required
        to_date     => '28/02/2013',        # optional
    );

Returns a list of L<Finance::Bank::Bankwest::Transaction> objects, each
representing a single transaction.  On failure, throws a
L<Finance::Bank::Bankwest::Error::ExportFailed> exception.

The following arguments are accepted:

=begin :list

= C<account>

    account => '303-111 0012345'

The BSB and account numbers of a single account to which all returned
transaction details belong.  Must be in C<BBB-BBB AAAAAAA> format where
C<B> refers to a BSB digit and C<A> refers to an account digit.

= C<from_date>

    from_date => '31/12/2012'

A string in C<DD/MM/YYYY> format representing the earliest date allowed
in returned transactions (time is ignored).  Cannot be a future date,
and cannot be a date earlier than 1 January of the year before the
last.

= C<to_date>

    to_date => undef            # default
    to_date => '31/12/2013'

A string in C<DD/MM/YYYY> format representing the latest date allowed
in returned transactions.  Cannot be before the C<from_date>, and
cannot be a date later than 31 December of next year.

Defaults to C<undef>, causing all transactions with a date on or later
than the C<from_date> to be returned.

Transactions with a posted date occurring later than this date are not
returned, even if those transactions actually occurred before or on
this date.  For example, setting both C<from_date> and C<to_date> to
a Saturday will probably result in nothing being returned because all
transactions actually occurring on that day will probably have a posted
date of the following Monday.

=end :list

=cut

    method transactions(
        Str :$account,
        Str :$from_date,
        Maybe[Str] :$to_date?
    ) {
        # Several hidden form fields (__EVENTTARGET, __EVENTVALIDATION,
        # __VIEWSTATE, __VS) need to be submitted with the request, so
        # GET the page first.
        try {
            Finance::Bank::Bankwest::Parsers->test(
                $self->mech->get($self->transactions_uri),
                qw{ TransactionSearch Login },
            );
        }
        catch (
            Finance::Bank::Bankwest::Error::ExportFailed::UnknownReason $e
        ) {
            # This is expected, so ignore the exception.
        }

        $self->mech->submit_form(
            form_id => 'aspnetForm',
            fields => {
                '__EVENTTARGET'
                    => '_ctl0:ContentButtonsLeft:btnExport',
                '_ctl0:ContentButtonsLeft:txtSelectedList'
                    => '3~4~5~6~7',
                '_ctl0:ContentMain:ddlAccount'
                    => $account,
                '_ctl0:ContentMain:dpFromDate:txtDate'
                    => $from_date,
                '_ctl0:ContentMain:dpToDate:txtDate'
                    => (defined $to_date ? $to_date : ''),
            },
        );

        # Assume that a CSV file has been returned.  Problems with the
        # supplied parameters would cause the form to be presented
        # again.  If nothing else, maybe a session problem?
        return Finance::Bank::Bankwest::Parsers->parse(
            $self->mech->res,
            qw{ TransactionExport TransactionSearch Login },
        );
    }

=method logout

    $session->logout;

Close down the Bankwest Online Banking session.  The session will no
longer be usable.

This method should be called when the session is no longer needed so
that Bankwest's server can release resources used by the session.

=cut

    method logout {
        Finance::Bank::Bankwest::Parsers->test(
            $self->mech->get($self->logout_uri),
            qw{ Logout Login },
        );
    }
}
