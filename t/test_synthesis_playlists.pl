#!/usr/bin/env perl
# Regression test for COMPARISON_REPORT.md P1.1: synthesis playlists
# ("Плейлисты для вас"). Verifies API/Async.pm::getSynthesisPlaylists/
# getShortPlaylists request the fixed ID set and correctly reshape the
# getPlaylists response / error into what Plugin.pm::handlePersonalizedPlaylists
# expects (an array on success, a {error=>...} hash on failure).
#
# _graphql itself (HTTP transport, throttling, retry, caching) is mocked out
# at the method boundary — it already has its own documented contract
# (API/Async.pm:87-99) and this test is about the shaping logic built on it.
#
# Run: perl t/test_synthesis_playlists.pl
use strict;
use warnings;
use utf8;
use open qw(:std :utf8);
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Test::More;

require "$Bin/slim_mocks.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::API::Async;

my $api = Plugins::Zvuk::API::Async->new({ userId => 'acctA' });

# ---------------------------------------------------------------------
# Success path: getPlaylists response is unwrapped into a bare array.
# ---------------------------------------------------------------------
{
    my @captured_args;
    no warnings 'redefine';
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb, $operationName, $query, $variables) = @_;
        @captured_args = ($operationName, $query, $variables);
        $cb->({ getPlaylists => [
            { id => 3, title => 'Синтез 1' },
            { id => 4, title => 'Синтез 2' },
        ] });
    };

    my $result;
    $api->getSynthesisPlaylists(sub { $result = shift });

    is($captured_args[0], 'getShortPlaylist', "operationName is 'getShortPlaylist'");
    is(ref($captured_args[2]{ids}), 'ARRAY', "variables.ids is an array ref");
    is_deeply($captured_args[2]{ids}, [3,4,6,11,12,13,14,15],
        "requests the fixed synthesis playlist ID set (3,4,6,11-15)");
    is(ref($result), 'ARRAY', "getSynthesisPlaylists returns a bare array on success");
    is(scalar(@$result), 2, "returns 2 playlists");
    is($result->[0]{title}, 'Синтез 1', "playlist metadata is passed through");
}

# ---------------------------------------------------------------------
# Error path: _graphql error hash is passed straight through untouched,
# so Plugin.pm::handlePersonalizedPlaylists's `ref $result eq 'HASH' &&
# $result->{error}` check still fires.
# ---------------------------------------------------------------------
{
    no warnings 'redefine';
    local *Plugins::Zvuk::API::Async::_graphql = sub {
        my ($self, $cb) = @_;
        $cb->({ error => 'No token' });
    };

    my $result;
    $api->getSynthesisPlaylists(sub { $result = shift });

    is(ref($result), 'HASH', "getSynthesisPlaylists returns hash on error");
    is($result->{error}, 'No token',
        "getSynthesisPlaylists propagates _graphql error hash unchanged");
}

done_testing();
