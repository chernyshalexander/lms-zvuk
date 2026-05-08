#!/usr/bin/env perl

# Clear Zvuk plugin cache
# Usage: perl clear_cache.pl [--all]
#
# Without arguments: clears only Zvuk GraphQL cache (zvuk_gql:*)
# With --all: clears all Zvuk cache including metadata (zvuk_*)

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use lib "$FindBin::Bin/../slimserver/lib";

use Slim::Utils::Cache;
use Slim::Utils::DbCache;

my $clearAll = grep { $_ eq '--all' } @ARGV;

print "Clearing Zvuk cache...\n";

# Get default cache instance
my $cache = Slim::Utils::Cache->new();

# Access the underlying database
my $db = Slim::Utils::DbCache->new();

my $count = 0;
my $pattern = $clearAll ? 'zvuk_%' : 'zvuk_gql:%';

# Query cache entries matching pattern
my $sth = $db->dbh()->prepare(q{
    SELECT key FROM cache WHERE key LIKE ?
});
$sth->execute($pattern);

my @keys;
while (my ($key) = $sth->fetchrow_array()) {
    push @keys, $key;
}

# Remove matching keys
foreach my $key (@keys) {
    $cache->remove($key);
    $count++;
}

if ($clearAll) {
    print "✓ Cleared all Zvuk cache: $count entries removed\n";
    print "  (GraphQL cache + metadata cache)\n";
} else {
    print "✓ Cleared Zvuk GraphQL cache: $count entries removed\n";
    print "  (Use --all to also clear metadata cache)\n";
}

exit(0);
