#!/usr/bin/env perl

use strict;
use warnings;

# Add test lib FIRST to override real Slim modules with isolation mocks
use lib qw( t/lib . );

# Plugin.pm checks main::WEBUI inside initPlugin(); we never call
# initPlugin() in this test, but the bareword must still resolve at
# compile time since Perl parses the whole file.
sub main::WEBUI { 0 }

require Plugin;

print "Testing GigaMix menu handlers in Plugin.pm...\n";
print "=" x 50 . "\n";

my $test_count = 0;
my $pass_count = 0;

sub ok {
    my ($cond, $name) = @_;
    $test_count++;
    if ($cond) {
        $pass_count++;
        print "  ok PASS: $name\n";
    } else {
        print "  NOT OK FAIL: $name\n";
    }
}

my $PKG = 'Plugins::Zvuk::Plugin';

# --- Test fixtures -------------------------------------------------------

# A fake API client we can install via _get_api_client override, so
# handlers never touch the network.
package FakeGigaMixAPI;
sub new { return bless { calls => [] }, shift }
sub getGenerativePlaylist {
    my ($self, $cb, $args) = @_;
    push @{ $self->{calls} }, [ 'getGenerativePlaylist', $args ];
    $cb->($self->{next_result} || {});
}
sub remakeGenerativePlaylist {
    my ($self, $cb, $args) = @_;
    push @{ $self->{calls} }, [ 'remakeGenerativePlaylist', $args ];
    $cb->($self->{next_result} || {});
}
sub getGenerativePlaylistPage {
    my ($self, $cb, $args) = @_;
    push @{ $self->{calls} }, [ 'getGenerativePlaylistPage', $args ];
    $cb->($self->{next_result} || {});
}
package main;

sub make_track {
    my ($id, $title) = @_;
    return {
        id             => $id,
        title          => $title,
        duration       => 123,
        artistTemplate => '',
        artists        => [ { id => 'a1', title => 'Some Artist' } ],
        release        => { id => 'r1', title => 'Some Album' },
        image          => { src => 'https://example.com/img.jpg' },
    };
}

# --- Test 1: handleGigaMix returns a single search menu item -------------
{
    no warnings 'redefine';
    my $cb_result;
    Plugins::Zvuk::Plugin::handleGigaMix(undef, sub { $cb_result = shift });

    ok(ref $cb_result eq 'HASH' && ref $cb_result->{items} eq 'ARRAY', "handleGigaMix: returns items array");
    ok(scalar(@{ $cb_result->{items} }) == 1, "handleGigaMix: exactly one menu item");

    my $item = $cb_result->{items}[0];
    ok($item->{name} eq 'PLUGIN_ZVUK_GIGAMIX_PROMPT', "handleGigaMix: uses cstring key for prompt name");
    ok($item->{type} eq 'search', "handleGigaMix: item type is 'search'");
    ok(ref $item->{url} eq 'CODE' && $item->{url} == \&Plugins::Zvuk::Plugin::handleGigaMixSearch, "handleGigaMix: url points to handleGigaMixSearch");
}

# --- Test 2: handleGigaMixSearch with empty prompt ------------------------
{
    no warnings 'redefine';
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { die "should not call API for empty prompt" };

    my $cb_result;
    Plugins::Zvuk::Plugin::handleGigaMixSearch(undef, sub { $cb_result = shift }, { search => '' });

    ok(ref $cb_result eq 'HASH', "handleGigaMixSearch(empty): returns hash");
    ok(scalar(@{ $cb_result->{items} }) == 1, "handleGigaMixSearch(empty): one item");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_GIGAMIX_EMPTY_PROMPT', "handleGigaMixSearch(empty): correct cstring key");

    # also test missing 'search' key entirely
    my $cb_result2;
    Plugins::Zvuk::Plugin::handleGigaMixSearch(undef, sub { $cb_result2 = shift }, {});
    ok($cb_result2->{items}[0]{name} eq 'PLUGIN_ZVUK_GIGAMIX_EMPTY_PROMPT', "handleGigaMixSearch(missing search key): correct cstring key");
}

