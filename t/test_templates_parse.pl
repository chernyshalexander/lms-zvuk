#!/usr/bin/env perl
# Guards the plugin templates against the two ways they have broken the web UI:
#
#   1. A backslash-escaped quote inside a directive, e.g. [% \"KEY\" | string %].
#      Template Toolkit fails to parse the file and LMS serves an empty page.
#   2. Non-ASCII characters written literally in the .html file. The template
#      loader does not decode templates as UTF-8, so a typographic minus or a
#      Russian word reaches the browser double-encoded (mojibake) and never
#      matches the text it is compared against. Localised text belongs in
#      strings.txt and reaches the template through the `string` filter.
#
# Run: perl t/test_templates_parse.pl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use Test::More;

my $repo_root = "$Bin/..";

# LMS ships Template Toolkit under its own lib paths
my @libs = (
	'/usr/share/squeezeboxserver/CPAN',
	'/usr/share/squeezeboxserver/lib',
	'/usr/local/share/squeezeboxserver/CPAN',
	'/usr/local/share/squeezeboxserver/lib',
);
unshift @INC, grep { -d $_ } @libs;

my $have_parser = eval { require Template::Parser; 1 };
plan skip_all => 'Template::Parser is not available (LMS not installed)' unless $have_parser;

my $parser = Template::Parser->new({
	FILTERS => { string => sub { my $s = shift; return $s } },
});

my @templates = sort glob("$repo_root/HTML/EN/plugins/zvuk/*.html"),
	sort glob("$repo_root/HTML/EN/plugins/zvuk/*.js"),
	sort glob("$repo_root/HTML/EN/plugins/zvuk/settings/*.html");

ok(@templates > 0, 'found templates to check');

for my $path (@templates) {
	(my $name = $path) =~ s{^\Q$repo_root\E/}{};

	open my $fh, '<:raw', $path or do { fail("$name: cannot read"); next };
	my $bytes = do { local $/; <$fh> };
	close $fh;

	# 1. non-ASCII bytes: the loader will mangle them
	my @offending;
	while ($bytes =~ /([\x80-\xFF])/g) {
		my $pos = pos($bytes);
		my $line = 1 + (substr($bytes, 0, $pos) =~ tr/\n//);
		push @offending, $line;
	}
	is(scalar(@offending), 0, "$name: ASCII only (mojibake-free)")
		or diag "non-ASCII on line(s): " . join(',', @offending);

	# 2. the file must compile as a Template Toolkit document
	my $src = $bytes;
	utf8::decode($src) unless utf8::is_utf8($src);
	my $doc = $parser->parse($src);
	ok($doc, "$name: parses as a template")
		or diag $parser->error;
}

# A directive with an escaped quote is exactly what broke the page before
{
	my $broken = 'var x = "[% \"KEY\" | string %]";';
	my $doc = $parser->parse($broken);
	ok(!$doc, 'parser rejects a backslash-escaped quote inside a directive (guard works)');
}

done_testing();
