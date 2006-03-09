package DBM::Deep::Engine;

use strict;

use Fcntl qw( :DEFAULT :flock :seek );

##
# Setup file and tag signatures.  These should never change.
##
sub SIG_FILE     () { 'DPDB' }
sub SIG_INTERNAL () { 'i'    }
sub SIG_HASH     () { 'H'    }
sub SIG_ARRAY    () { 'A'    }
sub SIG_NULL     () { 'N'    }
sub SIG_DATA     () { 'D'    }
sub SIG_INDEX    () { 'I'    }
sub SIG_BLIST    () { 'B'    }
sub SIG_SIZE     () {  1     }

sub precalc_sizes {
    ##
    # Precalculate index, bucket and bucket list sizes
    ##
    my $self = shift;

    $self->{index_size}       = (2**8) * $self->{long_size};
    $self->{bucket_size}      = $self->{hash_size} + $self->{long_size} * 2;
    $self->{bucket_list_size} = $self->{max_buckets} * $self->{bucket_size};

    return 1;
}

sub set_pack {
    ##
    # Set pack/unpack modes (see file header for more)
    ##
    my $self = shift;
    my ($long_s, $long_p, $data_s, $data_p) = @_;

    ##
    # Set to 4 and 'N' for 32-bit offset tags (default).  Theoretical limit of 4
    # GB per file.
    #    (Perl must be compiled with largefile support for files > 2 GB)
    #
    # Set to 8 and 'Q' for 64-bit offsets.  Theoretical limit of 16 XB per file.
    #    (Perl must be compiled with largefile and 64-bit long support)
    ##
    $self->{long_size} = $long_s ? $long_s : 4;
    $self->{long_pack} = $long_p ? $long_p : 'N';

    ##
    # Set to 4 and 'N' for 32-bit data length prefixes.  Limit of 4 GB for each
    # key/value. Upgrading this is possible (see above) but probably not
    # necessary. If you need more than 4 GB for a single key or value, this
    # module is really not for you :-)
    ##
    $self->{data_size} = $data_s ? $data_s : 4;
    $self->{data_pack} = $data_p ? $data_p : 'N';

    return $self->precalc_sizes();
}

sub set_digest {
    ##
    # Set key digest function (default is MD5)
    ##
    my $self = shift;
    my ($digest_func, $hash_size) = @_;

    $self->{digest} = $digest_func ? $digest_func : \&Digest::MD5::md5;
    $self->{hash_size} = $hash_size ? $hash_size : 16;

    return $self->precalc_sizes();
}

sub new {
    my $class = shift;
    my ($args) = @_;

    my $self = bless {
        long_size   => 4,
        long_pack   => 'N',
        data_size   => 4,
        data_pack   => 'N',

        digest      => \&Digest::MD5::md5,
        hash_size   => 16,

        ##
        # Maximum number of buckets per list before another level of indexing is
        # done.
        # Increase this value for slightly greater speed, but larger database
        # files. DO NOT decrease this value below 16, due to risk of recursive
        # reindex overrun.
        ##
        max_buckets => 16,
    }, $class;

    $self->precalc_sizes;

    return $self;
}

sub setup_fh {
    my $self = shift;
    my ($obj) = @_;

    $self->open( $obj ) if !defined $obj->_fh;

    my $fh = $obj->_fh;
    flock $fh, LOCK_EX;

    unless ( $obj->{base_offset} ) {
        seek($fh, 0 + $obj->_root->{file_offset}, SEEK_SET);
        my $signature;
        my $bytes_read = read( $fh, $signature, length(SIG_FILE));

        ##
        # File is empty -- write signature and master index
        ##
        if (!$bytes_read) {
            my $loc = $self->_request_space( $obj, length( SIG_FILE ) );
            seek($fh, $loc + $obj->_root->{file_offset}, SEEK_SET);
            print( $fh SIG_FILE);

            $obj->{base_offset} = $self->_request_space(
                $obj, $self->tag_size( $self->{index_size} ),
            );

            $self->create_tag(
                $obj, $obj->_base_offset, $obj->_type,
                chr(0)x$self->{index_size},
            );

            # Flush the filehandle
            my $old_fh = select $fh;
            my $old_af = $|; $| = 1; $| = $old_af;
            select $old_fh;
        }
        else {
            $obj->{base_offset} = $bytes_read;

            ##
            # Check signature was valid
            ##
            unless ($signature eq SIG_FILE) {
                $self->close_fh( $obj );
                $obj->_throw_error("Signature not found -- file is not a Deep DB");
            }

            ##
            # Get our type from master index signature
            ##
            my $tag = $self->load_tag($obj, $obj->_base_offset)
            or $obj->_throw_error("Corrupted file, no master index record");

            unless ($obj->{type} eq $tag->{signature}) {
                $obj->_throw_error("File type mismatch");
            }
        }
    }

    #XXX We have to make sure we don't mess up when autoflush isn't turned on
    unless ( $obj->_root->{inode} ) {
        my @stats = stat($obj->_fh);
        $obj->_root->{inode} = $stats[1];
        $obj->_root->{end} = $stats[7];
    }

    flock $fh, LOCK_UN;

    return 1;
}

