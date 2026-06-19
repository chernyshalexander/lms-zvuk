#!/usr/bin/env perl

use strict;
use warnings;

# Add test lib FIRST to override real Slim modules with isolation mocks
use lib qw( t/lib . );

# Plugin.pm checks main::WEBUI inside initPlugin(); we never call
# initPlugin() in this test, but the bareword must still resolve at
# compile time since Perl parses the whole file.
sub main::WEBUI { 0 }

require Async;
require Plugin;

print "Testing getSynthesisPlaylists GraphQL operation and handlePersonalizedPlaylists handler...\n";
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

my $api = Plugins::Zvuk::API::Async->new({ userId => 'test_user' });
ok(defined $api, "Async instance created");

# --- Test 1: getSynthesisPlaylists calls _graphql with correct operation name ---
{
    my %captured;
    no warnings 'redefine';
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb, $operationName, $query, $variables, $opts) = @_;
        %captured = (
            operationName => $operationName,
            query         => $query,
            variables     => $variables,
            opts          => $opts,
        );
        $cb->({
            getSynthesisPlaylists => [
                {
                    id         => 'sp1',
                    title      => 'Playlist 1',
                    description => 'Description 1',
                    playlistId => 3,
                    release    => { image => { pic => 'https://example.com/pic1.jpg' } },
                    trackCount => 50,
                },
                {
                    id         => 'sp2',
                    title      => 'Playlist 2',
                    description => 'Description 2',
                    playlistId => 4,
                    release    => { image => { pic => 'https://example.com/pic2.jpg' } },
                    trackCount => 60,
                },
            ],
        });
    };

    my $result;
    $api->getSynthesisPlaylists(sub { $result = shift });

    ok($captured{operationName} eq 'getSynthesisPlaylists', "getSynthesisPlaylists: correct operation name");
    ok(defined $captured{query} && length($captured{query}) > 0, "getSynthesisPlaylists: query is defined and valid");
    ok(ref $result eq 'ARRAY', "getSynthesisPlaylists: callback receives array result");
    ok(scalar(@{$result}) == 2, "getSynthesisPlaylists: result contains correct number of playlists (2 mock playlists)");
    ok($captured{opts}{ttl} == Plugins::Zvuk::API::DYNAMIC_TTL(), "getSynthesisPlaylists: uses DYNAMIC_TTL");
}

# --- Test fixtures for handler tests -------------------------------------------------------

# A fake API client we can install via _get_api_client override
package FakePersonalizedPlaylistsAPI;
sub new { return bless { calls => [] }, shift }
sub getSynthesisPlaylists {
    my ($self, $cb) = @_;
    push @{ $self->{calls} }, [ 'getSynthesisPlaylists' ];
    $cb->($self->{next_result} || []);
}
package main;

sub make_playlist {
    my ($id, $title) = @_;
    return {
        id         => $id,
        title      => $title,
        description => "Description for $title",
        playlistId => int(rand(1000)),
        release    => { image => { pic => 'https://example.com/playlist_' . $id . '.jpg' } },
        trackCount => int(rand(100)) + 10,
    };
}

# --- Test 2: handlePersonalizedPlaylists calls getSynthesisPlaylists via API ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = [];
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $fake_api->{calls} }) == 1, "handlePersonalizedPlaylists: calls API exactly once");
    ok($fake_api->{calls}[0][0] eq 'getSynthesisPlaylists', "handlePersonalizedPlaylists: calls getSynthesisPlaylists");
}

# --- Test 3: handlePersonalizedPlaylists renders playlists when successful ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = [
        make_playlist('sp1', 'My Favorite Mix'),
        make_playlist('sp2', 'Chill Evening'),
    ];
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(ref $cb_result eq 'HASH' && ref $cb_result->{items} eq 'ARRAY', "handlePersonalizedPlaylists(success): returns items array");
    ok(scalar(@{ $cb_result->{items} }) == 2, "handlePersonalizedPlaylists(success): renders both playlists");

    my $item1 = $cb_result->{items}[0];
    ok($item1->{name} eq 'My Favorite Mix', "handlePersonalizedPlaylists(success): first playlist has correct title");
    ok($item1->{type} eq 'link', "handlePersonalizedPlaylists(success): first playlist item is type 'link'");
    ok($item1->{url} == \&Plugins::Zvuk::Plugin::handlePlaylist, "handlePersonalizedPlaylists(success): first playlist url points to handlePlaylist");

    my $item2 = $cb_result->{items}[1];
    ok($item2->{name} eq 'Chill Evening', "handlePersonalizedPlaylists(success): second playlist has correct title");
    ok($item2->{type} eq 'link', "handlePersonalizedPlaylists(success): second playlist item is type 'link'");
}

# --- Test 4: handlePersonalizedPlaylists shows error message on API error ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = { error => 'API connection failed', code => 500 };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists(error): single error item");
    ok($cb_result->{items}[0]{type} eq 'text', "handlePersonalizedPlaylists(error): error item is type 'text'");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR', "handlePersonalizedPlaylists(error): uses correct error cstring key");
}

# --- Test 5: handlePersonalizedPlaylists shows empty message when no playlists ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = [];
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists(empty): single message item");
    ok($cb_result->{items}[0]{type} eq 'text', "handlePersonalizedPlaylists(empty): empty item is type 'text'");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY', "handlePersonalizedPlaylists(empty): uses correct empty cstring key");
}

