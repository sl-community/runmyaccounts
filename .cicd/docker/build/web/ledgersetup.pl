#!/usr/bin/perl
use strict;
use warnings;
use feature qw(say);
use File::Path qw(make_path remove_tree);
use YAML::Tiny;
use Data::Dumper;
use File::Basename;
use Time::Piece;
use Getopt::Long;

# Basic checks and tasks:
say STDERR "Running with permissions of user: ", scalar(getpwuid( $< ));

exists $ENV{LEDGER_DOCUMENT_ROOT} ||
    die "LEDGER_DOCUMENT_ROOT environment variable not defined.\n";

chdir($ENV{LEDGER_DOCUMENT_ROOT}) || die $!;




my %opts;

GetOptions(
    \%opts,
    "init",
    "rootpw=s") || die;



init() if exists $opts{init};

rootpw() if exists $opts{rootpw};


sub init {
    say STDERR "Initializing/Clearing users and spool folders...";

    remove_tree("users", "spool");
    make_path("users", "spool");
}


sub rootpw {
    say STDERR "(Re)creating users/members with single root entry...";

    my $rootpw_hash = crypt($opts{rootpw}, "root");

    -d "users" || die "No users directory found. Use --init before?\n";
    open(my $members, ">", 'users/members') || die $!;

    print $members <<EOF;
# Run my Accounts Accounting members

[root login]
password=$rootpw_hash
EOF
    close $members;
}




=for nix




# We will be called with e.g. "/sl-community/rmac/develop"


my $instance_identifier = $ARGV[0] // die "No instance name or id given\n";


my $instances = YAML::Tiny->read( '/ledgersetup.yml' )->[0]{instances};




my ($instance) = grep {
    (exists $_->{name} && $_->{name} eq $instance_identifier) ||
    (exists $_->{id} && $_->{id} eq $instance_identifier)
} @$instances;

defined $instance || die
    "Instance with identifier '$instance_identifier' not found in config\n";


say STDERR "Initializing $instance_identifier...";


# Set admin/root password
defined $instance->{rootpw} || die "Instance has no root password\n";
my $rootpw_hash = crypt($instance->{rootpw}, "root");

chdir("/srv/www/sql-ledger") || die $!;
make_path("users");

say STDERR "(Re)creating users/members...";
open(my $members, ">", 'users/members') || die $!;

print $members <<EOF;
# Run my Accounts Accounting members

[root login]
password=$rootpw_hash
EOF
close $members;


# Eventually wait for db to come up:
my $tries = 0;
my $db_ready = 0;
while ($tries <= 10) {
    
    if (system("pg_isready -h db") == 0) {
        $db_ready = 1;
        last;
    }

    say STDERR "db is not yet ready. Waiting...";
    sleep 5;
    $tries++;
}

die "Database not reachable\n" unless $db_ready;


# Create db user:
system "createuser -h db -e -U postgres --superuser sql-ledger";


# Create and load databases:
$instance->{databases}{names} = [];

my @expanded_list = expand_list_of_dumps(@{$instance->{databases}{dumps}});    
status_and_exit("No database dump was available", 1) unless @expanded_list;

foreach my $dumpfile ( @expanded_list ) {
    if (-r $dumpfile) {
        say STDERR "$dumpfile is readable";
    }
    else {
        die "Unreadable dumpfile: $dumpfile\n";
    }

    # If dumpfile is something like "/foo/bar/acme.20190303.bz2",
    # dbname will be "acme":
    my ($dbname) = $dumpfile =~ m|.*/([^.]+)|;

    defined $dbname || die
        "Cannot detect database name out of filename: $dumpfile";
    
    push @{$instance->{databases}{names}}, $dbname;
    

    my $db_exists = system("psql -h db -U postgres -d $dbname -c '' >/dev/null 2>&1") == 0;

    say STDERR "Database $dbname " .
        ($db_exists?  "exists" : "does not exist");


    if ($db_exists && $instance->{databases}{force_recreate}) {
        say STDERR "Drop database due to force_recreate: $dbname";
        system "dropdb -h db -e -U postgres $dbname";

        $db_exists = 0;
    }
    
    if (!$db_exists) {
        say STDERR "Setup database: $dbname";
        # CREATE DATABASE is included in dump.
        #system "createdb -h db -e -U postgres $dbname"; 
        system "acat $dumpfile | psql -o /dev/null -h db -U postgres -q";
    }
}


# Create users

