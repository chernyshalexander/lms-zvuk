#!/usr/bin/env perl

use strict;
use warnings;

# Add test lib FIRST to override real Slim modules with isolation mocks
use lib qw( t/lib . );

require Async;

print "Testing GigaMix GraphQL operations in API::Async...\n";
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

# --- Test 1: getGenerativePlaylist exists and builds correct request ---
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
            getGenerativePlaylist => {
                cursor       => 'CURSOR1',
                playlistName => 'Chill Vibes',
                genId        => 42,
                tracks       => [
                    { id => 't1', title => 'Song 1', artistTemplate => '', artists => [], release => {}, image => { src => 'https://example.com/t1.jpg' } },
                ],
            },
        });
    };

    my $result;
    $api->getGenerativePlaylist(sub { $result = shift }, { queryText => 'спокойная музыка', promptUuid => undef });

    ok($captured{operationName} eq 'getGenerativePlaylist', "getGenerativePlaylist: correct operation name");
    ok($captured{variables}{queryText} eq 'спокойная музыка', "getGenerativePlaylist: queryText passed");
    ok(exists $captured{variables}{promptUuid}, "getGenerativePlaylist: promptUuid passed (even if undef)");
    ok($captured{query} =~ /getGenerativePlaylist\(\$queryText: String!, \$promptUuid: String\)/, "getGenerativePlaylist: query has correct variable signature");
    ok($captured{query} =~ /cursor/ && $captured{query} =~ /playlistName/ && $captured{query} =~ /genId/, "getGenerativePlaylist: query requests cursor/playlistName/genId");
    ok($captured{query} =~ /hasFlac/ && $captured{query} =~ /availability/ && $captured{query} =~ /artistTemplate/, "getGenerativePlaylist: track fields present");
    ok($captured{opts}{ttl} == Plugins::Zvuk::API::DYNAMIC_TTL(), "getGenerativePlaylist: uses DYNAMIC_TTL");
    ok($result->{playlistName} eq 'Chill Vibes', "getGenerativePlaylist: callback receives playlistName");
    ok($result->{genId} == 42, "getGenerativePlaylist: callback receives genId");
    ok($result->{cursor} eq 'CURSOR1', "getGenerativePlaylist: callback receives cursor");
    ok(ref $result->{tracks} eq 'ARRAY' && scalar(@{$result->{tracks}}) == 1, "getGenerativePlaylist: callback receives tracks array");

    # Metadata caching: verify cached entry now exists for the track
    my $cached = Plugins::Zvuk::API->cache->get('zvuk_meta_t1');
    ok(defined $cached && $cached->{title} eq 'Song 1', "getGenerativePlaylist: track metadata cached");
}

# --- Test 2: getGenerativePlaylistPage requires cursor ---
{
    my $called_graphql = 0;
    no warnings 'redefine';
    local *Plugins::Zvuk::API::Async::_graphql = sub { $called_graphql++; };

    my $result;
    $api->getGenerativePlaylistPage(sub { $result = shift }, { limit => 20 }); # no cursor

    ok($called_graphql == 0, "getGenerativePlaylistPage: does not call _graphql without cursor");
    ok($result->{error} eq 'no_cursor', "getGenerativePlaylistPage: returns no_cursor error when cursor missing");
}

