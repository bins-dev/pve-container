package PVE::LXC::Create;

use strict;
use warnings;
use File::Basename;
use File::Path;
use Fcntl;

use PVE::RPCEnvironment;
use PVE::RESTEnvironment qw(log_warn);
use PVE::Storage::PBSPlugin;
use PVE::Storage::Plugin;
use PVE::Storage;
use PVE::DataCenterConfig;
use PVE::LXC;
use PVE::LXC::Setup;
use PVE::VZDump::ConvertOVZ;
use PVE::Tools;
use POSIX;

sub restore_archive {
    my ($storage_cfg, $archive, $rootdir, $conf, $no_unpack_error, $bwlimit) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($archive, 1);
    if (defined($storeid)) {
        my $scfg = PVE::Storage::storage_check_enabled($storage_cfg, $storeid);
        if ($scfg->{type} eq 'pbs') {
            return restore_proxmox_backup_archive(
                $storage_cfg, $archive, $rootdir, $conf, $no_unpack_error, $bwlimit,
            );
        }
        if (PVE::Storage::storage_has_feature($storage_cfg, $storeid, 'backup-provider')) {
            my $log_function = sub {
                my ($log_level, $message) = @_;
                my $prefix = $log_level eq 'err' ? 'ERROR' : uc($log_level);
                print "$prefix: $message\n";
            };
            my $backup_provider =
                PVE::Storage::new_backup_provider($storage_cfg, $storeid, $log_function);
            return restore_external_archive(
                $backup_provider,
                $storeid,
                $volname,
                $rootdir,
                $conf,
                $no_unpack_error,
                $bwlimit,
            );
        }
    }

    $archive = PVE::Storage::abs_filesystem_path($storage_cfg, $archive) if $archive ne '-';
    restore_tar_archive($archive, $rootdir, $conf, $no_unpack_error, $bwlimit);
}

sub restore_proxmox_backup_archive {
    my ($storage_cfg, $archive, $rootdir, $conf, $no_unpack_error, $bwlimit) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($archive);
    my $scfg = PVE::Storage::storage_config($storage_cfg, $storeid);

    my ($vtype, $name, undef, undef, undef, undef, $format) =
        PVE::Storage::parse_volname($storage_cfg, $archive);

    die "got unexpected vtype '$vtype'\n" if $vtype ne 'backup';

    die "got unexpected backup format '$format'\n" if $format ne 'pbs-ct';

    my ($id_map, $root_uid, $root_gid) = PVE::LXC::parse_id_maps($conf);
    my $userns_cmd = PVE::LXC::userns_command($id_map);

    my $cmd = "restore";
    my $param = [$name, "root.pxar", $rootdir, '--allow-existing-dirs'];

    if ($no_unpack_error) {
        push(@$param, '--ignore-extract-device-errors');
    }

    PVE::Storage::PBSPlugin::run_raw_client_cmd(
        $scfg,
        $storeid,
        $cmd,
        $param,
        userns_cmd => $userns_cmd,
    );
}

my sub tar_compression_option {
    my ($archive) = @_;

    my %compression_map = (
        '.gz' => '-z',
        '.bz2' => '-j',
        '.xz' => '-J',
        '.lzo' => '--lzop',
        '.zst' => '--zstd',
    );
    if ($archive =~ /\.tar(\.[^.]+)?$/) {
        if (defined($1)) {
            die "unrecognized compression format: $1\n" if !defined($compression_map{$1});
            return $compression_map{$1};
        }
        return;
    } else {
        die "file does not look like a template archive: $archive\n";
    }
}

