package Slim::Buttons::Common;

# $Id$

# SlimServer Copyright (c) 2001-2006 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

=head1 NAME

Slim::Buttons::Common

=head1 SYNOPSIS

Slim::Buttons::Common::addMode('mymodename', getFunctions(), \&setMode);

Slim::Buttons::Common::addSaver('screensaver', getFunctions(), \&setMode, undef, 'SCREENSAVER_JUMP_BACK_NAME');

Slim::Buttons::Common::pushModeLeft($client,'mymodename');

Slim::Buttons::Common::pushMode($client, 'INPUT.List', \%params);

Slim::Buttons::Common::popModeRight($client);

Slim::Buttons::Common::popMode($client);

Slim::Buttons::Common::scroll($client, $dir, 6, $m0);

=head1 DESCRIPTION

L<Slim::Buttons::Common> is the central collection of functions for accessing and manipulating the Player UI state machine.  
This includes navigating menus, registering and managing player modes, and accessing core UI widgets.

=cut

use strict;
use warnings;

use File::Spec::Functions qw(:ALL);
use File::Spec::Functions qw(updir);
use Scalar::Util qw(blessed);

use Slim::Player::Client;
use Slim::Utils::DateTime;
use Slim::Utils::Misc;
use Slim::Utils::PluginManager;
use Slim::Display::Display;
use Slim::Buttons::Block;
use Slim::Buttons::Favorites;
use Slim::Buttons::SqueezeNetwork;
use Slim::Buttons::XMLBrowser;
use Slim::Buttons::Volume;

# hash of references to functions to call when we leave a mode
our %leaveMode = ();

#references to mode specific function hashes
our %modeFunctions = ();

my $SCAN_RATE_MULTIPLIER = 2;
my $SCAN_RATE_MAX_MULTIPLIER = 256;

# hash of references to functions to call when we enter a mode
# Note:  don't add to this list, rather use the addMode() function 
# below to have the module add its mode itself
our %modes = ();

# Hashed list for registered Screensavers. Register these using addSaver. 
our %savers = ();

# Map the numbers on the remote to their corresponding letter sequences.
our @numberLetters = (
	[' ','0'], # 0
	['.',',',"'",'?','!','@','-','1'], # 1
	['A','B','C','2'], 	# 2
	['D','E','F','3'], 	# 3
	['G','H','I','4'], 	# 4
	['J','K','L','5'], 	# 5
	['M','N','O','6'], 	# 6
	['P','Q','R','S','7'], 	# 7
	['T','U','V','8'], 	# 8
	['W','X','Y','Z','9']   # 9
);

# Minimum Velocity for scrolling, in items/second
my $minimumVelocity = 2;

# Time that you must hold the scroll button before the automatic
# scrolling and acceleration starts. 
# in seconds.
my $holdTimeBeforeScroll = 0.300;  

our $scrollClientHash = {};

=head1 METHODS

=head2 init( )

This method must be called before all other Slim::Buttons::* modules.  It
initialises all other SlimServer core button modules and registers the "Now
Playing" screensaver.

=cut

# The address of the function hash is set at run time rather than compile time
# so initialize the modeFunctions hash here
sub init {

	# Home must come first!
	Slim::Buttons::Home::init();
	
	# Initialise main settings menu next
	Slim::Buttons::Settings::init();
	
	Slim::Buttons::AlarmClock::init();
	Slim::Buttons::Block::init();
	Slim::Buttons::BrowseDB::init();
	Slim::Buttons::BrowseTree::init();
	Slim::Buttons::Favorites::init();
	Slim::Buttons::Information::init();
	Slim::Buttons::Playlist::init();
	Slim::Buttons::XMLBrowser::init();
	Slim::Buttons::Power::init();
	Slim::Buttons::ScreenSaver::init();
	Slim::Buttons::Search::init();
	Slim::Buttons::SqueezeNetwork::init();
	Slim::Buttons::Synchronize::init();
	Slim::Buttons::TrackInfo::init();
	Slim::Buttons::RemoteTrackInfo::init();
	Slim::Buttons::Volume::init();

	$savers{'playlist'} = 'NOW_PLAYING';
}

=head2 addSaver ( $name, [ $buttonFunctions ], [ $setModeFunction ], [ $leaveModeFunction ], $displayName )

This function registers a screensaver mode.  The required $name argument should be a unique string,
identifying the mode, $displayName is also required and must be a valid string token (all caps, with
localised translations) for identifying the friendly name of the screensaver.

Optional $buttonFunctions is a reference the routine to call for accessing the reference to the button
functions used while operating in the screensaver.  This is only required if the screensaver makes use
 of any custom functions not found in this module.

$setModeFunction is an optional reference to the modes setMode function call, which sets up the required
state for the screensaver mode. This is not required if the screensaver is only for display or makes use
of existing INPUT.* modes.

$leaveModeFunction is an optional reference to a routine to run when exiting the screensaver mode.

=cut

sub addSaver {
	my $name = shift;
	my $buttonFunctions = shift;
	my $setModeFunction = shift;
	my $leaveModeFunction = shift;
	my $displayName = shift;

	$savers{$name} = $displayName;

	$::d_plugins && msg("Registering screensaver $displayName\n");

	addMode($name, $buttonFunctions, $setModeFunction, $leaveModeFunction);
	if ($name =~ s/^SCREENSAVER\./OFF\./) {
		addMode($name, $buttonFunctions, $setModeFunction, $leaveModeFunction);
	}
}

=head2 hash_of_savers ( )

Taking no arguments, this function returns a reference to teh current hash of screensavers. Called from settings routines
in Slim::Web::Setup and Slim::Buttons::Settings

=cut

sub hash_of_savers {

	my %saversCopy = %savers;

	return \%saversCopy;
}

=head2 addMode ( )

Register new modes with the server. $name must be a uniqe string to identify the player mode. 

Optional $buttonFunctions is a reference the routine to call for accessing the reference to the button
functions used while operating in the screensaver.  This is only required if the screensaver makes use
 of any custom functions not found in this module.

$setModeFunction is an optional reference to the modes setMode function call, which sets up the required
state for the screensaver mode. This is not required if the screensaver is only for display or makes use
of existing INPUT.* modes.

$leaveModeFunction is an optional reference to a routine to run when exiting the screensaver mode.

=cut
sub addMode {
	my $name = shift;
	my $buttonFunctions = shift;
	my $setModeFunction = shift;
	my $leaveModeFunction = shift;

	$modeFunctions{$name} = $buttonFunctions;
	$modes{$name} = $setModeFunction;
	$leaveMode{$name} = $leaveModeFunction;
}
	
