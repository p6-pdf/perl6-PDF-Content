use v6;
use Test;

# ensure consistant document ID generation
srand(123456);

use PDF::Graphics::Doc;
my $doc = PDF::Graphics::Doc.new;
my $page = $doc.add-page;
my $header-font = $page.core-font( :family<Helvetica>, :weight<bold> );

$page.text: -> $_ {
    .text-position = [200, 200];
    .set-font($header-font, 18);
    .say(:width(250),
	"Lorem ipsum dolor sit amet, consectetur adipiscing elit,
         sed do eiusmod tempor incididunt ut labore et dolore
         magna aliqua");
}

$page.graphics: -> $_ {
    my $img = .load-image: "t/images/basn0g01.png";
    .do($img, 100, 100);
}

lives-ok { $doc.save-as("t/doc.pdf") }, 'save-as';

done-testing;
