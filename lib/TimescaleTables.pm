# 
# The Paleobiology Database
# 
#   TimescaleTables.pm
# 

package TimescaleTables;

use strict;

use Carp qw(carp croak);
use Try::Tiny;

use TableDefs qw($TIMESCALE_DATA $TIMESCALE_REFS $TIMESCALE_INTS $TIMESCALE_BOUNDS
		 $TIMESCALE_PERMS
	         $INTERVAL_DATA $INTERVAL_MAP $SCALE_MAP $MACROSTRAT_SCALES $MACROSTRAT_INTERVALS
	         $MACROSTRAT_SCALES_INTS $REFERENCES);
use CoreFunction qw(activateTables loadSQLFile);
use ConsoleLog qw(logMessage logQuestion);

use base 'Exporter';

our(@EXPORT_OK) = qw(establish_timescale_tables copy_international_timescales
		   copy_pbdb_timescales copy_macrostrat_timescales process_one_timescale
		   update_timescale_descriptions model_timescale complete_bound_updates 
		   establish_procedures establish_triggers
		   %TIMESCALE_BOUND_ATTRS %TIMESCALE_ATTRS %TIMESCALE_REFDEF);

our ($TIMESCALE_FIX) = 'timescale_fix';


our (%TIMESCALE_ATTRS) = 
    ( timescale_id => 'IGNORE',
      timescale_name => 'varchar80',
      timescale_type => { eon => 1, era => 1, period => 1, epoch => 1, stage => 1,
			  substage => 1, zone => 1, chron => 1, other => 1, multi => 1 },
      timescale_extent => 'varchar80',
      timescale_taxon => 'varchar80',
      authority_level => 'range0-255',
      source_timescale_id => 'timescale_no',
      reference_id => 'reference_no',
      is_active => 'boolean' );
    
our (%TIMESCALE_BOUND_ATTRS) = 
    ( bound_id => 'IGNORE',
      bound_type => { absolute => 1, spike => 1, same => 1, percent => 1, alternate => 1, error => 1 },
      interval_type => { eon => 1, era => 1, period => 1, epoch => 1, stage => 1,
			 substage => 1, zone => 1, chron => 1, other => 1 },
      interval_extent => 'varchar80',
      interval_taxon => 'varchar80',
      timescale_id => 'timescale_no',
      interval_id => 'interval_no',
      lower_id => 'interval_no',
      interval_name => 'varchar80',
      lower_name => 'varchar80',
      base_id => 'bound_no',
      range_id => 'bound_no',
      color_id => 'bound_no',
      refsource_id => 'bound_no',
      age => 'pos_decimal',
      age_error => 'pos_decimal',
      percent => 'pos_decimal',
      percent_error => 'pos_decimal',
      color => 'colorhex',
      reference_no => 'reference_no' );

our (%TIMESCALE_REFDEF) = 
    ( timescale_no => [ 'TSC', $TIMESCALE_DATA, 'timescale' ],
      interval_no => [ 'INT', $TIMESCALE_INTS, 'interval' ],
      bound_no => [ 'BND', $TIMESCALE_BOUNDS, 'interval boundary' ],
      reference_no => [ 'REF', $REFERENCES, 'bibliographic reference' ] );
    
    
# Table and file names

our $TIMESCALE_WORK = 'tsw';
our $TS_REFS_WORK = 'tsrw';
our $TS_INTS_WORK = 'tsiw';
our $TS_BOUNDS_WORK = 'tsbw';
our $TS_PERMS_WORK = 'tspw';
our $TS_QUEUE_WORK = 'tsqw';

=head1 NAME

Timescale tables

=head1 SYNOPSIS

This module builds and maintains the tables for storing the definitions of timescales and
timescale intervals and boundaries.

=head2 TABLES

The following tables are maintained by this module:

=over 4

=item timescales

Lists each timescale represented in the database.

=back

=cut

=head1 INTERFACE

In the following documentation, the parameter C<dbi> refers to a DBI database handle.

=cut


# establishTimescaleTables ( dbh, options )
# 
# This function creates the timescale tables, or replaces the existing ones.  The existing ones,
# if any, are renamed to *_bak.