sub open {
    ##
    # Open a fh to the database, create if nonexistent.
    # Make sure file signature matches DBM::Deep spec.
    ##
    my $self = shift;
    my ($obj) = @_;

    # Theoretically, adding O_BINARY should remove the need for the binmode
    # Of course, testing it is going to be ... interesting.
    my $flags = O_RDWR | O_CREAT | O_BINARY;

    my $fh;
    my $filename = $obj->_root->{file};
    sysopen( $fh, $filename, $flags )
        or $obj->_throw_error("Cannot sysopen file '$filename': $!");
    $obj->_root->{fh} = $fh;

    #XXX Can we remove this by using the right sysopen() flags?
    # Maybe ... q.v. above
    binmode $fh; # for win32

    if ($obj->_root->{autoflush}) {
        my $old = select $fh;
        $|=1;
        select $old;
    }

    return 1;
}

sub close_fh {
    my $self = shift;
    my ($obj) = @_;

    if ( my $fh = $obj->_root->{fh} ) {
        close $fh;
    }
    $obj->_root->{fh} = undef;

    return 1;
}

sub tag_size {
    my $self = shift;
    my ($size) = @_;
    return SIG_SIZE + $self->{data_size} + $size;
}

sub create_tag {
    ##
    # Given offset, signature and content, create tag and write to disk
    ##
    my $self = shift;
    my ($obj, $offset, $sig, $content) = @_;
    my $size = length( $content );

    my $fh = $obj->_fh;

    if ( defined $offset ) {
        seek($fh, $offset + $obj->_root->{file_offset}, SEEK_SET);
    }

    print( $fh $sig . pack($self->{data_pack}, $size) . $content );

    return unless defined $offset;

    return {
        signature => $sig,
        size => $size,
        offset => $offset + SIG_SIZE + $self->{data_size},
        content => $content
    };
}

sub load_tag {
    ##
    # Given offset, load single tag and return signature, size and data
    ##
    my $self = shift;
    my ($obj, $offset) = @_;

#    print join(':',map{$_||''}caller(1)), $/;

    my $fh = $obj->_fh;

    seek($fh, $offset + $obj->_root->{file_offset}, SEEK_SET);

    #XXX I'm not sure this check will work if autoflush isn't enabled ...
    return if eof $fh;

    my $b;
    read( $fh, $b, SIG_SIZE + $self->{data_size} );
    my ($sig, $size) = unpack( "A $self->{data_pack}", $b );

    my $buffer;
    read( $fh, $buffer, $size);

    return {
        signature => $sig,
        size => $size,
        offset => $offset + SIG_SIZE + $self->{data_size},
        content => $buffer
    };
}

sub _length_needed {
    my $self = shift;
    my ($obj, $value, $key) = @_;

    my $is_dbm_deep = eval {
        local $SIG{'__DIE__'};
        $value->isa( 'DBM::Deep' );
    };

    my $len = SIG_SIZE + $self->{data_size}
            + $self->{data_size} + length( $key );

    if ( $is_dbm_deep && $value->_root eq $obj->_root ) {
        return $len + $self->{long_size};
    }

    my $r = Scalar::Util::reftype( $value ) || '';
    if ( $obj->_root->{autobless} ) {
        # This is for the bit saying whether or not this thing is blessed.
        $len += 1;
    }

    unless ( $r eq 'HASH' || $r eq 'ARRAY' ) {
        if ( defined $value ) {
            $len += length( $value );
        }
        return $len;
    }

    $len += $self->{index_size};

    # if autobless is enabled, must also take into consideration
    # the class name as it is stored after the key.
    if ( $obj->_root->{autobless} ) {
        my $value_class = Scalar::Util::blessed($value);
        if ( defined $value_class && !$is_dbm_deep ) {
            $len += $self->{data_size} + length($value_class);
        }
    }

    return $len;
}

