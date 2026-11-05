#!/usr/bin/env perl
# Covers the genre catalog and the two-level genre menu.
#
# Contract under test:
#   - every catalog entry carries name/label/family/level, and every family has
#     at least one genre;
#   - getGenreNames() sends the level stored in the catalog, not a hardcoded
#     LVL1: a sub-genre sent as LVL1 is silently ignored by the Zvuk recommender;
#   - loadSettings() drops slugs that are not in the catalog;
#   - the native menu has a family level and a family-local genre level, and a
#     toggle returns into the same family.
#
# Run: perl t/test_wave_genre_catalog.pl
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

require Plugins::Zvuk::WaveSettings;
require Plugins::Zvuk::UI::Wave;
require Plugins::Zvuk::Plugin;

my $client = Test::FakeClient->new(id => 'player1');
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{accounts} = { acctA => { token => 'tokA', name => 'A' } };
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{userId} = 'acctA';
	$Slim::Utils::Prefs::CLIENT_STORE{'plugin.zvuk'}{ $client->id }{'_ts_userId'} = time();
}

# --- catalog shape -------------------------------------------------------
my $genres    = Plugins::Zvuk::WaveSettings::getGenres();
my $families  = Plugins::Zvuk::WaveSettings::getFamilies();

ok(@$genres > 100, 'catalog has more than 100 genres (' . scalar(@$genres) . ')');
is(scalar(@$families), 7, 'seven families');

my @bad;
my %seen;
for my $g (@$genres) {
	ok($g->{name}, "genre has a slug") if !$g->{name};
	push @bad, $g->{name} unless $g->{name} && $g->{label} && $g->{family} && $g->{level};
	$seen{ $g->{name} }++;
}
is(scalar(@bad), 0, 'every genre has name/label/family/level')
	or diag "incomplete: @bad";

my @dupes = grep { $seen{$_} > 1 } keys %seen;
is(scalar(@dupes), 0, 'no duplicate slugs') or diag "dupes: @dupes";

for my $f (@$families) {
	my $items = Plugins::Zvuk::WaveSettings::getGenresByFamily($f->{id});
	ok(@$items > 0, "family $f->{id} is not empty");
}
is_deeply(Plugins::Zvuk::WaveSettings::getGenresByFamily('no_such_family'), [],
	'unknown family returns an empty list');

# unknown slugs are ignored by the API mapping
my $names = Plugins::Zvuk::WaveSettings::getGenreNames(['metal', 'nope', 'chillwave']);
is(scalar(@$names), 2, 'getGenreNames drops unknown slugs');

# --- levels --------------------------------------------------------------
my %level = map { $_->{name} => $_->{level} } @$genres;
is($level{metal}, 'LVL1', 'metal is LVL1');
is($level{disco}, 'LVL2', 'disco is LVL2');
is($level{chillwave}, 'LVL3', 'chillwave is LVL3');

my ($metal) = grep { $_->{name} eq 'metal' } @{ Plugins::Zvuk::WaveSettings::getGenreNames(['metal']) };
is($metal->{type}, 'LVL1', 'metal goes to the API as LVL1');

my ($chill) = grep { $_->{name} eq 'chillwave' } @{ Plugins::Zvuk::WaveSettings::getGenreNames(['chillwave']) };
is($chill->{type}, 'LVL3', 'chillwave goes to the API as LVL3, not LVL1');

my ($trip) = @{ Plugins::Zvuk::WaveSettings::getGenreNames(['trip_hop']) };
is($trip->{type}, 'LVL3', 'trip_hop goes to the API as LVL3');

# --- collapsing a fully selected family --------------------------------
my @jazz_members = map { $_->{name} } @{ Plugins::Zvuk::WaveSettings::getGenresByFamily('jazz') };
ok(@jazz_members > 1, 'jazz family has several members');

my $full = Plugins::Zvuk::WaveSettings::getGenreNames(\@jazz_members);
is(scalar(@$full), 1, 'a fully selected family collapses to a single entry');
is($full->[0]{name}, 'jazz', 'collapsed entry uses the family slug');
is($full->[0]{type}, 'LVL1', 'collapsed entry uses the family level');

my $partial = Plugins::Zvuk::WaveSettings::getGenreNames([ $jazz_members[0], $jazz_members[1] ]);
is(scalar(@$partial), 2, 'a partially selected family keeps its genres');
is_deeply([ map { $_->{name} } @$partial ], [ $jazz_members[0], $jazz_members[1] ],
	'partial family sends exactly the chosen genres');

# two full families collapse independently
my @world_members = map { $_->{name} } @{ Plugins::Zvuk::WaveSettings::getGenresByFamily('world') };
my $two = Plugins::Zvuk::WaveSettings::getGenreNames([ @jazz_members, @world_members ]);
is(scalar(@$two), 2, 'two fully selected families collapse to two entries');
is_deeply([ map { $_->{name} } @$two ], [ 'jazz', 'world' ],
	'each family collapses to its own slug in selection order');
my ($world_entry) = grep { $_->{name} eq 'world' } @$two;
is($world_entry->{type}, 'LVL3', 'world family collapses at its own level (LVL3)');

# --- settings sanitising -------------------------------------------------
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{'wave_settings_acctA'} = {
		popular => 0.5, energy => 0.5, fun => 0.5, language => 'all', vocal => 1,
		genres  => [ 'metal', 'not_a_genre', '${genre.name}', '', 'chillwave' ],
	};
}
my $loaded = Plugins::Zvuk::WaveSettings::loadSettings('acctA');
is_deeply($loaded->{genres}, [ 'metal', 'chillwave' ],
	'loadSettings keeps catalog slugs and drops junk');

