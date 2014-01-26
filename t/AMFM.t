use 5.014;
use warnings;
use Test::More;
use AMFMTest;
use utf8;

my %test_titles = (
    '06 - The Abhorrent Rays' => 'Draconian <> The Abhorrent Rays',
    'X-Fusion - Shadow Of Myself (Club-Mix)' => 'X-Fusion <> Shadow Of Myself (Club-Mix)',
    '11-Dance Macabre-Cradle of Filth' => 'Cradle of Filth <> Dance Macabre',
    '06 - The Abhorrent Rays' => 'Draconian <> The Abhorrent Rays',
    '04. Everyone I Love Is Dead' => 'Type O Negative <> Everyone I Love Is Dead',
    'Lords Of Acid - Heaven Is An Orgasm - Undress and Possess (Trance-Rave-Techno)' => 'Lords of Acid <> Heaven Is An Orgasm - Undress and Possess (Trance-Rave-Techno)',
    'Tristesse de la Lune - Queen of The Damned' => 'Tristesse de la Lune <> Queen of The Damned',
    'Bloodbound -10- Midnight Sun' => 'Bloodbound <> Midnight Sun',
    'King Diamond - The Eye - Eye Of The Witch' => 'King Diamond <> Eye Of The Witch',
    'Mud and Ashes' => 'Of Echoes <> Mud and Ashes',
    '13-Hallowed Be Thy Name-Cradle of Filth' => 'Cradle of Filth <> Hallowed Be Thy Name',
    'Nightmare' => ' <> ',
    '13- Nightmare- ' => ' <> ',
    'Birthday Massacre, The - Shallow Grave [Assemblage  Mix]' => 'The Birthday Massacre <> Shallow Grave (Assemblage 23 Mix)',
    'eSa:Tori - Belief' => 'eSa:Tori <> Belief',
    'I:Scintilla - Hollowed' => 'I:Scintilla <> Hollowed',
    "L'Âme Immortelle - Forgive Me (Remix" => "l'âme immortelle <> forgive me (remix 2000)",
    'De/Vision - Rage (Extended Club Version)' => 'De/Vision <> Rage (Extended Club Version)',
    'Orchestral Manoeuvres In The Dark - Stay (The Black Rose And The U' => ' <> ', # TODO
    'Echoing Green, The - Voices Carry' => 'The Echoing Green <> Voices Carry',
    'skindeep-radial' => ' <> ',
    '104-syrian_-_empire_of_the_sands-tfp' => 'Syrian <> Empire of the Sands',
);

my $test_scrobbler = AMFM::Test->new;
$test_scrobbler->handshake;

for my $title (keys %test_titles) {
    $test_scrobbler->{title} = $title;
    is(lc($test_scrobbler->get_track_test()), lc($test_titles{$title}), "parse '$title'");
}

done_testing();