# Common functions for more than one mode:
our %functions = (
	'dead' => sub  {},

	'fwd' => sub  {
		my $client = shift;

		# ignore if we aren't playing anything or if we're scanning
		my $playlistlen = Slim::Player::Playlist::count($client);
		my $rate = Slim::Player::Source::rate($client);

		if ($playlistlen == 0 || ($rate != 0 && $rate != 1)) {
			return;
		}

		$client->execute(["playlist", "jump", "+1"]);
		$client->showBriefly($client->currentSongLines()) unless suppressStatus($client);
	},

	'rew' => sub  {
		my $client = shift;

		# ignore if we aren't playing anything or if we're scanning
		my $playlistlen = Slim::Player::Playlist::count($client);
		my $rate = Slim::Player::Source::rate($client);

		if ($playlistlen == 0 || ($rate != 0 && $rate != 1)) {
			return;
		}

		my $noplay = Slim::Player::Source::playmode($client) eq 'pause';

		# either starts the same song over, or the previous one, depending on whether we jumped back.
		if (Time::HiRes::time() - Slim::Hardware::IR::lastIRTime($client) < 1.0) {

			# less than second, jump back to the previous song
			$client->execute(["playlist", "jump", "-1", $noplay]);

		} else {

			# otherwise, restart this song.
			$client->execute(["playlist", "jump", "+0", $noplay]);
		}

		$client->showBriefly($client->currentSongLines()) unless suppressStatus($client);
	},

	'jump' => sub  {
		my $client   = shift;
		my $funct    = shift;
		my $functarg = shift;

		# ignore if we aren't playing anything or if we're scanning
		my $playlistlen = Slim::Player::Playlist::count($client);
		my $rate        = Slim::Player::Source::rate($client);

		if ($playlistlen == 0) {
			return;
		}

		if (!defined $functarg) {
			$functarg = '';
		}

		# ignore if we're scanning that way already			
		if ($rate > 1 && $functarg eq 'fwd') {
			return;
		}

		if ($rate < 0 && $functarg eq 'rew') {
			return;
		}

		# if we aren't scanning that way, then use it to stop scanning  and just play.
		if ($rate != 0 && $rate != 1) {

			$client->execute(["play"]);

			return;	
		}

		my $noplay = Slim::Player::Source::playmode($client) eq 'pause';

		# either starts the same song over, or the previous one, or
		# the next one depending on whether/how we jumped
		if ($functarg eq 'rew') { 

			my $now = Time::HiRes::time();

			if (Slim::Player::Source::songTime($client) < 5 || Slim::Player::Source::playmode($client) eq "stop") {

				# jump back a song if stopped, invalid
				# songtime, or current song has been playing
				# less than 5 seconds (use modetime instead of now when paused)
				$client->execute(["playlist", "jump", "-1", $noplay]);

			} else {

				#restart current song
				$client->execute(["playlist", "jump", "+0", $noplay]);
			}

		} elsif ($functarg eq 'fwd') {

			# jump to next song
			$client->execute(["playlist", "jump", "+1", $noplay]);

		} else {

			#restart current song
			$client->execute(["playlist", "jump", "+0", $noplay]);
		}

		$client->showBriefly($client->currentSongLines()) unless suppressStatus($client);
	},

	'jumpinsong' => sub {
		my ($client, $funct, $functarg) = @_;

		my $dir     = 0;
		my $timeinc = 1;

		if (!defined $functarg) {

			return;

		} elsif ($functarg =~ /(.+?)_(\d+)_(\d+)/) {

			$dir = ($1 eq 'fwd' ? '+' : '-') . "$2";

		} elsif ($functarg eq 'fwd') {

			$dir = "+$timeinc";

		} elsif ($functarg eq 'rew') {

			$dir = "-$timeinc";

		} else {

			return;
		}

		$client->execute(['gototime', $dir]);
	},

	'scan' => sub {
		my ($client, $funct, $functarg) = @_;

		my $rate = Slim::Player::Source::rate($client);

		if (!defined $functarg) {

			return;

		} elsif ($functarg eq 'fwd') {

			Slim::Buttons::Common::pushMode($client, 'playlist');

			if ($rate < 0) {
				$rate = 1;
			}

			if (abs($rate) == $SCAN_RATE_MAX_MULTIPLIER) {
				return;
			}

			$client->execute(['rate', $rate * $SCAN_RATE_MULTIPLIER]);

		} elsif ($functarg eq 'rew') {

			Slim::Buttons::Common::pushMode($client, 'playlist');

			if ($rate > 0) {
				$rate = 1;
			}

			if (abs($rate) == $SCAN_RATE_MAX_MULTIPLIER) {
				return;
			}

			$client->execute(['rate', -abs($rate * $SCAN_RATE_MULTIPLIER)]);
		}

		$client->update();
	},

	'pause' => sub  {
		my $client = shift;

		# ignore if we aren't playing anything
		my $playlistlen = Slim::Player::Playlist::count($client);

		if ($playlistlen == 0) {
			return;
		}

		# try to avoid toggle commands, they make life difficult for listeners
		my $wantmode = (Slim::Player::Source::playmode($client) eq 'pause') ? '0' : '1';

		$client->execute(["pause", $wantmode]);

		$client->showBriefly($client->currentSongLines()) unless suppressStatus($client);
	},

	'stop' => sub  {
		my $client = shift;

		if (Slim::Player::Playlist::count($client) == 0) {

			$client->showBriefly($client->string('PLAYLIST_EMPTY'), "");

		} else {

			$client->execute(["stop"]);

			Slim::Buttons::Common::pushMode($client, 'playlist');

			$client->showBriefly($client->string('STOPPING'), "") unless suppressStatus($client);
		}
	},

	'menu_pop' => sub  {
		my $client = shift;

		Slim::Buttons::Common::popMode($client);

		$client->update();
	},

	'menu' => sub  {
		my $client = shift;
		my $button = shift || '';
		my $buttonarg = shift;

		my $jump = $client->curSelection($client->curDepth());

		Slim::Buttons::Common::setMode($client, 'home');

		if ($button eq 'menu_playlist') {

			Slim::Buttons::Common::pushMode($client, 'playlist');
			$jump = 'NOW_PLAYING';

		} elsif ($button eq 'menu_browse_genre') {

			Slim::Buttons::Common::pushMode($client, 'browsedb', {
				'hierarchy' => 'genre,artist,album,track',
				'level'     => 0,
			});

			$jump = 'BROWSE_BY_GENRE';

		} elsif ($button eq 'menu_browse_artist') {

			Slim::Buttons::Common::pushMode($client, 'browsedb', {
				'hierarchy' => 'artist,album,track',
				'level'     => 0,
			});

			$jump = 'BROWSE_BY_ARTIST';

		} elsif ($button eq 'menu_browse_album') {

			Slim::Buttons::Common::pushMode($client, 'browsedb', {
				'hierarchy' => 'album,track',
				'level'     => 0,
			});

			$jump = 'BROWSE_BY_ALBUM';

		} elsif ($button eq 'menu_browse_song') {

			Slim::Buttons::Common::pushMode($client, 'browsedb', {
				'hierarchy' => 'track',
				'level'     => 0,
			});

			$jump = 'BROWSE_BY_SONG';

		} elsif ($button eq 'menu_browse_music') {

			Slim::Buttons::Common::pushMode($client, 'browsetree', {
				'hierarchy' => '',
			});

			$jump = 'BROWSE_MUSIC_FOLDER';

		} elsif ($button eq 'menu_synchronize') {

			Slim::Buttons::Common::pushMode($client, 'settings');

			$jump = 'SETTINGS';

			Slim::Buttons::Common::pushModeLeft($client, 'synchronize');

		} elsif ($button eq 'menu_search_artist') {

			my %params = Slim::Buttons::Search::searchFor($client, 'ARTISTS');

			Slim::Buttons::Common::pushModeLeft($client, $params{'useMode'}, \%params);

			$jump = 'SEARCH_FOR_ARTISTS';

		} elsif ($button eq 'menu_search_album') {

			my %params = Slim::Buttons::Search::searchFor($client, 'ALBUMS');

			Slim::Buttons::Common::pushModeLeft($client, $params{'useMode'}, \%params);

			$jump = 'SEARCH_FOR_ALBUMS';

		} elsif ($button eq 'menu_search_song') {

			my %params = Slim::Buttons::Search::searchFor($client, 'SONGS');

			Slim::Buttons::Common::pushModeLeft($client, $params{'useMode'}, \%params);

			$jump = 'SEARCH_FOR_SONGS';

		} elsif ($button eq 'menu_browse_playlists') {

			Slim::Buttons::Common::pushMode($client, 'browsedb', {
				'hierarchy' => 'playlist,playlistTrack',
				'level'     => 0,
			});

			$jump = 'SAVED_PLAYLISTS';

		} elsif ($buttonarg =~ /^plugin/i) {

			if (exists($modes{$buttonarg})) {
				Slim::Buttons::Common::pushMode($client, $buttonarg);
			} else {
				Slim::Buttons::Common::pushMode($client, 'plugins');
			}

			$jump = 'PLUGINS';

		} elsif ($button eq 'menu_settings') {

			Slim::Buttons::Common::pushMode($client, 'settings');
			$jump = 'SETTINGS';
		}

		Slim::Buttons::Home::jump($client,$jump);

		$client->update();
	},

	'brightness' => sub  {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;
		
		my $mode = Slim::Buttons::Common::mode($client);

		if (!defined $buttonarg || ($mode eq 'block' && $client->modeParam('block.name') eq 'upgrade')) {
			return;
		}

		my $brightmode = 'powerOffBrightness';

		if ($client->power) {

			$brightmode = 'powerOnBrightness';

			my $lastIR  = Slim::Hardware::IR::lastIRTime($client);
			my $saver   = 0;
			my $timeout = Time::HiRes::time() - $client->prefGet('screensavertimeout');

			if ($mode eq $client->prefGet('screensaver') ||
			    $mode eq $client->prefGet('idlesaver')) {

				$saver = 1;
			}

			if (($saver || $client->prefGet('autobrightness')) && ($lastIR && $lastIR < $timeout)) {

				$brightmode = 'idleBrightness';
			}
		}

		$::d_ui && msg("UI: Brightness using $brightmode during mode: $mode\n");

		my $newBrightness;

		if ($buttonarg eq 'toggle') {

			$newBrightness = $client->brightness() - 1;

			if ($newBrightness < 0) {

				$newBrightness = $client->maxBrightness();
			}

		} else {

			if ($buttonarg eq 'down') {

				$newBrightness = $client->brightness() - 1;

			} else {
	
				$newBrightness = $client->brightness() + 1;
			}

			if ($newBrightness > $client->maxBrightness()) {

				$newBrightness = $client->maxBrightness();
			}

			if ($newBrightness < 0) {
				$newBrightness = 0;
			}
		}

		$client->prefSet($brightmode, $newBrightness);

		$client->brightness($newBrightness);
	},

	'playdisp' => sub  {
		my $client    = shift;
		my $button    = shift;
		my $buttonarg = shift;
		my $playdisp  = undef;

		if (mode($client) eq 'playlist') {

			Slim::Buttons::Playlist::jump($client);
			return;
		}

		if (!defined $buttonarg) {
			$buttonarg = 'toggle';
		}

		if ($buttonarg eq 'toggle') {

			$::d_ui && msg("Switching to playlist view\n");

			if (Slim::Player::Playlist::count($client) == 0) {

				$client->showBriefly($client->string('PLAYLIST_EMPTY'), "");

			} else {

				Slim::Buttons::Common::setMode($client, 'home');
				Slim::Buttons::Home::jump($client, 'playlist');
				Slim::Buttons::Common::pushModeLeft($client, 'playlist');
			}

		} elsif ($buttonarg =~ /^[0-5]$/) {

			$client->prefSet("playingDisplayMode", $buttonarg);
		}
	},

	'visual' => sub {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;
		
		my $visModes = $client->prefGetArrayMax('visualModes') + 1;
		my $vm       = $client->prefGet('visualMode');

		if (!defined $vm || $vm > $visModes) {
			$vm = 0;
		}
		
		if (!defined $buttonarg) {
			$buttonarg = 'toggle';
		}

		if ($button eq 'visual_toggle') {

			$vm = ($vm + 1) % $visModes;

		} elsif (defined $buttonarg && $buttonarg < $visModes) {

			$vm = $buttonarg;
		}

		$client->prefSet('visualMode', $vm);

		updateScreen2Mode($client);

		$client->update();
	},

	'search' => sub  {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;
		my $playdisp = undef;

		if (mode($client) ne 'search') {
			Slim::Buttons::Home::jumpToMenu($client, "SEARCH");
			$client->update();
		}
	},

	'browse' => sub  {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;
		my $playdisp = undef;

		setMode($client, 'home');

		Slim::Buttons::Home::jumpToMenu($client, "BROWSE_MUSIC");

		$client->update();
	},

	'favorites' => sub  {
		my $client    = shift;
		my $button    = shift;
		my $buttonarg = shift;
		my $playdisp  = undef;

		if (defined $buttonarg && $buttonarg eq "add") {

			# First lets try for a listRef from INPUT.*
			my $list = $client->modeParam('listRef');
			my $obj;
			my $title;
			my $url;
			
			# If there is a list, try grabbing the current index.
			if ($list) {
			
				$obj = $list->[$client->modeParam('listIndex')];
			
			# hack to grab currently browsed item from current playlist (needs to use INPUT.List at some point)
			} elsif (mode($client) eq 'playlist') {
			
				$obj = Slim::Player::Playlist::song($client, Slim::Buttons::Playlist::browseplaylistindex($client));
			}
			
			# if that doesn't work, perhaps we have a track param from something like trackinfo
			if (!blessed($obj) && $client->modeParam('track')) {
			
				$obj = $client->modeParam('track');
			
			# specific HACK for Live365
			} elsif(Slim::Player::ProtocolHandlers->handlerForURL('live365://') && (Plugins::Live365::Plugin::getLive365($client))) {

				my $live365 = Plugins::Live365::Plugin::getLive365($client);
				my $station = $live365->getCurrentStation();
				
				$title = $station->{STATION_TITLE};
				$url   = $station->{STATION_ADDRESS};
				
				# fix url to activate protocol handler
				$url =~ s/http\:/live365\:/;
			}
			
			# start with the object if we have one
			if ($obj && !$url) {
				
				if (blessed($obj) && $obj->can('url')) {
					$url = $obj->url;
				
				# xml browser uses hash lists with url and name values.
				} elsif (ref($obj) eq 'HASH') {
					
					$url = $obj->{'url'};
				}
				
				if (blessed($obj) && $obj->can('name')) {

					$title = $obj->name;
				}elsif (ref($obj) eq 'HASH') {

					$title = $obj->{'name'} || $obj->{'title'};
				} else {
					
					# failing specified name values, try the db title
					$title = Slim::Music::Info::standardTitle($client, $obj);
				}
			} 
			
			# remoteTrackInfo uses url and title params for lists.
			if ($client->modeParam('url') && !$url) {
				
				$url   = $client->modeParam('url');
				$title = $client->modeParam('title');
			}

			if ($url && $title) {
				Slim::Utils::Favorites->clientAdd($client, $url, $title);
				$client->showBriefly($client->string('FAVORITES_ADDING'), $title);
			
			# if all of that fails, send the debug with a best guess helper for tracing back
			} else {

				if ($::d_favorites) { 
					msg("Favorites: no valid url found, not adding favorite\n");
					
					if ($obj) {
						msg(Data::Dumper::Dumper($obj));
					
					} else {
						Slim::Utils::Misc::bt();
					}
				}
			}

		} elsif (mode($client) ne 'FAVORITES') {

			setMode($client, 'home');
			Slim::Buttons::Home::jump($client, 'FAVORITES');
			Slim::Buttons::Common::pushModeLeft($client, 'FAVORITES');
		}
	},

	# pressing recall toggles the repeat.
	'repeat' => sub  {
		my $client    = shift;
		my $button    = shift;
		my $buttonarg = shift;
		my $repeat    = undef;

		if (defined $buttonarg && $buttonarg =~ /^[0-2]$/) {
			$repeat = $buttonarg;
		}

		$client->execute(["playlist", "repeat", $repeat]);

		# display the fact that we are (not) repeating

		if (Slim::Player::Playlist::repeat($client) == 0) {

			$client->showBriefly($client->string('REPEAT_OFF'), "");

		} elsif (Slim::Player::Playlist::repeat($client) == 1) {

			$client->showBriefly($client->string('REPEAT_ONE'), "");

		} elsif (Slim::Player::Playlist::repeat($client) == 2) {

			$client->showBriefly($client->string('REPEAT_ALL'), "");
		}
	},

	# XXXX This mode is used by the Transporter knob - _NOT_ by the remote
	# volume buttons, which are defined below. They should be combined.
	# See Slim::Buttons::Volume
	'volumemode' => sub {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;

		return if (!$client->hasVolumeControl());
		
		if ($client->modeParam('parentMode') && $client->modeParam('parentMode') eq 'volume') {
			popModeRight($client);
		} else {
			pushModeLeft($client, 'volume');
		}
	},

	'volume' => sub {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;

		return if (!$client->hasVolumeControl());

		mixer($client, 'volume', $buttonarg);
	},

	'pitch' => sub {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;

		mixer($client, 'pitch', $buttonarg);
	},

	'bass' => sub {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;

		mixer($client, 'bass', $buttonarg);
	},

	'treble' => sub {
		my $client = shift;
		my $button = shift;
		my $buttonarg = shift;

		mixer($client, 'treble', $buttonarg);
	},

	'muting' => sub  {
		my $client = shift;

		# try to avoid toggle commands, they make life difficult for listeners
		my $mute = !($client->prefGet("mute"));

		$client->execute(["mixer", "muting", $mute]);
	},

	'sleep' => sub  {
		my $client = shift;
		
		# Bug: 2151 some extra stuff to add the option to sleep after the current song.
		# first make sure we're playing, and its a valid song.
		my $remaining;

		if (Slim::Player::Source::playingSong($client) && $client->playmode =~ /play/) { 

			my $dur = Slim::Player::Source::playingSongDuration($client);

			# calculate the time based remaining, in seconds then into fractional minutes.
			$remaining = $dur - Slim::Player::Source::songTime($client);
			$remaining = $remaining / 60;
		}

		# add the 'after this song' option only if there is a defined value.
		my @sleepChoices = $remaining ? sort({$a <=> $b} (0, $remaining, 15,30,45,60,90)) : (0,15,30,45,60,90);
		my $i = 0;

		# find the next value for the sleep timer
		for ($i = 0; $i <= $#sleepChoices; $i++) {

			# case of remaining time matching a defined time within same range as used in prettySleepTime.
			if ( int($remaining + 0.5) == int($sleepChoices[$i] + 0.5)) {
				
				#don't skip if this is the last entry, but reset the redundant entries to end of song.
				$sleepChoices[$i] = $remaining;
				if ($i != $#sleepChoices) {
					$i++;
					$sleepChoices[$i] = $remaining;
				}
			}
			
			if ( $sleepChoices[$i] > $client->currentSleepTime() ) {
				last;
			}
		}

		if ($i > $#sleepChoices) {
			$i = 0;
		}

		# if remaining time matches the sleeptime to within a minute, set as remaining time
		my $sleepTime = $sleepChoices[$i];

		$client->execute(["sleep", $sleepTime * 60]);

		if ($sleepTime == 0) {
			$client->showBriefly($client->string('CANCEL_SLEEP') , '');
		} else {
			$client->showBriefly($client->prettySleepTime,'');
		}
	},

	'power' => sub  {
		my $client = shift;
		my $button = shift;
		my $power= undef;
		
		# try to avoid toggle commands, they make life difficult for listeners
		if ($button eq 'power_on') {
			$power = 1;
		} elsif ($button eq 'power_off') {
			$power = 0;
		} else {
			$power = $client->power() ? 0 : 1;
		}

		$client->execute(["power", $power]);
	},

	'shuffle' => sub  {
		my $client = shift;
		my $button = shift;
		my $shuffle = undef;

		if ($button eq 'shuffle_on') {
			$shuffle = 1;
		} elsif ($button eq 'shuffle_off') {
			$shuffle = 0;
		}

		$client->execute(["playlist", "shuffle" , $shuffle]);
		
		if (Slim::Player::Playlist::shuffle($client) == 2) {

			$client->showBriefly($client->string('SHUFFLE_ON_ALBUMS'), "");

		} elsif (Slim::Player::Playlist::shuffle($client) == 1) {

			$client->showBriefly($client->string('SHUFFLE_ON_SONGS'), "");

		} else {

			$client->showBriefly($client->string('SHUFFLE_OFF'), "");
		}
	},

	'titleFormat' => sub  {
		my $client = shift;

		# rotate the titleFormat
		$client->prefSet("titleFormatCurr" , 
			($client->prefGet("titleFormatCurr") + 1) %
			($client->prefGetArrayMax("titleFormat") + 1)
		);

		$client->update();
	},

 	'datetime' => sub  {
		my $client = shift;

 		# briefly display the time/date
 		$client->showBriefly(dateTime(), 3);
 	},

	'textsize' => sub  {
		my $client = shift;
		my $button = shift;

		my $doublesize = $client->textSize;

		if ($button eq 'textsize_large') {

			$doublesize = $client->maxTextSize;

		} elsif ($button eq 'textsize_medium') {

			$doublesize = 1;

		} elsif ($button eq 'textsize_small') {

			$doublesize = 0;

		} elsif ($button eq 'textsize_toggle') {

			$doublesize++;
		}

		if ($doublesize && $doublesize > $client->maxTextSize) {
			$doublesize = 0;
		}

		$client->textSize($doublesize);
		$client->update();
	},

	'clearPlaylist' => sub {
		my $client = shift;

		$client->showBriefly($client->string('CLEARING_PLAYLIST'), '');

		$client->execute(['playlist', 'clear']);
	},

	'modefunction' => sub {
		my ($client, $funct, $functarg) = @_;

		return if !$functarg;

		# XXXX - WTF?
		my ($mode,$modefunct) = split('->', $functarg, 2);

		return if !exists($modeFunctions{$mode});

		my $coderef = $modeFunctions{$mode}{$modefunct};
		my $modefunctarg;

 		if (!$coderef && ($modefunct =~ /(.+?)_(.+)/) && ($coderef = $modeFunctions{$mode}{$1})) {
 			$modefunctarg = $2;
 		}

		&$coderef($client,$modefunct,$modefunctarg) if $coderef;
	},

	'changeMap' => sub {
		my ($client, $funct, $functarg) = @_;

		return if !$functarg;

		my $mapref = Slim::Hardware::IR::mapfiles();
		my %maps   = reverse %$mapref;

		if (!exists($maps{$functarg})) {
			return;
		}

		$client->prefSet('irmap',$maps{$functarg});

		$client->showBriefly($client->string('SETUP_IRMAP') . ':', $functarg);
	},
);

