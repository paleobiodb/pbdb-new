# CollectionData
# 
# A class that contains common routines for formatting and processing PBDB data.
# 
# Author: Michael McClennen

package PB2::CommonData;

use strict;

use HTTP::Validate qw(:validators);
use Carp qw(croak);
use TableDefs qw(%IDP);

use parent 'Exporter';

our (@EXPORT_OK) = qw(generateAttribution generateReference generateRISReference);

use Moo::Role;

our (%PERSON_NAME);

our ($COMMON_OPT_RE) = qr{ ^ ( taxa_ | ops_ | refs_ | occs_ | colls_ )?
			     ( created_before | created_after | 
			       modified_before | modified_after |
			       authorized_by | entered_by | modified_by |
			       authent_by | touched_by ) $ }xs;


# Initialization
# --------------

# initialize ( )
# 
# This routine is called once by the Web::DataService module, to initialize this
# output class.

sub initialize {
    
    my ($class, $ds) = @_;
    
    $ds->define_ruleset('1.2:special_params' => 
	"The following parameters can be used with most requests:",
	{ optional => 'SPECIAL(limit)' },
	{ optional => 'SPECIAL(offset)' },
	{ optional => 'SPECIAL(count)' },
	{ optional => 'SPECIAL(datainfo)' },
	{ optional => 'textresult', valid => FLAG_VALUE },
	    "If specified, then the result will be given a content type of 'text/plain'.",
	    "With most browsers, that will cause the result to be displayed directly",
	    "instead of saved to disk.  This parameter does not need any value.",
	{ optional => 'markrefs', valid => FLAG_VALUE },
	    "If specified, then formatted references will be marked up with E<lt>bE<gt> and E<lt>iE<gt> tags.",
	    "This parameter does not need a value.",
	{ optional => 'SPECIAL(vocab)' },
	{ optional => 'SPECIAL(save)' },
	">>The following parameters are only relevant to the text formats (.csv, .tsv, .txt):",
	{ optional => 'noheader', valid => FLAG_VALUE },
	    "If specified, then the header line which gives the field names is omitted.",
	    "This parameter does not need any value.  It is equivalent to \"header=no\".",
	{ optional => 'SPECIAL(linebreak)', alias => 'lb' },
	{ optional => 'SPECIAL(header)', undocumented => 1 },
	{ ignore => 'splat' });
    
    $ds->define_ruleset('1.2:common:select_crmod' =>
	{ param => 'created_before', valid => \&datetime_value },
	    "Select only records that were created before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'created_after', valid => \&datetime_value, alias => 'created_since' },
	    "Select only records that were created on or after the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'modified_before', valid => \&datetime_value },
	    "Select only records that were last modified before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'modified_after', valid => \&datetime_value, alias => 'modified_since' },
	    "Select only records that were modified on or after the specified L<date or date/time|/data1.1/datetime>.");
    
    $ds->define_ruleset('1.2:common:select_taxa_crmod' =>
	{ param => 'taxa_created_before', valid => \&datetime_value },
	    "Select only records associated with taxa that were created before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'taxa_created_after', valid => \&datetime_value, alias => 'taxa_created_since' },
	    "Select only records associated with taxa that were created on or after the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'taxa_modified_before', valid => \&datetime_value },
	    "Select only records associated with taxa that were last modified before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'taxa_modified_after', valid => \&datetime_value, alias => 'taxa_modified_since' },
	    "Select only records associated with taxa that were modified on or after the specified L<date or date/time|/data1.1/datetime>.");
    
    $ds->define_ruleset('1.2:common:select_ops_crmod' =>
	{ param => 'ops_created_before', valid => \&datetime_value },
	    "Select only records associated with taxa that were created before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'ops_created_after', valid => \&datetime_value, alias => 'ops_created_since' },
	    "Select only records associated with taxa that were created on or after the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'ops_modified_before', valid => \&datetime_value },
	    "Select only records associated with taxa that were last modified before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'ops_modified_after', valid => \&datetime_value, alias => 'ops_modified_since' },
	    "Select only records associated with taxa that were modified on or after the specified L<date or date/time|/data1.1/datetime>.");
    
    $ds->define_ruleset('1.2:common:select_refs_crmod' =>
	{ param => 'refs_created_before', valid => \&datetime_value },
	    "Select only records associated with references that were created before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'refs_created_after', valid => \&datetime_value, alias => 'refs_created_since' },
	    "Select only records associated with references that were created on or after the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'refs_modified_before', valid => \&datetime_value },
	    "Select only records associated with references that were last modified before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'refs_modified_after', valid => \&datetime_value, alias => 'refs_modified_since' },
	    "Select only records associated with references that were modified on or after the specified L<date or date/time|/data1.1/datetime>.");
    
    $ds->define_ruleset('1.2:common:select_occs_crmod' =>
	{ param => 'occs_created_before', valid => \&datetime_value },
	    "Select only records associated with occurrences that were created before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'occs_created_after', valid => \&datetime_value, alias => 'occs_created_since' },
	    "Select only records associated with occurrences that were created on or after the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'occs_modified_before', valid => \&datetime_value },
	    "Select only records associated with occurrences that were last modified before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'occs_modified_after', valid => \&datetime_value, alias => 'occs_modified_since' },
	    "Select only records associated with occurrences that were modified on or after the specified L<date or date/time|/data1.1/datetime>.");
    
    $ds->define_ruleset('1.2:common:select_colls_crmod' =>
	{ param => 'colls_created_before', valid => \&datetime_value },
	    "Select only records associated with collections that were created before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'colls_created_after', valid => \&datetime_value, alias => 'colls_created_since' },
	    "Select only records associated with collections that were created on or after the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'colls_modified_before', valid => \&datetime_value },
	    "Select only records associated with collections that were last modified before the specified L<date or date/time|/data1.1/datetime>.",
	{ param => 'colls_modified_after', valid => \&datetime_value, alias => 'colls_modified_since' },
	    "Select only records associated with collections that were modified on or after the specified L<date or date/time|/data1.1/datetime>.");
    
    $ds->define_block('1.2:common:crmod' =>
	{ select => ['$cd.created', '$cd.modified'], tables => '$cd' },
	{ output => 'created', com_name => 'dcr' },
	  "The date and time at which this record was created.",
	{ output => 'modified', com_name => 'dmd' },
	  "The date and time at which this record was last modified.");
    
    $ds->define_ruleset('1.2:common:select_ent' =>
	{ param => 'authorized_by', valid => ANY_VALUE, list => ',' },
	    "Select only records that were authorized by the specified person,",
	    "indicated by name or identifier",
	{ param => 'entered_by', valid => ANY_VALUE, list => ',' },
	    "Select only records that were entered by the specified person,",
	    "indicated by name or identifier",
	{ param => 'modified_by', valid => ANY_VALUE, list => ',' },
	    "Select only records that were modified by the specified person,",
	    "indicated by name or identifier",
	{ param => 'touched_by', valid => ANY_VALUE, list => ',' },
	    "Select only records that were either authorized, entered or modified by",
	    "the specified person, indicated by name or identifier",
	{ param => 'authent_by', valid => ANY_VALUE, list => ',' },
	    "Select only records that were authorized or entered by the specified",
	    "the specified person, indicated by name or identifier");
    
    $ds->define_ruleset('1.2:common:select_taxa_ent' =>
	{ param => 'taxa_authorized_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were authorized by the specified person,",
	    "indicated by name or identifier",
	{ param => 'taxa_entered_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were entered by the specified person,",
	    "indicated by name or identifier",
	{ param => 'taxa_modified_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were modified by the specified person,",
	    "indicated by name or identifier",
	{ param => 'taxa_touched_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were either authorized, entered or modified by",
	    "the specified person, indicated by name or identifier",
	{ param => 'taxa_authent_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were authorized or entered by the specified",
	    "the specified person, indicated by name or identifier");
    
    $ds->define_ruleset('1.2:common:select_ops_ent' =>
	{ param => 'ops_authorized_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were authorized by the specified person,",
	    "indicated by name or identifier",
	{ param => 'ops_entered_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were entered by the specified person,",
	    "indicated by name or identifier",
	{ param => 'ops_modified_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were modified by the specified person,",
	    "indicated by name or identifier",
	{ param => 'ops_touched_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were either authorized, entered or modified by",
	    "the specified person, indicated by name or identifier",
	{ param => 'ops_authent_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with taxa that were authorized or entered by the specified",
	    "the specified person, indicated by name or identifier");
    
    $ds->define_ruleset('1.2:common:select_refs_ent' =>
	{ param => 'refs_authorized_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with references that were authorized by the specified person,",
	    "indicated by name or identifier",
	{ param => 'refs_entered_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with references that were entered by the specified person,",
	    "indicated by name or identifier",
	{ param => 'refs_modified_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with references that were modified by the specified person,",
	    "indicated by name or identifier",
	{ param => 'refs_touched_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with references that were either authorized, entered or modified by",
	    "the specified person, indicated by name or identifier",
	{ param => 'refs_authent_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with references that were authorized or entered by the specified",
	    "the specified person, indicated by name or identifier");
    
    $ds->define_ruleset('1.2:common:select_occs_ent' =>
	{ param => 'occs_authorized_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with occurrences that were authorized by the specified person,",
	    "indicated by name or identifier",
	{ param => 'occs_entered_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with occurrences that were entered by the specified person,",
	    "indicated by name or identifier",
	{ param => 'occs_modified_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with occurrences that were modified by the specified person,",
	    "indicated by name or identifier",
	{ param => 'occs_touched_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with occurrences that were either authorized, entered or modified by",
	    "the specified person, indicated by name or identifier",
	{ param => 'occs_authent_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with occurrences that were authorized or entered by the specified",
	    "the specified person, indicated by name or identifier");
    
    $ds->define_ruleset('1.2:common:select_colls_ent' =>
	{ param => 'colls_authorized_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with collections that were authorized by the specified person,",
	    "indicated by name or identifier",
	{ param => 'colls_entered_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with collections that were entered by the specified person,",
	    "indicated by name or identifier",
	{ param => 'colls_modified_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with collections that were modified by the specified person,",
	    "indicated by name or identifier",
	{ param => 'colls_touched_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with collections that were either authorized, entered or modified by",
	    "the specified person, indicated by name or identifier",
	{ param => 'colls_authent_by', valid => ANY_VALUE, list => ',' },
	    "Select only records associated with collections that were authorized or entered by the specified",
	    "the specified person, indicated by name or identifier");
        
    $ds->define_block('1.2:common:ent' =>
	{ select => ['$cd.authorizer_no', '$cd.enterer_no', '$cd.modifier_no'], tables => '$cd' },
	{ output => 'authorizer_no', com_name => 'ati', if_block => 'ent,entname' },
	    "The identifier of the person who authorized the entry of this record",
	{ output => 'enterer_no', com_name => 'eni', if_block => 'ent,entname' },
	    "The identifier of the person who actually entered this record.",
	{ output => 'modifier_no', com_name => 'mdi', if_block => 'ent,entname' },
	    "The identifier of the person who last modified this record, if it has been modified.");
    
    $ds->define_block('1.2:common:entname' =>
	{ select => ['$cd.authorizer_no', '$cd.enterer_no', '$cd.modifier_no'], tables => '$cd' },
	{ set => 'authorizer', from => 'authorizer_no', lookup => \%PERSON_NAME, default => 'unknown' },
	{ set => 'enterer', from => 'enterer_no', lookup => \%PERSON_NAME, default => 'unknown' },
	{ set => 'modifier', from => 'modifier_no', lookup => \%PERSON_NAME },
	{ output => 'authorizer', com_name => 'ath' },
	    "The name of the person who authorized the entry of this record",
	{ output => 'enterer', com_name => 'ent' },
	    "The name of the person who actually entered this record",
	{ output => 'modifier', com_name => 'mdf' },
	    "The name of the person who last modified this record, if it has been modified.");
    
    # Now fill in the %PERSON_NAME hash.
    
    my $dbh = $ds->get_connection;
    
    my $values = $dbh->selectcol_arrayref("SELECT person_no, reversed_name FROM person",
					  { Columns => [1, 2] });
    
    %PERSON_NAME = @$values;
}


# datetime_value ( )
# 
# Validate a date or date/time value.

my (%UNIT_MAP) = ( d => 'DAY', m => 'MINUTE', h => 'HOUR', w =>'WEEK', M => 'MONTH', Y => 'YEAR' );

sub datetime_value {
    
    my ($value, $context) = @_;
    
    my $dbh = $PBData::ds1->get_connection;
    my $quoted = $dbh->quote($value);
    my $clean;
    
    # If we were given a number of days/hours, then treat that as "ago".
    
    if ( $value =~ /^(\d+)([mhdwMY])$/xs )
    {
	if ( $2 eq 'm' || $2 eq 'h' )
	{
	    ($clean) = $dbh->selectrow_array("SELECT DATE_SUB(NOW(), INTERVAL $1 $UNIT_MAP{$2})");
	}
	
	else
	{
	    ($clean) = $dbh->selectrow_array("SELECT DATE_SUB(CURDATE(), INTERVAL $1 $UNIT_MAP{$2})");
	}
    }
    
    else {
	($clean) = $dbh->selectrow_array("SELECT CONVERT($quoted, datetime)");
    }
    
    if ( $clean )
    {
	return { value => "'$clean'" };
    }
    
    else
    {
	return { error => "the value of {param} must be a valid date or date/time as defined by the MySQL database (was {value})" };
    }
}


# generate_crmod_filters ( table_name )
# 
# Generate the proper filters to select records by date created/modified.

sub generate_crmod_filters {

    my ($request, $table_name, $tables_hash) = @_;
    
    my @filters;
    
    if ( my $dt = $request->clean_param('created_after') )
    {
	push @filters, "$table_name.created >= $dt";
    }
    
    if ( my $dt = $request->clean_param('created_before') )
    {
	push @filters, "$table_name.created < $dt";
    }
    
    if ( my $dt = $request->clean_param('modified_after') )
    {
	push @filters, "$table_name.modified >= $dt";
    }
    
    if ( my $dt = $request->clean_param('modified_before') )
    {
	push @filters, "$table_name.modified < $dt";
    }
    
    $tables_hash->{$table_name} = 1 if @filters && ref $tables_hash eq 'HASH';
    
    return @filters;
}


# generate_ent_filters ( table_name )
# 
# Generate the proper filters to select records by authorizer/enterer/modifier
# name or number.

sub generate_ent_filters {
    
    my ($request, $table_name, $tables_hash) = @_;
    
    my @filters;
    
    # First go through the parameters and figure out if we have names or
    # identifiers.  Convert all names into identifiers.
    
    if ( my $value = $request->clean_param('authorized_by') )
    {
	push @filters, ent_filter($request, $table_name, 'authorizer_no', $value);
    }
    
    if ( my $value = $request->clean_param('entered_by') )
    {
	push @filters, ent_filter($request, $table_name, 'enterer_no', $value);
    }
    
    if ( my $value = $request->clean_param('modified_by') )
    {
	push @filters, ent_filter($request, $table_name, 'modifier_no', $value);
    }
    
    if ( my $value = $request->clean_param('touched_by') )
    {
	push @filters, ent_filter($request, $table_name, 'touched', $value);
    }
    
    $tables_hash->{$table_name} = 1 if @filters && ref $tables_hash eq 'HASH';
        
    return @filters;
}


sub ent_filter {
    
    my ($request, $tn, $param, $person_value) = @_;

    my $dbh = $request->get_connection;
    my @values = ref $person_value eq 'ARRAY' ? @$person_value : $person_value;
    my @ids;
    
    # Go through each of the names in the list.  Any names we find get looked
    # up in the database.
    
    foreach my $p ( @values )
    {
	if ( $p =~ /^\d+$/ )
	{
	    push @ids, $p;
	}
	
	else
	{
	    my $quoted = $dbh->quote("$p%");
	    my $values = $dbh->selectcol_arrayref("
		SELECT person_no, name FROM person
		WHERE name like $quoted or reversed_name like $quoted", { Columns => [1, 2] });
	    
	    if ( defined $values && @$values < 3 )
	    {
		push @ids, $values->[0];
	    }
	    
	    elsif ( defined $values )
	    {
		my @ambiguous;
		
		while ( @$values )
		{
		    shift @$values;
		    push @ambiguous, "'" . shift(@$values) . "'";
		}
		
		my $list = join(', ', @ambiguous);
		$request->add_warning("Ambiguous name: '$p' could match any of the following names: $list");
	    }
	    
	    else
	    {
		$request->add_warning("Unknown name: '$p' is not a name known to this database");
	    }
	}
    }
    
    # Now generate a filter expression using the ids.  If we have no
    # identifiers, return a string which will select nothing.  This is the
    # proper response because the client clearly wanted to filter by identifier.
    
    my $id_list = join(',', @ids);
    return "$tn.authorizer_no = 0" unless $id_list;
    
    if ( $param eq 'touched' )
    {
	return "($tn.authorizer_no in ($id_list) or $tn.enterer_no in ($id_list) or $tn.modifier_no in ($id_list))";
    }
    
    else
    {
	return "$tn.$param in ($id_list)";
    }
}


# generateAttribution ( )
# 
# Generate an attribution string for the given record.  This relies on the
# fields "a_al1", "a_al2", "a_ao", and "a_pubyr".

sub generateAttribution {

    my ($request, $row) = @_;
    
    my $auth1 = $row->{a_al1} || '';
    my $auth2 = $row->{a_al2} || '';
    my $auth3 = $row->{a_ao} || '';
    my $pubyr = $row->{a_pubyr} || '';
    
    $auth1 =~ s/( Jr)|( III)|( II)//;
    $auth1 =~ s/\.$//;
    $auth1 =~ s/,$//;
    $auth2 =~ s/( Jr)|( III)|( II)//;
    $auth2 =~ s/\.$//;
    $auth2 =~ s/,$//;
    
    my $attr_string = $auth1;
    
    if ( $auth3 ne '' or $auth2 =~ /et al/ )
    {
	$attr_string .= " et al.";
    }
    elsif ( $auth2 ne '' )
    {
	$attr_string .= " and $auth2";
    }
    
    $attr_string .= " $pubyr" if $pubyr ne '';
    
    if ( $attr_string ne '' )
    {
	$attr_string = "($attr_string)" if defined $row->{orig_no} &&
	    $row->{orig_no} > 0 && defined $row->{taxon_no} && 
		$row->{orig_no} != $row->{taxon_no};
	
	return $attr_string;
    }
    
    return;
}


1;