sub establish_timescale_tables {
    
    my ($dbh, $options) = @_;
    
    $options ||= { };
    
    # First create the table 'timescales'.  This stores information about each timescale.
    
    $dbh->do("DROP TABLE IF EXISTS $TIMESCALE_WORK");
    
    $dbh->do("CREATE TABLE $TIMESCALE_WORK (
		timescale_no int unsigned primary key auto_increment,
		authorizer_no int unsigned not null,
		enterer_no int unsigned not null,
		modifier_no int unsigned not null,
		pbdb_id int unsigned not null,
		macrostrat_id int unsigned not null,
		timescale_name varchar(80) not null,
		source_timescale_no int unsigned not null,
		authority_level tinyint unsigned not null,
		min_age decimal(9,5),
		max_age decimal(9,5),
		min_age_prec tinyint,
		max_age_prec tinyint,
		reference_no int unsigned not null,
		timescale_type enum('eon', 'era', 'period', 'epoch', 'stage', 'substage', 
			'zone', 'chron', 'other', 'multi') not null,
		timescale_extent varchar(80) not null,
		timescale_taxon varchar(80) not null,
		is_active boolean,
		is_updated boolean,
		is_error boolean,
		created timestamp default current_timestamp,
		modified timestamp default current_timestamp,
		updated timestamp default current_timestamp on update current_timestamp,
		key (reference_no),
		key (authorizer_no),
		key (min_age),
		key (max_age),
		key (is_active),
		key (is_updated))");
    
    # $dbh->do("DROP TABLE IF EXISTS $TIMESCALE_ARCHIVE");
    
    # $dbh->do("CREATE TABLE $TIMESCALE_ARCHIVE (
    # 		timescale_no int unsigned,
    # 		revision_no int unsigned auto_increment,
    # 		authorizer_no int unsigned not null,
    # 		timescale_name varchar(80) not null,
    # 		source_timescale_no int unsigned,
    # 		max_age decimal(9,5),
    # 		late_age decimal(9,5),
    # 		reference_no int unsigned not null,
    # 		interval_type enum('eon', 'era', 'period', 'epoch', 'stage', 'zone'),
    # 		is_active boolean,
    # 		created timestamp default current_timestamp,
    # 		modified timestamp default current_timestamp,
    # 		key (reference_no),
    # 		key (authorizer_no),
    # 		primary key (timescale_no, revision_no))");
    
    # The table 'timescale_refs' stores secondary references for timescales.
    
    $dbh->do("DROP TABLE IF EXISTS $TS_REFS_WORK");
    
    $dbh->do("CREATE TABLE $TS_REFS_WORK (
		timescale_no int unsigned not null,
		reference_no int unsigned not null,
		primary key (timescale_no, reference_no))");
    
    # The table 'timescale_ints' associates interval names with unique identifiers.
    
    $dbh->do("DROP TABLE IF EXISTS $TS_INTS_WORK");
    
    $dbh->do("CREATE TABLE $TS_INTS_WORK (
		interval_no int unsigned primary key,
		macrostrat_id int unsigned not null,
		interval_name varchar(80) not null,
		early_age decimal(9,5),
		late_age decimal(9,5),
		early_age_prec tinyint,
		late_age_prec tinyint,
		abbrev varchar(10) not null,
		color varchar(10) not null,
		orig_early decimal(9,5),
		orig_late decimal(9,5),
		orig_color varchar(10) not null,
		orig_refno int unsigned not null,
		macrostrat_color varchar(10) not null,
		KEY (macrostrat_id),
		KEY (interval_name))");
    
    # The table 'timescale_bounds' defines boundaries between intervals.
    
    $dbh->do("DROP TABLE IF EXISTS $TS_BOUNDS_WORK");
    
    $dbh->do("CREATE TABLE $TS_BOUNDS_WORK (
		bound_no int unsigned primary key auto_increment,
		timescale_no int unsigned not null,
		authorizer_no int unsigned not null,
		enterer_no int unsigned not null,
		modifier_no int unsigned not null,
		bound_type enum('absolute', 'spike', 'same', 'percent', 'alternate'),
		interval_extent varchar(80) not null,
		interval_taxon varchar(80) not null,
		interval_type enum('eon', 'era', 'period', 'epoch', 'stage', 'substage', 'zone', 'other') not null,
		interval_no int unsigned not null,
		lower_no int unsigned not null,
		base_no int unsigned,
		range_no int unsigned,
		color_no int unsigned,
		refsource_no int unsigned,
		age decimal(9,5),
		age_error decimal(9,5),
		percent decimal(9,5),
		percent_error decimal(9,5),
		age_prec tinyint,
		age_error_prec tinyint,
		percent_prec tinyint,
		percent_error_prec tinyint,
		is_error boolean not null,
		is_updated boolean not null,
		is_modeled boolean not null,
		is_spike boolean not null,
		color varchar(10) not null,
		reference_no int unsigned,
		orig_age decimal(9,5),
		created timestamp default current_timestamp,
		modified timestamp default current_timestamp,
		updated timestamp default current_timestamp on update current_timestamp,
		key (timescale_no),
		key (base_no),
		key (range_no),
		key (color_no),
		key (age),
		key (reference_no),
		key (is_updated))");
    
    # The table 'timescale_perms' stores viewing and editing permission for timescales.
    
    $dbh->do("DROP TABLE IF EXISTS $TS_PERMS_WORK");
    
    $dbh->do("CREATE TABLE $TS_PERMS_WORK (
		timescale_no int unsigned not null,
		person_no int unsigned,
		group_no int unsigned,
		access enum ('none', 'view', 'edit'),
		key (timescale_no),
		key (person_no),
		key (group_no))");
    
    activateTables($dbh, $TIMESCALE_WORK => $TIMESCALE_DATA,
		         $TS_REFS_WORK => $TIMESCALE_REFS,
			 $TS_INTS_WORK => $TIMESCALE_INTS,
			 $TS_BOUNDS_WORK => $TIMESCALE_BOUNDS,
			 $TS_PERMS_WORK => $TIMESCALE_PERMS);
    
    # Now establish the necessary triggers on the new tables.

    establish_triggers($dbh, $options);
    
    # Now make sure the timescale_fix table is properly initialized.
    
    $dbh->do("DROP TABLE IF EXISTS $TIMESCALE_FIX");
    
    $dbh->do("CREATE TABLE $TIMESCALE_FIX (
		timescale_no int unsigned not null,
		interval_name varchar(80) not null,
		bound_type enum('absolute', 'spike') null,
		age decimal(9,5) null,
		age_prec tinyint null,
	        age_error decimal(9,5) null,
		age_error_prec tinyint null,
		primary key (timescale_no, interval_name))");
    
    $dbh->do("REPLACE INTO $TIMESCALE_FIX (timescale_no, interval_name, bound_type, age, age_prec,
			age_error, age_error_prec) VALUES
		(1, 'Holocene', 'spike', '0.0117', 4, null, null),
		(1, 'Calabrian', 'spike', '1.80', 2, null, null),
		(1, 'Gelasian', 'spike', '2.58', 2, null, null),
		(1, 'Piacenzian', 'spike', '3.600', 3, null, null),
		(1, 'Zanclean', 'spike', '5.333', 3, null, null),
		(1, 'Messinian', 'spike', '7.246', 3, null, null),
		(1, 'Tortonian', 'spike', '11.63', 2, null, null),
		(1, 'Serravallian', 'spike', '13.82', 2, null, null),
		(1, 'Aquitanian', 'spike', '23.03', 2, null, null),
		(1, 'Chattian', 'spike', '27.82', 2, null, null),
		(1, 'Rupelian', 'spike', '33.9', 1, null, null),
		(1, 'Bartonian', 'absolute', '41.2', 1, null, null),
		(1, 'Lutetian', 'spike', '47.8', 1, null, null),
		(1, 'Ypresian', 'spike', '56.0', 1, null, null),
		(1, 'Thanetian', 'spike', '59.2', 1, null, null),
		(1, 'Selandian', 'spike', '61.6', 1, null, null),
		(1, 'Danian', 'spike', '66.0', 1, null, null),
		(1, 'Maastrichtian', 'spike', '72.1', 1, '0.2', 1),
		(1, 'Campanian', 'absolute', '83.6', 1, '0.2', 1),
		(1, 'Santonian', 'spike', '86.3', 1, '0.5', 1),
		(1, 'Coniacian', 'absolute', '89.8', 1, '0.3', 1),
		(1, 'Turonian', 'spike', '93.9', 1, null, null),
		(1, 'Cenomanian', 'spike', '100.5', 1, null, null),
		(1, 'Albian', 'spike', '113.0', 1, null, null),
		(1, 'Aptian', 'absolute', '125.0', 1, null, null),
		(1, 'Berriasian', 'absolute', '145.0', 1, null, null),
		(1, 'Tithonian', 'absolute', '152.1', 1, '0.9', 1),
		(1, 'Kimmeridgian', 'absolute', '157.3', 1, '1.0', 1),
		(1, 'Oxfordian', 'absolute', '163.5', 1, '1.0', 1),
		(1, 'Callovian', 'absolute', '166.1', 1, '1.2', 1),
		(1, 'Bathonian', 'spike', '168.3', 1, '1.3', 1),
		(1, 'Bajocian', 'spike', '170.3', 1, '1.4', 1),
		(1, 'Aalenian', 'spike', '174.1', 1, '1.0', 1),
		(1, 'Toarcian', 'spike', '182.7', 1, '0.7', 1),
		(1, 'Pliensbachian', 'spike', '190.8', 1, '1.0', 1),
		(1, 'Sinemurian', 'spike', '199.3', 1, '0.3', 1),
		(1, 'Hettangian', 'spike', '201.3', 1, '0.2', 1),
		(1, 'Carnian', 'spike', '237', 0, null, null),
		(1, 'Ladinian', 'spike', '242', 0, null, null),
		(1, 'Anisian', 'absolute', '247.2', 1, null, null),
		(1, 'Olenekian', 'absolute', '251.2', 0, null, null),
		(1, 'Induan', 'spike', '251.902', 3, '0.024', 3),
		(1, 'Changhsingian', 'spike', '254.14', 2, '0.07', 2),
		(1, 'Wuchiapingian', 'spike', '259.1', 1, '0.5', 1),
		(1, 'Capitanian', 'spike', '265.1', 1, '0.4', 1),
		(1, 'Wordian', 'spike', '268.8', 1, '0.5', 1),
		(1, 'Roadian', 'spike', '272.95', 2, '0.11', 2),
		(1, 'Kungurian', 'absolute', '283.5', 1, '0.6', 1),
		(1, 'Artinskian', 'absolute', '290.1', 1, '0.26', 1),
		(1, 'Sakmarian', 'absolute', '295.0', 1, '0.18', 2),
		(1, 'Asselian', 'spike', '298.9', 1, '0.15', 2),
		(1, 'Gzhelian', 'absolute', '303.7', 1, '0.1', 1),
		(1, 'Kasimovian', 'absolute', '307.0', 1, '0.1', 1),
		(1, 'Bashkirian', 'spike', '323.2', 1, '0.4', 1),
		(1, 'Serpukhovian', 'absolute', '330.9', 1, '0.2', 1),
		(1, 'Visean', 'spike', '346.7', 1, '0.4', 1),
		(1, 'Tournaisian', 'spike', '358.9', 1, '0.4', 1),
		(1, 'Famennian', 'spike', '372.2', 1, '1.6', 1),
		(1, 'Frasnian', 'spike', '382.7', 1, '1.6', 1),
		(1, 'Givetian', 'spike', '387.7', 1, '0.8', 1),
		(1, 'Eifelian', 'spike', '393.3', 1, '1.2', 1),
		(1, 'Emsian', 'spike', '407.6', 1, '2.6', 1),
		(1, 'Pragian', 'spike', '410.8', 1, '2.8', 1),
		(1, 'Lochkovian', 'spike', '419.2', 1, '3.2', 1),
		(1, 'Pridoli', 'spike', '423.0', 1, '2.3', 1),
		(1, 'Ludfordian', 'spike', '425.6', 1, '0.9', 1),
		(1, 'Gorstian', 'spike', '427.4', 1, '0.5', 1),
		(1, 'Homerian', 'spike', '430.5', 1, '0.7', 1),
		(1, 'Sheinwoodian', 'spike', '433.4', 1, '0.8', 1),
		(1, 'Telychian', 'spike', '438.5', 1, '1.1', 1),
		(1, 'Aeronian', 'spike', '440.8', 1, '1.2', 1),
		(1, 'Rhuddanian', 'spike', '443.8', 1, '1.5', 1),
		(1, 'Hirnantian', 'spike', '445.2', 1, '1.4', 1),
		(1, 'Katian', 'spike', '453.0', 1, '0.7', 1),
		(1, 'Sandbian', 'spike', '458.4', 1, '0.9', 1),
		(1, 'Darriwilian', 'spike', '458.4', 1, '0.9', 1),
		(1, 'Dapingian', 'spike', '470.0', 1, '1.4', 1),
		(1, 'Floian', 'spike', '477.7', 1, '1.4', 1),
		(1, 'Tremadocian', 'spike', '485.4', 1, '1.9', 1),
		(1, 'Stage 10', 'absolute', '489.5', 1, null, null),
		(1, 'Jiangshanian', 'spike', '494', 0, null, null),
		(1, 'Paibian', 'spike', '497', 0, null, null),
		(1, 'Guzhangian', 'spike', '500.5', 1, null, null),
		(1, 'Drumian', 'spike', '504.5', 1, null, null),
		(1, 'Stage 5', 'absolute', '509', 0, null, null),
		(1, 'Stage 4', 'absolute', '514', 0, null, null),
		(1, 'Stage 3', 'absolute', '521', 0, null, null),
		(1, 'Stage 2', 'absolute', '529', 0, null, null),
		(1, 'Fortunian', 'spike', '541.0', 1, '1.0', 1),
		(3, 'Ediacaran', 'spike', '635', 0, null, null)");
}



# copy_international_timescales ( dbh, options )
# 
# Copy into the new tables the old set of timescales and intervals corresponding to the standard
# international timescale.