sub getFunction {
 	my $client = shift;
 	my $function = shift;
 	my $clientMode = shift;
 	my $coderef;

 	$clientMode = mode($client) unless defined($clientMode);

	if ($coderef = $modeFunctions{$clientMode}{$function}) {

 		return $coderef;

 	} elsif (($function =~ /(.+?)_(.+)/) && ($coderef = $modeFunctions{$clientMode}{$1})) {

 		return ($coderef, $2);

 	} elsif ($coderef = $functions{$function}) {

 		return $coderef;

 	} elsif (($function =~ /(.+?)_(.+)/) && ($coderef = $functions{$1})) {

 		return ($coderef, $2)

 	} else {

		return;
	}
}

=head2 setFunction( $mapping, $function )

setFunction enables a Plugin to affect all common modes. 

Originally added to allow Favorites plugin to make holding a number be a
shortcut to playing a users favorite station.

=cut

sub setFunction {
	my $mapping = shift;
	my $function = shift;

	$functions{$mapping} = $function;
}

sub pushButton {
	my $sub = shift;
	my $client = shift;

	no strict 'refs';

	my ($subref, $subarg) = getFunction($client,$sub);

	&$subref($client, $sub, $subarg);
}

sub scroll {
	scroll_dynamic(@_);
}

=head2 scrollDynamic ( $client, $direction, $listlength, $currentPosition )

