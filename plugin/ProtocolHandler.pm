package Plugins::Pyrrha::ProtocolHandler;

use strict;
use base qw(Slim::Player::Protocols::HTTP);
use Plugins::Pyrrha::Pandora qw(getPlaylist getAdMetadata registerAd);

use Promise::ES6;

my $log = Slim::Utils::Log->addLogCategory({
  category     => 'plugin.pyrrha',
  defaultLevel => 'INFO',
  description  => 'PLUGIN_PYRRHA_MODULE_NAME',
});


# max time player can be idle before stopping playback (8 hours)
my $MAX_IDLE_TIME = 60 * 60 * 8;


sub new {
  my $class = shift;
  my $args  = shift;

  my $client = $args->{client};

  my $song = $args->{'song'};
  my $streamUrl = $song->streamUrl() || return;

  $log->info( 'PH:new(): ' . $streamUrl );

  my $sock = $class->SUPER::new( {
    url     => $streamUrl,
    song    => $args->{'song'},
    client  => $client,
    bitrate => $song->bitrate() || 128_000,
  } ) || return;

  ${*$sock}{contentType} = 'audio/mpeg';

  return $sock;
}


sub scanUrl {
  my ($class, $url, $args) = @_;
  $args->{'cb'}->($args->{'song'}->currentTrack());
}


sub isRepeatingStream { 1 }


sub _trackOrAd {
  my $stationId = shift;
  my $track = shift;

  # just return the track if not an ad
  my $adToken = $track->{'adToken'};
  return Promise::ES6->resolve($track) if ! $adToken;

  # get ad metadata
  getAdMetadata(adToken => $adToken)->then(sub {
  my $ad = shift;

  # make this ad look like a track
  return {
    audioUrlMap         => $ad->{'audioUrlMap'},
    songIdentity        => $adToken,
    artistName          => $ad->{'companyName'},
    albumName           => 'Advertisement',
    songName            => $ad->{'title'},
    albumArtUrl         => $ad->{'imageUrl'},
    '_isAd'             => 1,
    '_stationId'        => $stationId,
    '_adTrackingTokens' => $ad->{'adTrackingTokens'},
  };

  })->catch(sub {
  my $error = shift;
  $log->error('unable to get ad metadata: ' . $error);
  die $error;
  });
}


sub _getPlaylistWithAds {
  my $stationId = shift;

  # fetch a new play list
  getPlaylist($stationId)->then(sub {
  my $playlist = shift;

  # convert any ads to "tracks"
  my @tracks = map { _trackOrAd($stationId, $_) } @$playlist;

  return Promise::ES6->all(\@tracks);
  });
}


sub _getNextStationTrack {
  my $stationId   = shift;
  my $oldPlaylist = shift;  # previously cached playlist

  # use previously cached playlist or fetch a new one
  ($oldPlaylist && @$oldPlaylist ?
      Promise::ES6->resolve($oldPlaylist)
    : _getPlaylistWithAds($stationId)
  )->catch(sub {
    die 'Unable to get play list';
  })->then(sub {
  my $playlist = shift;

  # get the next track
  my $track = shift @$playlist;

  # if it's an ad, register that we're going to play it
  if ($track->{'_isAd'}) {
    registerAd(
        stationId => $track->{'_stationId'},
        adTrackingTokens => $track->{'_adTrackingTokens'}
      )->catch(sub {
        $log->debug('registerAd failed: ' . shift);
      });
  }

  # if it doesn't have audio, go to the next one
  if (! $track->{'audioUrlMap'}) {
    return _getNextStationTrack($stationId, $playlist);
  }

  return [$track, $playlist];
  });
}


