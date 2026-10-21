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
use Test::More;

require "$Bin/slim_mocks.pl";

my $repo_root = "$Bin/..";
my $tmpdir = tempdir(CLEANUP => 1);
mkdir "$tmpdir/Plugins" or die $!;
symlink($repo_root, "$tmpdir/Plugins/Zvuk") or die "symlink: $!";
unshift @INC, $tmpdir;

require Plugins::Zvuk::Plugin;
require Plugins::Zvuk::ProtocolHandler;

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

    is($item->{type}, 'audio', "_renderEpisode sets type => 'audio' (was 'text')");
    is($item->{url}, 'zvuk://episode:42', "_renderEpisode url is zvuk://episode:<id>");
    is($item->{play}, 'zvuk://episode:42', "_renderEpisode play is zvuk://episode:<id>");
}

# ---------------------------------------------------------------------
# ProtocolHandler must extract the numeric ID from both bare track URLs
# and typed episode URLs.
# ---------------------------------------------------------------------
{
    no strict 'refs';
    my $parse = \&{'Plugins::Zvuk::ProtocolHandler::_parseZvukId'};

    is($parse->('zvuk://12345'), '12345', "_parseZvukId parses bare track URL");
    is($parse->('zvuk://episode:42'), '42', "_parseZvukId parses zvuk://episode:<id>");
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

done_testing();