This is a common UI function for moving up or down through a list,
accelerating as the scrolling continues.

Four arguments are required:

The $client object

$direction is typically either 1 or -1, but any positive or negative number
will properly decide direction

$listlength is the total number of items in the current list

$currentPosition is the zero-indexed position of the current item shown on the
player screen, from which the scroll is required to move.

The IR holdtime triggers acceleration of the scrolling effect.

=cut

sub scroll_dynamic {
	my $client = shift;
	my $direction = shift;
	my $listlength = shift;
	my $currentPosition = shift;
	my $newposition;
	my $holdTime = Slim::Hardware::IR::holdTime($client);
	# Set up initial conditions
	if (!defined $scrollClientHash->{$client}) {
		#$client->{scroll_params} =
		$scrollClientHash->{$client}{scrollParams} = scroll_getInitialScrollParams($minimumVelocity, $listlength, $direction);
	}

	my $scrollParams = $scrollClientHash->{$client}{scrollParams};

	my $result = undef;
	if ($holdTime == 0) {
		# define behavior for button press, before any acceleration
		# kicks in.
		
		# if at the end of the list, and down is pushed, go to the beginning.
		if ($currentPosition == $listlength-1  && $direction > 0) {
			# if at the end of the list, and down is pushed, go to the beginning.
			$currentPosition = -1; # Will be added to later...
			$scrollParams->{estimateStart} = 0;
			$scrollParams->{estimateEnd}   = $listlength - 1;
		} elsif ($currentPosition == 0 && $direction < 0) {
			# if at the beginning of the list, and up is pushed, go to the end.
			$currentPosition = $listlength;  # Will be subtracted from later.
			$scrollParams->{estimateStart} = 0;
			$scrollParams->{estimateEnd}   = $listlength - 1;
		}
		# Do the standard operation...
		$scrollParams->{lastHoldTime} = 0;
		$scrollParams->{V} = $scrollParams->{minimumVelocity} *
			$direction;
		$scrollParams->{A} = 0;
		$result = $currentPosition + $direction;
		if ($direction > 0) {
			$scrollParams->{estimateStart} = $result;
			if ($scrollParams->{estimateEnd} <
				$scrollParams->{estimateStart}) {
				$scrollParams->{estimateEnd} =
					$scrollParams->{estimateStart} + 1; 
			}
		} else {
			$scrollParams->{estimateEnd} = $result;
			if ($scrollParams->{estimateStart} >
				$scrollParams->{estimateEnd}) {
				$scrollParams->{estimateStart} =
					$scrollParams->{estimateEnd} - 1;
			}
		}
		scroll_resetScrollRange($result, $scrollParams, $listlength);
		$scrollParams->{lastPosition} = $result;
	} elsif ($holdTime < $holdTimeBeforeScroll) {
		# Waiting until holdTimeBeforeScroll is exceeded
		$result = $currentPosition;
	} else {
		# define behavior for scrolling, i.e. after the initial
		# timeout.
		$scrollParams->{A} = scroll_calculateAcceleration
			(
			 $direction, 
			 $scrollParams->{estimateStart},
			 $scrollParams->{estimateEnd},
			 $scrollParams->{Tc}
			 );
		my $accel = $scrollParams->{A};
		my $time = $holdTime - $scrollParams->{lastHoldTime};
		my $velocity = $scrollParams->{A} * $time + $scrollParams->{V};
		my $pos = ($scrollParams->{lastPositionReturned} == $currentPosition) ? 
			$scrollParams->{lastPosition} : 
			$currentPosition;
		my $X = 
			(0.5 * $scrollParams->{A} * $time * $time) +
			($scrollParams->{V} * $time) + 
			$pos;
		$scrollParams->{lastPosition} = $X; # Retain the last floating
		                                    # point value of $X
		                                    # because it's needed to
		                                    # maintain the proper
		                                    # acceleration when
		                                    # $minimumVelocity is
		                                    # small and not much
		                                    # motion happens between
		                                    # successive calls.
		$result = int(0.5 + $X);
		scroll_resetScrollRange($result, $scrollParams, $listlength);
		$scrollParams->{V} = $velocity;
		$scrollParams->{lastHoldTime} = $holdTime;
	}
	if ($result >= $listlength) {
		$result = $listlength - 1;
	}
	if ($result < 0) {
		$result = 0;
	}
	$scrollParams->{lastPositionReturned} = $result;
	$scrollParams->{lastDirection}        = $direction;
	return $result;
}