sub add_bucket {
    ##
    # Adds one key/value pair to bucket list, given offset, MD5 digest of key,
    # plain (undigested) key and value.
    ##
    my $self = shift;
    my ($obj, $tag, $md5, $plain_key, $value) = @_;

    # This verifies that only supported values will be stored.
    {
        my $r = Scalar::Util::reftype( $value );
        last if !defined $r;

        last if $r eq 'HASH';
        last if $r eq 'ARRAY';

        $obj->_throw_error(
            "Storage of variables of type '$r' is not supported."
        );
    }

    my $location = 0;
    my $result = 2;

    my $root = $obj->_root;
    my $fh   = $obj->_fh;

    my $actual_length = $self->_length_needed( $obj, $value, $plain_key );

    my ($subloc, $offset, $size) = $self->_find_in_buckets( $tag, $md5 );

    # Updating a known md5
    if ( $subloc ) {
        $result = 1;

        if ($actual_length <= $size) {
            $location = $subloc;
        }
        else {
            $location = $self->_request_space( $obj, $actual_length );
            seek(
                $fh,
                $tag->{offset} + $offset
              + $self->{hash_size} + $root->{file_offset},
                SEEK_SET,
            );
            print( $fh pack($self->{long_pack}, $location ) );
            print( $fh pack($self->{long_pack}, $actual_length ) );
        }
    }
    # Adding a new md5
    elsif ( defined $offset ) {
        $location = $self->_request_space( $obj, $actual_length );

        seek( $fh, $tag->{offset} + $offset + $root->{file_offset}, SEEK_SET );
        print( $fh $md5 . pack($self->{long_pack}, $location ) );
        print( $fh pack($self->{long_pack}, $actual_length ) );
    }
    # If bucket didn't fit into list, split into a new index level
    else {
#XXX This is going to be a problem.
        $self->split_index( $obj, $md5, $tag );

        $location = $self->_request_space( $obj, $actual_length );
    }

    $self->write_value( $obj, $location, $plain_key, $value );

    return $result;
}

sub write_value {
    my $self = shift;
    my ($obj, $location, $key, $value) = @_;

    my $fh = $obj->_fh;
    my $root = $obj->_root;

    my $is_dbm_deep = eval {
        local $SIG{'__DIE__'};
        $value->isa( 'DBM::Deep' );
    };

    my $internal_ref = $is_dbm_deep && ($value->_root eq $root);

    seek($fh, $location + $root->{file_offset}, SEEK_SET);

    ##
    # Write signature based on content type, set content length and write
    # actual value.
    ##
    my $r = Scalar::Util::reftype($value) || '';
    if ( $internal_ref ) {
        $self->create_tag( $obj, undef, SIG_INTERNAL,pack($self->{long_pack}, $value->_base_offset) );
    }
    elsif ($r eq 'HASH') {
        $self->create_tag( $obj, undef, SIG_HASH, chr(0)x$self->{index_size} );
    }
    elsif ($r eq 'ARRAY') {
        $self->create_tag( $obj, undef, SIG_ARRAY, chr(0)x$self->{index_size} );
    }
    elsif (!defined($value)) {
        $self->create_tag( $obj, undef, SIG_NULL, '' );
    }
    else {
        $self->create_tag( $obj, undef, SIG_DATA, $value );
    }

    ##
    # Plain key is stored AFTER value, as keys are typically fetched less often.
    ##
    print( $fh pack($self->{data_pack}, length($key)) . $key );

    # Internal references don't care about autobless
    return 1 if $internal_ref;

    ##
    # If value is blessed, preserve class name
    ##
    if ( $root->{autobless} ) {
        my $value_class = Scalar::Util::blessed($value);
        if ( defined $value_class && !$is_dbm_deep ) {
            print( $fh chr(1) );
            print( $fh pack($self->{data_pack}, length($value_class)) . $value_class );
        }
        else {
            print( $fh chr(0) );
        }
    }

    ##
    # If content is a hash or array, create new child DBM::Deep object and
    # pass each key or element to it.
    ##
    if ( !$internal_ref ) {
        if ($r eq 'HASH') {
            my $branch = DBM::Deep->new(
                type => DBM::Deep->TYPE_HASH,
                base_offset => $location,
                root => $root,
            );
            foreach my $key (keys %{$value}) {
                $branch->STORE( $key, $value->{$key} );
            }
        }
        elsif ($r eq 'ARRAY') {
            my $branch = DBM::Deep->new(
                type => DBM::Deep->TYPE_ARRAY,
                base_offset => $location,
                root => $root,
            );
            my $index = 0;
            foreach my $element (@{$value}) {
                $branch->STORE( $index, $element );
                $index++;
            }
        }
    }

    return 1;
}