# Basic checks trying to detect issues with a potentially untrusted or bogus tar archive.
# Just listing the files is already a good check against corruption.
# 'tar' itself already protects against '..' in component names and strips absolute member names
# when extracting, so no need to check for those here.
my sub check_tar_archive {
    my ($archive) = @_;

    print "checking archive..\n";

    # To resolve links to get to 'sbin/init' would mean keeping track of everything in the archive,
    # because the target might be ordered first. Check only that 'sbin' exists here.
    my $found_sbin;

    # Just to detect bogus archives, any valid container filesystem should have more than this.
    my $required_members = 10;
    my $member_count = 0;

    my $check_file_list = sub {
        my ($line) = @_;

        $member_count++;

        # Not always just a single number, e.g. for character devices.
        my $size_re = qr/\d+(?:,\d+)?/;

        # The date is in ISO 8601 format. The last part contains the potentially quoted file name,
        # potentially followed by some additional info (e.g. where a link points to).
        my ($type, $perms, $uid, $gid, $size, $date, $time, $file_info) =
            $line =~ m!^([a-zA-Z\-])(\S+)\s+(\d+)/(\d+)\s+($size_re)\s+(\S+)\s+(\S+)\s+(.*)$!;
        if (!defined($type)) {
            print "check tar: unable to parse line: $line\n";
            return;
        }

        die "found multi-volume member in archive\n" if $type eq 'M';

        if (
            !$found_sbin
            && (($file_info =~ m!^(?:\./)?sbin/$! && $type eq 'd')
                || ($file_info =~ m!^(?:\./)?sbin ->! && $type eq 'l')
                || ($file_info =~ m!^(?:\./)?sbin link to! && $type eq 'h'))
        ) {
            $found_sbin = 1;
        }

    };

    my $compression_opt = tar_compression_option($archive);

    my $cmd = ['tar', '-tvf', $archive];
    push $cmd->@*, $compression_opt if $compression_opt;
    push $cmd->@*, '--numeric-owner';

    PVE::Tools::run_command($cmd, outfunc => $check_file_list);

    die "no 'sbin' directory (or link) found in archive '$archive'\n" if !$found_sbin;
    die "less than 10 members in archive '$archive'\n" if $member_count < $required_members;
}

my sub restore_tar_archive_command {
    my ($conf, $compression_opt, $rootdir, $bwlimit, $untrusted) = @_;

    my ($id_map, $root_uid, $root_gid) = PVE::LXC::parse_id_maps($conf);
    my $userns_cmd = PVE::LXC::userns_command($id_map);

    die "refusing to restore privileged container backup from external source\n"
        if $untrusted && ($root_uid == 0 || $root_gid == 0);

    my $cmd = [@$userns_cmd, 'tar', 'xpf', '-'];
    push $cmd->@*, $compression_opt if $compression_opt;
    push $cmd->@*, '--totals';
    push $cmd->@*, @PVE::Storage::Plugin::COMMON_TAR_FLAGS;
    push $cmd->@*, '-C', $rootdir;

    # skip-old-files doesn't have anything to do with time (old/new), but is
    # simply -k (annoyingly also called --keep-old-files) without the 'treat
    # existing files as errors' part... iow. it's bsdtar's interpretation of -k
    # *sigh*, gnu...
    push @$cmd, '--skip-old-files';
    push @$cmd, '--anchored';
    push @$cmd, '--exclude', './dev/*';

    if (defined($bwlimit)) {
        $cmd = [['cstream', '-t', $bwlimit * 1024], $cmd];
    }

    return $cmd;
}

sub restore_tar_archive {
    my ($archive, $rootdir, $conf, $no_unpack_error, $bwlimit, $untrusted) = @_;

    my $archive_fh;
    my $tar_input = '<&STDIN';
    my $compression_opt;
    if ($archive ne '-') {
        # GNU tar refuses to autodetect this... *sigh*
        $compression_opt = tar_compression_option($archive);
        sysopen($archive_fh, $archive, O_RDONLY)
            or die "failed to open '$archive': $!\n";
        my $flags = $archive_fh->fcntl(Fcntl::F_GETFD(), 0);
        $archive_fh->fcntl(Fcntl::F_SETFD(), $flags & ~(Fcntl::FD_CLOEXEC()));
        $tar_input = '<&' . fileno($archive_fh);
    }

    if ($untrusted) {
        die "cannot verify untrusted archive on STDIN\n" if $archive eq '-';
        check_tar_archive($archive);
    }

    my $cmd = restore_tar_archive_command($conf, $compression_opt, $rootdir, $bwlimit, $untrusted);

    if ($archive eq '-') {
        print "extracting archive from STDIN\n";
    } else {
        print "extracting archive '$archive'\n";
    }
    eval { PVE::Tools::run_command($cmd, input => $tar_input); };
    my $err = $@;
    close($archive_fh) if defined $archive_fh;
    die $err if $err && !$no_unpack_error;
}

