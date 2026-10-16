#!/usr/bin/env perl
# Unit test for cacheTrackMetadata batch caching.
# Verifies that cached items do not cause premature return from the subroutine,
# and all tracks in the batch are properly cached and returned.
#
# Run: perl t/test_cache_batch.pl
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
require Plugins::Zvuk::API;

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

{
    no warnings 'once';
    %Slim::Utils::Cache::CACHE = ();
}

# Test batch 1: fresh tracks
my $batch1 = [
    { id => 101, title => 'Track 101', duration => 180, artists => [{ title => 'Artist A' }] },
    { id => 102, title => 'Track 102', duration => 200, artists => [{ title => 'Artist B' }] },
    { id => 103, title => 'Track 103', duration => 220, artists => [{ title => 'Artist C' }] },
];

my $res1 = Plugins::Zvuk::API->cacheTrackMetadata($batch1);
ok(ref($res1) eq 'ARRAY', "cacheTrackMetadata returns an array ref");
ok(scalar(@$res1) == 3, "Batch 1 returned all 3 tracks");
ok($res1->[0]{title} eq 'Track 101', "Track 101 title is correct");
ok($res1->[1]{title} eq 'Track 102', "Track 102 title is correct");
ok($res1->[2]{title} eq 'Track 103', "Track 103 title is correct");

# Test batch 2: contains track 102 (already cached in batch 1) in the middle
my $batch2 = [
    { id => 104, title => 'Track 104', duration => 190, artists => [{ title => 'Artist D' }] },
    { id => 102, title => 'Track 102', duration => 200, artists => [{ title => 'Artist B' }] }, # cached!
    { id => 105, title => 'Track 105', duration => 210, artists => [{ title => 'Artist E' }] }, # must not be skipped!
];

my $res2 = Plugins::Zvuk::API->cacheTrackMetadata($batch2);
ok(ref($res2) eq 'ARRAY', "Batch 2 with cached item still returns an array ref (not single item)");
ok(scalar(@$res2) == 3, "Batch 2 returned all 3 tracks despite cached item in middle");
ok($res2->[0]{id} == 104, "Track 104 is present");
ok($res2->[1]{id} == 102, "Track 102 is retrieved from cache");
ok($res2->[2]{id} == 105, "Track 105 was processed and not aborted");

# Verify track 105 is indeed in cache
my $cached_105 = Plugins::Zvuk::API->cache->get("zvuk_meta_105");
ok(defined $cached_105 && $cached_105->{title} eq 'Track 105', "Track 105 was properly cached");

print "\n" . ($failures ? "$failures assertion(s) FAILED\n" : "All assertions passed\n");
exit($failures ? 1 : 0);
