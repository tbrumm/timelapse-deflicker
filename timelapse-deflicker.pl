#!/usr/bin/perl

# Script for simple and fast photo deflickering using imagemagick library
# Copyright Vangelis Tasoulas (cyberang3l@gmail.com)
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

# Needed packages
use Getopt::Std;
use strict "vars";
use feature "say";
use Image::Magick;
use Data::Dumper;
use File::Type;
use Term::ProgressBar;
use Image::ExifTool qw(:Public);

#use File::Spec;

# Global variables
my $VERBOSE       = 0;
my $DEBUG         = 0;
my $RollingWindow = 15;
my $Passes        = 1;

#####################
# handle flags and arguments
# h is "help" (no arguments)
# v is "verbose" (no arguments)
# d is "debug" (no arguments)
# w is "rolling window size" (single numeric argument)
# p is "passes" (single numeric argument)
my $opt_string = 'hvdw:p:';
getopts( "$opt_string", \my %opt ) or usage() and exit 1;

# print help message if -h is invoked
if ( $opt{'h'} ) {
  usage();
  exit 0;
}

$VERBOSE       = 1         if $opt{'v'};
$DEBUG         = 1         if $opt{'d'};
$RollingWindow = $opt{'w'} if defined( $opt{'w'} );
$Passes        = $opt{'p'} if defined( $opt{'p'} );

#This integer test fails on "+n", but that isn't serious here.
die "The rolling average window for luminance smoothing should be a positive number greater or equal to 2" if ! ($RollingWindow eq int( $RollingWindow ) && $RollingWindow > 1 ) ;
die "The number of passes should be a positive number greater or equal to 1"                               if ! ($Passes eq int( $Passes ) && $Passes > 0 ) ;

# Create hash to hold luminance values.
# Format will be: TODO: Add this here
my %luminance;

# The working directory is the current directory.
my $data_dir = ".";
opendir( DATA_DIR, $data_dir ) || die "Cannot open $data_dir\n";
#Put list of files in the directory into an array:
my @files = readdir(DATA_DIR);
#Assume that the files are named in dictionary sequence - they will be processed as such.
@files = sort @files;

#Initialize count variable to number files in hash
my $count = 0;

#Initialize a variable to hold the previous image type detected - if this changes, warn user
my $prevfmt = "";

#Process the list of files, putting all image files into the luminance hash.
if ( scalar @files != 0 ) {
  foreach my $filename (@files) {
      my $ft   = File::Type->new();
      my $type = $ft->mime_type($filename);
      my ( $filetype, $fileformat ) = split( /\//, $type );
      #If it's an image file, add it to the luminance hash.
      if ( $filetype eq "image" ) {
	#Check whether we have a new image format - this is probably unwanted, so warn the user.
	if ( $prevfmt eq "" ) { $prevfmt = $fileformat } elsif ( $prevfmt ne "warned" && $prevfmt ne $fileformat ) {
	  say "Images of type $prevfmt and $fileformat detected! ARE YOU SURE THIS IS JUST ONE IMAGE SEQUENCE?";
	  #no more warnings about this from now on
	  $prevfmt = "warned"
	}
	$luminance{$count}{filename} = $filename;
	$count++;
      }
  }
}


my $max_entries = scalar( keys %luminance );

if ! ( $max_entries > 1 ) { die "Cannot process less than two files.\n" } else {
  say "$max_entries image files to be processed.";
  say "Original luminance of Images is being calculated";
  say "Please be patient as this might take several minutes...";
}

#Get luminance stats for each of the images:
for ( my $i = 0; $i < $max_entries; $i++ ) {

    verbose("Original luminance of Image $luminance{$i}{filename} is being processed...\n");

    #Create ImageMagick object for the image
    my $image = Image::Magick->new;
    #Evaluate the image using ImageMagick.
    $image->Read($luminance{$i}{filename});
    my @statistics = $image->Statistics();
    # Use the command "identify -verbose <some image file>" in order to see why $R, $G and $B
    # are read from the following index in the statistics array
    # This is the average R, G and B for the whole image.
    my $R          = @statistics[ ( 0 * 7 ) + 3 ];
    my $G          = @statistics[ ( 1 * 7 ) + 3 ];
    my $B          = @statistics[ ( 2 * 7 ) + 3 ];

    # We use the following formula to get the perceived luminance
    $luminance{$i}{original} = 0.299 * $R + 0.587 * $G + 0.114 * $B;
    $luminance{$i}{value}    = $luminance{$i}{original};

    #Create exifTool object for the image
    my $exifTool = new Image::ExifTool;
    #Write luminance info to an xmp file.
    $exifTool->SetNewValue(Author => "Joe Author" ); #TODO: Create and set custom tag instead of author tag
    $exifTool->WriteInfo(undef, $luminance{$i}{filename} . ".xmp", 'XMP'); #Write the XMP file
  }

}

