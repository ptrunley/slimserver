package Slim::Formats::MP3;

# $Id$

# Squeezebox Server Copyright 2001-2009 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License, 
# version 2.

=head1 NAME

Slim::Formats::MP3

=head1 SYNOPSIS

my $tags = Slim::Formats::MP3->getTag( $filename );

=head1 DESCRIPTION

Read tags & metadata embedded in MP3 files.

=head1 METHODS

=cut

use strict;
use base qw(Slim::Formats);

use Audio::Scan;

use Fcntl qw(:seek);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::SoundCheck;
use Slim::Utils::Strings qw(string);

my $prefs = preferences('server');

my $log        = logger('formats.audio');
my $scannerlog = logger('scan.scanner');
my $sourcelog  = logger('player.source');

my %tagMapping = (
	'MUSICBRAINZ ALBUM ARTIST'          => 'ALBUMARTIST',
	'MUSICBRAINZ ALBUM ARTIST ID'       => 'MUSICBRAINZ_ALBUMARTIST_ID',
	'MUSICBRAINZ ALBUM ID'              => 'MUSICBRAINZ_ALBUM_ID',
	'MUSICBRAINZ ALBUM STATUS'          => 'MUSICBRAINZ_ALBUM_STATUS',
	'MUSICBRAINZ ALBUM TYPE'            => 'MUSICBRAINZ_ALBUM_TYPE',
	'MUSICBRAINZ ARTIST ID'             => 'MUSICBRAINZ_ARTIST_ID',
	'MUSICBRAINZ TRM ID'                => 'MUSICBRAINZ_TRM_ID',

	# J.River Media Center uses messed up tags. See Bug 2250
	'MEDIA JUKEBOX: REPLAY GAIN'        => 'REPLAYGAIN_TRACK_GAIN',
	'MEDIA JUKEBOX: ALBUM GAIN'         => 'REPLAYGAIN_ALBUM_GAIN',
	'MEDIA JUKEBOX: PEAK LEVEL'         => 'REPLAYGAIN_TRACK_PEAK',
	'MEDIA JUKEBOX: ALBUM ARTIST'       => 'ALBUMARTIST',

	# bug 10724 - foobar2000 users like to use "ALBUM ARTIST" (instead of "ALBUMARTIST")
	'ALBUM ARTIST'                      => 'ALBUMARTIST',
	
	# ID3v2 frame ID mapping to our keywords
	# Notes:
	# Audio::Scan via libid3tag already converts everything to ID3v2.4 IDs
	# so that's all we have to worry about here.
	# Non-standard v2.3 tags are prefixed with 'Y'
	COMM => "COMMENT",
	TALB => "ALBUM",
	TBPM => "BPM",
	TCOM => "COMPOSER",
	TCMP => "COMPILATION",
	YTCP => "COMPILATION", # non-standard v2.3 frame
	TCON => "GENRE",
	TYER => "YEAR",
	TDRC => "YEAR",
	TDOR => "YEAR",
	XDOR => "YEAR",
	TIT2 => "TITLE",
	TPE1 => "ARTIST",
	TPE2 => "BAND",
	TPE3 => "CONDUCTOR",
	TPOS => "SET",
	TRCK => "TRACKNUM",
	TSOA => "ALBUMSORT",
	YTSA => 'ALBUMSORT',
	TSOP => "ARTISTSORT",
	YTSP => "ARTISTSORT",      # non-standard iTunes tag
	TSOT => "TITLESORT",
	YTST => "TITLESORT",       # non-standard iTunes tag
	'TST ' => "TITLESORT",     # broken iTunes tag
	TSO2 => "ALBUMARTISTSORT",
	YTS2 => "ALBUMARTISTSORT", # non-standard iTunes tag
	TSOC => "COMPOSERSORT",
	YTSC => "COMPOSERSORT",    # non-standard iTunes tag
	YRVA => "RVAD",
	UFID => "MUSICBRAINZ_ID",
	USLT => "LYRICS",
	XSOP => "ARTISTSORT",
);

=head2 getTag( $filename )

Extract and return audio information & any embedded metadata found.

=cut

sub getTag {
	my $class = shift;
	my $file  = shift;
	
	my $isDebug = $log->is_debug;

	if (!$file) {
		$log->error("No file was passed!");
		return {};
	}
	
	my $s = Audio::Scan->scan( $file );
	
	my $info = $s->{info};
	my $tags = $s->{tags};
	
	return unless $info->{song_length_ms};

	# map the existing tag names to the expected tag names
	$class->doTagMapping($tags);
	
	# Map info into tags
	$tags->{TAGVERSION} = $info->{id3_version};
	$tags->{OFFSET}     = $info->{audio_offset};
	$tags->{SIZE}       = $info->{audio_size};
	$tags->{SECS}       = $info->{song_length_ms} / 1000;
	$tags->{BITRATE}    = $info->{bitrate};
	$tags->{STEREO}     = $info->{stereo};
	$tags->{CHANNELS}   = $info->{stereo} ? 2 : 1;
	$tags->{RATE}       = $info->{samplerate};
	
	if ( $info->{vbr} ) {
		$tags->{VBR_SCALE} = 1;
	}

	# when scanning we brokenly align by bytes.
	# XXX: needed?
	$tags->{BLOCKALIGN} = 1;

	return $tags;
}