sub scroll_resetScrollRange
{
	my $currentPosition = shift;
	my $scrollParams    = shift;
	my $listlength      = shift;

	my $delta = ($scrollParams->{estimateEnd} - $scrollParams->{estimateStart})+1;
	if ($currentPosition > $scrollParams->{estimateEnd}) {
	    $scrollParams->{estimateEnd} = $scrollParams->{estimateEnd} + $delta;
	    if ($scrollParams->{estimateEnd} >= $listlength) {
			$scrollParams->{estimateEnd} = $listlength-1;
	    }
	} elsif ($currentPosition < $scrollParams->{estimateStart}) {
	    $scrollParams->{estimateStart} = $scrollParams->{estimateStart} - $delta;
	    if ($scrollParams->{estimateStart} < 0) {
			$scrollParams->{estimateStart} = 0;
		}
	}
}

sub scroll_calculateAcceleration {
	my ($direction, $estimatedStart, $estimatedEnd, $Tc)  = @_;
	my $deltaX = $estimatedEnd - $estimatedStart;

	return 2.0 * $deltaX / ($Tc * $Tc) * $direction;
}

sub scroll_getInitialScrollParams {
	my $minimumVelocity = shift; 
	my $listLength      = shift;
	my $direction       = shift;

	my $result = {
		# Constants.
		# Items/second.  Don't go any slower than this under any circumstances. 
		minimumVelocity => $minimumVelocity,  
					
		# seconds.  Finishs a list in this many seconds. 
		Tc              => 5,   

		# Variables
		# Starting estimate of target space.
		estimateStart   => 0,   
		
		# Ending estimate of target space
		estimateEnd     => $listLength, 
					
		# The current velocity.  account for direction
		V               => $minimumVelocity * $direction,
		
		# The current acceleration.
		A               => 0,

		# The 'hold Time' value the last time we were called.
		# a negative number means it hasn't been called before, or
		# the button has been released.
		lastHoldTime    => -1,

		# To make the 
		lastPosition    => 0,      # Last calculated position (floating point)
		lastPositionReturned => 0, # Last returned position   (integer), used to detect when $currentPosition 
					   # has been modified outside the scroll routines.
		
		# Maintain the last direction, so that we can implement a
		# slowdown when the user hits  the same direciton twice.
		# i.e. he's almost to where he wants to go, but not quite
		# there yet.  Slow velocity by half, and don't wait for
		# pause. 
		#lastDirection   => 0,      
	};

	return $result;
}

