## amfm

Simple Last.fm scrobbler for MPD written in Perl;

* Uses only the title tag (can scrobble radio);
* Updates 'Now Playing' status;
* Scrobbles track after 30 seconds playback; 
* Work-in-progress!

### Usage

There's no much configuration available yet. Everything script needs can be supplied through the environment variables:

        MPD_PORT=6600 MPD_HOST=locahost LASTFM_USERNAME=foo LASTFM_PASSWORD=bar perl amfm.pl
