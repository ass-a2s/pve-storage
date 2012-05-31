package PVE::Storage::RBDPlugin;

use strict;
use warnings;
use IO::File;
use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);


sub rbd_ls{
 my ($scfg) = @_;

    my $rbdpool = $scfg->{rbd_pool};
    my $monhost = $scfg->{rbd_monhost};
    $monhost =~ s/;/,/g;

    my $cmd = ['/usr/bin/rbd', '-p', $rbdpool, '-m', $monhost, '-n', "client.".$scfg->{rbd_id} ,'--key',$scfg->{rbd_key} ,'ls' ];
    my $list = {};
    run_command($cmd, errfunc => sub {},outfunc => sub {
        my $line = shift;

        $line = trim($line);
        my ($image) = $line;
	
        $list->{$rbdpool}->{$image} = {
            name => $image,
            size => "",
        };

    });


    return $list;

}

sub addslashes {
    my $text = shift;
    $text =~ s/;/\\;/g;
    $text =~ s/:/\\:/g;
    return $text;
}

# Configuration 

PVE::JSONSchema::register_format('pve-storage-rbd-mon', \&parse_rbd_mon);
sub parse_rbd_mon {
    my ($name, $noerr) = @_;

    if ($name !~ m/^[a-z][a-z0-9\-\_\.]*[a-z0-9]$/i) {
	return undef if $noerr;
	die "lvm name '$name' contains illegal characters\n";
    }

    return $name;
}


sub type {
    return 'rbd';
}

sub plugindata {
    return {
	content => [ {images => 1}, { images => 1 }],
    };
}

sub properties {
    return {
	rbd_monhost => {
	    description => "Monitors daemon ips.",
	    type => 'string', 
	},
	rbd_pool => {
	    description => "RBD Pool.",
	    type => 'string', 
	},
	rbd_id => {
	    description => "RBD Id.",
	    type => 'string',
	},
	rbd_key => {
	    description => "Key.",
	    type => 'string',
	},
	rbd_authsupported => {
	    description => "Authsupported.",
	    type => 'string',
	},
    };
}

sub options {
    return {
	rbd_monhost => { fixed => 1 },
        rbd_pool => { fixed => 1 },
	rbd_id => { fixed => 1 },
	rbd_key => { fixed => 1 },
        rbd_authsupported => { fixed => 1 },
	content => { optional => 1 },
    };
}

# Storage implementation

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^(vm-(\d+)-\S+)$/) {
	return ('images', $1, $2);
    }

    die "unable to parse rbd volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $monhost = addslashes($scfg->{rbd_monhost});
    my $pool = $scfg->{rbd_pool};
    my $id = $scfg->{rbd_id};
    my $key = $scfg->{rbd_key};
    my $authsupported = addslashes($scfg->{rbd_authsupported});

    my $path = "rbd:$pool/$name:id=$id:key=$key:auth_supported=$authsupported:mon_host=$monhost";

    return ($path, $vmid, $vtype);
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;


    die "illegal name '$name' - sould be 'vm-$vmid-*'\n" 
	if  $name && $name !~ m/^vm-$vmid-/;
    my $rbdpool = $scfg->{rbd_pool};
    my $monhost = $scfg->{rbd_monhost};
    $monhost =~ s/;/,/g;

    if (!$name) {
	my $rdb = rbd_ls($scfg);

	for (my $i = 1; $i < 100; $i++) {
	    my $tn = "vm-$vmid-disk-$i";
	    if (!defined ($rdb->{$rbdpool}->{$tn})) {
		$name = $tn;
		last;
	    }
	}
    }

    die "unable to allocate an image name for VM $vmid in storage '$storeid'\n"
	if !$name;

    my $cmd = ['/usr/bin/rbd', '-p', $rbdpool, '-m', $monhost, '-n', "client.".$scfg->{rbd_id}, '--key', $scfg->{rbd_key}, 'create', '--size', ($size/1024), $name  ];
    run_command($cmd, errmsg => "rbd create $name' error");

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname) = @_;

    my $rbdpool = $scfg->{rbd_pool};
    my $monhost = $scfg->{rbd_monhost};
    $monhost =~ s/;/,/g;

    my $cmd = ['/usr/bin/rbd', '-p', $rbdpool, '-m', $monhost, '-n', "client.".$scfg->{rbd_id}, '--key',$scfg->{rbd_key}, 'rm', $volname  ];
    run_command($cmd, errmsg => "rbd rm $volname' error");

    return undef;
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    $cache->{rbd} = rbd_ls($scfg) if !$cache->{rbd};
    my $rbdpool = $scfg->{rbd_pool};
    my $res = [];

    if (my $dat = $cache->{rbd}->{$rbdpool}) {
        foreach my $image (keys %$dat) {

            my $volname = $dat->{$image}->{name};

            my $volid = "$storeid:$volname";


            my $owner = $dat->{$volname}->{vmid};
            if ($vollist) {
                my $found = grep { $_ eq $volid } @$vollist;
                next if !$found;
            } else {
                next if defined ($vmid) && ($owner ne $vmid);
            }

            my $info = $dat->{$volname};
            $info->{volid} = $volid;

            push @$res, $info;
        }
    }
    
   return $res;
}


sub status {
    my ($class, $storeid, $scfg, $cache) = @_;


    my $total = 0;
    my $free = 0;
    my $used = 0;
    my $active = 1;
    return ($total,$free,$used,$active);

    return undef;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $exclusive, $cache) = @_;
    return 1;
}

1;