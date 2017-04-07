#
# InstitutionTables.pm
# 
# Create and manage tables for recording information about database contributors.
# 


package InstitutionTables;

use strict;

use base 'Exporter';

our (@EXPORT_OK) = qw(createInstitutionTables);

use Carp qw(carp croak);
use Try::Tiny;

use TableDefs qw($INSTITUTIONS $INST_NAMES $INST_ALTNAMES $INST_COLLS $INST_COLL_ALTNAMES $INST_CODES);

use CoreFunction qw(activateTables);
use ConsoleLog qw(logMessage);

our $INSTITUTIONS_WORK = "instw";
our $INST_ALTNAMES_WORK = "ianw";
our $INST_COLLS_WORK = "icollw";
our $INST_COLL_ALTNAMES_WORK = "iacw";
our $INST_CODES_WORK = "icodew";

sub init_institution_tables {

    my ($dbh) = @_;
    
    my ($result, $sql);
    
    logMessage(2, "Creating institution tables...");

    my $table_name;
    
    # First create new working tables.
    
    try {

	$table_name = $INSTITUTIONS_WORK;
	
	$dbh->do("DROP TABLE IF EXISTS $INSTITUTIONS_WORK");
	$dbh->do("CREATE TABLE $INSTITUTIONS_WORK (
		institution_no int unsigned PRIMARY KEY,
		institution_code varchar(20) not null,
		institution_name varchar(100) not null,
		main_url varchar(255) not null,
		websvc_url varchar(255) not null,
		last_updated datetime null,
		institution_lsid varchar(255) not null,
		lon decimal(9,3),
		lat decimal(9,3),
		KEY (institution_code),
		KEY (institution_name),
		KEY (lon, lat))");
	
	$dbh->do("DROP TABLE IF EXISTS $INST_ALTNAMES_WORK");
	$dbh->do("CREATE TABLE $INST_NAMES_WORK (
		institution_no int unsigned not null,
		institution_code varchar(20) not null,
		institution_name varchar(100) not null,
		KEY (institution_no),
		KEY (institution_code),
		KEY (institution_name))");
	
	$dbh->do("DROP TABLE IF EXISTS $INST_COLLS_WORK");
	$dbh->do("CREATE TABLE $INST_COLLS_WORK (
		collection_no int unsigned PRIMARY KEY,
		institution_no int unsigned not null,
		collection_code varchar(20) not null,
		collection_name varchar(255) not null,
		collection_status enum('active', 'inactive'),
		has_ih_record boolean,
		collection_url varchar(255) not null,
		catalog_url varchar(255) not null,
		last_updated datetime null,
		mailing_address varchar(255) not null,
		mailing_city varchar(80) not null,
		mailing_state varchar(80) not null,
		mailing_postcode varchar(20) not null,
		mailing_country varchar(80) not null,
		mailing_cc varchar(2) not null,
		physical_address varchar(255) not null,
		physical_city varchar(80) not null,
		physical_state varchar(80) not null,
		physical_postcode varchar(20) not null,
		physical_country varchar(80) not null,
		physical_cc varchar(2) not null,
		collection_contact varchar(80) not null,
		contact_role varchar(80) not null,
		contact_email varchar(80) not null,
		collection_lsid varchar(100) not null,
		KEY (institution_no),
		KEY (collection_code),
		KEY (collection_name))");
	
	$dbh->do("DROP TABLE IF EXISTS $INST_COLL_ALTNAMES_WORK");
	$dbh->do("CREATE TABLE $INST_COLL_ALTNAMES_WORK (
		collection_no int unsigned not null,
		collection_code varchar(20) not null,
		colleciton_name varchar(255) not null,
		KEY (collection_no),
		KEY (collection_code),
		KEY (collection_name))");
	
	$dbh->do("DROP TABLE IF EXISTS $INST_CODES_WORK");
	$dbh->do("CREATE TABLE $INST_CODES_WORK (
		collection_code varchar(20) not null,
		collection_no int unsigned not null,
		institution_no int unsigned not null,
		KEY (collection_code),
		KEY (collection_no),
		KEY (institution_no))");
	
    } catch {
	
	logMessage(1, "ABORTING");
	return;
    };

    # Then activate them.

    try {
	
	activateTables($dbh, $INSTITUTIONS_WORK => $INSTITUTIONS,
		       $INST_ALTNAMES_WORK => $INST_ALTNAMES,
		       $INST_COLLS_WORK => $INST_COLLS,
		       $INST_COLL_ALTNAMES_WORK => $INST_COLL_ALTNAMES,
		       $INST_CODES_WORK => $INST_CODES);

	$dbh->do("ALTER TABLE $INST_NAMES ADD FOREIGN KEY (institution_no) REFERENCES $INSTITUTIONS (institution_no) on delete cascade on update cascade");
	$dbh->do("ALTER TABLE $INST_COLLS ADD FOREIGN KEY (institution_no) REFERENCES $INSTITUTIONS (institution_no) on delete cascade on update cascade");

	logMessage(2, "Created institution tables.");
	
    } catch {

	logMessage(1, "ABORTING");
	return;
	
    };
}

1;