# --- Test 3: handleGigaMixSearch with a real prompt -----------------------
{
    no warnings 'redefine';
    my $fake_api = FakeGigaMixAPI->new;
    $fake_api->{next_result} = {
        playlistName => 'Chill Vibes',
        tracks       => [ make_track('t1', 'Song 1'), make_track('t2', 'Song 2') ],
        cursor       => 'CURSOR1',
        genId        => 42,
    };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handleGigaMixSearch(undef, sub { $cb_result = shift }, { search => 'спокойная музыка' });

    ok(scalar(@{ $fake_api->{calls} }) == 1, "handleGigaMixSearch: calls API exactly once");
    ok($fake_api->{calls}[0][0] eq 'getGenerativePlaylist', "handleGigaMixSearch: calls getGenerativePlaylist");
    ok($fake_api->{calls}[0][1]{queryText} eq 'спокойная музыка', "handleGigaMixSearch: passes queryText");

    my $items = $cb_result->{items};
    ok($items->[0]{name} eq 'PLUGIN_ZVUK_GIGAMIX_PLAYLIST_TITLE: Chill Vibes', "handleGigaMixSearch: playlist title item formatted correctly");
    ok($items->[0]{type} eq 'text', "handleGigaMixSearch: playlist title type is 'text'");
    ok($items->[1]{type} eq 'separator', "handleGigaMixSearch: separator after title");
    ok($items->[2]{name} =~ /Song 1/, "handleGigaMixSearch: first track rendered");
    ok($items->[2]{type} eq 'audio', "handleGigaMixSearch: track rendered via _renderTrack (type audio)");
    ok($items->[3]{name} =~ /Song 2/, "handleGigaMixSearch: second track rendered");
    ok($items->[4]{type} eq 'separator', "handleGigaMixSearch: separator after tracks");

    my $remix = $items->[5];
    ok($remix->{name} eq 'PLUGIN_ZVUK_GIGAMIX_REMAKE', "handleGigaMixSearch: remix button label");
    ok($remix->{type} eq 'link', "handleGigaMixSearch: remix button type link");
    ok($remix->{url} == \&Plugins::Zvuk::Plugin::handleGigaMixRemake, "handleGigaMixSearch: remix button url");
    ok(ref $remix->{passthrough} eq 'ARRAY' && $remix->{passthrough}[0]{prompt} eq 'спокойная музыка', "handleGigaMixSearch: remix button passes prompt");

    my $next = $items->[6];
    ok($next->{name} eq 'NEXT_PAGE', "handleGigaMixSearch: next page button label");
    ok($next->{type} eq 'link', "handleGigaMixSearch: next page button type link");
    ok($next->{url} == \&Plugins::Zvuk::Plugin::handleGigaMixNextPage, "handleGigaMixSearch: next page button url");
    ok($next->{passthrough}[0]{cursor} eq 'CURSOR1' && $next->{passthrough}[0]{prompt} eq 'спокойная музыка', "handleGigaMixSearch: next page button passes cursor+prompt");

    ok(scalar(@$items) == 7, "handleGigaMixSearch: exactly 7 items (title, sep, 2 tracks, sep, remix, next)");
}

# --- Test 4: _renderGigaMixPlaylist with no cursor (no Next Page button) --
{
    my $cb_result;
    Plugins::Zvuk::Plugin::_renderGigaMixPlaylist(undef, sub { $cb_result = shift }, {
        playlistName => 'No Cursor Playlist',
        tracks       => [ make_track('t1', 'Solo Song') ],
        cursor       => undef,
        genId        => 1,
    }, 'some prompt');

    my $items = $cb_result->{items};
    ok(scalar(@$items) == 5, "_renderGigaMixPlaylist(no cursor): 5 items (title, sep, 1 track, sep, remix), no Next Page button");
    ok($items->[-1]{name} eq 'PLUGIN_ZVUK_GIGAMIX_REMAKE', "_renderGigaMixPlaylist(no cursor): last item is remix button");
}

# --- Test 5: _renderGigaMixPlaylist with no tracks ------------------------
{
    my $cb_result;
    Plugins::Zvuk::Plugin::_renderGigaMixPlaylist(undef, sub { $cb_result = shift }, {
        playlistName => 'Empty',
        tracks       => [],
        cursor       => undef,
    }, 'prompt with no results');

    ok(scalar(@{ $cb_result->{items} }) == 1, "_renderGigaMixPlaylist(no tracks): single message item");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_GIGAMIX_NO_RESULTS', "_renderGigaMixPlaylist(no tracks): correct cstring key");
}