sub getNextTrack {
  my ($class, $song, $successCb, $errorCb) = @_;

  my $client = $song->master();
  my $url    = $song->track()->url;
  my ($urlUsername, $urlStationId) = $url =~ m{^pyrrha://([^/]+)/([^.]+)\.mp3};

  $log->info( $url );

  # idle time check
  if ($client->isPlaying()) {
    # get last activity time from this player and any synced players
    my $lastActivity = $client->lastActivityTime();
    if ($client->isSynced(1)) {
      for my $c ($client->syncGroupActiveMembers()) {
        my $otherActivity = $c->lastActivityTime();
        if ($otherActivity > $lastActivity) {
          $lastActivity = $otherActivity;
        }
      }
    }
    # idle too long?
    if (time() - $lastActivity >= $MAX_IDLE_TIME) {
      $log->info('idle time reached, stopping playback');
      $client->playingSong()->pluginData({
        songName => $client->string('PLUGIN_PYRRHA_IDLE_STOPPING'),
      });
      $errorCb->('PLUGIN_PYRRHA_IDLE_STOPPING');
      return;
    }
  }

  my $station = $client->master->pluginData('station');
  if ($station) {
    $log->info('found cached station data ' . ($station->{'stationId'}));
    $log->info('playlist length: ' . (scalar @{$station->{'playlist'}}));
    if ($urlStationId ne $station->{'stationId'}) {
      $log->info('station change ' . $urlStationId);
    }
  }
  else {
    $log->info('no previous station data');
  }

  my $oldPlaylist = $station && $urlStationId eq $station->{'stationId'}
    ? $station->{'playlist'}
    : [];

  # get next track for station
  _getNextStationTrack($urlStationId, $oldPlaylist)->then(sub {
  my $trackAndPlaylist = shift;
  my ($track, $newPlaylist) = @$trackAndPlaylist;

  # cache new playlist
  my %station = (
    'stationId' => $urlStationId,
    'playlist'  => $newPlaylist,
  );
  $client->master->pluginData('station', \%station);

  # populate song data
  my $audio = exists($track->{'additionalAudioUrl'}) ?
    {
      protocol => 'http',
      audioUrl => $track->{'additionalAudioUrl'},
      encoding => 'mp3',
      bitrate  => 128,
    } :
    $track->{'audioUrlMap'}->{'highQuality'};

  if ($track->{'_isAd'}) {
    #XXX squeezelite fails to connect to aws cloudfront when
    #    https is used, but it will work with http:
    $audio->{'audioUrl'} =~ s/^https/http/;
  }

  $track->{'_audio'} = $audio;
  $song->bitrate($audio->{'bitrate'} * 1000);
  $song->duration($track->{'trackLength'} * 1) if defined $track->{'trackLength'};
  $song->streamUrl($audio->{'audioUrl'});
  $song->pluginData('track', $track);
  $log->info('next in playlist: ' . ($track->{'songIdentity'}));

  $successCb->();

  })->catch(sub {

  $errorCb->('Unable to get play list');

  });
}


sub suppressPlayersMessage {
  my ($class, $master, $song, $message) = @_;
  if ($message eq 'PROBLEM_CONNECTING') {
    my $url = $song->track()->url;
    $log->error("stream error: $url PROBLEM_CONNECTING");
    # error possibly due to stale playlist
    # clear playlist cache to force fetch of new playlist
    my $client = $song->master();
    $client->master->pluginData('station', 0);
  }
  return 0;
}


sub handleDirectError {
  my ($class, $client, $url, $response, $status_line) = @_;
  $log->error("direct stream error: $url [$response] $status_line");
  # error possibly due to stale playlist
  # clear playlist cache to force fetch of new playlist
  $client->master->pluginData('station', 0);
  # notify the controller
  $client->controller()->playerStreamingFailed($client, 'PLUGIN_PYRRHA_STREAM_FAILED');
}


sub canDoAction {
  my ($class, $client, $url, $action) = @_;

  # disallow rewind
  if ($action eq 'rew') {
    return 0;
  }

  # disallow skip for now
  if ($action eq 'stop') {
    return 0;
  }

  return 1;
}


sub trackGain {
  my ($class, $client, $url) = @_;

  my $track = $client->streamingSong()->pluginData('track');
  my $gain = $track->{'trackGain'} || 0;

  return $gain * 1;
}


sub getMetadataFor {
  my ($class, $client, $url, $forceCurrent) = @_;

  my $song = $forceCurrent ? $client->streamingSong() : $client->playingSong();
  return {} unless $song;

  my $track = $song->pluginData('track');
  if ($track && %$track) {
    return {
      artist  => $track->{artistName},
      album   => $track->{albumName},
      title   => $track->{songName},
      cover   => $track->{albumArtUrl},
      bitrate => $song->bitrate ? ($song->bitrate/1000) . 'k' : '',
      buttons => {
        rew => 0,
        fwd => 0,
      },
    };
  }
  else {
    return {};
  }
}


sub formatOverride {
  my ($class, $song) = @_;
  my $track = $song->pluginData('track');
  my $audio = $track->{'_audio'};
  my $encoding = $audio->{'encoding'};
  return 'mp4' if $encoding eq 'aacplus';
  return 'mp3';
}


1;