foreach my $user (@{$instance->{users}}) {

    my $name = $user->{name} || die "No name given\n";

    my $lang = $user->{lang} // 'gb';
    unless (grep { $_ eq $lang } qw(de gb)) {
        die "Unsupported language: $lang";
    }

    my $pass = $user->{pass} || die "No pass given\n";
    my $database = $user->{database} || die "No database given\n";
    
    say STDERR "Create user $name (lang=$lang, database=$database)";
    
    

    my $settings = {
        gb => {
            dateformat   => 'yyyy-mm-dd',
            numberformat => '1,000.00',
            countrycode  => '',
            dboptions    => '',
        },
        de => {
            dateformat   => 'dd.mm.yy',
            numberformat => '1.000,00',
            countrycode  => 'de',
            dboptions    => "set DateStyle to 'GERMAN'",
        }
    };

    
    chdir("/srv/www/sql-ledger") || die $!;
    
    open(my $members, ">>", 'users/members') || die $!;

    print $members get_members_entry(
        name     => $name,
        database => $database,
        settings => $settings->{$lang},
        pass     => $pass,
    );

    close $members;

    if (my @confs = glob("users/${name}*.conf")) {
        say "Removing old users/*.conf file(s): @confs";
        unlink(@confs) || die $!;
    }
}


status_and_exit(
    "Complete (" . scalar(@expanded_list) . " database(s); see run info for details) " 
    );

#############################################################################

#####################
sub status_and_exit {
#####################
    my ($status, $exitcode) = @_;
    $exitcode //= 0;

    my %info = (
        timestamp => Time::Piece->new->strftime,
        status    => $status,
        dumps     => \@expanded_list,
    );

    my $infofile = "/tmp/ledgersetup/runinfo";
    make_path(dirname($infofile));

    say STDERR "Writing run information to $infofile";

    open(my $runinfo, ">", $infofile) || die $!;
    $Data::Dumper::Terse=1;
    $Data::Dumper::Sortkeys=1;
    print $runinfo Dumper(\%info);
    close $runinfo;

    exit $exitcode;
}

#######################
sub get_members_entry {
#######################
    my %args = @_;

    my $pw_hash = crypt($args{pass}, substr($args{name}, 0, 2));

    my @databases = ($args{database});
    my $multidb_user = 0;

    if ($args{database} eq '*') {
        @databases = @{$instance->{databases}{names}};
        $multidb_user = 1 if @databases > 1;
    }

    
    my $result = "";
    
    foreach my $db (@databases) {

        my $username = $multidb_user? "$args{name}\@$db" : $args{name}; 
        
        $result .= qq|
[$username]
acs=
company=$db
countrycode=$args{settings}{countrycode}
dateformat=$args{settings}{dateformat}
dbconnect=dbi:Pg:dbname=$db;host=db
dbdriver=Pg
dbhost=db
dbname=$db
dboptions=$args{settings}{dboptions}
dbpasswd=
dbport=
dbuser=sql-ledger
department=
department_id=
email=$args{name}\@localhost
fax=
menuwidth=155
name=$args{name}
numberformat=$args{settings}{numberformat}
outputformat=html
password=$pw_hash
printer=
role=user
sid=
signature=
stylesheet=sql-ledger.css
tel=
templates=templates/$args{name}
timeout=10800
vclimit=1000
warehouse=
warehouse_id=
|;

    }

    return $result;
}



##########################
sub expand_list_of_dumps {
##########################
    my @result = ();

    say STDERR "expand_list_of_dumps: @_";
    
    foreach my $entry (@_) {
        say STDERR "Parsing entry: $entry";
        $entry =~ s/\{\{(.*)?\}\}/_evaluate($1)/ge;
        say STDERR "Entry before globbing: >$entry<";
        my @globbed = glob($entry);
        say STDERR "After globbing: >", join(" ", @globbed), "<";
        push @result, @globbed;
    }

    say STDERR "Expanded list of dumps: @result";

    return @result;
}



sub _evaluate {
    my $expr = shift;

    die "Invalid expression: $expr\n"
        unless $expr =~ m/(build_time|latest_nonempty_dir_in)\(/;
    
    return eval $expr;
}

sub build_time {
    my $format = shift;

    return Time::Piece->new->localtime->strftime($format); 
}


sub latest_nonempty_dir_in {
    my $dir = $_[0];

    my ($newest_file, $newest_time) = (undef, 0);

    opendir(my $dh, $dir) or die "Error opening $dir: $!";
    while (my $file = readdir($dh)) {
        next if $file eq '.' || $file eq '..';
        my $path = File::Spec->catfile($dir, $file);
        next unless (-d $path);
        
        my ($mtime) = (stat($path))[9];
        next if $mtime < $newest_time;
        
        # We have a directory, but does it have some content?
        opendir(my $pathtest, $path) || die $!;
        my $has_content = grep ! /^\.\.?/, readdir $pathtest;
        closedir $pathtest;
        
        next unless $has_content;
        
        ($newest_file, $newest_time) = ($file, $mtime);
    }
    closedir $dh;

    return $newest_file;
}