sub copy_international_timescales {

    my ($dbh, $options) = @_;
    
    $options ||= { };
    
    my $authorizer_no = $options->{authorizer_no} || 0;
    my $auth_quoted = $dbh->quote($authorizer_no);
    my ($sql, $result);
    
    # First establish the international timescales.
    
    $sql = "REPLACE INTO $TIMESCALE_DATA (timescale_no, authorizer_no, enterer_no, timescale_name,
	timescale_type, timescale_extent, authority_level, is_active) VALUES
	(1, $auth_quoted, $auth_quoted, 'ICS Stages', 'stage', 'ics', 5, 1),
	(2, $auth_quoted, $auth_quoted, 'ICS Epochs', 'epoch', 'ics', 5, 1),
	(3, $auth_quoted, $auth_quoted, 'ICS Periods', 'period', 'ics', 5, 1),
	(4, $auth_quoted, $auth_quoted, 'ICS Eras', 'era', 'ics', 5, 1),
	(5, $auth_quoted, $auth_quoted, 'ICS Eons', 'eon', 'ics', 5, 1)";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    # Then copy the interval data from the old tables for scale_no 1.
    
    $sql = "REPLACE INTO $TIMESCALE_INTS (interval_no, interval_name, abbrev,
		orig_early, orig_late, orig_color, orig_refno)
	SELECT i.interval_no, i.interval_name, i.abbrev, i.early_age, i.late_age, 
		sm.color, i.reference_no
	FROM $INTERVAL_DATA as i join scale_map as sm using (interval_no)
	WHERE scale_no = 1
	GROUP BY interval_no";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(1, "Inserted 5 timescales and $result intervals from PBDB");
    
    # For every interval in macrostrat whose name matches one already in the table, overwrite its
    # attributes with the attributes from macrostrat.
    
    $sql = "UPDATE $TIMESCALE_INTS as i join $MACROSTRAT_INTERVALS as msi using (interval_name)
	SET i.orig_early = msi.age_bottom, i.orig_late = msi.age_top,
	    i.macrostrat_id = msi.id,
	    i.orig_color = msi.orig_color, i.macrostrat_color = msi.interval_color";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(1, "Updated $result intervals with data from Macrostrat");
    
    # Then we need to establish the bounds for each timescale. Bound #1 will always be 'the present'.
    
    $sql = "TRUNCATE TABLE $TIMESCALE_BOUNDS";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    # $sql = "	INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, age,
    # 			bound_type, lower_no, interval_no)
    # 		VALUES (4, $auth_quoted, $auth_quoted, 0, 'absolute', 0, 0)";
    
    # print STDERR "$sql\n\n" if $options->{debug};
    
    # $result = $dbh->do($sql);
    
    # Then add all of the bounds for each of the 5 international timescales in turn. Bound number
    # 1 will be the present, with an age of zero.
    
    foreach my $level_no (5,4,3,2,1)
    {
	my $timescale_no = 6 - $level_no;
	
	$sql = "INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, 
			bound_type, lower_no, interval_no, age, color, reference_no)
	SELECT $timescale_no as timescale_no, $auth_quoted as authorizer_no, $auth_quoted as enterer_no,
			'absolute' as bound_type, lower_no, interval_no, age, color, orig_refno
	FROM
	((SELECT null as lower_no, null as lower_name, i1.orig_early as age, i1.interval_name, i1.interval_no,
		if(i1.macrostrat_color <> '', i1.macrostrat_color, i1.orig_color) as color, i1.orig_refno
	FROM scale_map as sm1 join $TIMESCALE_INTS as i1 using (interval_no)
	WHERE sm1.scale_level = $level_no ORDER BY i1.orig_early desc LIMIT 1)
	UNION
	(SELECT i1.interval_no as lower_no, i1.interval_name as lower_name, i2.orig_early as age,
		i2.interval_name, i2.interval_no,
		if(i2.macrostrat_color <> '', i2.macrostrat_color, i2.orig_color) as color, i2.orig_refno
	FROM scale_map as sm1 join scale_map as sm2 on (sm1.scale_no = sm2.scale_no and sm1.scale_level = sm2.scale_level)
		join $TIMESCALE_INTS as i1 on i1.interval_no = sm1.interval_no
		join $TIMESCALE_INTS as i2 on i2.interval_no = sm2.interval_no
	WHERE (i1.orig_late = i2.orig_early) and sm1.scale_level = $level_no GROUP BY i1.interval_no)
	UNION
	(SELECT i1.interval_no as lower_no, i1.interval_name as lower_name, i1.orig_late as age,
		null as interval_name, null as interval_no, null as color, null as orig_refno
	FROM scale_map as sm1 join $TIMESCALE_INTS as i1 using (interval_no)
	WHERE sm1.scale_level = $level_no ORDER BY i1.orig_late asc LIMIT 1)
	ORDER BY age asc) as innerquery";
	# HAVING not(timescale_no = 4 and age = 0)";
	
	print STDERR "$sql\n\n" if $options->{debug};
	
	$dbh->do($sql);
	
	# Set the precision of each of the newly entered bounds to the
	# position of the last non-zero digit after the decimal. Some of these
	# will have to be adjusted by hand after initialization.
	
	$sql = "UPDATE $TIMESCALE_BOUNDS 
		SET age_prec = length(regexp_substr(age, '(?<=[.])\\\\d*?(?=0*\$)'))
		WHERE timescale_no = $timescale_no";
	
	print STDERR "$sql\n\n" if $options->{debug};
	
	$dbh->do($sql);
	
	# Then set the min and max age for each timescale.
	
	$sql = "CALL update_timescale_ages($timescale_no)";
	
	print STDERR "$sql\n\n" if $options->{debug};
	
	$dbh->do($sql);
    }
    
    # Correct bad interval numbers from PBDB
    
    $sql = "UPDATE $TIMESCALE_BOUNDS
	    SET lower_no = if(lower_no = 3002, 32, if(lower_no = 3001, 59, lower_no))";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    $sql = "UPDATE $TIMESCALE_BOUNDS
	    SET interval_no = if(interval_no = 3002, 32, if(interval_no = 3001, 59, interval_no))";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result += $dbh->do($sql);
    
    logMessage(2, "    Updated $result bad interval numbers from PBDB") if $result and $result > 0;
    
    $sql = "DELETE FROM $TIMESCALE_INTS WHERE interval_no > 3000";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $dbh->do($sql);
    
    # Set the other interval attributes, which are attached to the lower bound
    # record. 
    
    $sql = "UPDATE $TIMESCALE_BOUNDS as tsb join $TIMESCALE_DATA as ts using (timescale_no)
		SET tsb.interval_type = ts.timescale_type, tsb.interval_extent = ts.timescale_extent
		WHERE timescale_no in (1,2,3,4,5)";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(2, "    Initialized the attributes of $result bounds");
    
    # Then we create links between same-age bounds across these different
    # scales. 
    
    my %ages;
    
    foreach my $timescale_no ( 2, 3, 4, 5 )
    {
	foreach my $source_no ( 1 )
	{
	    $sql = "UPDATE $TIMESCALE_BOUNDS as tsb join $TIMESCALE_BOUNDS as source on tsb.age = source.age
		SET tsb.bound_type = 'same', tsb.base_no = source.bound_no,
		    tsb.age = source.age
		WHERE tsb.timescale_no = $timescale_no and source.timescale_no = $source_no";
	
	    print STDERR "$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);
	    
	    logMessage(2, "    Linked up $result bounds from timescale $source_no to timescale $timescale_no");
	}
    }
    
    # Save the ages that we just loaded from the source databases
    
    $sql = "UPDATE $TIMESCALE_BOUNDS as tsb SET orig_age = age WHERE timescale_no in (1,2,3,4,5)";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $dbh->do($sql);
    
    # Then update the international bounds to their currently accepted values and attributes.
    
    update_international_bounds($dbh, $options);
    
    # Finally, we knit pieces of these together into a single timescale, for demonstration
    # purposes. 
    
    my $test_timescale_no = 10;
    
    $sql = "REPLACE INTO $TIMESCALE_DATA (timescale_no, authorizer_no, timescale_name,
	is_active, timescale_type, timescale_extent) VALUES
	($test_timescale_no, $auth_quoted, 'Time Ruler', 1,
	 'multi', 'international')";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $dbh->do($sql);
    
    my @boundaries;
    
    add_timescale_chunk($dbh, \@boundaries, 1);
    add_timescale_chunk($dbh, \@boundaries, 2);
    add_timescale_chunk($dbh, \@boundaries, 3);
    add_timescale_chunk($dbh, \@boundaries, 5);
    
    set_timescale_boundaries($dbh, $test_timescale_no, \@boundaries, $authorizer_no);
    
    $sql = "CALL update_timescale_ages($test_timescale_no)";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $dbh->do($sql);
    
    # Now check each of these new timescales to make sure there are no gaps. This will also let us
    # set the bottom and top bounds on each timescale.
    
 TIMESCALE:
    foreach my $timescale_no (1..5, $test_timescale_no)
    {
	my @bounds;
	
	# Check the timescale.
	
	my @errors = check_timescale_integrity($dbh, $timescale_no, \@bounds);
	
	# Then report.
	
	my $boundary_count = scalar(@bounds);
	my $early_age = $bounds[0]{age};
	my $late_age = $bounds[-1]{age};
	
	logMessage(1, "");
	logMessage(1, "Timescale $timescale_no: $boundary_count boundaries from $early_age Ma to $late_age Ma");
	
	foreach my $e (@errors)
	{
	    logMessage(2, "    $e");
	}
	
	if ( $options->{verbose} && $options->{verbose} > 2 )
	{
	    logMessage(3, "");
	    
	    foreach my $r (@bounds)
	    {
		my $name = $r->{interval_name} || "TOP";
		my $interval_no = $r->{interval_no};
		
		logMessage(3, sprintf("  %-20s%s", $r->{age}, "$name ($interval_no)"));
	    }
	}
    }
    
    logMessage(1, "done.");
}


# copy_pbdb_timescales ( dbh, options )
# 
# Copy into the new tables the old set of timescales and intervals from the pbdb (other than the
# international ones).

sub copy_pbdb_timescales {

    my ($dbh, $options) = @_;
    
    $options ||= { };
    
    my ($sql, $result);
    
    # First copy the timescales from the PBDB.
    
    $sql = "REPLACE INTO $TIMESCALE_DATA (timescale_no, reference_no, pbdb_id, timescale_name,
		timescale_type, is_active, authorizer_no, enterer_no, modifier_no, created, modified)
	SELECT scale_no + 100, reference_no, scale_no, scale_name, null, 0,
		authorizer_no, enterer_no, modifier_no, created, modified
	FROM scales";
    
    print STDERR "\n$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    # Then get ourselves a list of what we just copied.
    
    $sql = "SELECT scale_no + 100 as timescale_no, scale_no as pbdb_id, scale_name
	FROM scales";
    
    my $timescale_list = $dbh->selectall_arrayref($sql, { Slice => {} });
    my $timescale_count = scalar(@$timescale_list);
    
    logMessage(1, "Inserted $timescale_count timescales from the PBDB");
    
    # Then copy the intervals from the PBDB. But skip the ones from scale 1, which were already
    # copied by 'copy_international_timescales' above.
    
    $sql = "INSERT IGNORE INTO $TIMESCALE_INTS (interval_no, interval_name, abbrev,
		orig_early, orig_late, orig_refno)
	SELECT interval_no, interval_name, abbrev, early_age, late_age, reference_no
	FROM $INTERVAL_DATA as i left join scale_map as sm using (interval_no)
	WHERE scale_no is null";
    
    print STDERR "\n$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(1, "Inserted $result intervals from the PBDB");
    
    # Now go through the timescales we just copied, one by one.
    
 TIMESCALE:
    foreach my $t ( @$timescale_list )
    {
	next unless $t->{timescale_no} && $t->{pbdb_id};
	
	process_one_timescale($dbh, $t->{timescale_no}, $options);
    }
}