sub split_index {
    my $self = shift;
    my ($obj, $md5, $tag) = @_;

    my $fh = $obj->_fh;
    my $root = $obj->_root;
    my $keys = $tag->{content};

    seek($fh, $tag->{ref_loc} + $root->{file_offset}, SEEK_SET);

    my $loc = $self->_request_space(
        $obj, $self->tag_size( $self->{index_size} ),
    );

    print( $fh pack($self->{long_pack}, $loc) );

    my $index_tag = $self->create_tag(
        $obj, $loc, SIG_INDEX,
        chr(0)x$self->{index_size},
    );

    my @offsets = ();

    $keys .= $md5 . (pack($self->{long_pack}, 0) x 2);

    BUCKET:
    for (my $i = 0; $i <= $self->{max_buckets}; $i++) {
        my ($key, $old_subloc, $size) = $self->_get_key_subloc( $keys, $i );

        next BUCKET unless $key;

        my $num = ord(substr($key, $tag->{ch} + 1, 1));

        if ($offsets[$num]) {
            my $offset = $offsets[$num] + SIG_SIZE + $self->{data_size};
            seek($fh, $offset + $root->{file_offset}, SEEK_SET);
            my $subkeys;
            read( $fh, $subkeys, $self->{bucket_list_size});

            for (my $k=0; $k<$self->{max_buckets}; $k++) {
                my ($temp, $subloc) = $self->_get_key_subloc( $subkeys, $k );

                if (!$subloc) {
                    seek($fh, $offset + ($k * $self->{bucket_size}) + $root->{file_offset}, SEEK_SET);
                    print( $fh $key . pack($self->{long_pack}, $old_subloc || $root->{end}) );
                    last;
                }
            } # k loop
        }
        else {
            $offsets[$num] = $root->{end};
            seek($fh, $index_tag->{offset} + ($num * $self->{long_size}) + $root->{file_offset}, SEEK_SET);

            my $loc = $self->_request_space(
                $obj, $self->tag_size( $self->{bucket_list_size} ),
            );

            print( $fh pack($self->{long_pack}, $loc) );

            my $blist_tag = $self->create_tag(
                $obj, $loc, SIG_BLIST,
                chr(0)x$self->{bucket_list_size},
            );

            seek($fh, $blist_tag->{offset} + $root->{file_offset}, SEEK_SET);
            print( $fh $key . pack($self->{long_pack}, $old_subloc || $root->{end}) );
        }
    } # i loop

    return;
}

sub read_from_loc {
    my $self = shift;
    my ($obj, $subloc) = @_;

    my $fh = $obj->_fh;

    ##
    # Found match -- seek to offset and read signature
    ##
    my $signature;
    seek($fh, $subloc + $obj->_root->{file_offset}, SEEK_SET);
    read( $fh, $signature, SIG_SIZE);

    ##
    # If value is a hash or array, return new DBM::Deep object with correct offset
    ##
    if (($signature eq SIG_HASH) || ($signature eq SIG_ARRAY)) {
        my $obj = DBM::Deep->new(
            type => $signature,
            base_offset => $subloc,
            root => $obj->_root,
        );

        if ($obj->_root->{autobless}) {
            ##
            # Skip over value and plain key to see if object needs
            # to be re-blessed
            ##
            seek($fh, $self->{data_size} + $self->{index_size}, SEEK_CUR);

            my $size;
            read( $fh, $size, $self->{data_size}); $size = unpack($self->{data_pack}, $size);
            if ($size) { seek($fh, $size, SEEK_CUR); }

            my $bless_bit;
            read( $fh, $bless_bit, 1);
            if (ord($bless_bit)) {
                ##
                # Yes, object needs to be re-blessed
                ##
                my $class_name;
                read( $fh, $size, $self->{data_size}); $size = unpack($self->{data_pack}, $size);
                if ($size) { read( $fh, $class_name, $size); }
                if ($class_name) { $obj = bless( $obj, $class_name ); }
            }
        }

        return $obj;
    }
    elsif ( $signature eq SIG_INTERNAL ) {
        my $size;
        read( $fh, $size, $self->{data_size});
        $size = unpack($self->{data_pack}, $size);

        if ( $size ) {
            my $new_loc;
            read( $fh, $new_loc, $size );
            $new_loc = unpack( $self->{long_pack}, $new_loc );

            return $self->read_from_loc( $obj, $new_loc );
        }
        else {
            return;
        }
    }
    ##
    # Otherwise return actual value
    ##
    elsif ($signature eq SIG_DATA) {
        my $size;
        read( $fh, $size, $self->{data_size});
        $size = unpack($self->{data_pack}, $size);

        my $value = '';
        if ($size) { read( $fh, $value, $size); }
        return $value;
    }

    ##
    # Key exists, but content is null
    ##
    return;
}

