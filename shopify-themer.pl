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
			Mainly used for debugging.

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
	'verbose' => \my $verbose,
	'<>' => sub { push(@ARGS, $_[0]->name); }
);
pod2usage() if ($help);
pod2usage(-verbose => 2) if ($fullhelp);

my $action = $ARGS[0];

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
	my $plugin_directory = $ENV{'HOME'} . "/.local/share/gedit/plugins";
	my $old_dir = "$plugin_directory/shopifyeditor";
	if (!-e $old_dir) {
		print "Checking for presence of gedit settings directory in $plugin_directory... ";
		if (!-d $plugin_directory) {
			print "No.\n";
			my $result = &prompt("y", "Would you like to create it?", undef, "y");
			if (!$result) {
				print "Aborting install.\n";
				exit(0);
			}
			make_path($plugin_directory);
		}
		else {
			print "Yes.\n";
		}
		print "Symlinking sharedir to directory... ";
		my $share_dir = dist_dir('WWW-Shopify-Tools-Themer');
		if (!-e $old_dir) {
			die "Can't symlink, for some reason.\n" unless symlink($share_dir, $old_dir) == 1;
		}
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

die "Please specify an action.\n" unless defined $action;

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