sub copy_macrostrat_timescales {

    my ($dbh, $options) = @_;
    
    $options ||= { };
    
    my $authorizer_no = $options->{authorizer_no} || 0;
    my $auth_quoted = $dbh->quote($authorizer_no);
    
    my ($sql, $result);
    
    # First copy the timescales from Macrostrat. Ignore 1,2,3,13,14, which are the international
    # stages, epochs, etc. and have already been taken care of in 'copy_international_timescales'
    # above.
    
    my $skip_list = "1,2,3,11,13,14";
    
    $sql = "REPLACE INTO $TIMESCALE_DATA (timescale_no, reference_no, macrostrat_id, timescale_name,
		timescale_type, is_active, authorizer_no, enterer_no)
	SELECT id + 50, 0, id, timescale, null, 0, $auth_quoted as authorizer_no, $auth_quoted as enterer_no
	FROM $MACROSTRAT_SCALES
	WHERE id not in ($skip_list)";
    
    print STDERR "\n$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    # Then get ourselves a list of what we just copied.
    
    $sql = "SELECT id + 50 as timescale_no, id as macrostrat_id, timescale as timescale_name
	FROM $MACROSTRAT_SCALES
	WHERE id not in ($skip_list)";
    
    my $timescale_list = $dbh->selectall_arrayref($sql, { Slice => {} });
    my $timescale_count = scalar(@$timescale_list);
    
    logMessage(1, "Inserted $timescale_count timescales from Macrostrat");
    
    # Update any intervals from these timescales that are already in the table.
    
    $sql = "UPDATE $TIMESCALE_INTS as i join $MACROSTRAT_INTERVALS as msi using (interval_name)
		join $MACROSTRAT_SCALES_INTS as im on im.interval_id = msi.id
	SET i.macrostrat_id = msi.id, i.macrostrat_color = msi.interval_color
	WHERE im.timescale_id not in ($skip_list)";
    
    print STDERR "\n$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(1, "Updated $result existing intervals using Macrostrat data");
    
    # Add any new intervals that are not already in the table.
    
    $sql = "INSERT INTO $TIMESCALE_INTS (interval_no, macrostrat_id, interval_name, abbrev, orig_early, orig_late,
    	    orig_color, macrostrat_color)
	SELECT msi.id+2000 as interval_no, msi.id, msi.interval_name, msi.interval_abbrev, msi.age_bottom, msi.age_top,
    		msi.interval_color, msi.orig_color
	FROM $MACROSTRAT_INTERVALS as msi join $MACROSTRAT_SCALES_INTS as im on im.interval_id = msi.id
		left join $TIMESCALE_INTS as tsi using (interval_name)
	WHERE tsi.interval_name is null and im.timescale_id not in ($skip_list)
	GROUP BY msi.id";
    
    print STDERR "\n$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(1, "Inserted $result intervals from Macrostrat");
    
    $result = $dbh->do($sql);
    
    logMessage(1, "Inserted $result intervals from the PBDB");
    
    # Now go through the timescales we just copied, one by one.
    
 TIMESCALE:
    foreach my $t ( @$timescale_list )
    {
	next unless $t->{timescale_no} && $t->{macrostrat_id};
	
	process_one_timescale($dbh, $t->{timescale_no}, $options);
    }

}


sub process_one_timescale {
    
    my ($dbh, $timescale_no, $options) = @_;
    
    $options ||= { };
    
    my ($sql, $result);
    
    my ($timescale_name, $macrostrat_id, $pbdb_id) = $dbh->selectrow_array("
	SELECT timescale_name, macrostrat_id, pbdb_id FROM $TIMESCALE_DATA
	WHERE timescale_no = $timescale_no");
    
    if ( $pbdb_id )
    {
	logMessage(1, "Processing $timescale_name ($timescale_no from PBDB $pbdb_id)");
    }
    
    elsif ( $macrostrat_id )
    {
	logMessage(1, "Processing $timescale_name ($timescale_no from Macrostrat $macrostrat_id)");
    }
    
    else
    {
	logMessage(1, "Processing $timescale_name ($timescale_no source unknown)");
    }
    
    my $is_chron = $timescale_name =~ /chrons/i;
    
    my $authorizer_no = $options->{authorizer_no} || 0;
    my $auth_quoted = $dbh->quote($authorizer_no);
    
    # Delete any bounds that are already in the table.
    
    $sql = "DELETE FROM $TIMESCALE_BOUNDS WHERE timescale_no = $timescale_no";
    
    print STDERR "\n$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(2, "    deleted $result old bounds") if $result && $result > 0;
    
    # Then get all of the intervals for this timescale, in order from youngest to oldest
    
    if ( $pbdb_id )
    {
	my $order = $is_chron ? 'i.top_age, i.base_age' : 'i.base_age, i.top_age desc';
	
    	$sql = "SELECT interval_no, i.base_age, i.top_age, c.authorizer_no, c.reference_no, ir.interval_name
    		FROM interval_lookup as i join correlations as c using (interval_no)
    			join intervals as ir using (interval_no)
    		WHERE scale_no = $pbdb_id
    		ORDER BY $order, i.interval_no";
	
    	print STDERR "\n$sql\n\n" if $options->{debug};
    }
    
    elsif ( $macrostrat_id )
    {
	my $order = $is_chron ? 'i.age_top, i.age_bottom' : 'i.age_bottom, i.age_top desc';

    	$sql = "SELECT tsi.interval_no, i.age_bottom as base_age, i.age_top as top_age,
    			0 as authorizer_no, 0 as reference_no, i.interval_name, i.id as macrostrat_no
    		FROM $MACROSTRAT_SCALES_INTS as im
    			join $MACROSTRAT_INTERVALS as i on i.id = im.interval_id
    			join $TIMESCALE_INTS as tsi on tsi.macrostrat_id = im.interval_id
    		WHERE im.timescale_id = $macrostrat_id
    		ORDER BY $order, tsi.interval_no";
	
    	print STDERR "\n$sql\n\n" if $options->{debug};
    }
    
    else
    {
    	logMessage(1, "    no source for this timescale");
    	return;
    }
    
    my $interval_list = $dbh->selectall_arrayref($sql, { Slice => {} });
    
    if ( ref $interval_list eq 'ARRAY' && @$interval_list )
    {
    	my $interval_count = scalar(@$interval_list);
    	logMessage(1, "    found $interval_count intervals");
    }
    
    else
    {
    	logMessage(1, "    no intervals found for this timescale");
    	return;
    }
    
    # Now go through the intervals and generate boundaries for them. Usually, the upper boundary
    # of each interval will match the lower boundary of the previous one. However, there may be
    # gaps, or alternative interval names, or overlaps. Each of these cases must be dealt with.
    # The variable $link_bound_no records the last non-alias bound that we encountered, while
    # @pending_bound_nos keeps track of alias bounds whose lower_no values need updating.
    
    my ($last_early, $last_late, $link_bound_no, @pending_bound_nos, $last_interval);
    my (%bound_by_age);
    
 INTERVAL:
    foreach my $i ( @$interval_list )
    {
	# Since we are loading from tables that do not store precisions for the ages, we must
	# simply use the place of the last non-zero digit after the decimal point as the
	# precision. This will not always be correct, and will have to be updated manually after
	# loading. The calls to get_precision() compute these values.
	
	# If no reference number is given for this interval, we should store a null value so it
	# will default to the reference number for the timescale. If no authorizer_no or
	# enterer_no is known, then we default to the authorizer_no given in $options or else 0.
	
	my $reference_no = $i->{reference_no} || 'NULL';
	my $authorizer_no = $i->{authorizer_no} || $auth_quoted || '0';
	my $enterer_no = $i->{enterer_no} || $i->{authorizer_no} || $auth_quoted || '0';
	
	# If the top of this interval matches the bottom of the previous one, we add a new
	# boundary to mark the bottom of the interval and update the lower_no value of the
	# last non-alias boundary plus pending ones. This will be the most common case.
	
	if ( defined $last_early && abs($i->{top_age} - $last_early) < 1 )
	{
	    my $bound_list = join(',', $link_bound_no, @pending_bound_nos);
	    
	    $sql = "
		UPDATE $TIMESCALE_BOUNDS SET lower_no = $i->{interval_no}
		WHERE bound_no in ($bound_list) and timescale_no = $timescale_no";
	    
	    print STDERR "\n$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);
	    
	    @pending_bound_nos = ();
	    
	    my $base_prec = get_precision($i->{base_age});
	    
	    $sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'absolute',
			$i->{interval_no}, 0, $i->{base_age}, $base_prec, $reference_no)";
	    
	    print STDERR "\n$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);
	    
	    $last_early = $i->{base_age};
	    $last_late = $i->{top_age};
	    $link_bound_no = $dbh->last_insert_id(undef, undef, undef, undef);
	    $bound_by_age{$i->{base_age}} = $link_bound_no;
	    $last_interval = $i;
	    
	    next INTERVAL;
	}
	
	# If the bottom of this interval corresponds with the previous one, then this represents
	# an alternate name for an interval or interval range. We need to add a new boundary, with
	# an empty age and a type of 'alias'. We then add the new boundary to the
	# @pending_bound_nos list so that its lower_no will be properly updated later once we find
	# out what goes below it.
	
	elsif ( defined $last_early && $i->{base_age} == $last_early )
	{
	    my $range_no;
	    
	    if ( $i->{top_age} == $last_late )
	    {
		$range_no = 'NULL';
	    }
	    
	    elsif ( $bound_by_age{$i->{top_age}} )
	    {
		$range_no = $bound_by_age{$i->{top_age}};
	    }
	    
	    else
	    {
		my $top_prec = get_precision($i->{top_age});
		
		$sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'alternate',
			0, 0, $i->{top_age}, $top_prec, $reference_no)";
		
		print STDERR "\n$sql\n\n" if $options->{debug};
		
		$result = $dbh->do($sql);

		$range_no = $dbh->last_insert_id(undef, undef, undef, undef);
		$bound_by_age{$i->{top_age}} = $range_no;
	    }
	    
	    my $base_prec = get_precision($i->{base_age});
	    
	    $sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, base_no, range_no, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'alternate',
			$i->{interval_no}, 0, $i->{base_age}, $base_prec, $link_bound_no, $range_no, $reference_no)";
	    
	    print STDERR "\n$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);
	    
	    # push @pending_bound_nos, $dbh->last_insert_id(undef, undef, undef, undef);
	    
	    next INTERVAL;
	}
	
	# If this interval overlaps with the previous one, we insert the top boundary as an alternate.
	
	elsif ( defined $last_early && $i->{top_age} < $last_early )
	{
	    my $range_no;
	    
	    if ( $bound_by_age{$i->{top_age}} )
	    {
		$range_no = $bound_by_age{$i->{top_age}};
	    }

	    else
	    {
		my $top_prec = get_precision($i->{top_age});
		
		$sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'alternate',
			0, 0, $i->{top_age}, $top_prec, $reference_no)";
		
		print STDERR "\n$sql\n\n" if $options->{debug};
		
		$result = $dbh->do($sql);

		$range_no = $dbh->last_insert_id(undef, undef, undef, undef);
		$bound_by_age{$i->{top_age}} = $range_no;
	    }
	    
	    my $base_prec = get_precision($i->{base_age});
	    
	    $sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, range_no, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'alternate',
			$i->{interval_no}, 0, $i->{base_age}, $base_prec, $range_no, $reference_no)";
	    
	    print STDERR "\n$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);

	    my $new_bound = $dbh->last_insert_id(undef, undef, undef, undef);
	    $bound_by_age{$i->{base_age}} ||= $new_bound;
	    
	    next INTERVAL;
	}

	# If this interval has the same base_age and top_age, skip it.

	elsif ( $i->{base_age} == $i->{top_age} )
	{
	    next INTERVAL;
	}
	
	# Otherwise, there is either a gap in the timescale or this is the top boundary. In either
	# case, we need to add both a top and a bottom boundary for the next interval.
	
	else
	{
	    # if ( defined $last_early )
	    # {
	    # 	my $diff = $i->{top_age} - $last_early;
	    # 	logMessage(2, "    gap: $i->{interval_name} ($i->{interval_no}) to $last_interval->{interval_name} ($last_interval->{interval_no}): $diff");
	    # }
	    
	    my $top_prec = get_precision($i->{top_age});
	    my $base_prec = get_precision($i->{base_age});
	    
	    $sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'absolute', 
			0, $i->{interval_no}, $i->{top_age}, $top_prec, $reference_no)";
	    
	    print STDERR "\n$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);
	    
	    $bound_by_age{$i->{top_age}} = $dbh->last_insert_id(undef, undef, undef, undef);
	    
	    $sql = "
		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no, bound_type,
			interval_no, lower_no, age, age_prec, reference_no)
		VALUES ($timescale_no, $authorizer_no, $enterer_no, 'absolute',
			$i->{interval_no}, 0, $i->{base_age}, $base_prec, $reference_no)";
	    
	    print STDERR "\n$sql\n\n" if $options->{debug};
	    
	    $result = $dbh->do($sql);
	    
	    $last_early = $i->{base_age};
	    $last_late = $i->{top_age};
	    $link_bound_no = $dbh->last_insert_id(undef, undef, undef, undef);
	    $bound_by_age{$i->{base_age}} = $link_bound_no;
	    $last_interval = $i;
	    
	    @pending_bound_nos = ();
	    
	    next INTERVAL;
	}
	
    }
    
    my $a = 1; # we can stop here when debugging
}
    
