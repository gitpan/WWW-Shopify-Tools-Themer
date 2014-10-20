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
#use threads;
#use threads::shared;

our $VERSION = '0.09';

=head1 WWW::Shopify::Tools::Themer

The core class that deals with theme management, pushing and pulling to and from a shopify store.

	my $STC = new WWW::Shopify::Tools::Themer({url => $myurl, apikey => $myapikey, password => $mypassword});
	OR
	my $STC = new WWW::Shopify::Tools::Themer({url => $myurl, email => $myemail, password => $mypassword});

Can use either a private API key, or a password.

=cut

sub new {
	my ($package, $settings) = @_;
	die new WWW::Shopify::Exception("Please pass in url, password, apikey xor email.") unless defined $settings->{url} && defined $settings->{password} && (defined $settings->{apikey} xor defined $settings->{email});
	my $SA = new WWW::Shopify::Private($settings->{url}, $settings->{apikey}, $settings->{password});
	$SA->login_admin($settings->{email}, $settings->{password}) if $settings->{email};
	my $threads = (defined $settings->{threads}) ? $settings->{threads} : 4;
	return bless { _SA => $SA, _manifest => new WWW::Shopify::Tools::Themer::Manifest(), _threads => $threads }, $package;
}

use IO::Handle;
STDERR->autoflush(1);
STDOUT->autoflush(1);

sub threads { return $_[0]->{_threads}; }
sub log { print STDOUT $_[1]; }
sub manifest { $_[0]->{_manifest} = $_[1] if defined $_[1]; return $_[0]->{_manifest}; }
sub sa { return $_[0]->{_SA}; }

=head1 transfer_progress($self, $type, $theme, $files_transferred, $files_remaining, $file)

Called during theme pushes. Lets you easily log what's happening. Normally, simply makes formatted output to log.

=cut

sub transfer_progress {
	my ($self, $type, $theme, $files_transferred, $files_total, $file) = @_;
	my $action;
	$action = "Pushing" if $type eq "push";
	$action = "Pulling" if $type eq "pull";
	$action = "Deleting" if $type eq "delete";
	$self->log("[" . sprintf("%3.2f", ($files_transferred/$files_total)*100.0) . "%] $action $file...\n");
}

=head1 read_exception 

Spits out a nice exception message from all the underlying exception types that may be thrown.

=cut

sub read_exception {
	my ($self, $exception) = @_;
	if (ref($exception) && ref($exception->error) eq "HTTP::Response") {
		if ($exception->error->code == 500) {
			return $exception->error->decoded_content;
		}
		else {
			my $json = decode_json($exception->error->content);
			return $json->{errors}->{asset}->[0];
		}
	}
	elsif (ref($exception)) {
		return $exception->error;
	}
	else {
		return "$exception";
	}
}


=head1 get_themes

get_themes returns an array of all the themes present in the shop, with the active theme first.

=cut

sub get_themes {
	my ($self) = @_;
	my @themes = $self->sa()->get_all('Theme');
	$self->manifest->{themes} = [map { { name => $_->name, id => $_->id } } @themes];
	return @{$self->manifest->{themes}};
}

=head1 pull_all

pull_all essentially pulls all themes from the remote site. Gets all themes using the API, and then calls pull on each of them. Also pulls on pages.

	$STC = new WWW::Shopify::Tools::Themer($settings);
	$STC->pull_all([$folder]);

=cut

sub pull_all {
	my ($self, $folder) = @_;
	$self->pull(new WWW::Shopify::Model::Theme($_), $folder) for (@{$self->manifest->{themes}});
	$self->pull_pages($folder);
}

=head1 pull_pages

Pulls all pages from a store and dumps them into the working/specified folder, in a directory named pages.

	$STC->pull_pages([$folder]);

Files that are locally and remotely changed will be overwritten locally, so keep an eye out for this.
Files that are locally not, and remotely chagned will be overritten locally.
Files that are not present locally and remotely present will be pulled.

=cut

sub pull_pages {
	my ($self, $folder) = @_;
	$folder = "." unless defined $folder;
	my $manifest = $self->manifest;
	make_path("$folder/pages");
	foreach my $page ($self->sa->get_all("Page")) {
		my $path = "$folder/pages/" . $page->handle . ".html";
		$manifest->remote($path, $page->updated_at);
		next if !$manifest->has_remote_changes($path);
		$manifest->local($path, $page->updated_at);
		write_file($path, $page->body_html) or die $!;
		$manifest->system($path, DateTime->from_epoch(epoch => stat($path)->mtime));
	}
}

=head1 pull

Pulls all assets from a particular theme and then dumps them into the working/specified folder, in a directory named for the particular theme.

	my @themes = $sa->get_all('ShopifyAPI::Model::Theme');
	$STC->pull($themes[2], [$folder]);

Files that are locally and remotely changed will be overwritten locally, so keep an eye out for this.
Files that are locally not, and remotely chagned will be overritten locally.
Files that are not present locally and remotely present will be pulled.

=cut

sub pull {
	# Get all assets.
	my ($self, $theme, $folder) = @_;
	$folder = "." unless defined $folder;
	my $manifest = $self->manifest();
	my $truncated = $self->sa->shop_url;
	$truncated =~ s/\.myshopify.com//;
	my $n = "$folder/$truncated-" . $theme->{id};
	make_path($n); write_file("$n/.info", encode_json({ id => $theme->{id} }));
	my @assets = $self->sa()->get_all('Asset', {parent => $theme});
	# We do a threaded pull, because we can.
	my @asset_ids:shared = (0 .. int(@assets)-1);

	my %present = map { "$n/" . $_->key => 1 } @assets;
	my @files = $self->manifest->files;
	# Check to see if the file is deleted on the server side. If so, then delete it on our side.
	for (grep { !exists $present{$_} && $_ =~ m/$n/ } @files) {
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
				$self->transfer_progress("pull", $theme, int(@assets) - int(@asset_ids), int(@assets), $asset->key);
				$manifest->local($path, $datetime);
				if (defined $asset->public_url()) {
					write_file($path, get($asset->public_url())) or die $!;
				} else {
					# Assets which don't have a public url, we have to get individually.
					my $full_asset = $self->sa()->get('Asset', $asset->key(), {parent => $theme});
					write_file($path, {binmode => ':raw'}, $full_asset->value());
				}
				$manifest->system($path, DateTime->from_epoch(epoch => stat($path)->mtime));
			}
		#});
	}
}