=head2 mixer ( $client, $feature, $setting)

Update audio mixer settings

$client object is required.
$feature argument is a string to determine which of teh mixer settings is to be changed: bass/treble/pitch where applicable
$setting is a scalar value for the new mixer setting.  Optionally it may be the string 'up' or 'down to adjust the current
value either up or down.  

Holding the IR button causes the up or down adjustment to accelerate the longer the button is held.

=cut

sub mixer {
	my $client = shift;
	my $feature = shift; # bass/treble/pitch
	my $setting = shift; # up/down/value
	
	my $accel = 8; # Hz/sec
	my $rate = 50; # Hz
	my $inc = 1;
	my $midpoint = $client->mixerConstant($feature,'mid');

	my $cmd;
	if (Slim::Hardware::IR::holdTime($client) > 0) {
		$inc *= Slim::Hardware::IR::repeatCount($client,$rate,$accel);
	} else {
		$inc = $client->mixerConstant($feature,'increment');
	}
	
	if ((!$inc && $setting =~ /up|down/) || $feature !~ /volume|bass|treble|pitch/) {
		return;
	}
	
	my $currVal = $client->prefGet($feature);
	if ($setting  eq 'up') {
		$cmd = "+$inc";
		if ($currVal < ($midpoint - 1.5) && ($currVal + $inc) >= ($midpoint - 1.5)) {
			# make the midpoint sticky by resetting the start of the hold
			$cmd = $midpoint;
			Slim::Hardware::IR::resetHoldStart($client);
		}
	} elsif ($setting eq 'down') {
		$cmd = "-$inc";
		if ($currVal > ($midpoint + 1.5) && ($currVal - $inc) <= ($midpoint + 1.5)) {
			# make the midpoint sticky by resetting the start of the hold
			$cmd = $midpoint;
			Slim::Hardware::IR::resetHoldStart($client);
		}
	} elsif ($setting =~ /(\d+)/) {
		$cmd = $1;
	} else {
		# just display current value
		$client->mixerDisplay($feature);
		return;
	}
		
	$client->execute(["mixer", $feature, $cmd]);
	
	$client->mixerDisplay($feature);
}

sub numberLetter {
	my $client = shift;
	my $digit = shift;
	my $table = shift || \@numberLetters;
	my $letter;
	my $index;

	my $now = Time::HiRes::time();
	# if the user has hit new button or hasn't hit anything for 1.0 seconds, use the first letter
	if (($digit ne $client->lastLetterDigit) ||
		($client->lastLetterTime + Slim::Utils::Prefs::get("displaytexttimeout") < $now)) {
		$index = 0;
	} else {
		$index = $client->lastLetterIndex + 1;
		$index = $index % (scalar(@{$table->[$digit]}));
	}

	$client->lastLetterDigit($digit);
	$client->lastLetterIndex($index);
	$client->lastLetterTime($now);

	return $table->[$digit][$index];
}

sub testSkipNextNumberLetter {
	my $client = shift;
	my $digit = shift;
	return (($digit ne $client->lastLetterDigit) && (($client->lastLetterTime + Slim::Utils::Prefs::get("displaytexttimeout")) > Time::HiRes::time()));
}