#     # Then update the timescale age range
    
#     $sql = "CALL update_timescale_ages($timescale_no)";
    
#     print STDERR "$sql\n\n" if $options->{debug};
    
#     $dbh->do($sql);

    
# INTERVAL:
#     foreach my $i ( @$interval_list )
#     {
# 	my $prec = get_precision($i->{base_age});
	
# 	unless ( $last_early )
# 	{
# 	    my $reference_no = $i->{reference_no} || '0';
	    
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type,
# 			lower_no, interval_no, age, orig_age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'absolute', 0,
# 			$i->{interval_no}, $i->{base_age}, $prec, $reference_no)";
	    
# 	    $result = $dbh->do($sql);
	    
# 	    $first_early = $i->{base_age};
# 	    $first_early_prec = $prec;
# 	    $last_early = $i->{base_age};
# 	    $last_late = $i->{top_age};
# 	    $last_late_prec = $prec;
# 	    $last_interval = $i;
	    
# 	    next INTERVAL;
# 	}
	
# 	elsif ( $i->{base_age} == $last_late )
# 	{
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'absolute', $last_interval->{interval_no},
# 			$i->{interval_no}, $i->{base_age}, $prec, $i->{reference_no})";
	    
# 	    $result = $dbh->do($sql);
	    
# 	    $last_early = $i->{base_age};
# 	    $last_late = $i->{top_age};
# 	    $last_late_prec = get_precision($i->{top_age});
# 	    $last_interval = $i;
	    
# 	    next INTERVAL;
# 	}
	
# 	elsif ( $i->{base_age} == $last_early && $i->{top_age} == $last_late )
# 	{
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'alias', $last_interval->{interval_no},
# 			$i->{interval_no}, $i->{base_age}, $prec, $i->{reference_no})";
	    
# 	    $result = $dbh->do($sql);
	    
# 	    next INTERVAL;
# 	}
	
# 	elsif ( $i->{base_age} == $last_early )
# 	{
# 	    logMessage(2, "  ERROR: $i->{interval_name} ($i->{interval_no}) matches bottom of previous");
	    
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type, is_error,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'absolute', 1, $last_interval->{interval_no},
# 			$i->{interval_no}, $i->{base_age}, $prec, $i->{reference_no})";
	    
# 	    $result = $dbh->do($sql);
	    
# 	    next INTERVAL;
# 	}
	
# 	elsif ( $i->{top_age} == $last_late )
# 	{
# 	    logMessage(2, "  ERROR: $i->{interval_name} ($i->{interval_no}) matches top of previous");
	    
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type, is_error,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'absolute', 1, $last_interval->{interval_no},
# 			$i->{interval_no}, $i->{base_age}, $prec, $i->{reference_no})";
	    
# 	    $result = $dbh->do($sql);
	    
# 	    next INTERVAL;
# 	}
	
# 	elsif ( $i->{base_age} > $last_late )
# 	{
# 	    logMessage(2, "  ERROR: $i->{interval_name} ($i->{interval_no}) overlaps top");
	    
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type, is_error,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'absolute', 1, $last_interval->{interval_no},
# 			$i->{interval_no}, $i->{base_age}, $prec, $i->{reference_no})";
	    
# 	    $result = $dbh->do($sql);
	    
# 	    next INTERVAL;
# 	}
	
# 	else
# 	{
# 	    my $gap = $last_late - $i->{base_age};
# 	    logMessage(2, "  ERROR: $i->{interval_name} ($i->{interval_no}) has a gap of $gap Ma");
	    
# 	    $sql = "
# 		INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $i->{authorizer_no}, 'absolute', $last_interval->{interval_no},
# 			$i->{interval_no}, $i->{base_age}, $prec, $i->{reference_no})";
	    
# 	    # print "\n$sql\n\n" if $options->{debug};
	    
# 	    $result = $dbh->do($sql);
	    
# 	    $last_early = $i->{base_age};
# 	    $last_late = $i->{top_age};
# 	    $last_late_prec = get_precision($i->{top_age});
# 	    $last_interval = $i;	
# 	}
#     }
    
#     # Now we need to process the upper boundary of the last interval.
    
#     $sql = "INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, bound_type,
# 			lower_no, interval_no, age, age_prec, reference_no)
# 		VALUES ($timescale_no, $last_interval->{authorizer_no}, 'absolute',
# 			$last_interval->{interval_no}, 0, $last_late, $last_late_prec, 
# 			$last_interval->{reference_no})";
    
#     $result = $dbh->do($sql);
    

# get_precision ( value )
#
# Return the number of digits after the decimal point other than trailing zeros.

sub get_precision {
    
    my ($value) = @_;

    if ( $value =~ qr{ (?<=[.]) (\d*?) (?=0*$) }xs )
    {
	return length($1);
    }

    else
    {
	return 'NULL';
    }
}

# add_timescale_chunk ( timescale_dest, timescale_source, last_boundary_age )
# 
# Add boundaries to the destination timescale, which refer to boundaries in the source timescale.
# Add only boundaries earlier than $last_boundary_age, and return the age of the last boundary
# added.
# 
# This routine is meant to be used in sequence to knit together a timescale with chunks from a
# variety of source timescales. It should be called most recent -> least recent.

sub add_timescale_chunk {

    my ($dbh, $boundary_list, $source_no, $max_age, $late_age) = @_;
    
    my ($sql, $result);
    
    # First get a list of boundaries from the specified timescale, restricted according to the
    # specified bounds.
    
    my $source_quoted = $dbh->quote($source_no);
    my @filters = "timescale_no = $source_quoted";
    
    if ( $max_age )
    {
	my $quoted = $dbh->quote($max_age);
	push @filters, "age <= $quoted";
    }
    
    if ( @$boundary_list && $boundary_list->[-1]{age} )
    {
	$late_age = $boundary_list->[-1]{age} + 0.1 if ! defined $late_age || $boundary_list->[-1]{age} >= $late_age;
    }
    
    if ( $late_age )
    {
	my $quoted = $dbh->quote($late_age);
	push @filters, "age >= $quoted";
    }
    
    my $filter = "";
    
    if ( @filters )
    {
	$filter = "WHERE " . join( ' and ', @filters );
    }
    
    $sql = "SELECT bound_no, age, lower_no, interval_no, timescale_type, timescale_extent
	    FROM $TIMESCALE_BOUNDS join $TIMESCALE_DATA using (timescale_no)
	    $filter ORDER BY age asc";
    
    my $result = $dbh->selectall_arrayref($sql, { Slice => { } });
    my @results;
    
    @results = @$result if ref $result eq 'ARRAY';
    
    # If we have no results, do nothing.
    
    return unless @results;
    
    # If the top boundary has no interval_no, and the list to which we are adding has at least one
    # member, then remove it.
    
    if ( @$boundary_list && ! $results[0]{interval_no} )
    {
	shift @results;
    }
    
    # Now tie the two ranges together.
    
    if ( @$boundary_list )
    {
	$boundary_list->[-1]{lower_no} = $results[0]{interval_no};
    }
    
    # Alter each record so that it is indicated as a copy of the specified bound.
    
    foreach my $b (@results)
    {
	$b->{bound_type} = 'same';
    }
    
    # Then add the new results on to the list.
    
    push @$boundary_list, @results;
}