sub get_bucket_value {
    ##
    # Fetch single value given tag and MD5 digested key.
    ##
    my $self = shift;
    my ($obj, $tag, $md5) = @_;

    my ($subloc, $offset, $size) = $self->_find_in_buckets( $tag, $md5 );
    if ( $subloc ) {
        return $self->read_from_loc( $obj, $subloc );
    }
    return;
}

sub delete_bucket {
    ##
    # Delete single key/value pair given tag and MD5 digested key.
    ##
    my $self = shift;
    my ($obj, $tag, $md5) = @_;

    my ($subloc, $offset, $size) = $self->_find_in_buckets( $tag, $md5 );
    if ( $subloc ) {
        my $fh = $obj->_fh;
        seek($fh, $tag->{offset} + $offset + $obj->_root->{file_offset}, SEEK_SET);
        print( $fh substr($tag->{content}, $offset + $self->{bucket_size} ) );
        print( $fh chr(0) x $self->{bucket_size} );

        return 1;
    }
    return;
}

sub bucket_exists {
    ##
    # Check existence of single key given tag and MD5 digested key.
    ##
    my $self = shift;
    my ($obj, $tag, $md5) = @_;

    my ($subloc, $offset, $size) = $self->_find_in_buckets( $tag, $md5 );
    return $subloc && 1;
}

sub find_bucket_list {
    ##
    # Locate offset for bucket list, given digested key
    ##
    my $self = shift;
    my ($obj, $md5, $args) = @_;
    $args = {} unless $args;

    ##
    # Locate offset for bucket list using digest index system
    ##
    my $tag = $self->load_tag($obj, $obj->_base_offset)
        or $obj->_throw_error( "INTERNAL ERROR - Cannot find tag" );

    my $ch = 0;
    while ($tag->{signature} ne SIG_BLIST) {
        my $num = ord substr($md5, $ch, 1);

        my $ref_loc = $tag->{offset} + ($num * $self->{long_size});
        $tag = $self->index_lookup( $obj, $tag, $num );

        if (!$tag) {
            return if !$args->{create};

            my $fh = $obj->_fh;
            seek($fh, $ref_loc + $obj->_root->{file_offset}, SEEK_SET);

            my $loc = $self->_request_space(
                $obj, $self->tag_size( $self->{bucket_list_size} ),
            );

            print( $fh pack($self->{long_pack}, $loc) );

            $tag = $self->create_tag(
                $obj, $loc, SIG_BLIST,
                chr(0)x$self->{bucket_list_size},
            );

            $tag->{ref_loc} = $ref_loc;
            $tag->{ch} = $ch;

            last;
        }

        $tag->{ch} = $ch++;
        $tag->{ref_loc} = $ref_loc;
    }

    return $tag;
}

sub index_lookup {
    ##
    # Given index tag, lookup single entry in index and return .
    ##
    my $self = shift;
    my ($obj, $tag, $index) = @_;

    my $location = unpack(
        $self->{long_pack},
        substr(
            $tag->{content},
            $index * $self->{long_size},
            $self->{long_size},
        ),
    );

    if (!$location) { return; }

    return $self->load_tag( $obj, $location );
}