sub numberScroll {
	my $client = shift;
	my $digit = shift;
	my $listref = shift;
	my $sorted = shift; # is the list sorted?

	# optional reference to subroutine that takes a single parameter
	# of an index and returns the value for the item in the array we're searching.
	my $lookupsubref = shift;

	my $listsize = scalar @{$listref};

	if ($listsize <= 1) {
		return 0;
	}

	my $i;
	if (!$sorted) {
		# If there are 10 items or less then jump straight to the requested item
		if ($listsize <= 10) {
			$i = ($digit - 1) % 10;
			if ($i > $listsize - 1) { $i = $listsize - 1; }
		}else{
			my $now = Time::HiRes::time();
			# If the user hasn't pressed a button for the last 1.0 seconds then jump straight to the requested item
			if ($client->lastDigitTime + Slim::Utils::Prefs::get("displaytexttimeout") < $now) {
				$i = ($digit - 1) % 10;
			}else{
				$i = $client->lastDigitIndex * 10 + $digit - 1;
			}
			if ($i > $listsize - 1) { $i = $listsize - 1; }

			$client->lastDigitIndex($i + 1);
			$client->lastDigitTime($now);
		}
	} else {

		if (!defined($lookupsubref)) {
			$lookupsubref = sub { return $listref->[shift]; }
		}

		my $letter = numberLetter($client, $digit);
		# binary search	through the diritems, assuming that they are sorted...
		$i = firstIndexOf($letter, $lookupsubref, $listsize);


		# reset the scroll parameters so that the estimated start and end are at the previous letter and next letter respectively.
		$scrollClientHash->{$client}{scrollParams}{estimateStart} =
			firstIndexOf(chr(ord($letter)-1), $lookupsubref, $listsize);
		$scrollClientHash->{$client}{scrollParams}{estimateEnd} = 
			firstIndexOf(chr(ord($letter)+1), $lookupsubref, $listsize);
	}
	return $i;
}
# 
# utility function for numberScroll.  Does binary search for $letter,
# using $lookupsubref to lookup where we are.
# 
sub firstIndexOf
{
	my ($letter, $lookupsubref, $listsize)  = @_;

	my $high = $listsize;
	my $low = -1;
	my $i = -1;
	for ( $low = -1; $high - $low > 1; ) {
		$i = int(($high + $low) / 2);
		my $j = uc(substr($lookupsubref->($i), 0, 1));
		if ($letter eq $j) {
			last;
		} elsif ($letter lt $j) {
			$high = $i;
		} else {
			$low = $i;
		}
	}
	
	# skip back to the first matching item.
	while ($i > 0 && $letter eq uc(substr($lookupsubref->($i-1), 0, 1))) {
		$i--;
	}
	return $i;

}

=head2 mode ( $client)

Return the unique string name for the current player mode.

Required argument is the $client object for which the current mode information is desired.

=cut

sub mode {
	my $client = shift;

	assert($client);

	return $client->modeStack(-1);
}

=head2 validMode ( $client)

Given a string, returns true or false if the given string is a match for a valid, registered player mode.

=cut

sub validMode {
	my $mode = shift;

	return exists $modes{$mode} ? 1 : 0;
}

=head2 checkBoxOverlay ( $client, $value)

Update audio mixer settings

This is a standard UI widget for showing a single selected item in a list, or a true/false state of a setting

If the $client argument is a valid client object, graphics capable players will show a 'radio button'-style ui.
Otherwise, an text-based check box will be marked wtih an X for true and empty for false.

The $value argument is a boolean result provided by the caller to determine if the box is checked or not.

=cut

# standard UI feature enable/disable a setting
sub checkBoxOverlay {
	my $client = shift;
	my $value = shift;

	unless (blessed($client) && $client->isa('Slim::Player::Client')) {

		msg ("PLUGIN WARNING: plugins must now provide client when calling checkBoxOverlay\n");
		bt();
		$value = $client;

	} elsif ($client->display->isa('Slim::Display::Graphics')) {

		return $client->symbols( $value ? 'filledcircle' : 'circle' );

	}

	return $value ? "[X]" : "[ ]";
}


sub param {
	my $client = shift;
	return $client->modeParam(@_);
}

sub paramOrPref {
	my $client = shift;
	return $client->paramOrPref(@_);
}

=head2 pushMode ( $client, $setmode, [ $paramHashRef ])

Push the next mode onto the client's mode stack.

pushMode takes the following parameters:
   client - reference to a client structure
   setmode - name of mode we are pushing into
   paramHashRef - optional reference to a hash containing the parameters for that mode. 
      If no preset params are required, this arg is not required.

=cut
sub pushMode {
	my $client = shift;
	my $setmode = shift;
	my $paramHashRef = shift;

	$::d_ui && msg("pushing button mode: $setmode\n");

	my $oldscreen2 = $client->modeParam('screen2active');

	my $oldmode = mode($client);

	if ($oldmode) {

		my $exitFun = $leaveMode{$oldmode};

		if ($exitFun && ref($exitFun) eq 'CODE') {
			&$exitFun($client, 'push');
		}
	}

	# reset the scroll parameters
	push (@{$scrollClientHash->{$client}{scrollParamsStack}}, 
		$scrollClientHash->{$client}{scrollParams});
	
	$scrollClientHash->{$client}{scrollParams} = scroll_getInitialScrollParams($minimumVelocity, 1, 1);

	push @{$client->modeStack}, $setmode;

	if (!defined($paramHashRef)) {
		$paramHashRef = {};
	}

	push @{$client->modeParameterStack}, $paramHashRef;

	my $newModeFunction = $modes{$setmode};

	if (!$newModeFunction || ref($newModeFunction) ne "CODE") {
		bt();
		msg("Crashing because '$setmode' has no mode function or a bogus function.  Perhaps you mis-typed the mode name.\n");
	}

	eval { &$newModeFunction($client, 'push') };

	if ($@) {
		msg("Couldn't push into new mode: [$setmode] !: $@\n");
	}

	if ($client->display->hasScreen2) {
		my $screen2 = $client->modeParam('screen2');

		if ($client->display->showExtendedText() && !$screen2) {
			$screen2 = 'periodic';
		} elsif ($screen2 && $screen2 eq 'inherit') {
			$screen2 = $oldscreen2;
		}

		# set active param so we can modify it later
		$client->modeParam('screen2active', $screen2);
	}

	# some modes require periodic updates
	startPeriodicUpdates($client);
	
	$client->updateKnob(1);
}

=head2 popMode ( $client, $setmode, [ $paramHashRef ])

Pop's the current mode from the mode stack, and returns the player to the previous mode on the stack.

Only the $client object or structure is a required argument for popMode.

If the mode stack is empty, this function only updates the knob parameters and exits.