# set_timescale_boundaries ( dbh, timescale_no, boundary_list )
# 
# 

sub set_timescale_boundaries {
    
    my ($dbh, $timescale_no, $boundary_list, $authorizer_no) = @_;
    
    my $result;
    my $sql = "INSERT INTO $TIMESCALE_BOUNDS (timescale_no, authorizer_no, enterer_no,
		bound_type, lower_no, interval_no, base_no, age, age_prec,
		interval_type, interval_extent, interval_taxon) VALUES ";
    
    my @values;
    
    my $ts_quoted = $dbh->quote($timescale_no);
    my $auth_quoted = $dbh->quote($authorizer_no);
    
    foreach my $b (@$boundary_list)
    {
	my $lower_quoted = $dbh->quote($b->{lower_no});
	my $upper_quoted = $dbh->quote($b->{interval_no});
	my $source_quoted = $dbh->quote($b->{base_no} // $b->{bound_no});
	my $age_quoted = $dbh->quote($b->{age});
	my $prec_quoted = $dbh->quote(get_precision($b->{age}));
	my $type_quoted = $dbh->quote($b->{timescale_type} // '');
	my $extent_quoted = $dbh->quote($b->{timescale_extent} // '');
	my $taxon_quoted = $dbh->quote($b->{timescale_taxon} // '');
	
	push @values, "($ts_quoted, $auth_quoted, $auth_quoted, 'same', $lower_quoted, " .
	    "$upper_quoted, $source_quoted, $age_quoted, $prec_quoted, " .
	    "$type_quoted, $extent_quoted, $taxon_quoted)";
    }
    
    $sql .= join( q{, } , @values );
    
    $result = $dbh->do($sql);
}


# check_timescale_integrity ( dbh, timescale_no )
# 
# Check the specified timescale for integrity.  If any errors are found, return a list of them.

sub check_timescale_integrity {
    
    my ($dbh, $timescale_no, $bounds_ref, $options) = @_;
    
    my ($sql);
    
    $sql = "	SELECT bound_no, age, lower_no, lower.interval_name as lower_name,
			upper.interval_no, upper.interval_name
		FROM $TIMESCALE_BOUNDS as tsb
			left join $TIMESCALE_INTS as lower on lower.interval_no = tsb.lower_no
			left join $TIMESCALE_INTS as upper on upper.interval_no = tsb.interval_no
		WHERE timescale_no = $timescale_no";
	
    my ($results) = $dbh->selectall_arrayref($sql, { Slice => { } });
    my (@results);
    
    @results = @$results if ref $results eq 'ARRAY';
    
    my (@errors);
    
    # Make sure that we actually have some results.
    
    unless ( @results )
    {
	push @errors, "No boundaries found";
	return @errors;
    }
    
    # Make sure that the first and last intervals have the correct properties.
    
    if ( $results[0]{interval_no} )
    {
	my $bound_no = $results[0]{bound_no};
	push @errors, "Error in bound $bound_no: should be upper boundary but has interval_no = $results[0]{interval_no}";
    }
    
    if ( $results[-1]{lower_no} )
    {
	my $bound_no = $results[-1]{bound_no};
	push @errors, "Error in bound $bound_no: should be lower boundary but has lower_no = $results[-1]{lower_no}";
    }
    
    # Then check all of the boundaries in sequence.
    
    my ($early_age, $late_age, $last_age, $last_lower_no);
    my $boundary_count = 0;
    
    $results[-1]{last_record} = 1;
    
    foreach my $r (@results)
    {
	my $bound_no = $r->{bound_no};
	my $age = $r->{age};
	my $interval_no = $r->{interval_no};
	my $lower_no = $r->{lower_no};
	
	$boundary_count++;
	
	# The first age will be the late end of the scale, the last age will be the early end.
	
	# $late_age //= $age;
	# $early_age = $age;
	
	# Make sure the ages are all defined and monotonic.
	
	unless ( defined $age )
	{
	    push @errors, "Error in bound $bound_no: age is not defined";
	}
	
	if ( defined $last_age && $last_age >= $age )
	{
	    push @errors, "Error in bound $bound_no: age ($age) >= last age ($last_age)";
	}
	
	# Make sure that the interval_no matches the lower_no of the previous
	# record.
	
	if ( defined $last_lower_no )
	{
	    unless ( $interval_no )
	    {
		push @errors, "Error in bound $bound_no: interval_no not defined";
	    }
	    
	    elsif ( $interval_no ne $last_lower_no )
	    {
		push @errors, "Error in bound $bound_no: interval_no ($interval_no) does not match upward ($last_lower_no)";
	    }
	}
	
	$last_lower_no = $lower_no;
	
	unless ( $lower_no || $r->{last_record} )
	{
	    push @errors, "Error in bound $bound_no: lower_no not defined";
	}
    }
    
    if ( ref $bounds_ref eq 'ARRAY' )
    {
	@$bounds_ref = @results;
    }
    
    return @errors;
}


# update_timescale_descriptions ( dbh, timescale_no, options )
# 
# Update the fields 'timescale_type', 'timescale_extent', and 'timescale_taxon' based on the name
# of each timescale. If $timescale_no is given, just update that timescale. Otherwise, update
# everything.

sub update_timescale_descriptions {
    
    my ($dbh, $timescale_no, $options) = @_;
    
    $options ||= { };
    
    logMessage(1, "Setting timescale descriptions...");
    
    my ($sql, $result);
    
    my $selector = '';
    
    $selector = "and timescale_no = $timescale_no" if $timescale_no && $timescale_no =~ qr{^\d+$} && $timescale_no > 0;
    
    # First clear all existing attributes and re-compute them.
    
    $dbh->do("UPDATE $TIMESCALE_DATA
		SET timescale_type = null, timescale_extent = null, timescale_taxon = null
		WHERE timescale_no > 10 $selector");
    
    # Scan for all of the possible types.
    
    foreach my $type ('stage', 'substage', 'zone', 'chron', 'epoch', 'period', 'era', 'eon')
    {
	my $regex = $type;
	$regex = 's?t?age' if $type eq 'stage';
	$regex = '(?:subs?t?age|unit)' if $type eq 'substage';
	$regex = '(?:zone|zonation)' if $type eq 'zone';
	$regex = 'chron' if $type eq 'chron';
	
	$sql = "UPDATE $TIMESCALE_DATA
		SET timescale_type = '$type'
		WHERE timescale_name rlike '\\\\b${regex}s?\\\\b' $selector";
	
	print STDERR "$sql\n\n" if $options->{debug};
	
	$result = $dbh->do($sql) + 0;
	
	logMessage(2, "    type = '$type' - $result");
    }
    
    # Scan for taxa that are known to be used in naming zones
    
    foreach my $taxon ('ammonite', 'conodont', 'mammal', 'faunal')
    {
	my $regex = $taxon;
	
	$sql = "UPDATE $TIMESCALE_DATA
		SET timescale_taxon = '$taxon'
		WHERE timescale_name rlike '$regex' $selector";
	
	print STDERR "$sql\n\n" if $options->{debug};
	
	$result = $dbh->do($sql) + 0;
	
	logMessage(2, "    taxon = '$taxon' - $result");
    }
    
    # Now scan for geographic extents
    
    my (%extent) = ('china' => 'Chinese',
		    'asia' => 'Asian',
		    'north america' => 'North American',
		    'south america' => 'South American',
		    'africa' => 'African',
		    'europe' => 'European',
		    'laurentia' => 'Laurentian',
		    'western interior' => 'Western interior',
		    'boreal' => 'Boreal');
    
    foreach my $regex ( keys %extent )
    {
	my $extent = $extent{$regex};
	
	$sql = "UPDATE $TIMESCALE_DATA
		SET timescale_extent = '$extent'
		WHERE timescale_name rlike '$regex' $selector";
	
	print STDERR "$sql\n\n" if $options->{debug};
	
	$result = $dbh->do($sql);
	
	logMessage(2, "    extent = '$extent' - $result") if $result && $result > 0;
    }
    
    # Now copy these to the intervals boundaries.
    
    $sql = "UPDATE $TIMESCALE_BOUNDS as tsb join $TIMESCALE_DATA as ts using (timescale_no)
		SET tsb.interval_type = ts.timescale_type,
		    tsb.interval_extent = ts.timescale_extent,
		    tsb.interval_taxon = ts.timescale_taxon
		WHERE tsb.interval_type = ''";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    $result = $dbh->do($sql);
    
    logMessage(2, "Updated attributes of $result boundaries to match their timescales") if $result && $result > 0;
}


# complete_bound_updates ( dbh, options )
# 
# Make sure that all changes to bound updates are propagated to referring bounds, and check for
# errors. Then clear the 'is_updated' flag on all updated bounds.

sub complete_bound_updates {
    
    my ($dbh, $options) = @_;
    
    logMessage(2, "Completing bound updates...");
    
    $dbh->do("CALL complete_bound_updates");
    $dbh->do("CALL check_updated_bounds");
    $dbh->do("CALL unmark_updated_bounds");
    
    print STDERR "CALL complete_bound_updates\nCALL check_updated_bounds\nCALL unmark_updated\n\n"
	if $options->{debug};
    
    logMessage(2, "Done.");
}


# update_international_bounds ( dbh, options )
# 
# A few of the international boundaries are not correct in the source database. Correct them, and
# also set precision and 'spike' where appropriate.

sub update_international_bounds {
    
    my ($dbh, $options) = @_;
    
    logMessage(1, "Fixing international boundaries...");
    
    # First check that all of our fixes actually match up to one of the international time intervals.
    
    my $sql = "	SELECT fix.timescale_no, fix.interval_name
		FROM $TIMESCALE_FIX as fix left join $TIMESCALE_INTS as tsi using (interval_name)
			left join $TIMESCALE_BOUNDS as tsb on tsb.timescale_no = fix.timescale_no
			and tsb.interval_no = tsi.interval_no
		WHERE tsb.bound_no is null";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    my $result = $dbh->selectall_arrayref($sql, { Slice => { } });
    
    if ( ref $result eq 'ARRAY' && @$result )
    {
	foreach my $r ( @$result )
	{
	    my $message = "  ERROR: fix for '$r->{interval_name}' in timescale $r->{timescale_no} has no match";
	    logMessage(2, $message);
	}
    }
    
    else
    {
	logMessage(2, "  All fixes are okay.");
    }
    
    # Then use this table to update the international timescale boundaries.
    
    $sql = "	UPDATE $TIMESCALE_BOUNDS as tsb	join $TIMESCALE_INTS as tsi using (interval_no)
			join $TIMESCALE_FIX as fix using (timescale_no, interval_name)
		SET tsb.bound_type = coalesce(fix.bound_type, tsb.bound_type),
		    tsb.age = coalesce(fix.age, tsb.age),
		    tsb.age_prec = coalesce(fix.age_prec, tsb.age_prec),
		    tsb.age_error = coalesce(fix.age_error, tsb.age_error),
		    tsb.age_error_prec = coalesce(fix.age_error_prec, tsb.age_error_prec),
		    tsb.is_spike = coalesce(fix.bound_type, tsb.bound_type) = 'spike'";
    
    print STDERR "$sql\n\n" if $options->{debug};
    
    my $result = $dbh->do($sql);
    
    logMessage(2, "  Fixed $result international bounds from timescale_fix table") if $result && $result > 0;
}


# Given a timescale number, check to see which of the boundaries might correspond to international
# interval boundaries, and model the rest as percentages.

sub model_timescale {
    
    my ($dbh, $timescale_no, $options) = @_;

    # Check that the argument is in the proper range.
    
    unless ( $timescale_no && $timescale_no =~ /^\d+$/ )
    {
	print STDERR "Invalid timescale number '$timescale_no'. Aborting.\n";
	return;
    }
    
    # Then query all of the boundaries for the specified timescale.
    
    my $sql = " SELECT tsb.*, tsi.interval_name FROM $TIMESCALE_BOUNDS as tsb 
			left join $TIMESCALE_INTS as tsi using (interval_no)
		WHERE timescale_no = $timescale_no ORDER BY age";

    my $ts_res = $dbh->selectall_arrayref($sql, { Slice => {} });

    unless ( ref $ts_res eq 'ARRAY' && @$ts_res )
    {
	logMessage(2, "No boundaries found for timescale '$timescale_no'");
	return;
    }

    # Now query all of the international boundaries.
    
    my (@INTERNATIONAL, %INT, %INT_BY_AGE, @AGES);
    
    $sql = "	SELECT tsb.*, tsi.interval_name FROM $TIMESCALE_BOUNDS as tsb 
			left join $TIMESCALE_INTS as tsi using (interval_no)
		WHERE timescale_no in (1,2,3,4,5) ORDER BY age, timescale_no desc";
    
    my $int_res = $dbh->selectall_arrayref($sql, { Slice => {} });
    
    foreach my $r ( @$int_res )
    {
	push @INTERNATIONAL, $r;
	push @{$INT_BY_AGE{$r->{age}}}, $r;
	$INT{$r->{bound_no}} = $r;
    }

    @AGES = sort { $a <=> $b } keys %INT_BY_AGE;
    
    # Then go through the interval bounds and see which if any match up to international bounds.

 BOUND:
    foreach my $r ( @$ts_res )
    {
	foreach my $a1 ( @AGES )
	{
	    my $diff = abs($r->{age} - $a1);
	    my $r1 = match_age($a1, \%INT_BY_AGE);
	    
	    if ( $r->{age} == $a1 )
	    {
		logMessage(2, "Matched $r->{age} ($r->{interval_name}) to $r1->{age} ($r1->{interval_name})");
		$r->{match} = $r1->{bound_no};
		next BOUND;
		
	    }
	    
	    elsif ( $r->{age} > 0 && $diff < 2.0 && $diff < 0.05 * $r1->{age} )
	    {
		my $answer = logQuestion("Match $r->{age} ($r->{interval_name}) to $r1->{age} ($r1->{interval_name})?");
		if ( $answer && $answer =~ /y/i )
		{
		    $r->{match} = $r1->{bound_no};
		    next BOUND;
		}
	    }
	}
    }

    # Now go back through them again. For each one that doesn't match, compute a percentage offset based on
    # the ORIGINAL ages (not the matched ones).
    
    my ($base_age, $base_no);
    my ($top_age, $top_no);
    
    foreach my $r ( reverse @$ts_res )
    {
	if ( $r->{match} )
	{
	    $base_age = $r->{age};
	    $base_no = $r->{match};
	}
	
	elsif ( $base_age )
	{
	    $r->{base_age} = $base_age;
	    $r->{base_no} = $base_no;
	}
    }
    
    foreach my $r ( @$ts_res )
    {
	if ( $r->{match} )
	{
	    $top_age = $r->{age};
	    $top_no = $r->{match};
	}
	
	elsif ( defined $top_age )
	{
	    $r->{top_age} = $top_age;
	    $r->{top_no} = $top_no;
	}

	if ( $r->{base_no} && $r->{top_no} )
	{
	    my $percent = 100 * ($r->{base_age} - $r->{age}) / ($r->{base_age} - $r->{top_age});
	    $r->{percent} = sprintf("%.1f", $percent);
	}
    }
    
    # Now print them out
    
    logMessage(2, "");
    logMessage(2, "Modeled boundaries:");
    
    foreach my $r ( @$ts_res )
    {
	if ( $r->{match} )
	{
	    my $name = $INT{$r->{match}}{interval_name};
	    logMessage(2, "$r->{age} ($r->{interval_name}) : matches $name [$r->{match}]");
	}

	elsif ( defined $r->{percent} )
	{
	    logMessage(2, "$r->{age} ($r->{interval_name}) : $r->{percent}\% : $r->{base_age} ($r->{base_no}) - $r->{top_age} ($r->{top_no})");
	}

	else
	{
	    logMessage(2, "$r->{age} ($r->{interval_name}) : absolute");
	}
    }

    # Ask if the user wants to update, and if so then do it.

    my $answer = logQuestion("Update these boundaries?");

    if ( $answer && $answer =~ /y/i )
    {
	$dbh->do("START TRANSACTION");

	try {
	    update_modeled($dbh, $ts_res, $options);
	}

        catch {
	    $dbh->do("ROLLBACK");
	    logMessage(2, "Aborted...");
	};

	$dbh->do("COMMIT");	
    }
}


sub match_age {
    
    my ($age, $intervals) = @_;

    my $limit;
    
    if ( $age <= 66 ) { $limit = 2; }
    elsif ( $age <= 542 ) { $limit = 3; }
    else { $limit = 4; }

    foreach my $r ( @{$intervals->{$age}} )
    {
	return $r if $r->{timescale_no} <= $limit;
    }

    return $intervals->{$age}[0];
}


sub update_modeled {
    
    my ($dbh, $ints, $options) = @_;

    my $sql;
    
    foreach my $r ( @$ints )
    {
	if ( $r->{match} )
	{
	    $sql = "
		UPDATE $TIMESCALE_BOUNDS SET bound_type = 'same', base_no = $r->{match}
		WHERE bound_no = $r->{bound_no}";

	    print STDERR "$sql\n\n" if $options->{debug};

	    $dbh->do($sql);
	}

	elsif ( $r->{percent} )
	{
	    $sql = "
		UPDATE $TIMESCALE_BOUNDS SET bound_type = 'percent', base_no = $r->{base_no},
			range_no = $r->{top_no}, offset = $r->{percent}, is_modeled = 1
		WHERE bound_no = $r->{bound_no}";

	    print STDERR "$sql\n\n" if $options->{debug};

	    $dbh->do($sql);
	}
    }
}


# establish_procedures ( dbh )
#
# Create or replace the triggers and stored procedures necessary for the timescale tables to work
# properly.

sub establish_procedures {
    
    my ($dbh, $options) = @_;

    logMessage(1, "Creating or replacing stored procedures...");
    
    logMessage(2, "    complete_bound_updates");
    
    $dbh->do("DROP PROCEDURE IF EXISTS complete_bound_updates");
    
    $dbh->do("CREATE PROCEDURE complete_bound_updates ( )
	BEGIN

	SET \@row_count = 1;
	SET \@age_iterations = 0;
	
	# Mark all timescales that have updated bounds as updated, plus all
	# other bounds in those timescales.
	
	# UPDATE $TIMESCALE_BOUNDS as tsb join $TIMESCALE_DATA as ts using (timescale_no)
	# 	join $TIMESCALE_BOUNDS as base using (timescale_no)
	# SET ts.is_updated = 1, tsb.is_updated = 1
	# WHERE base.is_updated;
	
	# For all updated records where the precision fields have not been
	# set, set them to the position of the last nonzero digit after the
	# decimal place.
	
	UPDATE $TIMESCALE_BOUNDS
	SET age_prec = coalesce(age_prec, length(regexp_substr(age, '(?<=[.])\\\\d*?(?=0*\$)'))),
	    age_error_prec = coalesce(age_error_prec, 
				length(regexp_substr(age_error, '(?<=[.])\\\\d*?(?=0*\$)'))),
	    percent_prec = coalesce(percent_prec, length(regexp_substr(percent, '(?<=[.])\\\\d*?(?=0*\$)'))),
	    percent_error_prec = coalesce(percent_error_prec,
				length(regexp_substr(percent_error, '(?<=[.])\\\\d*?(?=0*\$)')))
	WHERE is_updated and (age_prec is null or age_error_prec is null or
			      percent_prec is null or percent_error_prec is null);
	
	# Now update the ages and flags on all bounds that are marked as is_updated.  If
	# this results in any updated records, repeat the process until no
	# records change. We put a limit of 20 on the number of iterations.
	
	WHILE \@row_count > 0 AND \@age_iterations < 20 DO
	    
	    UPDATE $TIMESCALE_BOUNDS as tsb
		left join $TIMESCALE_BOUNDS as base on base.bound_no = tsb.base_no
		left join $TIMESCALE_BOUNDS as top on top.bound_no = tsb.range_no
	    SET tsb.is_updated = 1,
		tsb.age = case tsb.bound_type
			when 'same' then base.age
			when 'alias' then base.age
			when 'percent' then base.age - (tsb.percent / 100) * ( base.age - top.age )
			else tsb.age
			end,
		tsb.age_prec = case tsb.bound_type
			when 'same' then base.age_prec
			when 'alias' then base.age_prec
			when 'percent' then least(coalesce(base.age_prec, 0),
						  coalesce(top.age_prec, 0))
			else tsb.age_prec
			end,
		tsb.age_error = case tsb.bound_type
			when 'same' then base.age_error
			when 'alias' then base.age_error
			when 'percent' then coalesce(greatest(base.age_error, top.age_error),
						     base.age_error, top.age_error)
			else tsb.age_error
			end,
		tsb.age_error_prec = case tsb.bound_type
			when 'same' then base.age_error_prec
			when 'alias' then base.age_error_prec
			when 'percent' then least(coalesce(base.age_error_prec, 0),
						  coalesce(top.age_error_prec, 0))
			else tsb.age_error_prec
			end,
		tsb.is_spike = case tsb.bound_type
			when 'spike' then 1
			when 'same' then base.is_spike
			when 'alias' then base.is_spike
			else 0
			end
	    WHERE base.is_updated or top.is_updated or tsb.is_updated;
	    
	    SET \@row_count = ROW_COUNT();
	    SET \@age_iterations = \@age_iterations + 1;
	    
	    # SET \@debug = concat(\@debug, \@cnt, ' : ');
	    
	END WHILE;
	
	# Then do the same thing for the color and reference_no attributes
	
	SET \@row_count = 1;
	SET \@attr_iterations = 0;

	WHILE \@row_count > 0 AND \@attr_iterations < 20 DO
	
	    UPDATE $TIMESCALE_BOUNDS as tsb
		join $TIMESCALE_DATA as ts using (timescale_no)
		left join $TIMESCALE_BOUNDS as csource on csource.bound_no = tsb.color_no
		left join $TIMESCALE_BOUNDS as rsource on rsource.bound_no = tsb.refsource_no
	    SET tsb.is_updated = 1,
		tsb.color = if(tsb.color_no > 0, csource.color, tsb.color),
		tsb.reference_no = if(tsb.refsource_no > 0, rsource.reference_no, tsb.reference_no)
	    WHERE tsb.is_updated or csource.is_updated or rsource.is_updated;
	    
	    SET \@row_count = ROW_COUNT();
	    SET \@attr_iterations = \@attr_iterations + 1;
	    
	END WHILE;
	
	# Then check all of the bounds in the specified timescales for errors.
	
	CALL check_updated_bounds;
	
	END;");
    
    logMessage(2, "    update_timescale_ages");
    
    $dbh->do("DROP PROCEDURE IF EXISTS update_timescale_ages");
    
    $dbh->do("CREATE PROCEDURE update_timescale_ages ( t int unsigned )
	BEGIN
	
	UPDATE $TIMESCALE_DATA as ts join
	    (SELECT age, age_prec, timescale_no FROM $TIMESCALE_BOUNDS
	     WHERE timescale_no = t
	     ORDER BY age LIMIT 1) as min using (timescale_no)
	SET ts.min_age = min.age, ts.min_age_prec = min.age_prec
	WHERE timescale_no = t;
	
	UPDATE $TIMESCALE_DATA as ts join
	    (SELECT age, age_prec, timescale_no FROM $TIMESCALE_BOUNDS
	     WHERE timescale_no = t
	     ORDER BY age desc LIMIT 1) as max using (timescale_no)
	SET ts.max_age = max.age, ts.max_age_prec = max.age_prec
	WHERE timescale_no = t;
	
	END;");
    
    logMessage(2, "    check_updated_bounds");
    
    $dbh->do("DROP PROCEDURE IF EXISTS check_updated_bounds");
    
    $dbh->do("CREATE PROCEDURE check_updated_bounds ( )
	BEGIN
	
	UPDATE $TIMESCALE_DATA as ts join
	    (SELECT timescale_no, min(b.age) as min, max(b.age) as max FROM
		$TIMESCALE_BOUNDS as b join $TIMESCALE_BOUNDS as base using (timescale_no)
	     WHERE base.is_updated GROUP BY timescale_no) as all_bounds using (timescale_no)
	SET ts.min_age = all_bounds.min,
	    ts.max_age = all_bounds.max;
	
	UPDATE $TIMESCALE_BOUNDS as tsb join $TIMESCALE_DATA as ts using (timescale_no) join
		(SELECT b1.bound_no,
		    if(b1.is_top, 1, b1.age_this > b1.age_prev) as age_ok,
		    if(b1.is_top, b1.interval_no = 0, b1.interval_no = b1.lower_prev) as bound_ok,
		    (b1.interval_no = 0 or b1.upper_int > 0) as interval_ok,
		    (b1.lower_this = 0 or b1.lower_int > 0) as lower_ok,
		    (b1.duplicate_no is null) as unique_ok
		 FROM
		  (SELECT b0.bound_no, b0.timescale_no, (\@ts_prev:=\@ts_this) as ts_prev, (\@ts_this:=timescale_no) as ts_this,
			(\@ts_prev is null or \@ts_prev <> \@ts_this) as is_top, b0.interval_no, upper_int, lower_int,
			(\@lower_prev:=\@lower_this) as lower_prev, (\@lower_this:=lower_no) as lower_this,
			(\@age_prev:=\@age_this) as age_prev, (\@age_this:=b0.age) as age_this, b0.duplicate_no
		   FROM (SELECT b.bound_no, b.timescale_no, b.age, b.interval_no, b.lower_no,
			upper.interval_no as upper_int, lower.interval_no as lower_int,
			duplicate.bound_no as duplicate_no
		   FROM $TIMESCALE_BOUNDS as b
			join $TIMESCALE_BOUNDS as base using (timescale_no)
			left join $TIMESCALE_BOUNDS as duplicate on duplicate.timescale_no = b.timescale_no and
				duplicate.interval_no = b.interval_no and duplicate.bound_no <> b.bound_no and
				duplicate.bound_no > 0
		        left join timescale_ints as upper on upper.interval_no = b.interval_no
		        left join timescale_ints as lower on lower.interval_no = b.lower_no
			join (SELECT \@lower_this:=null, \@lower_prev:=null, \@age_this:=null, \@age_prev:=null,
				\@ts_prev:=0, \@ts_this:=0) as initializer
		   WHERE base.is_updated GROUP BY b.bound_no ORDER BY b.timescale_no, b.age) as b0) as b1) as b2 using (bound_no)
		 
	      SET tsb.is_error = not(bound_ok and age_ok and interval_ok and lower_ok and unique_ok),
		  ts.is_error = not(bound_ok and age_ok and interval_ok and lower_ok and unique_ok);
	END;");
    
    $dbh->do("DROP PROCEDURE IF EXISTS unmark_updated");
    
    $dbh->do("CREATE PROCEDURE unmark_updated ( )
	BEGIN
	
	UPDATE $TIMESCALE_BOUNDS SET is_updated = 0;
	
	END;");
    
    logMessage(2, "    unmark_updated_bounds");
    
    $dbh->do("DROP PROCEDURE IF EXISTS unmark_updated_bounds");
    
    $dbh->do("CREATE PROCEDURE unmark_updated_bounds ( )
	BEGIN
	
	UPDATE $TIMESCALE_BOUNDS SET is_updated = 0;
	
	END;");
    
    logMessage(1, "Done.");
}


# establish_triggers ( dbh )
#
# Create or replace the triggers and stored procedures necessary for the timescale tables to work
# properly.

sub establish_triggers {
    
    my ($dbh, $options) = @_;

    logMessage(1, "Creating or replacing triggers...");
    
    logMessage(2, "    insert_bound on $TIMESCALE_BOUNDS");
    
    $dbh->do("DROP TRIGGER IF EXISTS insert_bound");
    
    $dbh->do("CREATE TRIGGER insert_bound
	BEFORE INSERT ON $TIMESCALE_BOUNDS FOR EACH ROW
	BEGIN
	    DECLARE ts_interval_type varchar(10);
	    
	    IF NEW.timescale_no > 0 THEN
		SELECT timescale_type INTO ts_interval_type
		FROM $TIMESCALE_DATA WHERE timescale_no = NEW.timescale_no;
		
		IF NEW.interval_type is null or NEW.interval_type = ''
		THEN SET NEW.interval_type = interval_type; END IF;
	    END IF;
	    
	    SET NEW.is_updated = 1;
	END;");
    
    logMessage(2, "    update_bound on $TIMESCALE_BOUNDS");
    
    $dbh->do("DROP TRIGGER IF EXISTS update_bound");
    
    $dbh->do("CREATE TRIGGER update_bound
	BEFORE UPDATE ON $TIMESCALE_BOUNDS FOR EACH ROW
	BEGIN
	    IF OLD.bound_type <> NEW.bound_type or OLD.interval_no <> NEW.interval_no or
		OLD.lower_no <> NEW.lower_no or OLD.base_no <> NEW.base_no or
		OLD.range_no <> NEW.range_no or OLD.color_no <> NEW.color_no or
		OLD.refsource_no <> NEW.refsource_no or OLD.age <> NEW.age or
		OLD.age_error <> NEW.age_error or OLD.percent <> NEW.percent or
		OLD.percent_error <> NEW.percent_error or OLD.age_prec <> NEW.age_prec or
		OLD.age_error_prec <> NEW.age_error_prec or OLD.percent_prec <> NEW.percent_prec or
		OLD.percent_error_prec <> NEW.percent_error_prec or
		OLD.color <> NEW.color or OLD.reference_no <> NEW.reference_no
		 THEN
	    SET NEW.is_updated = 1; END IF;
	END;");

    logMessage(1, "Done.");
}

1;