sub restore_external_archive {
    my ($backup_provider, $storeid, $volname, $rootdir, $conf, $no_unpack_error, $bwlimit) = @_;

    die "refusing to restore privileged container backup from external source\n"
        if !$conf->{unprivileged};

    my ($mechanism, $vmtype) = $backup_provider->restore_get_mechanism($volname, $storeid);
    die "cannot restore non-LXC guest of type '$vmtype'\n" if $vmtype ne 'lxc';

    my $info = $backup_provider->restore_container_init($volname, $storeid, {});
    eval {
        if ($mechanism eq 'tar') {
            my $tar_path = $info->{'tar-path'}
                or die "did not get path to tar file from backup provider\n";
            die "not a regular file '$tar_path'" if !-f $tar_path;
            restore_tar_archive($tar_path, $rootdir, $conf, $no_unpack_error, $bwlimit, 1);
        } elsif ($mechanism eq 'directory') {
            my $directory = $info->{'archive-directory'}
                or die "did not get path to archive directory from backup provider\n";
            die "not a directory '$directory'" if !-d $directory;

            # Give backup provider more freedom, e.g. mount backed-up mount point volumes
            # individually.
            my @flags =
                grep { $_ ne '--one-file-system' } @PVE::Storage::Plugin::COMMON_TAR_FLAGS;

            my $create_cmd = [
                'tar', 'cpf', '-', @flags, "--directory=$directory", '.',
            ];

            # archive is trusted, we created it
            my $extract_cmd = restore_tar_archive_command($conf, undef, $rootdir, $bwlimit);

            my $cmd;
            # if there is a bandwidth limit, the command is already a nested array reference
            if (ref($extract_cmd) eq 'ARRAY' && ref($extract_cmd->[0]) eq 'ARRAY') {
                $cmd = [$create_cmd, $extract_cmd->@*];
            } else {
                $cmd = [$create_cmd, $extract_cmd];
            }

            eval { PVE::Tools::run_command($cmd); };
            die $@ if $@ && !$no_unpack_error;
        } else {
            die
                "mechanism '$mechanism' requested by backup provider is not supported for LXCs\n";
        }
    };
    my $err = $@;
    eval { $backup_provider->restore_container_cleanup($volname, $storeid, {}); };
    if (my $cleanup_err = $@) {
        die $cleanup_err if !$err;
        warn $cleanup_err;
    }
    die $err if $err;

}

sub recover_config {
    my ($storage_cfg, $volid, $vmid) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid, 1);
    if (defined($storeid)) {
        my $scfg = PVE::Storage::storage_check_enabled($storage_cfg, $storeid);
        if ($scfg->{type} eq 'pbs') {
            return recover_config_from_proxmox_backup($storage_cfg, $volid, $vmid);
        } elsif (PVE::Storage::storage_has_feature($storage_cfg, $storeid, 'backup-provider')) {
            return recover_config_from_external_backup($storage_cfg, $volid, $vmid);
        }
    }

    my $archive = PVE::Storage::abs_filesystem_path($storage_cfg, $volid);
    recover_config_from_tar($archive, $vmid);
}

