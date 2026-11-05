#!/usr/bin/env perl
# Regression test: context-menu "Search <artist/album/track>" must carry the
# search term to the search handlers.
#
# Root cause this guards against: LMS XMLBrowser invokes coderef feed URLs as
#   $subFeed->{url}->( $client, $callback, \%args, @{passthrough} )
# (Slim/Control/XMLBrowser.pm:529). The info-menu search items pass
# passthrough => [{ search => $title }], i.e. ONE extra positional argument --
# a hashref. The handlers (searchTracks/searchArtists/searchAlbums) declared
# only ($client, $cb, $args), so the hashref was discarded and $args->{search}
# was undef -> GraphQL search with an empty query -> "empty" result list.
# The NEXT_PAGE link inside search results used the same broken pattern.
#
# Run: perl t/test_context_search.pl
use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/slim_mocks.pl";
require "$Bin/test_helpers.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::UI::InfoMenu;
require Plugins::Zvuk::API::Async;

my $client = Test::FakeClient->new(id => 'player1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{'_ts_userId'} = time();
}

# ---- capture what the search handlers ask the API for ----
my @api_calls;
my $fixture = {
	search => {
		tracks => {
			items => [ { id => '111', title => 'Danse', duration => 305,
				artists => [{ id => '7', title => 'Debussy' }],
				release => { id => '99', title => 'I grandi successi' } } ],
			page => { total => 1, next => undef },
		},
		artists => {
			items => [ { id => '7', title => 'Claude Debussy' } ],
			page => { total => 1, next => undef },
		},
		releases => {
			items => [ { id => '99', title => 'I grandi successi', type => 'album' } ],
			page => { total => 1, next => undef },
		},
	},
};

no warnings 'redefine';
local *Plugins::Zvuk::API::Async::search = sub {
	my ($self, $cb, $vars) = @_;
	push @api_calls, $vars;
	$cb->($fixture);
};
use warnings 'redefine';

# ---- build the real context menu (wiring covered end-to-end) ----
my $menu = Plugins::Zvuk::UI::InfoMenu::trackInfoMenu($client, 'zvuk://10298243', undef, {
	track  => 'Danse',
	artist => 'Claude Debussy',
	album  => 'I grandi successi',
});
ok($menu, 'trackInfoMenu returned a menu');

my $search_outline;
for my $it (@{ $menu->{items} }) {
	$search_outline = $it if ($it->{type} || '') eq 'outline' && ($it->{name} || '') eq 'SEARCH';
}
ok($search_outline, 'context menu contains a SEARCH outline');
my @search_items = @{ $search_outline->{items} };
is(scalar(@search_items), 3, 'SEARCH outline has artist/album/track items');

# ---- invoke each item exactly as XMLBrowser does (XMLBrowser.pm:529) ----
my %want = (
	ARTISTS => 'Claude Debussy',
	ALBUMS  => 'I grandi successi',
);

for my $item (@search_items) {
	my $name = $item->{name} || '';
	my ($section) = map { $name =~ /\Q$_\E/ ? $_ : () } keys %want;
	next unless $section;

	my ($result, $done);
	# \args mimics the framework's args hash: NO 'search' key in it.
	my %args = ( item => $item, feedTitle => 'Search', isControl => 1 );
	$item->{url}->($client, sub { $result = shift; $done = 1 }, \%args, @{ $item->{passthrough} });

	ok($done, "search item '$section' invoked its feed");
	ok($result && @{ $result->{items} || [] }, "search item '$section' returns non-empty items");

	my $vars = pop @api_calls;
	is($vars->{query}, $want{$section}, "search item '$section' passes query='$want{$section}' to the API");
}

# ---- section flags: track search enables tracks only ----
{
	my $track_item = (grep { ($_->{name} || '') =~ /SONGS/ } @search_items)[0];
	ok($track_item, 'track search item exists');

	my ($result, $done);
	my %args = ( item => $track_item, feedTitle => 'Search', isControl => 1 );
	$track_item->{url}->($client, sub { $result = shift; $done = 1 }, \%args, @{ $track_item->{passthrough} });

	my $vars = pop @api_calls;
	is($vars->{query}, 'Danse', 'track search passes query=Danse');
	ok($vars->{tracks}, 'track search enables tracks section');
	ok(!$vars->{artists} && !$vars->{releases} && !$vars->{playlists}, 'track search disables other sections');
	is($result->{items}[0]{name}, 'Danse - Debussy', 'track search renders the fixture track');
}

# ---- NEXT_PAGE passthrough carries search term + cursor ----
{
	my $paged_fixture = {
		search => {
			tracks => {
				items => [],
				page  => { total => 10, next => 'CURSOR_2' },
			},
		},
	};
	no warnings 'redefine';
	local *Plugins::Zvuk::API::Async::search = sub {
		my ($self, $cb, $vars) = @_;
		push @api_calls, $vars;
		$cb->($paged_fixture);
	};
	use warnings 'redefine';

	my $track_item = (grep { ($_->{name} || '') =~ /SONGS/ } @search_items)[0];
	my ($result1);
	my %args1 = ( item => $track_item, feedTitle => 'Search', isControl => 1 );
	$track_item->{url}->($client, sub { $result1 = shift }, \%args1, @{ $track_item->{passthrough} });

	my $next = (grep { ($_->{name} || '') eq 'NEXT_PAGE' } @{ $result1->{items} })[0];
	ok($next, 'NEXT_PAGE link present when page.next exists');

	my ($result2, $done2);
	my %args2 = ( item => $next, feedTitle => 'Search', isControl => 1 );
	$next->{url}->($client, sub { $result2 = shift; $done2 = 1 }, \%args2, @{ $next->{passthrough} });

	my $vars = pop @api_calls;
	ok($done2, 'NEXT_PAGE invoked its feed');
	is($vars->{query}, 'Danse', 'NEXT_PAGE keeps the original search term');
	is($vars->{trackCursor}, 'CURSOR_2', 'NEXT_PAGE passes the next cursor');
	# empty item list + page.next => result is exactly the NEXT_PAGE link again
	is(scalar @{ $result2->{items} }, 1, 'empty second page renders without dying');
	is(($result2->{items}[0]{name} || ''), 'NEXT_PAGE', 'second page carries the NEXT_PAGE link');
}

done_testing();
