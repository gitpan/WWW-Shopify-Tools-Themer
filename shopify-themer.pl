#!/usr/bin/perl
use strict;
use warnings;

use File::Slurp;
use Getopt::Long;
use IO::Handle;
use File::Basename;
use Term::Prompt;
use File::ShareDir qw(dist_dir);
use File::Path qw(make_path);
use Pod::Usage;
use Cwd 'abs_path';
STDERR->autoflush(1);
STDOUT->autoflush(1);

=head1 NAME

shopify-themer.pl - Supports the pushing and pulling of themes from a shopify store.

=head1 SYNOPSIS

shopify-themer.pl action [options]

	action		Action can be one of several things.
		
			info
			Spits out a bunch of theme information in JSON form.
			Mainly used for debugging, and gedit integration.

			pullAll
			Pulls all themes from the shop

			pushAll
			Pushes all assets from all themes.

			push <ID/Name>
			Pushes all assets from the specified theme.

			pull <ID/Name>
			Pulls all assets form the specified theme.

			installGedit
			Checks for gedit on the system and then
			installs the appropriate plugin into
			the gedit configuration folder.
	
	--help		Displays this messaqge.
	--fullhelp	Displays the full pod doc.

	--wd		Sets the working directory to be something other
			than .

	This following three parameters only need to be speciefied once
	per working directory, as it will be saved in a hidden file in
	that directory.

	--url		Sets the shop url.
	--api_key	Sets the api key of your private application.
	--password	Sets the password of your prviate application.

=cut

=head1 DESCRIPTION

Shopify themer is a simple script which uses WWW::Shopify::Private to 
fetch themes and assets from a Shopify store. It is meant to be used
as either a standalone application, or integrated with Gedit as a plugin.

The gedit plugin is written in python, but ultimately is simply a wrapper
around this script. Currently, support is limited to those OSs which look
like Linux (i.e., have a home folder, with the gedit plugins located at
~/.local/share/gedit/plugins, and which can make symlinnks (not Windows XP)).

Windows support will be possible in newer versions.

Normally, you only have to specify the shop url, api key and password
once per working directory/site. Don't try and create multiple site themes
in the same directory as this is a _BAD_ _IDEA_. 

The Shopify shop is the ultimate arbitrator of what is the 'final' version
of a file; this makes good sense when multiple people are working on a shop,
but may be somewhat annoying. What this means, is that:

For pushing:
Files that are locally changed, and remotely not, will be pushed.
Files that are locally changed, and remotely changed, will not be pushed.
Files that are locally unchanged will only be pushed if the file is missing on the server.

For pulling:
Files that are locally and remotely changed will be overwritten locally, so keep an eye out for this.
Files that are locally not, and remotely chagned will be overritten locally.
Files that are not present locally and remotely present will be pulled.

=cut

use WWW::Shopify::Tools::Themer;

use JSON qw(encode_json decode_json);

my @ARGS = ();

my $settings = {working => '.'};
GetOptions(
	"url=s" => \$settings->{url},
	"api_key=s" => \$settings->{apikey},
	"password=s" => \$settings->{password},
	"wd=s" => \$settings->{working},
	"help" => \my $help,
	"fullhelp" => \my $fullhelp,
	'<>' => sub { push(@ARGS, $_[0]->name); }
);

my $action = $ARGS[0];

pod2usage(-verbose => 2) if ($fullhelp);
pod2usage() if ($help || !defined $action);

