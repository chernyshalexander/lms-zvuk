package Plugins::Zvuk::AtlasUI;

use strict;
use warnings;
use utf8;

use Plugins::Zvuk::UI::Atlas;

# Backward compatibility aliases
*handleAtlasMenu             = \&Plugins::Zvuk::UI::Atlas::handleAtlasMenu;
*handleAllIslands            = \&Plugins::Zvuk::UI::Atlas::handleAllIslands;
*handleGenresMenu            = \&Plugins::Zvuk::UI::Atlas::handleGenresMenu;
*handleGenreIslands          = \&Plugins::Zvuk::UI::Atlas::handleGenreIslands;
*handleMoodsMenu             = \&Plugins::Zvuk::UI::Atlas::handleMoodsMenu;
*handleMoodIslands           = \&Plugins::Zvuk::UI::Atlas::handleMoodIslands;
*handleIslandDetail          = \&Plugins::Zvuk::UI::Atlas::handleIslandDetail;
*handleIslandTrackList       = \&Plugins::Zvuk::UI::Atlas::handleIslandTrackList;
*handleStartIslandWave       = \&Plugins::Zvuk::UI::Atlas::handleStartIslandWave;
*handleStartRandomIslandWave = \&Plugins::Zvuk::UI::Atlas::handleStartRandomIslandWave;
*_renderIslandItem           = \&Plugins::Zvuk::UI::Atlas::_renderIslandItem;
*_uiKind                     = \&Plugins::Zvuk::UI::Atlas::_uiKind;

1;