=cut
sub popMode {
	my $client = shift;

	if (scalar(@{$client->modeStack}) < 1) {

		$client->updateKnob(1);

		$::d_ui && msg("popMode: nothing on the modeStack - updatingKnob & returning.\n");

		return undef;
	}

	my $oldscreen2 = $client->modeParam('screen2active');

	my $oldMode = mode($client);

	if ($oldMode) {

		my $exitFun = $leaveMode{$oldMode};

		if ($exitFun && ref($exitFun) eq 'CODE') {
			&$exitFun($client, 'pop');
		}
	}
	
	pop @{$client->modeStack};
	pop @{$client->modeParameterStack};
	$scrollClientHash->{$client}{scrollParams} = pop @{$scrollClientHash->{$client}{scrollParamsStack}};
	
	my $newMode = mode($client);

	# Block mode is special.  Avoid running setmode again when leaving block mode as this 
	# can cause confusion (eq. broken play in BMF)
	if ($newMode && $oldMode ne 'block') {

		my $fun = $modes{$newMode};

		&$fun($client,'pop');
	}

	$::d_ui && msg("popped to button mode: " . (mode($client) || 'empty!') . "\n");

	if ($client->display->hasScreen2) {

		my $suppressScreen2Update = shift;

		my $screen2 = $client->modeParam('screen2active');

		if ($client->display->showExtendedText()) {

			$client->modeParam('screen2active', 'periodic') unless $screen2;

		} elsif ($screen2 && $screen2 eq 'periodic') {

			$client->modeParam('screen2active', undef);
		}

		if (!$suppressScreen2Update && $oldscreen2 && !$client->modeParam('screen2active')) {

			$client->update( { 'screen2' => {} } );
		}
	}

	# some modes require periodic updates
	startPeriodicUpdates($client);

	$client->updateKnob(1);
	
	return $oldMode
}

sub setMode {
	my $client = shift;
	my $setmode = shift;
	my $paramHashRef = shift;

	while (popMode($client)) {};

	pushMode($client, $setmode, $paramHashRef);
}

sub pushModeLeft {
	my $client = shift;
	my $setmode = shift;
	my $paramHashRef = shift;
	my $display = $client->display();

	my $oldlines = $display->curLines();

	unless ($display->hasScreen2) {
		
		pushMode($client, $setmode, $paramHashRef);

		if (!$client->modeParam('handledTransition')) {
			$display->pushLeft($oldlines, $display->curLines());
			$client->modeParam('handledTransition',0);
		}

	} else {

		my $oldscreen2 = $client->modeParam('screen2active');

		pushMode($client, $setmode, $paramHashRef);

		if (!$client->modeParam('handledTransition')) {
			$client->pushLeft($oldlines, pushpopScreen2($client, $oldscreen2));
			$client->modeParam('handledTransition',0);
		}
	}
}

sub popModeRight {
	my $client = shift;
	my $display = $client->display();

	my $oldlines = $display->curLines();

	unless ($display->hasScreen2) {

		Slim::Buttons::Common::popMode($client);

		$display->pushRight($oldlines, $display->curLines());

	} else {

		my $oldscreen2 = $client->modeParam('screen2active');

		Slim::Buttons::Common::popMode($client, 1);

		$display->pushRight($oldlines, pushpopScreen2($client, $oldscreen2));
	}
}

sub pushpopScreen2 {
	my $client = shift;
	my $oldscreen2 = shift;

	my $display = $client->display;

	my $newlines = $display->curLines();

	my $newscreen2 = $client->modeParam('screen2active');

	if ($newscreen2 && $newscreen2 eq 'periodic' && (!$oldscreen2 || $oldscreen2 ne 'periodic')) {
		my $linesfunc = $client->lines2periodic();
		$newlines->{'screen2'} = &$linesfunc($client);

	} elsif ($oldscreen2 && !$newscreen2) {
		$newlines->{'screen2'} = {};
	}

	return $newlines;
}

sub updateScreen2Mode {
	my $client = shift || return;

	my $screen2 = $client->modeParam('screen2active');

	if ($client->display->showExtendedText()) {
		if (!$screen2) {
			$client->modeParam('screen2active', 'periodic');
			startPeriodicUpdates($client);
		}
	} else {
		if ($screen2) {
			if ($screen2 eq 'periodic') {
				$client->modeParam('screen2active', undef);
			}
			$client->update( { 'screen2' => {} } );
		}
	}
}

sub suppressStatus {
	my $client = shift;

	my $suppress = $client->suppressStatus();

	return $suppress if (defined ($suppress));

	return undef unless $client->display->hasScreen2();

	my $screen2 = $client->modeParam('screen2active');

	if ($screen2 && $screen2 eq 'periodic') {
		return 1;
	}

	return undef;
}

sub dateTime {
	my $client = shift;

	return {
		'center' => [ Slim::Utils::DateTime::longDateF(), Slim::Utils::DateTime::timeF() ]
	};
}

sub startPeriodicUpdates {
	my $client = shift;

	# unset any previous timers
	Slim::Utils::Timers::killTimers($client, \&_periodicUpdate);

	my $interval  = $client->modeParam('modeUpdateInterval');
	my $interval2 = undef;

	if ($client->modeParam('screen2active') && $client->modeParam('screen2active') eq 'periodic') {

		$interval2 = 1;
	}

	return unless ($interval || $interval2);

	my $time = Time::HiRes::time() + ($interval || 0.05);

	Slim::Utils::Timers::setTimer($client, $time, \&_periodicUpdate, $client);

	$client->periodicUpdateTime($time);
}

# resych periodic updates to $time - to synchonise updates with time/elaspsed time
sub syncPeriodicUpdates {
	my $client = shift;
	my $time = shift || Time::HiRes::time();

	if (Slim::Utils::Timers::killTimers($client, \&_periodicUpdate)) {
		Slim::Utils::Timers::setTimer($client, $time, \&_periodicUpdate, $client);
		$client->periodicUpdateTime($time);
	}
}

sub _periodicUpdate {
	my $client = shift;

	my $update  = $client->modeParam('modeUpdateInterval');
	my $update2 = undef;

	if ($client->modeParam('screen2active') && $client->modeParam('screen2active') eq 'periodic') {

		$update2 = 1;
	}

	# if params not set then no longer required
	return unless ($update || $update2);

	# schedule the next update time, skip if running late
	my $time     = $client->periodicUpdateTime();
	my $timenow  = Time::HiRes::time();
	my $interval = $update || 1;

	do {
		$time += $interval;
	} while ($time < $timenow);

	Slim::Utils::Timers::setTimer($client, $time, \&_periodicUpdate, $client);

	$client->periodicUpdateTime($time);

	if ($client->display->updateMode) {
		return;
	}

	# updates not blocked
	if ($update) {
		$client->display->update();
	}

	if ($update2 && !$client->display->animateState() && (my $linefunc = $client->lines2periodic()) ) {
		$client->display->update({ 'screen2' => &$linefunc($client, 1) });
	}
}

=head1 SEE ALSO

L<Scalar::Util>

L<Slim::Utils::PluginManager>

L<Slim::Display::Display>

L<Slim::Buttons::*>

=cut


1;

__END__


# Local Variables:
# tab-width:4
# indent-tabs-mode:t
# End:
