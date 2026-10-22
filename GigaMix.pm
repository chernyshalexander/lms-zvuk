package Plugins::Zvuk::GigaMix;

use strict;
use warnings;
use utf8;

use Plugins::Zvuk::UI::GigaMix;

# Backward compatibility aliases
*handleGigaMix          = \&Plugins::Zvuk::UI::GigaMix::handleGigaMix;
*handleGigaMixSearch    = \&Plugins::Zvuk::UI::GigaMix::handleGigaMixSearch;
*handleGigaMixRemake    = \&Plugins::Zvuk::UI::GigaMix::handleGigaMixRemake;
*handleGigaMixAddMore   = \&Plugins::Zvuk::UI::GigaMix::handleGigaMixAddMore;
*handleGigaMixNextPage  = \&Plugins::Zvuk::UI::GigaMix::handleGigaMixNextPage;
*_renderGigaMixPlaylist = \&Plugins::Zvuk::UI::GigaMix::_renderGigaMixPlaylist;

1;
