package Plugins::Zvuk::Browse::InfoMenu;

use strict;
use warnings;
use utf8;

use Plugins::Zvuk::UI::InfoMenu;

# Backward compatibility aliases
*init           = \&Plugins::Zvuk::UI::InfoMenu::init;
*menuInfoCLI    = \&Plugins::Zvuk::UI::InfoMenu::menuInfoCLI;
*albumInfoMenu  = \&Plugins::Zvuk::UI::InfoMenu::albumInfoMenu;
*artistInfoMenu = \&Plugins::Zvuk::UI::InfoMenu::artistInfoMenu;
*trackInfoMenu  = \&Plugins::Zvuk::UI::InfoMenu::trackInfoMenu;

1;