# --- Test 6: handleGigaMixRemake ------------------------------------------
{
    no warnings 'redefine';
    my $fake_api = FakeGigaMixAPI->new;
    $fake_api->{next_result} = {
        playlistName => 'Remixed!',
        tracks       => [ make_track('t9', 'Remixed Song') ],
        cursor       => undef,
        genId        => 99,
    };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handleGigaMixRemake(undef, sub { $cb_result = shift }, {}, { prompt => 'original prompt' });

    ok(scalar(@{ $fake_api->{calls} }) == 1, "handleGigaMixRemake: calls API exactly once");
    ok($fake_api->{calls}[0][0] eq 'remakeGenerativePlaylist', "handleGigaMixRemake: calls remakeGenerativePlaylist");
    ok($fake_api->{calls}[0][1]{queryText} eq 'original prompt', "handleGigaMixRemake: passes original prompt as queryText");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_GIGAMIX_PLAYLIST_TITLE: Remixed!', "handleGigaMixRemake: renders new playlist via _renderGigaMixPlaylist");
}

# --- Test 7: handleGigaMixNextPage missing cursor -------------------------
{
    no warnings 'redefine';
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { die "should not call API without cursor" };

    my $cb_result;
    Plugins::Zvuk::Plugin::handleGigaMixNextPage(undef, sub { $cb_result = shift }, {}, { prompt => 'p' });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handleGigaMixNextPage(no cursor): single error item");
    ok($cb_result->{items}[0]{name} =~ /Error/i && $cb_result->{items}[0]{name} =~ /cursor/i, "handleGigaMixNextPage(no cursor): error mentions cursor");
}

# --- Test 8: handleGigaMixNextPage renders tracks only (no header) --------
{
    no warnings 'redefine';
    my $fake_api = FakeGigaMixAPI->new;
    $fake_api->{next_result} = {
        tracks => [ make_track('t10', 'Page 2 Song') ],
        cursor => 'CURSOR2',
    };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handleGigaMixNextPage(undef, sub { $cb_result = shift }, {}, { cursor => 'CURSOR1', prompt => 'p' });

    ok(scalar(@{ $fake_api->{calls} }) == 1, "handleGigaMixNextPage: calls API exactly once");
    ok($fake_api->{calls}[0][0] eq 'getGenerativePlaylistPage', "handleGigaMixNextPage: calls getGenerativePlaylistPage");
    ok($fake_api->{calls}[0][1]{cursor} eq 'CURSOR1', "handleGigaMixNextPage: passes cursor");
    ok($fake_api->{calls}[0][1]{limit} == 20, "handleGigaMixNextPage: passes limit=20");

    my $items = $cb_result->{items};
    ok($items->[0]{name} =~ /Page 2 Song/, "handleGigaMixNextPage: track item rendered");
    ok(!(grep { ($_->{name} // '') =~ /PLAYLIST_TITLE/ } @$items), "handleGigaMixNextPage: no playlist header rendered");
    my $next = $items->[-1];
    ok($next->{name} eq 'NEXT_PAGE', "handleGigaMixNextPage: includes Next Page button when cursor present");
    ok($next->{passthrough}[0]{cursor} eq 'CURSOR2' && $next->{passthrough}[0]{prompt} eq 'p', "handleGigaMixNextPage: next button passes new cursor + prompt");
}

# --- Test 9: handleGigaMixNextPage error handling in pagination -----------
{
	no warnings 'redefine';
	my $fake_api = FakeGigaMixAPI->new;
	$fake_api->{next_result} = { error => 'API failed' };
	local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

	my $cb_result;
	Plugins::Zvuk::Plugin::handleGigaMixNextPage(undef, sub { $cb_result = shift }, {}, { cursor => 'base64cursor123', prompt => 'test prompt' });

	ok($cb_result && $cb_result->{items}, "handleGigaMixNextPage(API error): returns items");
	ok(@{ $cb_result->{items} } == 1, "handleGigaMixNextPage(API error): error response is single item");
	ok($cb_result->{items}->[0]->{type} eq 'text', "handleGigaMixNextPage(API error): error item is type text");
	ok($cb_result->{items}->[0]->{name} eq 'PLUGIN_ZVUK_GIGAMIX_ERROR_LOAD_MORE', "handleGigaMixNextPage(API error): error message uses correct string key");
}

print "=" x 50 . "\n";
print "Results: $pass_count / $test_count passed\n";

exit( $pass_count == $test_count ? 0 : 1 );