my $CurrentPass = 1;

while ( $CurrentPass <= $Passes ) {
  say "\n-------------- LUMINANCE SMOOTHING PASS $CurrentPass/$Passes --------------\n";
  luminance_calculation();
  $CurrentPass++;
}

say "\n\n-------------- CHANGING OF BRIGHTNESS WITH THE CALCULATED VALUES --------------\n";
luminance_change();

say "\n\nJob completed";
say "$max_entries files have been processed";

#####################
# Helper routines

sub luminance_calculation {
  #my $max_entries = scalar( keys %luminance );
  my $progress    = Term::ProgressBar->new( { count => $max_entries } );
  my $low_window  = int( $RollingWindow / 2 );
  my $high_window = $RollingWindow - $low_window;

  for ( my $i = 0; $i < $max_entries; $i++ ) {
    my $sample_avg_count = 0;
    my $avg_lumi         = 0;
    for ( my $j = ( $i - $low_window ); $j < ( $i + $high_window ); $j++ ) {
      if ( $j >= 0 and $j < $max_entries ) {
        $sample_avg_count++;
        $avg_lumi += $luminance{$j}{value};
      }
    }
    $luminance{$i}{value} = $avg_lumi / $sample_avg_count;

    $progress->update( $i + 1 );
  }
}

sub luminance_change {
  my $max_entries = scalar( keys %luminance );
  my $progress = Term::ProgressBar->new( { count => $max_entries } );

  for ( my $i = 0; $i < $max_entries; $i++ ) {
    debug("Original luminance of $luminance{$i}{filename}: $luminance{$i}{original}\n");
    debug("Changed luminance of $luminance{$i}{filename}: $luminance{$i}{value}\n");

    my $brightness = ( 1 / ( $luminance{$i}{original} / $luminance{$i}{value} ) ) * 100;

    debug("Imagemagick will set brightness of $luminance{$i}{filename} to: $brightness\n");

    if ( !-d "Deflickered" ) {
      mkdir("Deflickered") || die "Error creating directory: $!\n";
    }
    #TODO: Create directory name with timestamp to avoid overwriting previous work.

    debug("Changing brightness of $luminance{$i}{filename} and saving to the destination directory...\n");
    my $image = Image::Magick->new;
    $image->Read( $luminance{$i}{filename} );

    $image->Mogrify( 'modulate', brightness => $brightness );

    $image->Write( "Deflickered/" . $luminance{$i}{filename} );

    $progress->update( $i + 1 );
  }
}

sub usage {

  # prints the correct use of this script
  say "Usage:";
  say "-w    Choose the rolling average window for luminance smoothing (Default 15)";
  say "-p    Number of luminance smoothing passes (Default 1)";
  say "       Sometimes 2 passes might give better results.";
  say "       Usually you would not want a number higher than 2.";
  say "-h    Usage";
  say "-v    Verbose";
  say "-d    Debug";
}

sub verbose {
  print $_[0] if ($VERBOSE);
}

sub debug {
  print $_[0] if ($DEBUG);
}
