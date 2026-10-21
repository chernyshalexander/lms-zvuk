#!/usr/bin/env perl
# Regression test for COMPARISON_REPORT.md P3.4.3: podcast episodes were
# rendered as type => 'text' (unplayable) and, once fixed to be playable
# zvuk://episode:<id> URLs, ProtocolHandler's ID-extraction regexes (which
# only matched bare zvuk://<digits>) would have silently failed to resolve
# them.
#
# Run: perl t/test_episode_playback.pl
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

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::ProtocolHandler;

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

# ---------------------------------------------------------------------
# _renderEpisode must produce a playable audio item, not a text item.
# ---------------------------------------------------------------------
{
    no strict 'refs';
    my $render = \&{'Plugins::Zvuk::Plugin::_renderEpisode'};
    my $item = $render->({
        id       => 42,
        title    => 'Episode Title',
        duration => 1234,
        podcast  => { id => 7, title => 'Podcast Title' },
    });

    ok($item->{type} eq 'audio', "_renderEpisode sets type => 'audio' (was 'text')");
    ok($item->{url} eq 'zvuk://episode:42', "_renderEpisode url is zvuk://episode:<id>");
    ok($item->{play} eq 'zvuk://episode:42', "_renderEpisode play is zvuk://episode:<id>");
}

# ---------------------------------------------------------------------
# ProtocolHandler must extract the numeric ID from both bare track URLs
# and typed episode URLs.
# ---------------------------------------------------------------------
{
    no strict 'refs';
    my $parse = \&{'Plugins::Zvuk::ProtocolHandler::_parseZvukId'};

    ok($parse->('zvuk://12345') eq '12345', "_parseZvukId parses bare track URL");
    ok($parse->('zvuk://episode:42') eq '42', "_parseZvukId parses zvuk://episode:<id>");
}

# ---------------------------------------------------------------------
# getFormatForURL must not exclude episode URLs (only container URLs
# like album:/playlist:/artist: that get exploded before playback).
# ---------------------------------------------------------------------
{
    my $fmt = Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://episode:42');
    ok(defined $fmt, "getFormatForURL returns a format for zvuk://episode:<id> (was excluded)");

    my $albumFmt = Plugins::Zvuk::ProtocolHandler->getFormatForURL('zvuk://album:42');
    ok(!defined $albumFmt, "getFormatForURL still excludes container URL zvuk://album:<id>");
}

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
