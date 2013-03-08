#!/usr/bin/perl

use strict;
use warnings;

use WWW::Shopify;
use WWW::Shopify::Private;

package WWW::Shopify::Tools::Themer::Manifest;
use JSON;
use File::Slurp::Unicode;
use File::stat;

sub new { return bless { }, $_[0]; }
sub load { 
	die unless -e $_[1];
	my $json = decode_json(read_file($_[1]));
	for (keys(%{$json->{files}})) {
		$json->{files}->{$_}->{'local'} = DateTime->from_epoch(epoch => $json->{files}->{$_}->{'local'});
		$json->{files}->{$_}->{'remote'} = DateTime->from_epoch(epoch => $json->{files}->{$_}->{'remote'});
		$json->{files}->{$_}->{'system'} = DateTime->from_epoch(epoch => $json->{files}->{$_}->{'system'});
	}
	$_[0]->{files} = $json->{files};
	$_[0]->{themes} = $json->{themes};
}
sub save { 
	my $json = {themes => [], files => {}};
	for (keys(%{$_[0]->{files}})) {
		$json->{files}->{$_} = {
			'local' => $_[0]->{files}->{$_}->{'local'}->epoch,
			'remote' => $_[0]->{files}->{$_}->{'remote'}->epoch,
			'system' => $_[0]->{files}->{$_}->{'system'}->epoch
		};
	}
	$json->{themes} = [map { {name => $_->{name}, id => $_->{id}} } @{$_[0]->{themes}} ];
	write_file($_[1], encode_json($json)) or die $!;
}

sub exists { return (exists $_[0]->{files}->{$_[1]}); }
sub local { $_[0]->{files}->{$_[1]}->{'local'} = $_[2] if int(@_) == 3; return $_[0]->{files}->{$_[1]}->{'local'}; }
sub remote { $_[0]->{files}->{$_[1]}->{'remote'} = $_[2] if int(@_) == 3; return $_[0]->{files}->{$_[1]}->{'remote'}; }
sub system { $_[0]->{files}->{$_[1]}->{'system'} = $_[2] if int(@_) == 3; return $_[0]->{files}->{$_[1]}->{'system'}; }
sub files { return keys(%{$_[0]->{files}}); }

sub has_local_changes($$) { 
	my ($self, $path) = @_;
	#return 0 if !$self->exists($path) || !(-e $path) || !$self->local($path);
	return 1 if !$self->exists($path) || !(-e $path) || !$self->local($path);
	return ($self->system($path) < DateTime->from_epoch(epoch => stat($path)->mtime));
}
sub has_remote_changes($$) {
	my ($self, $path) = @_;
	return undef unless $self->remote($path);
	return 1 if !(-e $path) || !$self->local($path);
	return ($self->local($path) < $self->remote($path));
}

package WWW::Shopify::Tools::Themer;
use File::Basename;
use LWP::Simple;
use File::Slurp::Unicode;
use File::Path qw(make_path);
use File::Find;
use File::stat;
use JSON;
use MIME::Base64;
use threads;
use threads::shared;

our $VERSION = '0.02';

=head1 WWW::Shopify::Tools::Themer

The core class that deals with theme management, pushing and pulling to and from a shopify store.

	my $STC = new WWW::Shopify::Tools::Themer({url => $myurl, apikey => $myapikey, password => $mypassword});

=cut

sub new {
	my ($package, $settings) = @_;
	my $SA = new WWW::Shopify::Private($settings->{url}, $settings->{apikey}, $settings->{password});
	die unless defined $settings->{url} && defined $settings->{password} && defined $settings->{apikey};
	my $threads = (defined $settings->{threads}) ? $settings->{threads} : 4;
	return bless { _SA => $SA, _manifest => new WWW::Shopify::Tools::Themer::Manifest(), _threads => $threads }, $package;
}

use IO::Handle;
STDERR->autoflush(1);
STDOUT->autoflush(1);

sub threads() { return $_[0]->{_threads}; }
sub log($$) { print STDOUT $_[1]; }
sub manifest() { return $_[0]->{_manifest}; }
sub sa() { return $_[0]->{_SA}; }

=head1 get_themes

get_themes returns an array of all the themes present in the shop, with the active theme first.s

=cut

sub get_themes {
	my ($self) = @_;
	my @themes = $self->sa()->get_all('Theme');
	$self->manifest->{themes} = [map { { name => $_->name, id => $_->id } } @themes];
	return @{$self->manifest->{themes}};
}

=head1 pull_all

pull_all essentially pulls all themes from the remote site. Gets all themes using the API, and then calls pull on each of them.

	$STC = new WWW::Shopify::Tools::Themer($settings);
	$STC->pull_all();

=cut

sub pull_all {
	my ($self, $folder) = @_;
	$self->pull($_, $folder) for (@{$self->manifest->{themes}});
}

=head1 pull

Pulls all assets from a particular theme and then dumps them into the working folder, in a directory named for the particular theme.

	my @themes = $sa->get_all('ShopifyAPI::Model::Theme');
	$STC->pull($themes[2]);

