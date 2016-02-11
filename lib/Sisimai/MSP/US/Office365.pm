package Sisimai::MSP::US::Office365;
use parent 'Sisimai::MSP';
use feature ':5.10';
use strict;
use warnings;

my $Re0 = {
    'subject'  => qr/Undeliverable:/,
    'received' => qr/.+[.](?:outbound[.]protection|prod)[.]outlook[.]com\b/,
};
my $Re1 = {
    'begin'  => qr{\A(?:
         Delivery[ ]has[ ]failed[ ]to[ ]these[ ]recipients[ ]or[ ]groups:
        |.+[ ]rejected[ ]your[ ]message[ ]to[ ]the[ ]following[ ]e[-]?mail[ ]addresses:
        )
    }x,
    'error'  => qr/\ADiagnostic information for administrators:\z/,
    'eoerr'  => qr/\AOriginal message headers:\z/,
    'rfc822' => qr|\AContent-Type: message/rfc822\z|,
    'endof'  => qr/\A__END_OF_EMAIL_MESSAGE__\z/,
};
my $CodeTable = {
    '4.4.7'     => 'expired',
    '5.1.0'     => 'rejected',
    '5.1.1'     => 'userunknown',
    '5.1.10'    => 'filtered',
    '5.4.1'     => 'networkerror',
    '5.4.14'    => 'networkerror',
    '5.7.1'     => 'rejected',
    '5.7.133'   => 'rejected',
};

my $Indicators = __PACKAGE__->INDICATORS;
my $LongFields = Sisimai::RFC5322->LONGFIELDS;
my $RFC822Head = Sisimai::RFC5322->HEADERFIELDS;

sub description { 'Microsoft Office 365: http://office.microsoft.com/' }
sub smtpagent   { 'US::Office365' }
sub headerlist  { 
    # X-MS-Exchange-Message-Is-Ndr:
    # X-Microsoft-Antispam-PRVS: <....@...outlook.com>
    # X-Exchange-Antispam-Report-Test: UriScan:;
    # X-Exchange-Antispam-Report-CFA-Test:
    # X-MS-Exchange-CrossTenant-OriginalArrivalTime: 29 Apr 2015 23:34:45.6789 (JST)
    # X-MS-Exchange-CrossTenant-FromEntityHeader: Hosted
    # X-MS-Exchange-Transport-CrossTenantHeadersStamped: ...
    return [ 
        'X-MS-Exchange-Message-Is-Ndr',
        'X-Microsoft-Antispam-PRVS',
        'X-Exchange-Antispam-Report-Test',
        'X-Exchange-Antispam-Report-CFA-Test',
        'X-MS-Exchange-CrossTenant-OriginalArrivalTime',
        'X-MS-Exchange-CrossTenant-FromEntityHeader',
        'X-MS-Exchange-Transport-CrossTenantHeadersStamped',
    ]
}
sub pattern     { return $Re0 }

