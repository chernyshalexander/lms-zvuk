#!/usr/bin/env perl

use strict;
use warnings;

# Add test lib FIRST to override real Slim modules
use lib qw( t/lib . );

# Now require WaveSettings - it will use our mocks
require WaveSettings;

print "Testing WaveSettings module...\n";
print "=" x 50 . "\n";

my $test_count = 0;
my $pass_count = 0;

# Test 1: Load defaults
$test_count++;
print "Test 1: Load defaults for new account\n";
my $defaults = Plugins::Zvuk::WaveSettings::loadSettings('test_account_1');
if ($defaults &&
    $defaults->{popular} == 0.5 &&
    $defaults->{energy} == 0.5 &&
    $defaults->{fun} == 0.5 &&
    $defaults->{language} eq 'all' &&
    $defaults->{vocal} == 1) {
    print "  ✓ PASS: Defaults loaded correctly\n";
    $pass_count++;
} else {
    print "  ✗ FAIL: Defaults not as expected\n";
    if ($defaults) {
        print "    Popular: $defaults->{popular}\n";
        print "    Energy: $defaults->{energy}\n";
        print "    Fun: $defaults->{fun}\n";
        print "    Language: $defaults->{language}\n";
        print "    Vocal: $defaults->{vocal}\n";
    } else {
        print "    Defaults returned as undef\n";
    }
}

# Test 2: Get genres
$test_count++;
print "Test 2: Get genres list\n";
my $genres = Plugins::Zvuk::WaveSettings::getGenres();
if ($genres && ref $genres eq 'ARRAY' && @$genres == 11) {
    print "  ✓ PASS: Got 11 genres\n";
    $pass_count++;
} else {
    my $count = $genres && ref $genres eq 'ARRAY' ? scalar(@$genres) : 0;
    print "  ✗ FAIL: Expected 11 genres, got $count\n";
}

# Test 3: Save and reload settings
$test_count++;
print "Test 3: Save and reload custom settings\n";
my $test_settings = {
    popular => 0.3,
    energy => 0.7,
    fun => 0.6,
    language => 'foreign',
    vocal => 0,
    genres => ['rock', 'metal', 'electronic'],
};
Plugins::Zvuk::WaveSettings::saveSettings('test_account_2', $test_settings);
my $reloaded = Plugins::Zvuk::WaveSettings::loadSettings('test_account_2');

if ($reloaded &&
    $reloaded->{popular} == 0.3 &&
    $reloaded->{energy} == 0.7 &&
    $reloaded->{fun} == 0.6 &&
    $reloaded->{language} eq 'foreign' &&
    $reloaded->{vocal} == 0 &&
    @{$reloaded->{genres}} == 3) {
    print "  ✓ PASS: Settings saved and reloaded correctly\n";
    $pass_count++;
} else {
    print "  ✗ FAIL: Settings not preserved\n";
    if ($reloaded) {
        print "    Popular: $reloaded->{popular}\n";
        print "    Language: $reloaded->{language}\n";
        print "    Genres: " . scalar(@{$reloaded->{genres}}) . "\n";
    } else {
        print "    Reloaded settings are undef\n";
    }
}

# Test 4: Genre name conversion
$test_count++;
print "Test 4: Convert genre names to API format\n";
my $genre_names = ['rock', 'pop'];
my $converted = Plugins::Zvuk::WaveSettings::getGenreNames($genre_names);
if ($converted && ref $converted eq 'ARRAY' && @$converted == 2) {
    my $has_type = 1;
    foreach my $genre (@$converted) {
        if (!$genre->{type} || $genre->{type} ne 'LVL1') {
            $has_type = 0;
            last;
        }
    }
    if ($has_type) {
        print "  ✓ PASS: Genres converted to API format with type=LVL1\n";
        $pass_count++;
    } else {
        print "  ✗ FAIL: Genre type incorrect\n";
    }
} else {
    my $count = $converted && ref $converted eq 'ARRAY' ? scalar(@$converted) : 0;
    print "  ✗ FAIL: Genre conversion failed (got $count genres)\n";
}

# Summary
print "=" x 50 . "\n";
print "Results: $pass_count/$test_count tests passed\n";
if ($pass_count == $test_count) {
    print "✓ ALL TESTS PASSED\n";
    exit 0;
} else {
    print "✗ SOME TESTS FAILED\n";
    exit 1;
}