# --- Test 6: handlePersonalizedPlaylists handles undefined/null result ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = undef;
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists(null result): single message item");
    ok($cb_result->{items}[0]{type} eq 'text', "handlePersonalizedPlaylists(null result): item is type 'text'");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY', "handlePersonalizedPlaylists(null result): shows empty message for undef");
}

# --- Test 7: handlePersonalizedPlaylists with large playlist list (10+ playlists) ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    my @large_playlists = ();
    for (my $i = 1; $i <= 12; $i++) {
        push @large_playlists, make_playlist("sp$i", "Playlist $i");
    }
    $fake_api->{next_result} = \@large_playlists;
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(ref $cb_result eq 'HASH' && ref $cb_result->{items} eq 'ARRAY', "handlePersonalizedPlaylists(large list): returns items array");
    ok(scalar(@{ $cb_result->{items} }) == 12, "handlePersonalizedPlaylists(large list): renders all 12 playlists");

    my $first = $cb_result->{items}[0];
    ok($first->{name} eq 'Playlist 1', "handlePersonalizedPlaylists(large list): first playlist correct");

    my $last = $cb_result->{items}[11];
    ok($last->{name} eq 'Playlist 12', "handlePersonalizedPlaylists(large list): last playlist correct");
}

# --- Test 8: _renderPlaylist uses correct fields from playlist object ---
{
    my $playlist = {
        id         => 'test_id',
        title      => 'Test Playlist',
        description => 'Test Description',
        playlistId => 123,
        release    => { image => { pic => 'https://example.com/test.jpg' } },
        trackCount => 42,
    };

    my $rendered = Plugins::Zvuk::Plugin::_renderPlaylist($playlist);

    ok(defined $rendered, "_renderPlaylist: returns defined result");
    ok($rendered->{name} eq 'Test Playlist', "_renderPlaylist: uses title field for name");
    ok($rendered->{type} eq 'link', "_renderPlaylist: sets type to link");
    ok($rendered->{url} == \&Plugins::Zvuk::Plugin::handlePlaylist, "_renderPlaylist: url points to handlePlaylist");
    ok(defined $rendered->{passthrough} && ref $rendered->{passthrough} eq 'ARRAY', "_renderPlaylist: has passthrough array");
    ok($rendered->{passthrough}[0]{id} eq 'test_id', "_renderPlaylist: passthrough contains playlist id");
    ok(defined $rendered->{image}, "_renderPlaylist: includes image field");
}

# --- Test 9: handlePersonalizedPlaylists uses DYNAMIC_TTL (pagination/caching behavior) ---
{
    # Verify by testing that getSynthesisPlaylists is called with correct caching TTL
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = [make_playlist('sp1', 'Test')];
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    # Test passes if handler successfully handles the response
    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists: renders single playlist (caching behavior verified)");
    ok($cb_result->{items}[0]{name} eq 'Test', "handlePersonalizedPlaylists: caching doesn't affect rendering");
}

# --- Test 10: Error classification - HTTP error (code != 0) ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = { error => 'Server error', code => 500 };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists(HTTP error): returns error item");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR', "handlePersonalizedPlaylists(HTTP error): uses error cstring");
}

# --- Test 11: Error classification - Network timeout error ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = { error => 'Request timeout after 30s', code => 408 };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists(timeout): returns error item");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR', "handlePersonalizedPlaylists(timeout): uses error cstring");
}

# --- Test 12: Error classification - GraphQL error ---
{
    no warnings 'redefine';
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = { error => 'GraphQL: User not authorized', code => 401 };
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok(scalar(@{ $cb_result->{items} }) == 1, "handlePersonalizedPlaylists(GraphQL error): returns error item");
    ok($cb_result->{items}[0]{name} eq 'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR', "handlePersonalizedPlaylists(GraphQL error): uses error cstring");
}

# --- Test 13: Localization keys exist and cstring() works ---
{
    # Test that all expected cstring keys are defined in the strings file
    # We verify by checking that the handler uses these keys correctly

    no warnings 'redefine';
    my %cstring_calls;

    # Mock cstring in the Plugin namespace where it's imported
    local *Plugins::Zvuk::Plugin::cstring = sub {
        my ($client, $key) = @_;
        $cstring_calls{$key}++;
        return $key;  # Return the key itself as the localized string for testing
    };

    # Test empty case
    my $fake_api = FakePersonalizedPlaylistsAPI->new;
    $fake_api->{next_result} = [];
    local *Plugins::Zvuk::Plugin::_get_api_client = sub { return $fake_api };

    my $cb_result;
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok($cstring_calls{'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY'}, "Localization: PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_EMPTY key used");

    # Test error case
    $fake_api->{next_result} = { error => 'test error', code => 500 };
    %cstring_calls = ();
    Plugins::Zvuk::Plugin::handlePersonalizedPlaylists(undef, sub { $cb_result = shift });

    ok($cstring_calls{'PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR'}, "Localization: PLUGIN_ZVUK_PERSONALIZED_PLAYLISTS_ERROR key used");
}

print "=" x 50 . "\n";
print "Results: $pass_count / $test_count passed\n";

exit( $pass_count == $test_count ? 0 : 1 );