sub scan {
    # Detect an error from Microsoft Office 365
    # @param         [Hash] mhead       Message header of a bounce email
    # @options mhead [String] from      From header
    # @options mhead [String] date      Date header
    # @options mhead [String] subject   Subject header
    # @options mhead [Array]  received  Received headers
    # @options mhead [String] others    Other required headers
    # @param         [String] mbody     Message body of a bounce email
    # @return        [Hash, Undef]      Bounce data list and message/rfc822 part
    #                                   or Undef if it failed to parse or the
    #                                   arguments are missing
    # @since v4.1.3
    my $class = shift;
    my $mhead = shift // return undef;
    my $mbody = shift // return undef;
    my $match = 0;

    $match++ if $mhead->{'subject'} =~ $Re0->{'subject'};
    $match++ if $mhead->{'x-ms-exchange-message-is-ndr'};
    $match++ if $mhead->{'x-microsoft-antispam-prvs'};
    $match++ if $mhead->{'x-exchange-antispam-report-test'};
    $match++ if $mhead->{'x-exchange-antispam-report-cfa-test'};
    $match++ if $mhead->{'x-ms-exchange-crosstenant-originalarrivaltime'};
    $match++ if $mhead->{'x-ms-exchange-crosstenant-fromentityheader'};
    $match++ if $mhead->{'x-ms-exchange-transport-crosstenantheadersstamped'};
    $match++ if grep { $_ =~ $Re0->{'received'} } @{ $mhead->{'received'} };
    return undef if $match < 2;

    if( $$mbody =~ /^Content-Transfer-Encoding: quoted-printable$/m ) {
        # --0000ffff-eeee-2222-a0000dddd000
        # Content-Type: multipart/alternative; differences=Content-Type;
        #     boundary="ff002222-2222-2222-bbcd-0123456789ab"
        #
        # --ff002222-2222-2222-bbcd-0123456789ab
        # Content-Type: text/plain; charset="Windows-1252"
        # Content-Transfer-Encoding: quoted-printable
        require Sisimai::MIME;
        $$mbody = Sisimai::MIME->qprintd( $mbody );
    }

    my $dscontents = []; push @$dscontents, __PACKAGE__->DELIVERYSTATUS;
    my @hasdivided = split( "\n", $$mbody );
    my $rfc822next = { 'from' => 0, 'to' => 0, 'subject' => 0 };
    my $rfc822part = '';    # (String) message/rfc822-headers part
    my $previousfn = '';    # (String) Previous field name
    my $readcursor = 0;     # (Integer) Points the current cursor position
    my $recipients = 0;     # (Integer) The number of 'Final-Recipient' header
    my $connheader = {};
    my $endoferror = 0;     # (Integer) Flag for the end of error messages
    my $htmlbegins = 0;     # (Integer) Flag for HTML part
    my $v = undef;

    for my $e ( @hasdivided ) {
        # Read each line between $Re1->{'begin'} and $Re1->{'rfc822'}.
        unless( $readcursor ) {
            # Beginning of the bounce message or delivery status part
            if( $e =~ $Re1->{'begin'} ) {
                $readcursor |= $Indicators->{'deliverystatus'};
                next;
            }
        }

        unless( $readcursor & $Indicators->{'message-rfc822'} ) {
            # Beginning of the original message part
            if( $e =~ $Re1->{'rfc822'} ) {
                $readcursor |= $Indicators->{'message-rfc822'};
                next;
            }
        }

        if( $readcursor & $Indicators->{'message-rfc822'} ) {
            # After "message/rfc822"
            if( $e =~ m/\A([-0-9A-Za-z]+?)[:][ ]*.+\z/ ) {
                # Get required headers only
                my $lhs = lc $1;
                $previousfn = '';
                next unless exists $RFC822Head->{ $lhs };

                $previousfn  = $lhs;
                $rfc822part .= $e."\n";

            } elsif( $e =~ m/\A[ \t]+/ ) {
                # Continued line from the previous line
                next if $rfc822next->{ $previousfn };
                $rfc822part .= $e."\n" if exists $LongFields->{ $previousfn };

            } else {
                # Check the end of headers in rfc822 part
                next unless exists $LongFields->{ $previousfn };
                next if length $e;
                $rfc822next->{ $previousfn } = 1;
            }
        } else {
            # Before "message/rfc822"
            next unless $readcursor & $Indicators->{'deliverystatus'};
            next unless length $e;

            # kijitora@example.com<mailto:kijitora@example.com>
            # The email address wasn=92t found at the destination domain. It might be mis=
            # spelled or it might not exist any longer. Try retyping the address and rese=
            # nding the message.
            $v = $dscontents->[ -1 ];

            if( $e =~ m/\A.+[@].+[<]mailto:(.+[@].+)[>]\z/ ) {
                # kijitora@example.com<mailto:kijitora@example.com>
                if( length $v->{'recipient'} ) {
                    # There are multiple recipient addresses in the message body.
                    push @$dscontents, __PACKAGE__->DELIVERYSTATUS;
                    $v = $dscontents->[ -1 ];
                }
                $v->{'recipient'} = $1;
                $recipients++;

            } elsif( $e =~ m/\AGenerating server: (.+)\z/ ) {
                # Generating server: FFFFFFFFFFFF.e0.prod.outlook.com
                $connheader->{'lhost'} = lc $1;

            } else {
                if( $endoferror ) {
                    # After "Original message headers:"
                    if( $htmlbegins ) {
                        # <html> .. </html>
                        $htmlbegins = 0 if $e =~ m|\A[<]/html[>]|;
                        next;
                    }

                    if( $e =~ m/\A[Aa]ction:[ ]*(.+)\z/ ) {
                        # Action: failed
                        $v->{'action'} = lc $1;

                    } elsif( $e =~ m/\A[Ss]tatus:[ ]*(\d[.]\d+[.]\d+)/ ) {
                        # Status:5.2.0
                        $v->{'status'} = $1;

                    } elsif( $e =~ m/\A[Rr]eporting-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/ ) {
                        # Reporting-MTA: dns;BLU004-OMC3S13.hotmail.example.com
                        $connheader->{'lhost'} = lc $1;

                    } elsif( $e =~ m/\A[Rr]eceived-[Ff]rom-MTA:[ ]*(?:DNS|dns);[ ]*(.+)\z/ ) {
                        # Reporting-MTA: dns;BLU004-OMC3S13.hotmail.example.com
                        $connheader->{'rhost'} = lc $1;

                    } elsif( $e =~ m/\A[Aa]rrival-[Dd]ate:[ ]*(.+)\z/ ) {
                        # Arrival-Date: Wed, 29 Apr 2009 16:03:18 +0900
                        next if length $connheader->{'date'};
                        $connheader->{'date'} = $1;

                    } else {
                        $htmlbegins = 1 if $e =~ m/\A[<]html[>]/;
                    }

                } else {
                    if( $e =~ $Re1->{'error'} ) {
                        # Diagnostic information for administrators:
                        $v->{'diagnosis'} = $e;

                    } else {
                        # kijitora@example.com
                        # Remote Server returned '550 5.1.10 RESOLVER.ADR.RecipientNotFound; Recipien=
                        # t not found by SMTP address lookup'
                        next unless $v->{'diagnosis'};
                        if( $e =~ $Re1->{'eoerr'} ) {
                            # Original message headers:
                            $endoferror = 1;
                            next;
                        }
                        $v->{'diagnosis'}  .= ' '.$e;
                    }
                }
            }
        } # End of if: rfc822
    }
    return undef unless $recipients;
    require Sisimai::String;
    require Sisimai::SMTP::Status;

    for my $e ( @$dscontents ) {
        # Set default values if each value is empty.
        map { $e->{ $_ } ||= $connheader->{ $_ } || '' } keys %$connheader;

        if( scalar @{ $mhead->{'received'} } ) {
            # Get localhost and remote host name from Received header.
            my $r0 = $mhead->{'received'};
            $e->{'lhost'} ||= shift @{ Sisimai::RFC5322->received( $r0->[0] ) };
            $e->{'rhost'} ||= pop @{ Sisimai::RFC5322->received( $r0->[-1] ) };
        }

        $e->{'spec'}    ||= 'SMTP';
        $e->{'agent'}     = __PACKAGE__->smtpagent;
        $e->{'diagnosis'} = Sisimai::String->sweep( $e->{'diagnosis'} );

        if( length( $e->{'status'} ) == 0 || $e->{'status'} =~ m/\A\d[.]0[.]0\z/ ) {
            # There is no value of Status header or the value is 5.0.0, 4.0.0
            my $r = Sisimai::SMTP::Status->find( $e->{'diagnosis'} );
            $e->{'status'} = $r if length $r;
        }

        if( $e->{'status'} ) {
            # Find the error code from $CodeTable
            $e->{'reason'} = $CodeTable->{ $e->{'status'} } || ''
        }
    }
    return { 'ds' => $dscontents, 'rfc822' => $rfc822part };
}

1;
__END__

=encoding utf-8

=head1 NAME

Sisimai::MSP::US::Office365 - bounce mail parser class for Microsoft Office 365.

=head1 SYNOPSIS

    use Sisimai::MSP::US::Office365;

=head1 DESCRIPTION

Sisimai::MSP::US::Office365 parses a bounce email which created by C<Microsoft
Office 365>. Methods in the module are called from only Sisimai::Message.

=head1 CLASS METHODS

=head2 C<B<description()>>

C<description()> returns description string of this module.

    print Sisimai::MSP::US::Office365->description;

=head2 C<B<smtpagent()>>

C<smtpagent()> returns MSP name.

    print Sisimai::MSP::US::Office365->smtpagent;

=head2 C<B<scan( I<header data>, I<reference to body string>)>>

C<scan()> method parses a bounced email and return results as a array reference.
See Sisimai::Message for more details.

=head1 AUTHOR

azumakuniyuki

=head1 COPYRIGHT

Copyright (C) 2016 azumakuniyuki, All rights reserved.

=head1 LICENSE

This software is distributed under The BSD 2-Clause License.

=cut