sub recover_config_from_proxmox_backup {
    my ($storage_cfg, $volid, $vmid) = @_;

    $vmid //= 0;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($volid);
    my $scfg = PVE::Storage::storage_config($storage_cfg, $storeid);

    my ($vtype, $name, undef, undef, undef, undef, $format) =
        PVE::Storage::parse_volname($storage_cfg, $volid);

    die "got unexpected vtype '$vtype'\n" if $vtype ne 'backup';

    die "got unexpected backup format '$format'\n" if $format ne 'pbs-ct';

    my $cmd = "restore";
    my $param = [$name, "pct.conf", "-"];

    my $raw = '';
    my $outfunc = sub { my $line = shift; $raw .= "$line\n"; };
    PVE::Storage::PBSPlugin::run_raw_client_cmd($scfg, $storeid, $cmd, $param, outfunc => $outfunc);

    my $conf = PVE::LXC::Config::parse_pct_config("/lxc/${vmid}.conf", $raw);

    delete $conf->{snapshots};

    my $mp_param = {};
    PVE::LXC::Config->foreach_volume(
        $conf,
        sub {
            my ($ms, $mountpoint) = @_;
            $mp_param->{$ms} = $conf->{$ms};
        },
    );

    return wantarray ? ($conf, $mp_param) : $conf;
}

sub recover_config_from_tar {
    my ($archive, $vmid) = @_;

    my ($raw, $conf_file) =
        PVE::Storage::extract_vzdump_config_tar($archive, qr!(\./etc/vzdump/(pct|vps)\.conf)$!);
    my $conf;
    my $mp_param = {};
    $vmid //= 0;

    if ($conf_file =~ m/pct\.conf/) {

        $conf = PVE::LXC::Config::parse_pct_config("/lxc/${vmid}.conf", $raw);

        delete $conf->{snapshots};

        PVE::LXC::Config->foreach_volume(
            $conf,
            sub {
                my ($ms, $mountpoint) = @_;
                $mp_param->{$ms} = $conf->{$ms};
            },
        );

    } elsif ($conf_file =~ m/vps\.conf/) {

        ($conf, $mp_param) = PVE::VZDump::ConvertOVZ::convert_ovz($raw);

    } else {

        die "internal error";
    }

    return wantarray ? ($conf, $mp_param) : $conf;
}

sub recover_config_from_external_backup {
    my ($storage_cfg, $volid, $vmid) = @_;

    $vmid //= 0;

    my $raw = PVE::Storage::extract_vzdump_config($storage_cfg, $volid);

    my $conf = PVE::LXC::Config::parse_pct_config("/lxc/${vmid}.conf", $raw);

    delete $conf->{snapshots};

    my $mp_param = {};
    PVE::LXC::Config->foreach_volume(
        $conf,
        sub {
            my ($ms, $mountpoint) = @_;
            $mp_param->{$ms} = $conf->{$ms};
        },
    );

    return wantarray ? ($conf, $mp_param) : $conf;
}

sub restore_configuration {
    my ($vmid, $storage_cfg, $archive, $rootdir, $conf, $restricted, $unique, $skip_fw) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($archive, 1);
    if (defined($storeid)) {
        my $scfg = PVE::Storage::storage_config($storage_cfg, $storeid);
        if ($scfg->{type} eq 'pbs') {
            return restore_configuration_from_proxmox_backup(
                $vmid,
                $storage_cfg,
                $archive,
                $rootdir,
                $conf,
                $restricted,
                $unique,
                $skip_fw,
            );
        }
        if (PVE::Storage::storage_has_feature($storage_cfg, $storeid, 'backup-provider')) {
            my $log_function = sub {
                my ($log_level, $message) = @_;
                my $prefix = $log_level eq 'err' ? 'ERROR' : uc($log_level);
                print "$prefix: $message\n";
            };
            my $backup_provider =
                PVE::Storage::new_backup_provider($storage_cfg, $storeid, $log_function);
            return restore_configuration_from_external_backup(
                $backup_provider,
                $vmid,
                $storage_cfg,
                $archive,
                $rootdir,
                $conf,
                $restricted,
                $unique,
                $skip_fw,
            );
        }
    }
    restore_configuration_from_etc_vzdump($vmid, $rootdir, $conf, $restricted, $unique, $skip_fw);
}

