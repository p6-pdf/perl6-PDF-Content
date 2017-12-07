use v6;

class X::PDF::Image::WrongHeader is Exception {
    has Str $.type is required;
    has Str $.header is required;
    has $.path is required;
    method message {
        "{$!path} image doesn't have a {$!type} header: {$.header.perl}"
    }
}

class X::PDF::Image::UnknownType is Exception {
    has $.path is required;
    method message {
        die "unable to open image: $!path";
    }
}

class PDF::Content::Image {
    use PDF::DAO;
    use PDF::DAO::Stream;
    use PDF::Content::XObject;
    use PDF::IO;

    has Str $.data-uri;
    subset IOish where PDF::IO|IO::Handle;
    has IOish $.source;
    subset ImageType of Str where 'JPEG'|'GIF'|'PNG'|'PDF';
    has ImageType $.image-type;

    method !image-type($_, :$path!) {
        when m:i/^ jpe?g $/    { 'JPEG' }
        when m:i/^ gif $/      { 'GIF' }
        when m:i/^ png $/      { 'PNG' }
        when m:i/^ pdf|json $/ { 'PDF' }
        default {
            die X::PDF::Image::UnknownType.new( :$path );
        }
    }

    method load(IOish :$fh!, ImageType :$image-type!,
                :$class = (require ::('PDF::Content::Image')::($image-type))) {
        my $image-obj = $class.new: :$image-type, :source($fh);
        $image-obj.read;
        my PDF::DAO::Stream $image-xobject = $image-obj.to-dict;
        $image-xobject does PDF::Content::XObject[$image-xobject<Subtype>]
            unless $image-xobject ~~ PDF::Content::XObject;
        $image-xobject.image-obj = $image-obj;
        $image-xobject;
    }

    multi method open(Str $data-uri where /^('data:' [<t=.ident> '/' <s=.ident>]? $<b64>=";base64"? $<start>=",") /) {
        my $path = ~ $0;
        my Str \mime-type = ( $0<t> // '(missing)').lc;
        my Str \mime-subtype = ( $0<s> // '').lc;
        my Bool \base64 = ? $0<b64>;
        my Numeric \start = $0<start>.to;

        die "expected mime-type 'image/*' or 'application/pdf', got '{mime-type}': $path"
            unless mime-type eq 'image' || mime-subtype eq 'pdf';
        my $image-type = self!image-type(mime-subtype, :$path);
        my $data = substr($data-uri, start);
	if base64 {
	    use Base64::Native;
	    $data = base64-decode($data).decode("latin-1");
	}

        my $fh = PDF::IO.coerce($data, :$path);
        self.load(:$fh, :$image-type, :$data-uri);
    }

    multi method open(Str $path! ) {
        self.open( $path.IO );
    }

    multi method open(IO::Path $io-path) {
        self.open( $io-path.open( :r, :enc<latin-1>) );
    }

    multi method open(IO::Handle $fh!) {
        my $path = $fh.path;
        my Str $image-type = self!image-type($path.extension, :$path);
        self.load(:$fh, :$image-type);
    }

    method data-uri is rw {
        Proxy.new(
            FETCH => sub ($) {
                $!data-uri //= do with $!source {
		    use Base64::Native;
		    my Str $bytes = .isa(Str)
			?? .substr(0)
			!! .path.IO.slurp(:enc<latin-1>);
		    my $enc = base64-encode($bytes, :str, :enc<latin-1>);
		    'data:image/%s;base64,%s'.sprintf($.image-type.lc, $enc);
		}
		else {
		    fail 'image is not associated with a source';
		}
            },
            STORE => sub ($, $!data-uri) {},
           )
    }

}