# --- Test 3: getGenerativePlaylistPage with cursor ---
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
            getGenerativePlaylistPagination => {
                cursor => 'CURSOR2',
                tracks => [
                    { id => 't2', title => 'Song 2', artistTemplate => '', artists => [], release => {}, image => { src => 'https://example.com/t2.jpg' } },
                ],
            },
        });
    };

    my $result;
    $api->getGenerativePlaylistPage(sub { $result = shift }, { limit => 10, cursor => 'CURSOR1' });

    ok($captured{operationName} eq 'getGenerativePlaylistPagination', "getGenerativePlaylistPage: correct operation name");
    ok($captured{variables}{cursor} eq 'CURSOR1', "getGenerativePlaylistPage: cursor passed");
    ok($captured{variables}{limit} == 10, "getGenerativePlaylistPage: limit passed");
    ok($captured{query} =~ /getGenerativePlaylistPagination\(limit: \$limit, cursor: \$cursor\)/, "getGenerativePlaylistPage: query calls getGenerativePlaylistPagination field");
    ok($captured{opts}{ttl} == Plugins::Zvuk::API::DYNAMIC_TTL(), "getGenerativePlaylistPage: uses DYNAMIC_TTL");
    ok($result->{cursor} eq 'CURSOR2', "getGenerativePlaylistPage: callback receives cursor");
    ok(ref $result->{tracks} eq 'ARRAY' && scalar(@{$result->{tracks}}) == 1, "getGenerativePlaylistPage: callback receives tracks");
    ok(!exists $result->{playlistName}, "getGenerativePlaylistPage: no playlistName in result (page response only has cursor/tracks)");
}

# --- Test 4: getGenerativePlaylistPage default limit ---
{
    my %captured;
    no warnings 'redefine';
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb, $operationName, $query, $variables, $opts) = @_;
        %captured = ( variables => $variables );
        $cb->({ getGenerativePlaylistPagination => { cursor => undef, tracks => [] } });
    };

    $api->getGenerativePlaylistPage(sub {}, { cursor => 'X' });
    ok($captured{variables}{limit} == 20, "getGenerativePlaylistPage: defaults limit to 20");
}

# --- Test 5: remakeGenerativePlaylist ---
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
            remakeGenerativePlaylist => {
                cursor       => 'CURSOR3',
                playlistName => 'Chill Vibes Remix',
                genId        => 43,
                tracks       => [
                    { id => 't3', title => 'Song 3', artistTemplate => '', artists => [], release => {}, image => { src => 'https://example.com/t3.jpg' } },
                ],
            },
        });
    };

    my $result;
    $api->remakeGenerativePlaylist(sub { $result = shift }, { queryText => 'спокойная музыка' });

    ok($captured{operationName} eq 'remakeGenerativePlaylist', "remakeGenerativePlaylist: correct operation name");
    ok($captured{variables}{queryText} eq 'спокойная музыка', "remakeGenerativePlaylist: queryText passed");
    ok($captured{query} =~ /remakeGenerativePlaylist\(\$queryText: String!\)/, "remakeGenerativePlaylist: query has correct variable signature");
    ok($captured{opts}{ttl} == Plugins::Zvuk::API::DYNAMIC_TTL(), "remakeGenerativePlaylist: uses DYNAMIC_TTL");
    ok($result->{playlistName} eq 'Chill Vibes Remix', "remakeGenerativePlaylist: callback receives playlistName");
    ok($result->{genId} == 43, "remakeGenerativePlaylist: callback receives genId");
    ok(ref $result->{tracks} eq 'ARRAY' && scalar(@{$result->{tracks}}) == 1, "remakeGenerativePlaylist: callback receives tracks");
}

# --- Test 6: error propagation ---
{
    no warnings 'redefine';
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb, $operationName, $query, $variables, $opts) = @_;
        $cb->({ error => 'some_api_error' });
    };

    my $result;
    $api->getGenerativePlaylist(sub { $result = shift }, { queryText => 'test' });
    ok($result->{error} eq 'some_api_error', "getGenerativePlaylist: propagates error from _graphql");

    $result = undef;
    $api->remakeGenerativePlaylist(sub { $result = shift }, { queryText => 'test' });
    ok($result->{error} eq 'some_api_error', "remakeGenerativePlaylist: propagates error from _graphql");

    $result = undef;
    $api->getGenerativePlaylistPage(sub { $result = shift }, { cursor => 'X' });
    ok($result->{error} eq 'some_api_error', "getGenerativePlaylistPage: propagates error from _graphql");
}

print "=" x 50 . "\n";
print "Results: $pass_count / $test_count passed\n";

exit( $pass_count == $test_count ? 0 : 1 );
