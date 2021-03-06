use strict;
use warnings;
use Test::More;
use lib qw(./lib ./blib/lib);
require './t/600-bite-email-code';

my $enginename = 'AmazonSES';
my $enginetest = Sisimai::Bite::Email::Code->maketest;
my $isexpected = [
    { 'n' => '01', 's' => qr/\A5[.]7[.]1\z/, 'r' => qr/securityerror/, 'b' => qr/\A1\z/  },
    { 'n' => '02', 's' => qr/\A5[.]3[.]0\z/, 'r' => qr/filtered/,      'b' => qr/\A1\z/  },
    { 'n' => '03', 's' => qr/\A5[.]2[.]2\z/, 'r' => qr/mailboxfull/,   'b' => qr/\A1\z/  },
    { 'n' => '05', 's' => qr/\A5[.]1[.]1\z/, 'r' => qr/userunknown/,   'b' => qr/\A0\z/  },
    { 'n' => '06', 's' => qr/\A5[.]1[.]1\z/, 'r' => qr/userunknown/,   'b' => qr/\A0\z/  },
    { 'n' => '07', 's' => qr/\A5[.]7[.]6\z/, 'r' => qr/securityerror/, 'b' => qr/\A1\z/  },
    { 'n' => '08', 's' => qr/\A5[.]7[.]9\z/, 'r' => qr/securityerror/, 'b' => qr/\A1\z/  },
    { 'n' => '09', 's' => qr/\A5[.]1[.]1\z/, 'r' => qr/userunknown/,   'b' => qr/\A0\z/  },
    { 'n' => '10', 's' => qr/\A5[.]1[.]1\z/, 'r' => qr/userunknown/,   'b' => qr/\A0\z/  },
    { 'n' => '11', 's' => qr/\A\z/,          'r' => qr/feedback/,      'b' => qr/\A-1\z/ },
    { 'n' => '12', 's' => qr/\A2[.]6[.]0\z/, 'r' => qr/delivered/,     'b' => qr/\A-1\z/ },
    { 'n' => '13', 's' => qr/\A2[.]6[.]0\z/, 'r' => qr/delivered/,     'b' => qr/\A-1\z/ },
];

$enginetest->($enginename, $isexpected);
done_testing;