sub restore_configuration_from_proxmox_backup {
    my ($vmid, $storage_cfg, $archive, $rootdir, $conf, $restricted, $unique, $skip_fw) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($archive);
    my $scfg = PVE::Storage::storage_config($storage_cfg, $storeid);

    my ($vtype, $name, undef, undef, undef, undef, $format) =
        PVE::Storage::parse_volname($storage_cfg, $archive);

    my $oldconf = recover_config_from_proxmox_backup($storage_cfg, $archive, $vmid);

    sanitize_and_merge_config($conf, $oldconf, $restricted, $unique);

    my $cmd = "files";

    my $list = PVE::Storage::PBSPlugin::run_client_cmd($scfg, $storeid, "files", [$name]);
    my $has_fw_conf = grep { $_->{filename} eq 'fw.conf.blob' } @$list;

    if ($has_fw_conf) {
        my $pve_firewall_dir = '/etc/pve/firewall';
        my $pct_fwcfg_target = "${pve_firewall_dir}/${vmid}.fw";
        if ($skip_fw) {
            warn
                "ignoring firewall config from backup archive's 'fw.conf', lacking API permission to modify firewall.\n";
            warn "old firewall configuration in '$pct_fwcfg_target' left in place!\n"
                if -e $pct_fwcfg_target;
        } else {
            mkdir $pve_firewall_dir; # make sure the directory exists
            unlink $pct_fwcfg_target;

            my $cmd = "restore";
            my $param = [$name, "fw.conf", $pct_fwcfg_target];
            PVE::Storage::PBSPlugin::run_raw_client_cmd($scfg, $storeid, $cmd, $param);
        }
    }
}

sub restore_configuration_from_external_backup {
    my (
        $backup_provider,
        $vmid,
        $storage_cfg,
        $archive,
        $rootdir,
        $conf,
        $restricted,
        $unique,
        $skip_fw,
    ) = @_;

    my ($storeid, $volname) = PVE::Storage::parse_volume_id($archive);
    my $scfg = PVE::Storage::storage_config($storage_cfg, $storeid);

    my ($vtype, $name, undef, undef, undef, undef, $format) =
        PVE::Storage::parse_volname($storage_cfg, $archive);

    my $oldconf = recover_config_from_external_backup($storage_cfg, $archive, $vmid);

    sanitize_and_merge_config($conf, $oldconf, $restricted, $unique);

    my $firewall_config = $backup_provider->archive_get_firewall_config($volname, $storeid);

    if ($firewall_config) {
        my $pve_firewall_dir = '/etc/pve/firewall';
        my $pct_fwcfg_target = "${pve_firewall_dir}/${vmid}.fw";
        if ($skip_fw) {
            warn
                "ignoring firewall config from backup archive, lacking API permission to modify firewall.\n";
            warn "old firewall configuration in '$pct_fwcfg_target' left in place!\n"
                if -e $pct_fwcfg_target;
        } else {
            mkdir $pve_firewall_dir; # make sure the directory exists
            PVE::Tools::file_set_contents($pct_fwcfg_target, $firewall_config);
        }
    }

    return;
}