Files that are locally and remotely changed will be overwritten locally, so keep an eye out for this.
Files that are locally not, and remotely chagned will be overritten locally.
Files that are not present locally and remotely present will be pulled.

=cut

sub pull {
	# Get all assets.
	my ($self, $theme, $folder) = @_;
	$folder = "." unless defined $folder;
	my $manifest = $self->manifest();
	my $n = "$folder/" . $theme->{name};
	make_path($n); write_file("$n/.info", encode_json({ id => $theme->{id} }));
	my @assets = $self->sa()->get_all('Asset', {parent => $theme->{id}});
	# We do a threaded pull, because we can.
	my @asset_ids:shared = (0 .. int(@assets)-1);

	my %present = map { "$n/" . $_->key => 1 } @assets;
	my @files = $self->manifest->files;
	# Check to see if the file is deleted on the server side. If so, then delete it on our side.
	for (grep { !exists $present{$_} } @files) {
		delete $self->manifest->{files}->{$_};
		unlink($_);
	}

	for (my $c = 0; $c < $self->threads(); ++$c) {
		#threads->create(sub {
			while (int(@asset_ids) > 0) {
				#lock(@asset_ids);
				my $asset = $assets[pop(@asset_ids)];
				#unlock(@asset_ids);
				my $path = "$n/" . $asset->key();
				my $datetime = $asset->updated_at();
				$manifest->remote($path, $datetime);
				make_path(dirname($path));
				next if !$manifest->has_remote_changes($path);
				$self->log("[" . sprintf("%3.2f", (1.0 - int(@asset_ids)/int(@assets))*100.0) . "%] Pulling " . $asset->key() . "...\n");
				$manifest->local($path, $datetime);
				if (defined $asset->public_url()) {
					write_file($path, get($asset->public_url())) or die $!;
				} else {
					# Assets which don't have a public url, we have to get individually.
					my $full_asset = $self->sa()->get('Asset', $asset->key(), {parent => $theme->{id}});
					write_file($path, {binmode => ':raw'}, $full_asset->value());
				}
				$manifest->system($path, DateTime->from_epoch(epoch => stat($path)->mtime));
			}
		#});
	}
	#for (@{threads->list(threads::joinable)}) { $_->join(); }
	$self->log("Done.\n");
}

=head1 push_all

Pushes all assets from all themes, if they need to be pushed.

=cut

sub push_all {
	my ($self, $folder) = @_;
	$self->push($_, $folder) for (@{$self->manifest->{themes}});
}


=head1 push

Pushes all assets from a particular theme that need to be pushed.

	$STC->push($theme);

Files that are locally changed, and remotely not, will be pushed.
Files that are locally changed, and remotely changed, will not be pushed.
Files that are locally unchanged will only be pushed if the file is missing on the server.

=cut

sub push {
	my ($self, $theme, $folder) = @_;
	$folder = "." unless defined $folder;
	my $manifest = $self->manifest();
	my $n = "$folder/" . $theme->{name};

	my @assets = $self->sa()->get_all('Asset', {parent => $theme->{id}});
	$manifest->remote("$n/" . $_->key(), $_->updated_at) for (@assets);

	my %present = map { "$n/" . $_->key() => 1 } @assets;

	@assets = ();
	find({no_chdir => 1, wanted => sub { 
		my ($path, $name) = ($_, basename($_));
		return if ($name =~ m/^\./);
		return if (-d $path);
		return if !$manifest->has_local_changes($path);
		die new WWW::Shopify::Exception("Unable to push to repo; there are remote changes on $path.") if $manifest->has_remote_changes($path);
		push(@assets, $path);
	}}, $n);

	my @asset_ids:shared = (0 .. int(@assets)-1);
	for (my $c = 0; $c < $self->threads(); ++$c) {
		#threads->create(sub {
			while (int(@asset_ids) > 0) {
				#lock(@asset_ids);
				my $path = $assets[pop(@asset_ids)];
				#unlock(@asset_ids);
				die $path unless $path =~ m/$n\/(.*?\.(\w+))$/;
				my $asset_key = $1;
				my $asset_extension = $2;
				my $asset = new WWW::Shopify::Model::Asset({key => $asset_key, container_id => $theme->{id}});
				$asset->value(scalar(read_file($path))) if ($asset_extension eq "liquid" || $asset_extension eq "json" || $asset_extension eq "js");
				$asset->attachment(encode_base64(scalar(read_file($path, encoding => "binary")))) if ($asset_extension =~ m/^(jpg|png|gif)$/);
				$self->log("[" . sprintf("%3.2f", (1.0 - int(@asset_ids)/int(@assets))*100.0) . "%] Pushing $path...\n");
				if ($manifest->exists($_)) {
					$asset = $self->sa->update($asset);
				}
				else {
					$asset->{parent} = $theme->{id};
					$asset = $self->sa->create($asset);
				}
				$manifest->system($path, DateTime->from_epoch(epoch => stat($path)->mtime));
				$manifest->local($path, $asset->updated_at);
				$manifest->remote($path, $asset->updated_at);
			}
		#}
	}
	$self->log("Done.\n");
}

1;
