## <a href="https://raw.github.com/anka-sirota/amfm/master/logo.png"><img src="https://raw.github.com/anka-sirota/amfm/master/logo_16x16.png" alt="Logo"/></a> amfm 


Simple Last.fm scrobbler for MPD written in Perl;

## How it works

This scrobbler is designed to scrobble internet radio.
amfm uses MPD 'currentsong' command to fetch a title of the song. Before submitting any track amfm searches for correct track name and artist using Last.fm API 'track.search' method. If search results looks good enough then amfm updates 'Now Playing' status and scrobbles the corrected track after 30 seconds playback.

Please keep in mind that this is still a work-in-progress.

### Usage

There's not much configuration available yet. Everything script needs can be supplied through the environment variables:

        MPD_PORT=6600 MPD_HOST=locahost LASTFM_USERNAME=foo LASTFM_PASSWORD=bar perl amfm.pl --start|--stop|--restart