sub traverse_index {
    ##
    # Scan index and recursively step into deeper levels, looking for next key.
    ##
    my $self = shift;
    my ($obj, $offset, $ch, $force_return_next) = @_;

    my $tag = $self->load_tag($obj, $offset );

    my $fh = $obj->_fh;

    if ($tag->{signature} ne SIG_BLIST) {
        my $content = $tag->{content};
        my $start = $obj->{return_next} ? 0 : ord(substr($obj->{prev_md5}, $ch, 1));

        for (my $idx = $start; $idx < (2**8); $idx++) {
            my $subloc = unpack(
                $self->{long_pack},
                substr(
                    $content,
                    $idx * $self->{long_size},
                    $self->{long_size},
                ),
            );

            if ($subloc) {
                my $result = $self->traverse_index(
                    $obj, $subloc, $ch + 1, $force_return_next,
                );

                if (defined($result)) { return $result; }
            }
        } # index loop

        $obj->{return_next} = 1;
    } # tag is an index

    else {
        my $keys = $tag->{content};
        if ($force_return_next) { $obj->{return_next} = 1; }

        ##
        # Iterate through buckets, looking for a key match
        ##
        for (my $i = 0; $i < $self->{max_buckets}; $i++) {
            my ($key, $subloc) = $self->_get_key_subloc( $keys, $i );

            # End of bucket list -- return to outer loop
            if (!$subloc) {
                $obj->{return_next} = 1;
                last;
            }
            # Located previous key -- return next one found
            elsif ($key eq $obj->{prev_md5}) {
                $obj->{return_next} = 1;
                next;
            }
            # Seek to bucket location and skip over signature
            elsif ($obj->{return_next}) {
                seek($fh, $subloc + $obj->_root->{file_offset}, SEEK_SET);

                # Skip over value to get to plain key
                my $sig;
                read( $fh, $sig, SIG_SIZE );

                my $size;
                read( $fh, $size, $self->{data_size});
                $size = unpack($self->{data_pack}, $size);
                if ($size) { seek($fh, $size, SEEK_CUR); }

                # Read in plain key and return as scalar
                my $plain_key;
                read( $fh, $size, $self->{data_size});
                $size = unpack($self->{data_pack}, $size);
                if ($size) { read( $fh, $plain_key, $size); }

                return $plain_key;
            }
        }

        $obj->{return_next} = 1;
    } # tag is a bucket list

    return;
}

sub get_next_key {
    ##
    # Locate next key, given digested previous one
    ##
    my $self = shift;
    my ($obj) = @_;

    $obj->{prev_md5} = $_[1] ? $_[1] : undef;
    $obj->{return_next} = 0;

    ##
    # If the previous key was not specifed, start at the top and
    # return the first one found.
    ##
    if (!$obj->{prev_md5}) {
        $obj->{prev_md5} = chr(0) x $self->{hash_size};
        $obj->{return_next} = 1;
    }

    return $self->traverse_index( $obj, $obj->_base_offset, 0 );
}

# Utilities

sub _get_key_subloc {
    my $self = shift;
    my ($keys, $idx) = @_;

    my ($key, $subloc, $size) = unpack(
        "a$self->{hash_size} $self->{long_pack} $self->{long_pack}",
        substr(
            $keys,
            ($idx * $self->{bucket_size}),
            $self->{bucket_size},
        ),
    );

    return ($key, $subloc, $size);
}

sub _find_in_buckets {
    my $self = shift;
    my ($tag, $md5) = @_;

    BUCKET:
    for ( my $i = 0; $i < $self->{max_buckets}; $i++ ) {
        my ($key, $subloc, $size) = $self->_get_key_subloc(
            $tag->{content}, $i,
        );

        return ($subloc, $i * $self->{bucket_size}, $size) unless $subloc;

        next BUCKET if $key ne $md5;

        return ($subloc, $i * $self->{bucket_size}, $size);
    }

    return;
}

sub _request_space {
    my $self = shift;
    my ($obj, $size) = @_;

    my $loc = $obj->_root->{end};
    $obj->_root->{end} += $size;

    return $loc;
}

sub _release_space {
    my $self = shift;
    my ($obj, $size, $loc) = @_;

    return;
}

1;
__END__

# This will be added in later, after more refactoring is done. This is an early
# attempt at refactoring on the physical level instead of the virtual level.
sub _read_at {
    my $self = shift;
    my ($obj, $spot, $amount, $unpack) = @_;

    my $fh = $obj->_fh;
    seek( $fh, $spot + $obj->_root->{file_offset}, SEEK_SET );

    my $buffer;
    my $bytes_read = read( $fh, $buffer, $amount );

    if ( $unpack ) {
        $buffer = unpack( $unpack, $buffer );
    }

    if ( wantarray ) {
        return ($buffer, $bytes_read);
    }
    else {
        return $buffer;
    }
}
