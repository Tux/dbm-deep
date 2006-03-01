##
# DBM::Deep Test
##
use strict;
use Test::More tests => 2;
use File::Temp qw( tempfile tempdir );

use_ok( 'DBM::Deep' );

my $dir = tempdir( CLEANUP => 1 );
my ($fh, $filename) = tempfile( 'tmpXXXX', UNLINK => 1, DIR => $dir );
my $db = DBM::Deep->new(
	file => $filename,
	type => DBM::Deep->TYPE_ARRAY
);

##
# put/get many keys
##
my $max_keys = 4000;

for ( 0 .. $max_keys ) {
    $db->put( $_ => $_ * 2 );
}

my $count = -1;
for ( 0 .. $max_keys ) {
    $count = $_;
    unless ( $db->get( $_ ) == $_ * 2 ) {
        last;
    };
}
is( $count, $max_keys, "We read $count keys" );
