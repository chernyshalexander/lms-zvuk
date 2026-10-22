package Plugins::Zvuk::WaveUI;

use strict;
use warnings;
use utf8;

use Plugins::Zvuk::UI::Wave;

# Backward compatibility aliases
*handleWaveSettingsRouter = \&Plugins::Zvuk::UI::Wave::handleWaveSettingsRouter;
*handleWaveSettings       = \&Plugins::Zvuk::UI::Wave::handleWaveSettings;
*handleSlider             = \&Plugins::Zvuk::UI::Wave::handleSlider;
*handleGenresMenu         = \&Plugins::Zvuk::UI::Wave::handleGenresMenu;
*handleGenreToggle        = \&Plugins::Zvuk::UI::Wave::handleGenreToggle;
*handleLanguageMenu       = \&Plugins::Zvuk::UI::Wave::handleLanguageMenu;
*handleLanguageSelect     = \&Plugins::Zvuk::UI::Wave::handleLanguageSelect;
*handleVocalMenu          = \&Plugins::Zvuk::UI::Wave::handleVocalMenu;
*handleVocalSelect        = \&Plugins::Zvuk::UI::Wave::handleVocalSelect;
*handleSliderValue        = \&Plugins::Zvuk::UI::Wave::handleSliderValue;
*handleStartWave          = \&Plugins::Zvuk::UI::Wave::handleStartWave;
*handleWaveMenu           = \&Plugins::Zvuk::UI::Wave::handleWaveMenu;
*_getWaveMenuItems        = \&Plugins::Zvuk::UI::Wave::_getWaveMenuItems;
*_getWaveSettingsItems    = \&Plugins::Zvuk::UI::Wave::_getWaveSettingsItems;
*_getSliderLabel          = \&Plugins::Zvuk::UI::Wave::_getSliderLabel;
*_getLangLabel            = \&Plugins::Zvuk::UI::Wave::_getLangLabel;
*_getVocalLabel           = \&Plugins::Zvuk::UI::Wave::_getVocalLabel;
*_getSettingValue         = \&Plugins::Zvuk::UI::Wave::_getSettingValue;
*_updateSetting           = \&Plugins::Zvuk::UI::Wave::_updateSetting;
*_getGenresMenu           = \&Plugins::Zvuk::UI::Wave::_getGenresMenu;
*_getAPIHandler           = \&Plugins::Zvuk::UI::Wave::_getAPIHandler;
*_uiKind                  = \&Plugins::Zvuk::UI::Wave::_uiKind;
*_getSliderItems          = \&Plugins::Zvuk::UI::Wave::_getSliderItems;
*_shouldGoBackToSettings  = \&Plugins::Zvuk::UI::Wave::_shouldGoBackToSettings;
*_getLanguageMenu         = \&Plugins::Zvuk::UI::Wave::_getLanguageMenu;
*_getVocalMenu            = \&Plugins::Zvuk::UI::Wave::_getVocalMenu;

1;
