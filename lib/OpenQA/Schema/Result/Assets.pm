# Copyright (C) 2014 SUSE Linux Products GmbH
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Schema::Result::Assets;
use base qw/DBIx::Class::Core/;

use OpenQA::Utils;
use Date::Format;
use db_helpers;

our %types = map { $_ => 1 } qw/iso repo hdd/;

__PACKAGE__->table('assets');
__PACKAGE__->load_components(qw/Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    type => {
        data_type => 'text',
    },
    name => {
        data_type => 'text',
    },
    size => {
        data_type   => 'bigint',
        is_nullable => 1
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/type name/]);
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'asset_id');
__PACKAGE__->many_to_many(jobs => 'jobs_assets', 'job');


sub _getDirSize {
    my ($dir, $size) = @_;
    $size //= 0;

    opendir(my $dh, $dir) || return 0;
    for my $dirContent (grep(!/^\.\.?/, readdir($dh))) {

        $dirContent = "$dir/$dirContent";

        if (-f $dirContent) {
            my $fsize = -s $dirContent;
            $size += $fsize;
        }
        elsif (-d $dirContent) {
            $size = _getDirSize($dirContent, $size);
        }
    }
    closedir($dh);
    return $size;
}

sub disk_file {
    my ($self) = @_;
    sprintf("%s/%s/%s", $OpenQA::Utils::assetdir, $self->type, $self->name);
}

sub remove_from_disk {
    my ($self) = @_;

    my $file = $self->disk_file;
    OpenQA::Utils::log_debug("remove_from_disk $file");
    if ($self->type eq 'iso') {
        return unless -f $file;
        unlink($file) || die "can't remove $file";
    }
    elsif ($self->type eq 'repo') {
        use File::Path qw(remove_tree);
        remove_tree($file) || die "can't remove $file";
    }

}

sub ensure_size {
    my ($self) = @_;

    return $self->size if defined($self->size);

    my $size = 0;
    my @st   = stat($self->disk_file);
    if (@st) {
        if ($self->type eq 'iso') {
            $size = $st[7];
        }
        elsif ($self->type eq 'repo') {
            $size = _getDirSize($self->disk_file);
        }
    }
    $self->update({size => $size}) if $size;
    return $size;
}

# this is a GRU task - abusing the namespace
sub limit_assets {
    my ($app) = @_;
    my $groups = $app->db->resultset('JobGroups')->search({}, {select => [qw/id size_limit_gb/]});
    # keep track of all assets related to jobs
    my %seen_asset;
    my %toremove;
    my %keep;

    # we go through the group and keep the last X GB of it in %keep and the others
    # in toremove. After that we remove all in %toremove that no other group put in %keep
    # (assets can easily be in 2 groups - and both have different update ratios, it's up
    # to the admin to configure the size limit)
    while (my $g = $groups->next) {
        my $sizelimit = $g->size_limit_gb * 1024 * 1024 * 1024;
        my $assets    = $app->db->resultset('JobsAssets')->search(
            {
                job_id => {-in => $g->jobs->get_column('id')->as_query},
                'asset.type' => ['iso', 'repo']
            },
            {
                prefetch => 'asset',
                order_by => 'me.t_created desc',
            });
        while (my $a = $assets->next) {
            # distinct is a bit too tricky
            next if ($seen_asset{$a->asset->id} // 0) == $g->id;
            $seen_asset{$a->asset->id} = $g->id;
            my $size = $a->asset->ensure_size;
            if ($size > 0 && $sizelimit > 0) {
                $keep{$a->asset_id} = 1;
            }
            else {
                $toremove{$a->asset_id} = 1;
            }
            $sizelimit -= $size;
        }
    }
    for my $id (keys %keep) {
        delete $toremove{$id};
    }
    my $assets = $app->db->resultset('Assets')->search({id => {in => [sort keys %toremove]}}, {order_by => qw/t_created/});
    while (my $a = $assets->next) {
        $a->remove_from_disk;
        $a->delete;
    }
    my $timecond = {"<" => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600 * 2, 'UTC')};

    $assets = $app->db->resultset('Assets')->search({t_created => $timecond, type => ['iso', 'repo'], id => {-not_in => [sort keys %seen_asset]}}, {order_by => [qw/type name/]});
    while (my $a = $assets->next) {
        OpenQA::Utils::log_debug("Asset " . $a->type . "/" . $a->name . " is not in any job group, DELETE from assets where id=" . $a->id . ";");
    }
    opendir(my $dh, $OpenQA::Utils::assetdir . "/iso") || die "can't open $OpenQA::Utils::assetdir/iso: $!";
    my %isos;
    while (readdir($dh)) {
        next unless $_ =~ m/\.iso$/;
        $isos{$_} = 0;
    }
    closedir($dh);
    $assets = $app->db->resultset('Assets')->search({type => 'iso', name => {in => [keys %isos]}});
    while (my $a = $assets->next) {
        $isos{$a->name} = $a->id;
    }
    for my $iso (keys %isos) {
        if ($isos{$iso} == 0) {
            OpenQA::Utils::log_debug "File iso/$iso is not a registered asset";
        }
    }
    opendir($dh, $OpenQA::Utils::assetdir . "/repo") || die "can't open $OpenQA::Utils::assetdir/repo: $!";
    my %repos;
    while (readdir($dh)) {
        next unless -d "$OpenQA::Utils::assetdir/repo/$_";
        $repos{$_} = 0;
    }
    closedir($dh);
    $assets = $app->db->resultset('Assets')->search({type => 'repo', name => {in => [keys %repos]}});
    while (my $a = $assets->next) {
        $repos{$a->name} = $a->id;
    }
    for my $repo (keys %repos) {
        if ($repos{$repo} == 0) {
            OpenQA::Utils::log_debug "Directory repo/$repo is not a registered asset";
        }
    }
}

1;
