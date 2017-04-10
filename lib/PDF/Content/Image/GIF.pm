use v6;
use PDF::Content::Image :Endian;

# adapted from Perl 5's PDF::API::Resource::XObject::Image::GIF

class PDF::Content::Image::GIF
    is PDF::Content::Image {

    method network-endian { False }

    method !read-colorspace($fh,  UInt $flags, %dict) {
        my UInt $col-size = 2 ** (($flags +& 0x7) + 1);
        my Str $encoded = $fh.read( 3 * $col-size).decode('latin-1');
        my $color-table = $col-size > 64
            ?? PDF::DAO.coerce( :stream{ :$encoded } )
            !! :hex-string($encoded);
        %dict<ColorSpace> = [ :name<Indexed>, :name<DeviceRGB>, :int($col-size-1), $color-table ];
    }

    sub vec(buf8 \buf, UInt \off) {
        (buf[ off div 8] +> (off mod 8)) mod 2
    }

    method !decompress(UInt \ibits, buf8 \stream --> Buf) {
        my UInt \reset-code = 1 +< (ibits - 1);
        my UInt \end-code   = reset-code + 1;
        my UInt \maxptr = 8 * +stream;
        my int $next-code  = end-code + 1;
        my int $bits = ibits;
        my int $ptr = 0;
        my uint8 @out;
        my int $outptr = 0;

        my @d = (0 ..^ reset-code).map: {[$_, ]};

        while ($ptr + $bits) <= maxptr {
            my UInt \tag = [+] (0 ..^ $bits).map: { vec(stream, $ptr + $_) +< $_ };
            $ptr += $bits;
            $bits++
                if $next-code == 1 +< $bits and $bits < 12;

            if tag == reset-code {
                $bits = ibits;
                $next-code = end-code + 1;
            } elsif tag == end-code {
                last;
            } else {
                @d[$next-code] = [ @d[tag].list ];
                @d[$next-code].push: @d[tag + 1][0]
                    if tag > end-code;
                @out.append: @d[$next-code++].list;
            }
        }

        Buf.new(@out);
    }

    method !deinterlace(Buf $data, UInt $width, UInt $height) {
        my UInt $row;
        my Buf @result;
        my UInt $idx = 0;

        for [ 0 => 8, 4 => 8, 2 => 4, 1 => 2] {
            my $row = .key;
            my \incr = .value;
            while $row < $height {
                @result[$row] = $data.subbuf( $idx*$width, $width);
                $row += incr;
                $idx++;
            }
        }

        [~] @result.map: *.decode('latin-1');
    }

    method read($fh!, Bool :$trans = True) {

        my %dict = :Type( :name<XObject> ), :Subtype( :name<Image> );
        my Bool $interlaced = False;
        my Str $encoded = '';

        my $header = $fh.read(6).decode: 'latin-1';
        die X::PDF::Image::WrongHeader.new( :type<GIF>, :$header, :path($fh.path) )
            unless $header ~~ /^GIF <[0..9]>**2 [a|b]/;

        my $buf = $fh.read: 7; # logical descr.
        my class LogicalDescriptor does PDF::Content::Image::Struct[Vax] {
            has uint16 $.wg;
            has uint16 $.hg;
            has uint8 $.flags;
            has uint8 $.bgColorIndex;
            has uint8 $.aspect;
        }
        my class ImageDescriptor does PDF::Content::Image::Struct[Vax] {
            has uint16 $.left;
            has uint16 $.top;
            has uint16 $.w;
            has uint16 $.h;
            has uint8 $.flags;
        }
        my LogicalDescriptor $descr .= unpack: $buf;

        with $descr.flags -> uint8 $flags {
            self!read-colorspace($fh, $flags, %dict)
                if $flags +& 0x80;
        }

        while !$fh.eof {
            my ($sep) = $.unpack( $fh.read(1), uint8); # tag.

            given $sep {
                when 0x2C {
                    $buf = $fh.read(9); # image-descr.
                    my ImageDescriptor $img .= unpack: $buf;

                    %dict<Width>  = $img.w || $descr.wg;
                    %dict<Height> = $img.h || $descr.hg;
                    %dict<BitsPerComponent> = 8;

                    with $img.flags -> uint8 $flags {
                        self!read-colorspace($fh, $flags, %dict)
                            if $flags +& 0x80; # local colormap

                        $interlaced = True  # need de-interlace
                            if $flags &+ 0x40;
                    }

                    my ($sep, $len) = $.unpack( $fh.read(2), uint8, uint8); # image-lzw-start (should be 9) + length.
                    my $stream = buf8.new;

                    while $len {
                        $stream.append: $fh.read($len).list;
                        ($len,) = $.unpack($fh.read(1), uint8);
                    }

                    my Buf $data = self!decompress($sep+1, $stream);
                    $encoded = $interlaced
                        ?? self!deinterlace($encoded, %dict<Width>, %dict<Height> )
                        !! $data.decode: 'latin-1';

                    %dict<Length> = $encoded.codes;
                    last;
                }

                when 0x3b {
                    last;
                }

                when 0x21 {
                    # Graphic Control Extension
                    my ($tag, $len) = $.unpack( $fh.read(2), uint8, uint8);
                    die "unsupported graphic control extension ($tag)"
                        unless $tag == 0xF9;

                    my $stream = Buf.new;

                    while $len {
                        $stream.append: $fh.read($len).list;
                        ($len,) = $.unpack($fh.read(1), uint8);
                    }

                    if $trans {
                        my class GCDescriptor does PDF::Content::Image::Struct[Vax] {
                            has uint8 $.cFlags;
                            has uint16 $.delay;
                            has uint8 $.transIndex
                        }
                        my GCDescriptor $gc .= unpack($stream);
                        with $gc.cFlags -> uint8 $cFlags {
                            my uint8 $transIndex = $gc.transIndex;
                            %dict<Mask> = [$transIndex, $transIndex]
                                if $cFlags +& 0x01;
                        }
                    }
                }

                default {
                    # misc extension
                    my ($tag, $len) = $.unpack( $fh.read(1), uint8, uint8);

                    # skip ahead
                    while $len {
                        $fh.seek($len, SeekFromCurrent);
                        ($len,) = $.unpack($fh.read(1), uint8);
                    }
                }
            }
        }
        $fh.close;

        use PDF::DAO;
        PDF::DAO.coerce: :stream{ :%dict, :$encoded };
    }

}