# --- catalog payload -----------------------------------------------------
my $catalog = Plugins::Zvuk::WaveSettings::getCatalog();
my ($first) = grep { $_->{name} eq 'metal' } @$catalog;
ok($first->{label}, 'catalog entry carries a resolved label');
is($first->{family}, 'rock', 'catalog entry carries its family');
ok($first->{family_label}, 'catalog entry carries the resolved family label');

my $grouped = Plugins::Zvuk::WaveSettings::getCatalogByFamily(undef, ['chillwave']);
my ($electron) = grep { $_->{id} eq 'electronic' } @$grouped;
my ($chill_in_family) = grep { $_->{name} eq 'chillwave' } @{ $electron->{genres} };
ok($chill_in_family, 'getCatalogByFamily returns the genre inside its family');
ok($chill_in_family->{selected}, 'getCatalogByFamily marks the selected genre');

# --- native two-level menu ----------------------------------------------
my $family_menu;
Plugins::Zvuk::UI::Wave::handleGenresMenu($client, sub { $family_menu = shift }, {});
ok($family_menu, 'handleGenresMenu returned a menu');
my @family_items = @{ $family_menu->{items} };
is(scalar(@family_items), 8, 'family menu has 7 families plus Back');
is($family_items[0]{url}, \&Plugins::Zvuk::UI::Wave::handleGenreFamily,
	'family item points at handleGenreFamily');
is_deeply($family_items[0]{passthrough}, [ { family => 'rock' } ],
	'family item passes the family id');
is($family_items[-1]{name}, 'PLUGIN_ZVUK_BACK', 'last item is Back');

# selected count is visible in the family row
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{'wave_settings_acctA'}{genres}
		= [ 'chillwave', 'city_pop' ];
}
my $menu2;
Plugins::Zvuk::UI::Wave::handleGenresMenu($client, sub { $menu2 = shift }, {});
my ($electro_row) = grep { ($_->{name} || '') =~ /^\[x\]/ && ($_->{passthrough}[0]{family} || '') eq 'electronic' }
	@{ $menu2->{items} };
ok($electro_row, 'family row is marked and carries a count when it has selections');
like($electro_row->{name}, qr/\(1\)/, 'family row shows how many genres are selected');

# second level
my $family_menu2;
Plugins::Zvuk::UI::Wave::handleGenreFamily($client, sub { $family_menu2 = shift }, {},
	{ family => 'electronic' });
ok($family_menu2, 'handleGenreFamily returned a menu');
my @genre_items = @{ $family_menu2->{items} };
my @checks = grep { ($_->{passthrough}[0]{genre} || '') } @genre_items;
ok(@checks > 1, 'family menu lists several genres');
is($genre_items[-1]{url}, \&Plugins::Zvuk::UI::Wave::handleGenresMenu,
	'family menu returns to the family list');

my ($chill_row) = grep { ($_->{passthrough}[0]{genre} || '') eq 'chillwave' } @genre_items;
is($chill_row->{passthrough}[0]{family}, 'electronic',
	'genre item carries the family so a toggle can return here');
like($chill_row->{name}, qr/^\[x\]/, 'selected genre is checked');
my ($city_row) = grep { ($_->{passthrough}[0]{genre} || '') eq 'city_pop' } @genre_items;
ok(!$city_row, 'city_pop is not listed under electronic');

# unknown family falls back to the family list instead of an empty screen
my $fallback;
Plugins::Zvuk::UI::Wave::handleGenreFamily($client, sub { $fallback = shift }, {},
	{ family => 'nope' });
is(scalar(@{ $fallback->{items} }), 8, 'unknown family falls back to the family menu');

# --- toggle returns into the same family --------------------------------
{
	no warnings 'once';
	$Slim::Utils::Prefs::STORE{'plugin.zvuk'}{'wave_settings_acctA'}{genres} = [ 'chillwave' ];
}
my $after;
Plugins::Zvuk::UI::Wave::handleGenreToggle($client, sub { $after = shift }, {},
	{ genre => 'city_pop', family => 'pop' });
my @after_items = @{ $after->{items} };
my @after_genres = grep { ($_->{passthrough}[0]{genre} || '') } @after_items;
my ($city_after) = grep { ($_->{passthrough}[0]{genre} || '') eq 'city_pop' } @after_items;
ok($city_after, 'after a toggle the menu is still the same family');
like($city_after->{name}, qr/^\[x\]/, 'toggled genre is now checked');

my $saved = $Slim::Utils::Prefs::STORE{'plugin.zvuk'}{'wave_settings_acctA'}{genres};
ok((grep { $_ eq 'city_pop' } @$saved), 'toggle persisted the genre');

# --- web payload ---------------------------------------------------------
subtest 'web JSON contract' => sub {
	require Plugins::Zvuk::WebHandlers;
	my $req  = Test::FakeRequest->new();
	my $resp = Test::FakeResponse->new($req);

	@Slim::Web::HTTP::CAPTURED_RESPONSES = ();
	Plugins::Zvuk::WebHandlers::handleGetWaveSettingsWeb(undef, $resp);
	is($resp->code(), 200, 'getWaveSettings returns 200');

	my $body = $Slim::Web::HTTP::CAPTURED_RESPONSES[0]{body} || '';
	like($body, qr/"family":"rock"/, 'genres carry the family');
	like($body, qr/"level":"LVL3"/, 'genres carry the level');
	like($body, qr/"families":/, 'a grouped families list is exposed');
	like($body, qr/"family_label"/, 'family labels are resolved');
};

done_testing();
