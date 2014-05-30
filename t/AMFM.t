use 5.014;
use warnings;
use Test::More;
use AMFMTest;
use utf8;

# TODO should pass MPD-style statuses
# e.g.:
    #Time: 563
    #Artist: London After Midnight
    #Title: 99
    #Album: Psycho Magnet (re-release)
    #Track: 17
    #Date: 2003
    #Genre: Gothic
    #Pos: 22
# so that testing titles with tags would also be possible

my %test_titles = (
    'I want to be free' => ' <> ', # too much artists have the same song, skipping
    '06 - The Abhorrent Rays' => ' <> ', # -#-
    'X-Fusion - Shadow Of Myself (Club-Mix)' => 'X-Fusion <> Shadow Of Myself',
    '11-Dance Macabre-Cradle of Filth' => 'Cradle of Filth <> Dance Macabre',
    'Lords Of Acid - Heaven Is An Orgasm - Undress and Possess (Trance-Rave-Techno)' => 'Lords of Acid <> Heaven Is An Orgasm - undress and possess',
    'Tristesse de la Lune - Queen of The Damned' => 'Tristesse de la Lune <> Queen of The Damned',
    'Bloodbound -10- Midnight Sun' => 'Bloodbound <> Midnight Sun',
    'King Diamond - The Eye - Eye Of The Witch' => 'King Diamond <> Eye Of The Witch',
    '13-Hallowed Be Thy Name-Cradle of Filth' => 'Cradle of Filth <> Hallowed Be Thy Name',
    'Birthday Massacre, The - Shallow Grave [Assemblage  Mix]' => 'The Birthday Massacre <> Shallow Grave',
    'eSa:Tori - Belief' => 'eSa:Tori <> Belief',
    'I:Scintilla - Hollowed' => 'I:Scintilla <> Hollowed',
    "L'Âme Immortelle - Forgive Me (Remix)" => "l'âme immortelle <> forgive me",
    'De/Vision - Rage (Extended Club Version)' => 'De/Vision <> Rage',
    'Orchestral Manoeuvres In The Dark - Stay (The Black Rose And The U' => 'orchestral manoeuvres in the dark <> stay (the black rose and the u',
    'Echoing Green, The - Voices Carry' => 'The Echoing Green <> Voices Carry',
    #'104-syrian_-_empire_of_the_sands-tfp' => ' <> ', # TODO
    'Thomas Dolby - She Blinded Me With Science [12` Version]' => 'Thomas Dolby <> She Blinded Me With Science',
    'The Breath Of Life - No Way' => 'The Breath Of Life <> No Way', # weird search results with artist=The Breath of Life # TODO
    "Cure, The - Love Cats (12'' mix)" => 'The Cure <> The Love Cats',
    "Illuminate - Uber Deinen Schlaf" => 'Illuminate <> Uber Deinen Schlaf',
    "Sisters Of Mercy, The - Temple Of Love" => 'The Sisters Of Mercy <> Temple Of Love',
);

my $test_scrobbler = AMFM::Test->new;
$test_scrobbler->handshake;

for my $title (keys %test_titles) {
    $test_scrobbler->{title} = $title;
    is(lc($test_scrobbler->get_track_test()), lc($test_titles{$title}), "parse '$title'");
}

done_testing();