=head2 getCoverArt( $filename )

Extract and return cover image from the file.

=cut

sub getCoverArt {
	my $class = shift;
	my $file  = shift || return undef;
	
	my $s = Audio::Scan->scan_tags($file);
	
	my $tags = $s->{tags};
	
	if ( my $pic = $tags->{APIC} ) {
		if ( ref $pic->[0] eq 'ARRAY' ) {
			# multiple images, return image with lowest image_type value
			return ( sort { $a->[2] <=> $b->[2] } @{$pic} )[0]->[4];
		}
		else {
			return $pic->[4];
		}
	}

	return undef;
}

# Read the initial audio frame, this supports seeking while preserving
# the Xing header needed for gapless playback
sub getInitialAudioBlock {
	my ( $class, $fh, $track, $timeOffset ) = @_;
	
	# Only bother if not playing from the start
	return if !$timeOffset;
	
	open my $localFh, '<&=', $fh;
	
	# Find the location of the next frame past the audio offset
	my $second_frame = Audio::Scan->find_frame_fh( mp3 => $localFh, $track->audio_offset + 1 );
	
	seek $localFh, $track->audio_offset, 0;
	
	read $localFh, my $buffer, $second_frame - $track->audio_offset;
	
	close $localFh;
	
	return $buffer;
}

=head2 findFrameBoundaries( $fh, $offset, $time )

Locate MP3 frame boundaries when seeking through a file.

=cut

sub findFrameBoundaries {
	my ( $class, $fh, $offset, $time ) = @_;
	
	if (!defined $fh || !defined $offset) {
		return 0;
	}
	
	return Audio::Scan->find_frame_fh( mp3 => $fh, $offset );
}

=head2 scanBitrate( $fh )

Scans a file and returns just the bitrate and VBR setting.  This is used
to determine the bitrate for remote streams.  We first look for a Xing VBR
header which gives us accurate VBR bitrates.  If this isn't found, we parse
each frame and calculate an average bitrate for all frames found.

We also look for any ID3 tags and set the title based on any that are found.

=cut

sub scanBitrate {
	my ( $class, $fh, $url ) = @_;
	
	# Scan the header for info/tags
	seek $fh, 0, 0;
	
	my $s = Audio::Scan->scan_fh( mp3 => $fh );
	
	my $info = $s->{info};
	my $tags = $s->{tags};
	
	$class->doTagMapping($tags);
	
	if ( $tags->{TITLE} ) {
		
		# XXX: Schema ignores ARTIST, ALBUM, YEAR, and GENRE for remote URLs
		# so we have to format our title info manually.
		my $track = Slim::Schema->updateOrCreate({
			url        => $url,
			attributes => {
				TITLE => $tags->{TITLE},
			},
		});
		
		if ( main::DEBUGLOG && $scannerlog->is_debug ) {
			$scannerlog->debug("Read ID3 tags from stream: " . Data::Dump::dump($tags));
		}
		
		my $title = $tags->{TITLE};
		$title .= ' ' . string('BY') . ' ' . $tags->{ARTIST} if $tags->{ARTIST};
		$title .= ' ' . string('FROM') . ' ' . $tags->{ALBUM}  if $tags->{ALBUM};
		
		Slim::Music::Info::setCurrentTitle( $url, $title );
		
		# Save artwork if found
		if ( my $pic = $tags->{APIC} ) {
			if ( ref $pic->[0] eq 'ARRAY' ) {
				# multiple images, use image with lowest image_type value
				$pic = ( sort { $a->[2] <=> $b->[2] } @{$pic} )[0];
			}
			
			$track->cover(1);
			$track->update;
			
			my $data = {
				image => $pic->[4],
				type  => $pic->[1] || 'image/jpeg',
			};
			
			my $cache = Slim::Utils::Cache->new( 'Artwork', 1, 1 );
			
			if ( main::SLIM_SERVICE ) {
				$cache->set( "cover_$url", $data, 86400 );
			}
			else {
				$cache->set( "cover_$url", $data, $Cache::Cache::EXPIRES_NEVER );
			}
			
			main::DEBUGLOG && $scannerlog->is_debug && $scannerlog->debug( 'Found embedded cover art, saving for ' . $track->url );
		}
	}
	
	main::DEBUGLOG && $scannerlog->is_debug && $scannerlog->debug(
		"Scanned bitrate from stream: " . $info->{bitrate} . ' ' . ( $info->{vbr} ? 'VBR' : 'CBR' )
	);
	
	return wantarray ? ( $info->{bitrate}, $info->{vbr} ) : $info->{bitrate};
}