if ($action eq 'installGedit') {
	die "Must have HOME environment variable defined; I'm guessing you're using this on windows? Sorry, automatic gedit installation isn't supported.\n" unless $ENV{'HOME'};
	die "You system doesn't support symlinks. Which is crazy. Not supported, aborting install.\n" unless eval { symlink("", ""); 1; };
	print "Checking to see if gedit exists... ";
	`gedit --version`;
	die "Can't detect gedit.\n" unless $? == 0;
	print "Yes.\n";
	print "Checking to see if python exists... ";
	`python --version`;
	die "Can't detect python.\n" unless $? == 0;
	my $share_directory = $ENV{'HOME'} . "/.local/share";
	my $plugin_directory = "$share_directory/gedit/plugins";
	my $dist_directory = dist_dir('WWW-Shopify-Tools-Themer');

	sub prompt_directory {
		my ($directory) = @_;
		if (!-d $directory) {
			print "No.\n";
			my $result = &prompt("y", "Would you like to create it?", undef, "y");
			if (!$result) {
				print "Aborting install.\n";
				exit(0);
			}
			make_path($directory);
		}
		else {
			print "Yes.\n";
		}
	}

	my $target_directory = "$plugin_directory/shopifyeditor";
	if (!-e $target_directory) {
		print "Checking for presence of gedit settings directory in $plugin_directory... ";
		prompt_directory($plugin_directory);
		print "Symlinking sharedir to directory... ";
		die "Can't symlink, for some reason.\n" if symlink($dist_directory, $target_directory) != 1;
		print "Yes.\n";
	}
	my $language_directory = "$share_directory/gtksourceview-3.0";
	if (!-e "$language_directory/language-specs") {
		print "Checking for presence of source view languages in $language_directory... ";
		prompt_directory($language_directory);
		print "Symlinking language dir to directory... ";
		die "Can't symlink for some reason.\n" if symlink("$dist_directory/languages", "$language_directory/language-specs") != 1;
		print "Yes.\n";
	}
	print "Done.\n";
	exit(0);
}

my ($settingFile, $manifestFile) = ($settings->{working} . "/.shopsettings", $settings->{working} . "/.shopmanifest");
my $filesettings = decode_json(read_file($settingFile)) if (-e $settingFile);
for (keys(%$filesettings)) { $settings->{$_} = $filesettings->{$_} unless defined $settings->{$_}; }
die "Please specify a --url, --apikey and --password when using for the first time.\n" unless defined $settings->{url} && defined $settings->{password} && defined $settings->{apikey};

write_file($settingFile, encode_json($settings));


my $STC = new WWW::Shopify::Tools::Themer($settings);
$STC->manifest()->load($manifestFile) if -e $manifestFile;

use List::Util qw(first);
my %actions = (
	'info' => sub {
		my @themes = $STC->get_themes;
		print encode_json(int(@themes) > 0 ? \@themes : []);
	},
	'pullAll' => sub {
		$STC->pull_all($settings->{working});
	},
	'pushAll' => sub {
		$STC->push_all($settings->{working});
	},
	'push' => sub {
		die "Please specify a specific theme to push.\n" unless int(@ARGS) >= 2;
		my $theme = undef;
		if ($ARGS[1] =~ m/^\d+$/) {
			$theme = first { $_->{id} eq $ARGS[1] } @{$STC->manifest->{themes}};
		}
		else {
			$theme = first { $_->{name} eq $ARGS[1] } @{$STC->manifest->{themes}}
		}
		die "Unable to find theme " . $ARGS[1] . "\n" unless $theme;
		$STC->push($theme, $settings->{working});
	},
	'pull' => sub {
		die "Please specify a specific theme to pull.\n" unless int(@ARGS) >= 2;
		my $theme = undef;
		if ($ARGS[1] =~ m/^\d+$/) {
			$theme = first { $_->{id} eq $ARGS[1] } @{$STC->manifest->{themes}};
		}
		else {
			$theme = first { $_->{name} eq $ARGS[1] } @{$STC->manifest->{themes}}
		}
		die "Unable to find theme " . $ARGS[1] . "\n" unless $theme;
		$STC->pull($theme, $settings->{working});
	}
);

die "Unknown action: $action.\n" unless exists ($actions{$action});
eval {
	$actions{$action}();
};
if ($@) {
	use Data::Dumper;
	print STDERR Dumper($@);
	if (ref($@->error) eq "HTTP::Response") {
		if ($@->error->code == 500) {
			print $@->error->content;
		}
		else {
			my $json = decode_json($@->error->content);
			print $json->{errors}->{asset}->[0];
		}
	}
	else {
		print $@->error
	}
}

$STC->manifest->save($manifestFile);

exit 0;


=head1 SEE ALSO

L<WWW::Shopify>, L<WWW::Shopify::Private>

=head1 AUTHOR

Adam Harrison (adamdharrison@gmail.com)

=head1 LICENSE

Copyright (C) 2013 Adam Harrison

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut

