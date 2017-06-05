#!/usr/bin/env perl
# 
# timescale_tables.pl
# 
# Establish or reload the timescale tables.

use strict;

use lib '../lib', 'lib';
use Getopt::Long;
use Pod::Usage;
use Try::Tiny;

# The following modules are all part of the "new" pbdb.

use CoreFunction qw(connectDB
		    configData);
use ConsoleLog qw(initMessages
		  logMessage
		  logTimestamp);
use TimescaleTables qw(establish_timescale_tables copy_international_timescales
		       copy_pbdb_timescales process_one_timescale copy_macrostrat_timescales
		       update_timescale_descriptions create_triggers);
use TimescaleEdit qw(add_boundary update_boundary);
use CommonEdit qw(start_transaction commit_transaction rollback_transaction);


# First parse option switches.  If we were given an argument, then use that as
# the database name overriding what was in the configuration file.

my ($opt_init_tables, $opt_copy_old, $opt_authorizer_no, $opt_help, $opt_man, $opt_verbose, $opt_debug);
my ($opt_copy_from_pbdb, $opt_copy_from_macro, $opt_copy_international, $opt_update_one, $opt_update_desc);
my ($opt_init_triggers, $opt_ub);
my $options = { };

GetOptions("init-tables" => \$opt_init_tables,
	   "init-triggers" => \$opt_init_triggers,
	   "copy-old" => \$opt_copy_old,
	   "copy-international|ci" => \$opt_copy_international,
	   "copy-from-pbdb|cp" => \$opt_copy_from_pbdb,
	   "copy-from-macro|cm" => \$opt_copy_from_macro,
	   "update-one|u=s" => \$opt_update_one,
	   "update-desc|D" => \$opt_update_desc,
	   "ub" => \$opt_ub,
	   "auth=i" => \$opt_authorizer_no,
	   "debug" => \$opt_debug,
	   "help|h" => \$opt_help,
	   "man" => \$opt_man,
	   "verbose|v" => \$opt_verbose)
    or pod2usage(2);


# Check for documentation requests

pod2usage(1) if $opt_help;
pod2usage(2) unless $opt_init_tables || $opt_copy_from_pbdb || $opt_copy_from_macro || 
    $opt_update_one || $opt_update_desc || $opt_ub || $opt_init_triggers;
pod2usage(-exitval => 0, -verbose => 2) if $opt_man;

# If we get here, then we have stuff to do. So get a database handle.

my $cmd_line_db_name = shift;
my $dbh = connectDB("config.yml", $cmd_line_db_name);

initMessages(2, 'Timescale tables');
logTimestamp();

# Then process the options and execute the necessary functions.

$options->{verbose} = $opt_verbose ? 3 : 2;
$options->{authorizer_no} = $opt_authorizer_no if $opt_authorizer_no;
$options->{debug} = 1 if $opt_debug;

# First check for the init-tables option.

if ( $opt_init_tables )
{
    establish_timescale_tables($dbh, $options);
}

# If the "copy-old" option is given, then copy everything.

if ( $opt_copy_old )
{
    copy_international_timescales($dbh, $options);
    copy_pbdb_timescales($dbh, $options);
    copy_macrostrat_timescales($dbh, $options);
    update_timescale_descriptions($dbh, undef, $options);
    exit;
}

# Otherwise, check for the individual options.

if ( $opt_copy_international )
{
    copy_international_timescales($dbh, $options);
}

if ( $opt_copy_from_pbdb )
{
    copy_pbdb_timescales($dbh, $options);
}

if ( $opt_copy_from_macro )
{
    copy_macrostrat_timescales($dbh, $options);
}

if ( defined $opt_update_one && $opt_update_one ne '' )
{
    if ( $opt_update_one > 0 )
    {
	process_one_timescale($dbh, $opt_update_one, $options);
	update_timescale_descriptions($dbh, $opt_update_one, $options);
    }
    
    else
    {
	die "The value of --update-one must be a new-table timescale number\n";
    }
}

if ( $opt_update_desc )
{
    update_timescale_descriptions($dbh, undef, $options);
}

if ( $opt_ub )
{
    update_boundaries($dbh, $options);
}

if ( $opt_init_triggers )
{
    create_triggers($dbh);
}


sub update_boundaries {

    my ($dbh, $options) = @_;
    
    print "Enter attributes, in the form \"attr=value\", boundaries separated by \"==\":\n";
    
    my $bound_no;
    my $attrs = { };
    my @update;
    my $error;
    
    while ( my $line = <STDIN> )
    {
	last unless defined $line;
	chomp $line;
	
	if ( $line =~ qr{ ^ == }xsi )
	{
	    unless ( $bound_no )
	    {
		print "Boundary number? ";
		$line = <STDIN>;
		chomp $line;
	    }
	    
	    if ( $bound_no )
	    {
		push @update, $bound_no, $attrs;
		$bound_no = undef;
		$attrs = { };
	    }
	    
	    else
	    {
		print "ERROR: no bound specified.\n";
	    }
	}
	
	elsif ( $line =~ qr{ ^ \s* (\w+) \s* = \s* (.*) $ }xsi )
	{
	    if ( $1 eq 'bound_no' || $1 eq 'bn' )
	    {
		$bound_no = $2;
	    }
	    
	    else
	    {
		$attrs->{$1} = $2;
	    }
	}
	
	else
	{
	    print "IGNORED bad line\n";
	}
    }
    
    unless ( $bound_no )
    {
	print "Boundary number? ";
	my $line = <STDIN>;
	$bound_no = chomp $line;
    }
    
    if ( $bound_no )
    {
	push @update, $bound_no, $attrs;
	$bound_no = undef;
	$attrs = { };
    }
    
    else
    {
	print "ERROR: no bound specified.\n";
    }
    
    try {

	start_transaction($dbh);
	
	while ( @update )
	{
	    $bound_no = shift @update;
	    $attrs = shift @update;
	    
	    my ($result, $error_list, $warning_list) = update_boundary($dbh, $bound_no, $attrs, $options);
	    
	    if ( $result eq 'OK' )
	    {
		print "    boundary $bound_no OK\n";
	    }
	    
	    else
	    {
		$error = 1;
		
		print "    boundary $bound_no ERRORS:\n";
		
		foreach my $e ( @$error_list )
		{
		    print "        $e\n";
		}
	    }
	}
	
	if ( $error )
	{
	    rollback_transaction($dbh);
	}
	
	else
	{
	    commit_transaction($dbh);
	}
    }
	
    catch {
	print "EXCEPTION: $_\n";
	rollback_transaction($dbh);
    };
}


1;


__END__

=head1 NAME

timescale_tables.pl - initialize and/or reset the new timescale tables for The Paleobiology Database

=head1 SYNOPSIS

  timescale_tables [options] [database_name]

  Options:
    
    --help              Display a brief help message
    
    --man               Display the full documentation
    
    --debug             Produce debugging output
    
    --init-tables       Create or re-create the necessary database tables.
                        The tables will be empty after this is done.
    
    --copy-old          Copy the old interval data from both pbdb and macrostrat
    
    --copy-international    Copy the international intervals using data
                            from PBDB and macrostrat, either all or a
                            specified timescale.
    
    --copy-from-pbdb        Copy timescales from PBDB other than the
                            international ones, either all or a specified
                            timescale.
    
    --copy-from-macro       Copy timescales from Macrostrat other than
                            the international ones, either all or a 
                            specified timescale.
    
    --update-desc	Update timescale description attributes 'type', 'taxon', 'extent'
    
    --update-one=[n]    Re-process the timescale whose new number is given by [n].
    
    --auth [n]          Set the authorizer_no value for newly created records
                        to n.

=head1 OPTIONS

To be written later...

=cut


    