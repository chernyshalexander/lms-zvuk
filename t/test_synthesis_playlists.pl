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
use FindBin qw($Bin);
use File::Temp qw(tempdir);

require "$Bin/slim_mocks.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::API::Async;

my $failures = 0;
sub ok {
    my ($cond, $desc) = @_;
    if ($cond) {
        print "ok - $desc\n";
    } else {
        print "NOT OK - $desc\n";
        $failures++;
    }
}

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

    ok($captured_args[0] eq 'getShortPlaylist', "operationName is 'getShortPlaylist'");
    ok($captured_args[2]{ids} && ref($captured_args[2]{ids}) eq 'ARRAY',
        "variables.ids is an array ref");
    ok(join(',', @{ $captured_args[2]{ids} }) eq '3,4,6,11,12,13,14,15',
        "requests the fixed synthesis playlist ID set (3,4,6,11-15)");
    ok(ref $result eq 'ARRAY' && scalar(@$result) == 2,
        "getSynthesisPlaylists returns a bare array on success");
    ok($result->[0]{title} eq 'Синтез 1', "playlist metadata is passed through");
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

    ok(ref $result eq 'HASH' && $result->{error} eq 'No token',
        "getSynthesisPlaylists propagates _graphql error hash unchanged");
}

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