=head1 push_all

Pushes all assets from all themes, if they need to be pushed, as well as pages.

=cut

sub push_all {
	my ($self, $folder) = @_;
	$self->push(new WWW::Shopify::Model::Theme($_), $folder) for (@{$self->manifest->{themes}});
	$self->push_pages($folder);
}

=head1 push_pages

Pushes all pages that need to be pushed.

	$STC->push_pages([$folder]);

Files that are locally changed, and remotely not, will be pushed.
Files that are locally changed, and remotely changed, will not be pushed.
Files that are locally unchanged will only be pushed if the file is missing on the server.

=cut

use List::Util qw(first);
sub push_pages {
	my ($self, $folder) = @_;
	$folder = "." unless defined $folder;
	my $manifest = $self->manifest;

	my @remote_pages = $self->sa->get_all("Page");
	$manifest->remote("$folder/pages/" . $_->handle . ".html", $_->updated_at) for (@remote_pages);

	my @pages = ();
	my %present = ();
	find({no_chdir => 1, wanted => sub { 
		my ($path, $name) = ($_, basename($_));
		return if ($name =~ m/^\./) || -d $path || $name !~ m/\.html$/;
		$present{$path} = 1;
		return if !$manifest->has_local_changes($path);
		die new WWW::Shopify::Exception("Unable to push to repo; there are remote changes on $path.") if $manifest->has_remote_changes($path);
		push(@pages, $path);
	}}, "$folder/pages/");
	for (grep { !exists $present{"$folder/pages/" . $_->handle . ".html"} } @remote_pages) {
		$self->transfer_progress("delete", "pages", 0, 1, $_->handle);
		$self->sa->delete($_);
	}
	foreach my $i (0..$#pages) {
		my $path = $pages[$i];
		die new WWW::Shopify::Exception("Can't determine handle.") unless $path =~ m/\/?([\w\-]+)\.html$/;
		my $handle = $1;
		$self->transfer_progress("push", "pages", $i, int(@pages), $handle);
		my $remote_page = first { $_->handle eq $handle } @remote_pages;
		if ($remote_page) {
			$remote_page->body_html(scalar(read_file($path)));
			$remote_page = $self->sa->update($remote_page);
		}
		else {
			$remote_page = $self->sa->create(new WWW::Shopify::Model::Page({ 
				body_html => scalar(read_file($path)),
				handle => $handle,
				title => join(" ", map { ucfirst($_) } split(/-/, $handle)) 
			}));
		}
		$manifest->system($path, DateTime->from_epoch(epoch => stat($path)->mtime));
		$manifest->local($path, $remote_page->updated_at);
		$manifest->remote($path, $remote_page->updated_at);
	}
}

=head1 push

Pushes all assets from a particular theme that need to be pushed.

	$STC->push($theme, [$folder]);

Files that are locally changed, and remotely not, will be pushed.
Files that are locally changed, and remotely changed, will not be pushed.
Files that are locally unchanged will only be pushed if the file is missing on the server.

=cut

sub push {
	my ($self, $theme, $folder) = @_;
	$folder = "." unless defined $folder;
	my $manifest = $self->manifest();
	my $truncated = $self->sa->shop_url;
	$truncated =~ s/\.myshopify.com//;
	my $n = "$folder/$truncated-" . $theme->{id};

	my @remote_assets = $self->sa()->get_all('Asset', {parent => $theme});
	$manifest->remote("$n/" . $_->key(), $_->updated_at) for (@remote_assets);

	my %present = ();

	my @assets = ();
	find({no_chdir => 1, wanted => sub { 
		my ($path, $name) = ($_, basename($_));
		return if ($name =~ m/^\./);
		return if (-d $path);
		$present{$path} = 1;
		return if !$manifest->has_local_changes($path);
		die new WWW::Shopify::Exception("Unable to push to repo; there are remote changes on $path.") if $manifest->has_remote_changes($path);
		push(@assets, $path);
	}}, $n);
	for (grep { !exists $present{"$n/" . $_->key()} } @remote_assets) {
		$self->transfer_progress("delete", $theme, 0, 1, $_->key);
		$self->sa->delete($_);
	}

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
				my $asset = new WWW::Shopify::Model::Asset({key => $asset_key, associated_parent => $theme});
				if ($asset_extension eq "liquid" || $asset_extension eq "json" || $asset_extension eq "js" || $asset_extension eq "css") {
					$asset->value(scalar(read_file($path)));
				}
				else {
					$asset->attachment(encode_base64(scalar(read_file($path, encoding => "binary"))));
				}
				$self->transfer_progress("push", $theme, int(@assets) - int(@asset_ids), int(@assets), $asset->key);
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
}

1;

=head1 SEE ALSO

L<WWW::Shopify>, L<WWW::Shopify::Private>, L<WWW::Shopify::Model::Theme>, L<WWW::Shopify::Model::Asset>

=head1 AUTHOR

Adam Harrison (adamdharrison@gmail.com)

=head1 LICENSE

Copyright (C) 2013 Adam Harrison

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=cut