sub doTagMapping {
	my ( $class, $tags, $no_overwrite ) = @_;
	
	# Bug 8001, remap TPE2 if user wants it to mean Album Artist
	# XXX: move this out to another function, no need to call it on every tag scan
	if ( $prefs->get('useTPE2AsAlbumArtist') ) {
		$tagMapping{TPE2} = 'ALBUMARTIST';
	}
	else {
		$tagMapping{TPE2} = 'BAND';
	}
	
	while ( my ($old, $new) = each %tagMapping ) {
		if ( exists $tags->{$old} ) {
			# Caller can set $no_overwrite if ID3 tags should not replace
			# existing tags, i.e. FLAC tags
			next if $no_overwrite && exists $tags->{$new};
				
			$tags->{$new} = delete $tags->{$old};
		}
	}
	
	# Special handling for UFID, pull out ID from array
	if ( exists $tags->{MUSICBRAINZ_ID} && ref $tags->{MUSICBRAINZ_ID} eq 'ARRAY' ) {
		# Sometimes UFID might be swapped, check every element
		for my $id ( @{ delete $tags->{MUSICBRAINZ_ID} } ) {
			if ( length($id) == 36 ) {
				$tags->{MUSICBRAINZ_ID} = $id;
				last;
			}
		}
	}

	# Look for iTunes SoundCheck data, unless we have a TXXX track gain tag
	if ( !$tags->{REPLAYGAIN_TRACK_GAIN} ) {
		# Pull out Relative Volume Adjustment information
		if ( my $rvad = delete $tags->{RVAD} ) {
			# Assume right/left channels are the same
			$tags->{REPLAYGAIN_TRACK_GAIN} = $rvad->[0];
		}
		elsif ( my $rva2 = delete $tags->{RVA2} ) {
			if ( ref $rva2->[0] eq 'ARRAY' ) {
				# Multiple RVA2 tags, they look like this:
				# RVA2 => [
				#	 ["track", 1, "-7.478516 dB", "1.172028 dB"],
				#	 ["album", 1, "-7.109375 dB", "1.258026 dB"],
				#  ],
				for my $rva ( @{$rva2} ) {
					if ( lc( $rva->[0] ) eq 'track' ) {
						$tags->{REPLAYGAIN_TRACK_GAIN} = $rva->[2];
						$tags->{REPLAYGAIN_TRACK_PEAK} = $rva->[3];
					}
					elsif ( lc( $rva->[0] ) eq 'album' ) {
						$tags->{REPLAYGAIN_ALBUM_GAIN} = $rva->[2];
						$tags->{REPLAYGAIN_ALBUM_PEAK} = $rva->[3];
					}
				}
			}
			else {	
				$tags->{REPLAYGAIN_TRACK_GAIN} = $rva2->[2];
				$tags->{REPLAYGAIN_TRACK_PEAK} = $rva2->[3];
			}
		}
	
		# Logic used here is:
		# If there is an iTunNORM tag and an RVA tag:
		#   Gain values are added together
		# If there is no iTunNORM tag, the value used is RVA if available
		# See bug 6890 for more info
	
		# Sometimes iTunNORM is not in a comment tag
		if ( $tags->{ITUNNORM} ) {
			$tags->{COMMENT} ||= [];
			push @{ $tags->{COMMENT} }, [ 0, 'eng', 'iTunNORM', delete $tags->{ITUNNORM} ];
		}
	
		if ( $tags->{COMMENT} ) {
			Slim::Utils::SoundCheck::commentTagTodB($tags);
		}
	}
	
	# We only want a 4-digit year
	if ( defined $tags->{YEAR} ) {
		my $year = $tags->{YEAR};

		# In the case where multiple YEAR elements are 
		# present (eg multi-value ID3v2.4) we only use
		# the first.
		$year = $year->[0] if ref $year eq 'ARRAY';
		
		if ( $year =~ /(\d\d\d\d)/ ) {
			$year = $1;
		}
		
		$tags->{YEAR} = $year;
	}
	
	# Clean up comments
	if ( $tags->{COMMENT} && ref $tags->{COMMENT} eq 'ARRAY' ) {
		my $fixed = [];
		
		if ( ref $tags->{COMMENT}->[0] eq 'ARRAY' ) {
			for my $comment ( @{ $tags->{COMMENT} } ) {
				if ( $comment->[2] ) {
					# Comment has a description
					push @{$fixed}, $comment->[2] . ': ' . $comment->[3];
				}
				else {
					push @{$fixed}, $comment->[3];
				}
			}
		}
		else {
			if ( $tags->{COMMENT}->[2] ) {
				push @{$fixed}, $tags->{COMMENT}->[2] . ': ' . $tags->{COMMENT}->[3];
			}
			else {
				push @{$fixed}, $tags->{COMMENT}->[3];
			}
		}
		
		$tags->{COMMENT} = $fixed;
	}
	
	# Clean up lyrics
	if ( $tags->{LYRICS} && ref $tags->{LYRICS} eq 'ARRAY' ) {
		$tags->{LYRICS} = $tags->{LYRICS}->[3];
	}
	
	# Flag if we have embedded cover art
	$tags->{HAS_COVER} = 1 if $tags->{APIC};
}

sub canSeek { 1 }

1;