sub sanitize_and_merge_config {
    my ($conf, $oldconf, $restricted, $unique) = @_;

    my $rpcenv = PVE::RPCEnvironment::get();
    my $authuser = $rpcenv->get_user();

    foreach my $key (keys %$oldconf) {
        next
            if $key eq 'digest'
            || $key eq 'rootfs'
            || $key eq 'snapshots'
            || $key eq 'unprivileged'
            || $key eq 'parent';
        next if $key =~ /^mp\d+$/; # don't recover mountpoints
        next if $key =~ /^unused\d+$/; # don't recover unused disks
        # we know if it was a template in the restore API call and check if the target
        # storage supports creating a template there
        next if $key =~ /^template$/;

        if (
            $restricted && $key eq 'features' && !$conf->{unprivileged} && $oldconf->{unprivileged}
        ) {
            warn "changing from unprivileged to privileged, skipping features\n";
            next;
        }

        if ($key eq 'lxc' && $restricted) {
            my $lxc_list = $oldconf->{'lxc'};

            my $msg = "skipping custom lxc options, restore manually as root:\n";
            $msg .= "--------------------------------\n";
            foreach my $lxc_opt (@$lxc_list) {
                $msg .= "$lxc_opt->[0]: $lxc_opt->[1]\n";
            }
            $msg .= "--------------------------------";

            $rpcenv->warn($msg);

            next;
        }

        if ($key =~ /^net\d+$/ && !defined($conf->{$key})) {
            PVE::LXC::check_bridge_access($rpcenv, $authuser, $oldconf->{$key});
        }

        if ($unique && $key =~ /^net\d+$/) {
            my $net = PVE::LXC::Config->parse_lxc_network($oldconf->{$key});
            my $dc = PVE::Cluster::cfs_read_file('datacenter.cfg');
            $net->{hwaddr} = PVE::Tools::random_ether_addr($dc->{mac_prefix});
            $conf->{$key} = PVE::LXC::Config->print_lxc_network($net);
            next;
        }
        $conf->{$key} = $oldconf->{$key} if !defined($conf->{$key});
    }
}

sub restore_configuration_from_etc_vzdump {
    my ($vmid, $rootdir, $conf, $restricted, $unique, $skip_fw) = @_;

    # restore: try to extract configuration from archive

    my $pct_cfg_fn = "$rootdir/etc/vzdump/pct.conf";
    my $pct_fwcfg_fn = "$rootdir/etc/vzdump/pct.fw";
    my $ovz_cfg_fn = "$rootdir/etc/vzdump/vps.conf";
    if (-f $pct_cfg_fn) {
        my $raw = PVE::Tools::file_get_contents($pct_cfg_fn);
        my $oldconf = PVE::LXC::Config::parse_pct_config("/lxc/$vmid.conf", $raw);

        sanitize_and_merge_config($conf, $oldconf, $restricted, $unique);

        unlink($pct_cfg_fn);

        # note: this file is possibly from the container itself in backups
        # created prior to pve-container 2.0-40 (PVE 5.x) / 3.0-5 (PVE 6.x)
        # only copy non-empty, non-symlink files, and only if the user is
        # allowed to modify the firewall config anyways
        if (-f $pct_fwcfg_fn && !-l $pct_fwcfg_fn && -s $pct_fwcfg_fn) {
            my $pve_firewall_dir = '/etc/pve/firewall';
            my $pct_fwcfg_target = "${pve_firewall_dir}/${vmid}.fw";
            if ($skip_fw) {
                warn
                    "ignoring firewall config from backup archive's '$pct_fwcfg_fn', lacking API permission to modify firewall.\n";
                warn "old firewall configuration in '$pct_fwcfg_target' left in place!\n"
                    if -e $pct_fwcfg_target;
            } else {
                mkdir $pve_firewall_dir; # make sure the directory exists
                PVE::Tools::file_copy($pct_fwcfg_fn, $pct_fwcfg_target);
            }
            unlink $pct_fwcfg_fn;
        }

    } elsif (-f $ovz_cfg_fn) {
        print "###########################################################\n";
        print "Converting OpenVZ configuration to LXC.\n";
        print "Please check the configuration and reconfigure the network.\n";
        print "###########################################################\n";

        my $lxc_setup = PVE::LXC::Setup->new($conf, $rootdir); # detect OS
        $conf->{ostype} = $lxc_setup->{conf}->{ostype};
        my $raw = PVE::Tools::file_get_contents($ovz_cfg_fn);
        my $oldconf = PVE::VZDump::ConvertOVZ::convert_ovz($raw);
        foreach my $key (keys %$oldconf) {
            $conf->{$key} = $oldconf->{$key} if !defined($conf->{$key});
        }
        unlink($ovz_cfg_fn);

    } else {
        print "###########################################################\n";
        print "Backup archive does not contain any configuration\n";
        print "###########################################################\n";
    }
}

1;
