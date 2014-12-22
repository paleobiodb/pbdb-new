# 
# The Paleobiology Database
# 
#   Taxonomy.pm
# 

use lib '.';

package Taxonomy;

use TaxonDefs qw(%TAXON_TABLE %TAXON_RANK %RANK_STRING);
use Carp qw(carp croak);
use Try::Tiny;

use strict;
use feature 'unicode_strings';


our (%NOM_CODE) = ( 'iczn' => 1, 'icn' => 2, 'icnb' => 3 );

our (%TREE_TABLE_ID) = ( 'taxon_trees' => 1 );

our (%FIELD_LIST, %FIELD_TABLES);

our ($SQL_STRING);

=head3 new ( dbh, tree_table_name )

    $taxonomy = Taxonomy->new($dbh, 'taxon_trees');

Creates a new Taxonomy object, which will use the database connection given by
C<dbh> and the taxonomy table named by C<tree_table_name>.  As noted above,
the main taxonomy table is called I<taxon_trees>.  This is currently the only
one defined, but this module and C<TaxonTrees.pm> may at some point be changed
to include others.

=cut

sub new {

    my ($class, $dbh, $table_name) = @_;
    
    my $t = $TAXON_TABLE{$table_name};
    
    croak "unknown tree table '$table_name'" unless ref $t;
    croak "bad database handle" unless ref $dbh;
    
    my $self = { dbh => $dbh, 
		 sql_string => '',
		 TREE_TABLE => $table_name,
		 SEARCH_TABLE => $t->{search},
	         ATTRS_TABLE => $t->{attrs},
		 INTS_TABLE => $t->{ints},
		 LOWER_TABLE => $t->{lower},
		 COUNTS_TABLE => $t->{counts},
		 AUTH_TABLE => $t->{authorities},
		 OP_TABLE => $t->{opinions},
		 OP_CACHE => $t->{opcache},
		 REFS_TABLE => $t->{refs},
		 NAMES_TABLE => $t->{names},
		 SCRATCH_TABLE => 'ancestry_scratch',
	       };
        
    bless $self, $class;
    
    return $self;
}


my (%STD_OPTION) = ( fields => 1, 
		     min_rank => 1, max_rank => 1, 
		     extant => 1, 
		     status => 1, 
		     order => 1,
		     base_order => 1,
		     limit => 1,
		     offset => 1,
		     return => 1 );

my $VALID_TAXON_ID = qr{^[0-9]+$};


# get_last_sql ( )
# 
# Return the SQL statement last generated by this module (this means the last
# SQL statement used to actually fetch taxon records, ignoring any auxiliary requests).
# This can be used for debugging purposes.

sub get_last_sql {
    
    my ($taxonomy) = @_;
    
    return $taxonomy->{sql_string} || '';
}


sub clear_warnings {

    my ($taxonomy) = @_;
    delete $taxonomy->{warnings};
    delete $taxonomy->{warning_codes};
}


sub add_warning {

    my ($taxonomy, $code, $message) = @_;
    push @{$taxonomy->{warnings}}, $message;
    push @{$taxonomy->{warning_codes}}, $code;
}


# list_subtree ( base_id, options )
# 
# Return a reference to a list of records corresponding to the subtree rooted at
# the specified taxon, or to the empty list if none exists.  This is intended to
# be a simple routine to cover a common case.  For more flexibility, try
# &list_taxa or &list_related_taxa.

sub list_subtree {

    my ($taxonomy, $base_no, $options) = @_;
    
    # First check the arguments.
    
    $taxonomy->clear_warnings;
    
    croak "list_subtree: first argument must be a taxon identifier\n"
	if ref $base_no;
    
    croak "list_subtree: second argument must be a hashref if given"
	if defined $options && ref $options ne 'HASH';
    $options ||= {};
    
    my $return_type = lc $options->{return} || 'list';
    
    unless ( defined $base_no && $base_no =~ $VALID_TAXON_ID )
    {
	return $return_type eq 'listref' ? [] : ();
    }
    
    foreach my $key ( keys %$options )
    {
	croak "list_subtree: invalid option '$key'\n" unless $STD_OPTION{$key};
    }
    
    # Then generate an SQL statement according to the specified base_no and options.
    
    my $tables = {};
    my $fieldspec = $options->{fields} || 'SIMPLE';
    my @fields = $taxonomy->generate_fields($fieldspec, $tables);
    my $fields = join ', ', @fields;
    
    my @filters = "base.taxon_no = $base_no";
    push @filters, $taxonomy->simple_filters($options, $tables);
    my $filters = @filters ? join ' and ', @filters : '1=1';
    
    my $other_joins = $taxonomy->simple_joins('t', $tables);
    
    my $AUTH_TABLE = $taxonomy->{AUTH_TABLE};
    my $TREE_TABLE = $taxonomy->{TREE_TABLE};
    
    $taxonomy->{sql_string} = $SQL_STRING = "
	SELECT $fields
	FROM $AUTH_TABLE as base JOIN $TREE_TABLE as tb using (orig_no)
		JOIN $TREE_TABLE as t on t.lft between tb.lft and tb.rgt
		$other_joins
	WHERE $filters
	ORDER BY t.lft\n";
    
    my $result_list = $taxonomy->{dbh}->selectall_arrayref($SQL_STRING, { Slice => {} });
    
    return $return_type eq 'listref' ? $result_list : @$result_list;
}


sub list_taxa {

    my ($taxonomy, $base_nos, $options) = @_;
    
    # First check the arguments.
    
    $taxonomy->clear_warnings;
    
    croak "list_taxa: second argument must be a hashref if given"
	if defined $options && ref $options ne 'HASH';
    $options ||= {};
    
    my $return_type = lc $options->{return} || 'list';
    my $base_string;
    
    unless ( $base_string = $taxonomy->generate_id_string($base_nos, 'exclude') )
    {
	return $return_type eq 'listref' ? [] : ();
    }
    
    #my $base_exclude = $taxonomy->generate_exclude_hash($base_nos);
    
    foreach my $key ( keys %$options )
    {
	croak "list_taxa: invalid option '$key'\n" unless $STD_OPTION{$key};
    }
    
    # Then generate an SQL statement according to the specified base_no and options.
    
    my $tables = {};
    my $fieldspec = $options->{fields} || 'SIMPLE';
    my @fields = $taxonomy->generate_fields($fieldspec, $tables);
    push @fields, "base.taxon_no as base_no";
    my $fields = join ', ', @fields;
    
    my @filters = "base.taxon_no in ($base_string)";
    push @filters, $taxonomy->simple_filters($options, $tables);
    my $filters = join( q{ and }, @filters);
    
    my $other_joins = $taxonomy->simple_joins('t', $tables);
    
    my $AUTH_TABLE = $taxonomy->{AUTH_TABLE};
    my $TREE_TABLE = $taxonomy->{TREE_TABLE};
    
    $SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $fields
	FROM $AUTH_TABLE as base JOIN $TREE_TABLE as t using (orig_no)
		$other_joins
	WHERE $filters
	ORDER BY t.lft\n";
    
    my $result_list = $taxonomy->{dbh}->selectall_arrayref($SQL_STRING, { Slice => {} });
    
    $taxonomy->order_result_list($result_list, $base_nos) if $options->{base_order};
    
    # if ( keys %$base_exclude )
    # {
    # 	foreach my $t ( @$result_list )
    # 	{
    # 	    $t->{exclude} = 1 if $base_exclude->{$t->{base_no}};
    # 	}
    # }
    
    return $return_type eq 'listref' ? $result_list : @$result_list;
}


sub get_taxon {

    my ($taxonomy, $base_no, $options) = @_;
    
    # First check the arguments.
    
    $taxonomy->clear_warnings;
    
    croak "get_taxon: second argument must be a hashref if given"
	if defined $options && ref $options ne 'HASH';
    $options ||= {};
    
    foreach my $key ( keys %$options )
    {
	croak "get_taxon: invalid option '$key'\n" unless $STD_OPTION{$key};
    }
    
    croak "get_taxon: first argument must not be array"
	if ref $base_no eq 'ARRAY';
    
    my $base_string = $taxonomy->generate_id_string($base_no, 'exclude');
    
    my $tables = { use_a => 1 };
    
    my $fieldspec = $options->{fields} || 'SIMPLE';
    my @fields = $taxonomy->generate_fields($fieldspec, $tables);
    
    my $AUTH_TABLE = $taxonomy->{AUTH_TABLE};
    my $TREE_TABLE = $taxonomy->{TREE_TABLE};
    my $result;

    my $fields = join ', ', @fields;
    
    my @filters = "a.taxon_no in ($base_string)";
    push @filters, $taxonomy->simple_filters($options, $tables);
    my $filters = join( q{ and }, @filters);
    
    my $other_joins = $taxonomy->simple_joins('t', $tables);
    
    $SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $fields
	FROM $AUTH_TABLE as a JOIN $TREE_TABLE as t using (orig_no)
		$other_joins
	WHERE $filters
	GROUP BY a.taxon_no LIMIT 1\n";
    
    my $result = $taxonomy->{dbh}->selectrow_hashref($SQL_STRING);
    
    return $result;
}


sub list_related_taxa {
    
    my ($taxonomy, $rel, $base_nos, $options) = @_;
    
    # First check the arguments.
    
    $taxonomy->clear_warnings;
    
    croak "list_related_taxa: third argument must be a hashref if given"
	if defined $options && ref $options ne 'HASH';
    $options ||= {};
    
    my $return_type = lc $options->{return} || 'list';
    my $base_string;
    
    croak "list_related_taxa: second argument must be a valid relationship\n"
	unless defined $rel;
    
    unless ( $rel eq 'all_taxa' || 
	     ($base_string = $taxonomy->generate_id_string($base_nos, 'exclude')) )
    {
	return $return_type eq 'listref' ? [] : ();
    }
    
    foreach my $key ( keys %$options )
    {
	croak "list_related_taxa: invalid option '$key'\n" unless $STD_OPTION{$key};
    }
    
    my $tables = {};
    
    $tables->{use_a} = 1 if $rel eq 'variants' || $rel eq 'self';
    
    my $fieldspec = $options->{fields} || 'SIMPLE';
    $fieldspec = 'ID' if $return_type eq 'id';
    my @fields = $taxonomy->generate_fields($fieldspec, $tables);
    
    my $count_expr = $options->{count} ? 'SQL_CALC_FOUND_ROWS' : '';
    my $order_expr = $taxonomy->simple_order($options, $tables);
    my $limit_expr = $taxonomy->simple_limit($options);
    
    my $AUTH_TABLE = $taxonomy->{AUTH_TABLE};
    my $TREE_TABLE = $taxonomy->{TREE_TABLE};
    my $result;
    
    if ( $rel eq 'self' )
    {
	my $fields = join ', ', @fields;
	
	my @filters = "a.taxon_no in ($base_string)";
	push @filters, $taxonomy->simple_filters($options, $tables);
	my $filters = join( q{ and }, @filters);
	
	my $other_joins = $taxonomy->simple_joins('t', $tables);
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $count_expr $fields
	FROM $AUTH_TABLE as a JOIN $TREE_TABLE as t using (orig_no)
		$other_joins
	WHERE $filters
	GROUP BY a.taxon_no $order_expr $limit_expr\n";
    }
    
    elsif ( $rel eq 'current' || $rel eq 'valid' || $rel eq 'senior' || $rel eq 'parent' || $rel eq 'senpar' )
    {
	push @fields, 'base.taxon_no as base_no';
	my $fields = join ', ', @fields;
	
	my $rel_field = $rel eq 'current' ? 'spelling_no' : $rel . '_no';
	
	my @filters = "base.taxon_no in ($base_string)";
	push @filters, $taxonomy->simple_filters($options, $tables);
	my $filters = join( q{ and }, @filters);
	
	my $other_joins = $taxonomy->simple_joins('t', $tables);
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $count_expr $fields
	FROM $AUTH_TABLE as base JOIN $TREE_TABLE as tb using (orig_no)
		JOIN $TREE_TABLE as t on t.orig_no = tb.$rel_field
		$other_joins
	WHERE $filters
	GROUP BY t.orig_no $order_expr $limit_expr\n";
    }
    
    elsif ( $rel eq 'variants' )
    {
	push @fields, 'base.taxon_no as base_no';
	push @fields, 'if(a.taxon_no = t.spelling_no, 1, 0) as is_current';
	my $fields = join ', ', @fields;
	
	my @filters = "base.taxon_no in ($base_string)";
	push @filters, $taxonomy->simple_filters($options, $tables);
	my $filters = join( q{ and }, @filters);
	
	my $other_joins = $taxonomy->simple_joins('t', $tables);
	
	$order_expr ||= 'ORDER BY is_current desc, a.taxon_name';
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $count_expr $fields
	FROM $AUTH_TABLE as base JOIN $TREE_TABLE as t using (orig_no)
		JOIN $AUTH_TABLE as a on a.orig_no = t.orig_no
		$other_joins
	WHERE $filters
	GROUP BY a.taxon_no $order_expr $limit_expr\n";
    }
    
    elsif ( $rel eq 'synonyms' || $rel eq 'children' || $rel eq 'imm_children' )
    {
	push @fields, 'base.taxon_no as base_no';
	push @fields, 'if(t.orig_no = t.synonym_no, 1, 0) as is_senior' if $rel eq 'synonyms';
	my $fields = join ', ', @fields;
	
	my ($sel_field, $rel_field);
	
	if ( $rel eq 'synonyms' )
	{
	    $rel_field = 'synonym_no';
	    $sel_field = 'synonym_no';
	}
	
	elsif ( $rel eq 'imm_children' )
	{
	    $rel_field = 'parent_no';
	    $sel_field = 'orig_no';
	}
	
	else # ( $rel eq 'children' )
	{
	    $rel_field = 'senpar_no';
	    $sel_field = 'synonym_no';
	}
	
	my @filters = "base.taxon_no in ($base_string)";
	push @filters, $taxonomy->simple_filters($options, $tables);
	my $filters = join( q{ and }, @filters);
	
	my $other_joins = $taxonomy->simple_joins('t', $tables);
	
	$order_expr ||= 'ORDER BY is_senior desc' if $rel eq 'synonyms';
	$order_expr ||= 'ORDER BY t.lft';
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $count_expr $fields
	FROM $AUTH_TABLE as base JOIN $TREE_TABLE as tb using (orig_no)
		JOIN $TREE_TABLE as t on t.$rel_field = tb.$sel_field
		$other_joins
	WHERE $filters
	GROUP BY t.orig_no $order_expr $limit_expr\n";
    }
    
    elsif ( $rel eq 'all_children' || $rel eq 'all_imm_children' )
    {
	push @fields, 'base.taxon_no as base_no';
	my $fields = join ', ', @fields;
	
	my ($joins);
	
	if ( $rel eq 'all_imm_children' )
	{
	    $joins = "JOIN $TREE_TABLE as t on t.lft between tb.lft and tb.rgt";
	}
	
	else
	{
	    $joins = "JOIN $TREE_TABLE as tb2 on tb2.orig_no = tb.synonym_no
		JOIN $TREE_TABLE as t on t.lft between tb2.lft and tb2.rgt";
	}
	
	my @filters = "base.taxon_no in ($base_string)";
	push @filters, $taxonomy->simple_filters($options, $tables);
	push @filters, $taxonomy->exclusion_filters($base_nos);
	my $filters = join( q{ and }, @filters);
	
	my $other_joins = $taxonomy->simple_joins('t', $tables);
	
	$order_expr ||= 'ORDER BY t.lft';
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $count_expr $fields
	FROM $AUTH_TABLE as base JOIN $TREE_TABLE as tb using (orig_no)
		$joins
		$other_joins
	WHERE $filters
	GROUP BY t.orig_no $order_expr $limit_expr\n";
    }
    
    elsif ( $rel eq 'all_parents' )
    {
	# First select into the temporary table 'ancestry_temp' the set of
	# orig_no values representing the ancestors of the taxa identified by
	# $base_string.
	
	$taxonomy->compute_ancestry($base_string);
	
	# Now use this temporary table to do the actual query.
	
	push @fields, 's.is_base';
	my $fields = join ', ', @fields;
	
	if ( $rel eq 'common_ancestor' )
	{
	    $fields .= ', t.lft' unless $fields =~ qr{ t\.lft };
	    $fields .= ', t.rgt' unless $fields =~ qr{ t\.rgt };
	}
	
	#$fields =~ s{t\.senpar_no}{t.parent_no};
	
	my @filters = $taxonomy->simple_filters($options, $tables);
	my $filters = join( q{ and }, @filters);
	$filters ||= '1=1';
	
	my $other_joins = $taxonomy->simple_joins('t', $tables);
	
	$order_expr ||= 'ORDER BY t.lft';
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT $count_expr $fields
	FROM ancestry_temp as s JOIN $TREE_TABLE as ts using (orig_no)
		STRAIGHT_JOIN $TREE_TABLE as t on t.orig_no = ts.orig_no or t.orig_no = ts.synonym_no
		$other_joins
	WHERE $filters
	GROUP BY t.lft $order_expr $limit_expr\n";
    }
    
    elsif ( $rel eq 'crown_group' || $rel eq 'pan_group' || $rel eq 'stem_group' || $rel eq 'common_ancestor' )
    {
	# First select into the temporary table 'ancestry_temp' the set of
	# orig_no values representing the ancestors of the taxa identified by
	# $base_string.
	
	$taxonomy->compute_ancestry($base_string);
	
	# Now use this temporary table to query for the set of ancestral taxa.
	
	my $ATTRS_TABLE = $taxonomy->{ATTRS_TABLE};
	
	$SQL_STRING = $taxonomy->{sql_string} = "
	SELECT t.orig_no, t.lft, t.rgt, s.is_base, v.extant_children
	FROM ancestry_temp as s JOIN $TREE_TABLE as ts using (orig_no)
		JOIN $TREE_TABLE as t on t.orig_no = ts.synonym_no
		JOIN $ATTRS_TABLE as v on v.orig_no = t.orig_no
	GROUP BY t.lft ORDER BY t.lft desc";
	
	# my $result = $taxonomy->{dbh}->selectall_arrayref($SQL_STRING, { Slice => {} });
    }
    
    else
    {
	croak "list_related_taxa: invalid relationship '$rel'\n";
    }
    
    # Now execute the query and return the result.
    
    if ( $return_type eq 'list' )
    {
	my $result_list = $taxonomy->{dbh}->selectall_arrayref($SQL_STRING, { Slice => {} });
	$taxonomy->order_result_list($result_list, $base_nos) if $options->{base_order};
	return @$result_list;
    }
    
    elsif ( $return_type eq 'listref' )
    {
	my $result_list = $taxonomy->{dbh}->selectall_arrayref($SQL_STRING, { Slice => {} });
	$taxonomy->order_result_list($result_list, $base_nos) if $options->{base_order};
	return $result_list;
    }
    
    elsif ( $return_type eq 'stmt' )
    {
	my $stmt = $taxonomy->{dbh}->prepare($SQL_STRING);
	$stmt->execute();
	return $stmt;
    }
    
    elsif ( $return_type eq 'id' )
    {
	my $result_list = $taxonomy->{dbh}->selectcol_arrayref($SQL_STRING, { Slice => {} });
	return @$result_list;
    }
    
    else
    {
	croak "list_related_taxa: invalid return type '$return_type'\n";
    }
}


sub resolve_names {

    my ($taxonomy, $names, $options) = @_;
    
    # Check the arguments.
    
    $taxonomy->clear_warnings;
    
    croak "resolve_names: second argument must be a hashref"
	if defined $options && ref $options ne 'HASH';
    $options ||= {};
    
    my $return_type = lc $options->{return} || 'list';
    
    foreach my $key ( keys %$options )
    {
	croak "resolve_names: invalid option '$key'\n"
	    unless $STD_OPTION{$key} || $key eq 'fields';
    }
    
    # Generate a template query that will be able to find a name.
    
    my $tables = {};
    my @fields = $taxonomy->generate_fields($options->{fields} || 'SEARCH', $tables);
    
    my @filters, $taxonomy->simple_filters($options);
    
    my $fields = join q{, }, @fields;
    my $filters = @filters ? join( ' and ', @filters ) . ' and ' : '';
    my $joins = $taxonomy->simple_joins('t', $tables);
    
    my $limit = $options->{all_names} ? "LIMIT 500" : "LIMIT 1";
    
    my $sql_base = "
	SELECT $fields
	FROM taxon_search as s join taxon_trees as t on t.orig_no = s.orig_no
		join taxon_attrs as v on v.orig_no = t.orig_no
	WHERE $filters";
    
    my $sql_order = "
	ORDER BY s.is_current desc, s.is_exact desc, v.taxon_size desc $limit";
    
    # Then split the argument into a list of distinct names to interpret.
    
    my @names = $taxonomy->lex_namestring($names, $options);
    my @result;
    my (%base);
    
    # print STDERR "NAMES:\n\n";
    
    # foreach my $n (@names)
    # {
    # 	print STDERR "$n\n";
    # }
    
    # print STDERR "\n";
    # return;
    
    my $dbh = $taxonomy->{dbh};
    
  NAME:
    foreach my $n ( @names )
    {
	# If the name ends in ':', then it will be used as a base for
	# subsequent lookups.
	
	if ( $n =~ qr{ (.*) [:] $ }xs )
	{
	    my $base_name = $1;
	    
	    # If the base name itself contains a ':', then lookup the base
	    # using everything before the last ':'.  If nothing is found, then
	    # there must have been a bad name somewhere in the prefix.
	    
	    my ($prefix_base, $name);
	    
	    if ( $base_name =~ qr{ (.*) [:] (.*) }xs )
	    {
		$prefix_base = $base{$1};
		$name = $2;
		
		next NAME unless $prefix_base;
	    }
	    
	    else
	    {
		$name = $base_name;
	    }
	    
	    # Then try to see if the name matches an actual taxon.  If so,
	    # save it.
	    
	    if ( my $base = $taxonomy->lookup_base($name, $prefix_base) )
	    {
		$base{$base_name} = $base;
	    }
	    
	    # Otherwise, the base will be undefined which will cause
	    # subsequent lookups to fail.
	    
	    # Now go on to the next entry.
	    
	    next NAME;
	}
	
	# Otherwise, this entry represents a name to resolve.  If it
	# starts with '^', then set the 'exclude' flag.
	
	my $exclude;
	$exclude = 1 if $n =~ s{^\^}{};
	
	# If the name contains a prefix, split it off and look up the base.
	# If no base was found, then the base must have included a bad name.
	# In that case, skip this entry.
	
	my $range_clause;
	
	if ( $n =~ qr{ (.*) [:] (.*) }xs )
	{
	    my $prefix_base = $base{$1};	
	    $n = $2;
	    
	    if ( ref $prefix_base && $prefix_base->{lft} > 0 && $prefix_base->{rgt} > 0 )
	    {
		$range_clause = 'lft between '. $prefix_base->{lft} . ' and ' . $prefix_base->{rgt};
	    }
	    
	    elsif ( defined $prefix_base && $prefix_base =~ qr{ ^ lft }xs )
	    {
		$range_clause = $prefix_base
	    }
	    
	    else
	    {
		next NAME;
	    }
	}
	
	$n =~ s{[.]}{% }g;
	
	if ( $n =~ qr{ ^ ( [A-Za-z_%]+ )
			    (?: \s+ \( ( [A-Za-z_%]+ ) \) )?
			    (?: \s+    ( [A-Za-z_%]+ )    )?
			    (?: \s+    ( [A-Za-z_%]+ )    )? }xs )
	{
	    my $main = $1;
	    my $subgenus = $2;
	    my $species = $3;
	    $species .= " $4" if $4;
	    
	    my @clauses;
	    
	    if ( $species )
	    {
		my $quoted = $dbh->quote($species);
		push @clauses, "taxon_name like $quoted";
		
		$quoted = $dbh->quote($subgenus || $main || '_NOTHING_');
		push @clauses, "genus like $quoted";
	    }
	    
	    else
	    {
		my $quoted = $dbh->quote($subgenus || $main);
		push @clauses, "taxon_name like $quoted";
	    }
	    
	    push @clauses, "($range_clause)" if $range_clause;
	    
	    #$DB::single = 1;
	    my $sql = $sql_base . join(' and ', @clauses) . $sql_order;
	    
	    my $this_result = $dbh->selectall_arrayref($sql, { Slice => {} });
	    
	    foreach my $r ( @$this_result )
	    {
		$r->{exclude} = 1 if $exclude;
		push @result, $return_type eq 'id' ? $r->{orig_no} : $r;
	    }
	    
	    if ( ref $this_result->[0] )
	    {
		$base{$n} = $this_result->[0];
	    }
	}
    }
    
    return \@result if $return_type eq 'listref';
    return @result; # otherwise
}


sub lex_namestring {
    
    my ($taxonomy, $source_string) = @_;
    
    my (%prefixes, @names);
    
  LEXEME:
    while ( $source_string )
    {
	# Take out whitespace and commas at the beginning of the string (we
	# ignore these).
	
	if ( $source_string =~ qr{ ^ [\s,]+ (.*) }xs )
	{
	    $source_string = $1;
	    next LEXEME;
	}
	
	# Otherwise, grab everything up to the first comma.  This will be
	# taken to represent a taxonomic name possibly followed by exclusions.
	
	elsif ( $source_string =~ qr{ ^ ( [^,]+ ) (.*) }xs )
	{
	    $source_string = $2;
	    my $name_group = $1;
	    my $main_name;
	    
	    # From this string, take everything up to the first ^.  That's the
	    # main name.  Remove any whitespace at the end.
	    
	    if ( $name_group =~ qr{ ^ ( [^^]+ ) (.*) }xs )
	    {
		$name_group = $2;
		$main_name = $1;
		$main_name =~ s/\s+$//;
		
		# If the main name contains any invalid characters, just abort
		# the whole name group.
		
		if ( $main_name =~ qr{ [^\w%.:-] }xs )
		{
		    $taxonomy->add_warning('W_BAD_NAME', "invalid taxon name '$main_name'");
		    next LEXEME;
		}
		
		# If the name includes a ':', split off the first component as
		# an element that must be resolved first.  Repeat until there
		# are no such prefixes left.
		
		my $prefix = '';
		
		while ( $main_name =~ qr{ ( [^:]+ ) [:\s]+ (.*) }xs )
		{
		    $main_name = $2;
		    my $base_name = $1;
		    
		    # Remove any initial whitespace, change all '.' to '%',
		    # condense all repeated wildcards and spaces.
		    
		    $base_name =~ s/\s+$//;
		    $base_name =~ s/[.]/%/g;
		    $base_name =~ s/%+/%/g;
		    $base_name =~ s/\s+/ /g;
		    
		    # Keep track of the prefix so far, because each prefix
		    # will need to be looked up before the main name is.
		    
		    $prefix .= "$base_name:";
		    
		    $prefixes{$prefix} = 1;
		}
		
		# Now add the prefix(es) back to the main name.
		
		$main_name = $prefix . $main_name;
		
		# In the main name, '.' should be taken as a wildcard that
		# ends a word (as in "T.rex").  Condense any repeated
		# wildcards and spaces.
		
		$main_name =~ s/[.]/% /g;
		$main_name =~ s/%+/%/g;
		$main_name =~ s/\s+/ /g;
		
		# This will be one of the names to be resolved, as well as
		# being the base for any subsequent exclusions.
		
		push @names, $main_name;
	    }
	    
	    # Now, every successive string starting with '^' will represent an
	    # exclusion.  Remove any whitespace at the end.
	    
	EXCLUSION:
	    while ( $name_group =~ qr{ ^ \^+ ( [^^]+ ) (.*) }xs )
	    {
		$name_group = $2;
		my $exclude_name = $1;
		$exclude_name =~ s/\s+$//;
		
		# If the exclusion contains any invalid characters, ignore it.
		
		if ( $exclude_name =~ qr{ [^\w%.] }xs )
		{
		    $taxonomy->add_warning('W_BAD_NAME', "invalid taxon name '$exclude_name'");
		    next EXCLUSION;
		}
		
		# Any '.' should be taken as a wildcard with a space
		# following.  Condense any repeated wildcards and spaces.
		
		$exclude_name =~ s/[.]/% /g;
		$exclude_name =~ s/%+/%/g;
		$exclude_name =~ s/\s+/ /g;
		
		# Add this exclusion to the list of names to be resolved,
		# including the '^' flag and base name at the beginning.
		
		push @names, "^$main_name:$exclude_name";
	    }
	    
	    next LEXEME;
	}
	
	# If we get here, something went wrong with the parsing.
	
	else
	{
	    $taxonomy->add_warning('W_BAD_NAME', "invalid taxon name '$source_string'");
	}
    }
    
    # Now return the prefixes followed by the names.
    
    my @result = sort keys %prefixes;
    push @result, @names;
    
    return @result;
}


sub lookup_base {
    
    my ($taxonomy, $base_name, $prefix_base) = @_;
    
    return unless $base_name;
    
    my $dbh = $taxonomy->{dbh};
    
    # Names must contain only word characters, spaces, wildcards and dashes.
    
    unless ( $base_name =~ qr{ ^ ( \w [\w% -]+ ) $ }xs )
    {
	$taxonomy->add_warning('W_BAD_NAME', "invalid taxon name '$base_name'");
	return;
    }
    
    # If we were given a prefix base, construct a range clause.
    
    my $range_clause = '';
    
    if ( ref $prefix_base && $prefix_base->{lft} > 0 && $prefix_base->{rgt} )
    {
	$range_clause = 'and lft between '. $prefix_base->{lft} . ' and ' . $prefix_base->{rgt};
    }
    
    elsif ( defined $prefix_base && $prefix_base =~ qr{ ^ lft }xs )
    {
	$range_clause = "and ($prefix_base)";
    }
    
    # Count the number of letters (not punctuation or spaces).  This uses a
    # very obscure quirk of Perl syntax to evaluate the =~ in scalar but not
    # boolean context.
    
    my $letter_count = () = $base_name =~ m/\w/g;
    
    # If the base name doesn't contain any wildcards, and contains at least 2
    # letters, see if we can find an exactly coresponding taxonomic name.  If
    # we can find at least one, pick the one with the most subtaxa and we're
    # done.
    
    unless ( $base_name =~ qr{ [%_] } && $letter_count >= 2 )
    {
	my $quoted = $dbh->quote($base_name);
	
	# Note that we use 'like' so that that differences in case and
	# accent marks will be ignored.
	
	my $sql = "
		SELECT orig_no, lft, rgt, taxon_rank
		FROM taxon_search as s JOIN taxon_trees as t using (orig_no)
			JOIN taxon_attrs as v using (orig_no)
		WHERE taxon_name like $quoted and taxon_rank >= 4 $range_clause
		GROUP BY orig_no
		ORDER BY s.is_current desc, v.taxon_size desc LIMIT 1";
	
	my $result = $dbh->selectrow_hashref($sql);
	
	# If we found something, then we're done.
	
	if ( $result )
	{
	    return $result;
	}
    }
    
    # Otherwise, look up all entries where the name matches the given string
    # prefix-wise.  We require at least 3 actual letters, and if we get more
    # than 200 results then we declare the prefix to be bad.
    
    unless ( $letter_count >= 3 )
    {
	$taxonomy->add_warning('W_BAD_NAME', "base name '$base_name:' must be at least 3 characters");
	return;
    }
    
    my $quoted = $dbh->quote("$base_name%");
    
    my $sql = "
	SELECT lft, rgt
	FROM taxon_search as s JOIN taxon_trees as t using (orig_no)
	WHERE taxon_name like $quoted and taxon_rank >= 4 $range_clause
	GROUP BY orig_no";
    
    my $ranges = $dbh->selectall_arrayref($sql);
    
    unless ( $ranges && @$ranges > 0 && @$ranges <= 200 )
    {
	if ( @$ranges > 200 )
	{
	    $taxonomy->add_warning('W_BAD_NAME', "base name '$base_name:' is not specific enough");
	}
	
	else
	{
	    $taxonomy->add_warning('W_BAD_NAME', "base name '$base_name:' does not match any taxon");
	}
	
	return;
    }
    
    my @check = grep { $_->[0] > 0 && $_->[1] > 0 } @$ranges; 
    
    my $range_string = join(' or ', map { "lft between $_->[0] and $_->[1]" } @check);
    
    return $range_string;
}


sub generate_id_string {
    
    my ($taxonomy, $taxon_nos, $exclude) = @_;
    
    if ( ref $taxon_nos eq 'HASH' )
    {
	return join(q{,}, grep { $_ =~ $VALID_TAXON_ID } keys %$taxon_nos);
    }
    
    elsif ( ref $taxon_nos eq 'ARRAY' )
    {
	if ( ref $taxon_nos->[0] )
	{
	    if ( $exclude eq 'exclude' )
	    {
		my @include_taxa = grep { not $_->{exclude} } @$taxon_nos;
		return join(q{,}, map { $_->{taxon_no} || $_->{orig_no} } @include_taxa);
	    }
	    
	    else
	    {
		return join(q{,}, map { $_->{taxon_no} || $_->{orig_no} } @$taxon_nos);
	    }
	}
	
	else
	{
	    return join(q{,}, grep { $_ =~ $VALID_TAXON_ID } @$taxon_nos);
	}
    }
    
    elsif ( ref $taxon_nos )
    {
	croak "taxonomy: invalid taxon identifier '$taxon_nos'\n";
    }
    
    else
    {
	return join(q{,}, grep { $_ =~ $VALID_TAXON_ID } split(qr{\s*,\s*}, $taxon_nos));
    }
}


sub exclusion_filters {

    my ($taxonomy, $taxon_nos) = @_;
    
    return unless ref $taxon_nos eq 'ARRAY' && ref $taxon_nos->[0];
    
    my @filters;
    
    foreach my $t ( @$taxon_nos)
    {
	next unless $t->{exclude};
	next unless $t->{lft} && $t->{rgt};
	
	push @filters, "t.lft not between $t->{lft} and $t->{rgt}";
    }
    
    return @filters;
}


sub generate_fields {
    
    my ($taxonomy, $fields, $tables_hash) = @_;
    
    my @field_list;
    
    if ( ref $fields eq 'ARRAY' )
    {
	@field_list = @$fields;
    }
    
    elsif ( ref $fields )
    {
	croak "taxonomy: bad field specifier '$fields'\n";
    }
    
    elsif ( defined $fields )
    {
	@field_list = split qr{\s*,\s*}, $fields;
    }
    
    my (@result, %uniq);
    
    foreach my $f ( @field_list )
    {
	croak "taxonomy: unknown field specifier '$f'\n" unless ref $FIELD_LIST{$f};
	
	$f = 'AUTH_SIMPLE' if $f eq 'SIMPLE' && $tables_hash->{use_a};
	
	foreach my $n ( @{$FIELD_LIST{$f}} )
	{
	    next if $uniq{$n};
	    $uniq{$n} = 1;
	    push @result, $n;
	}
	
	# Note that the following shortcut implies at most three different
	# tables for any particular field specifier.  I can't see that this
	# will be a problem.
	
	@{$tables_hash}{@{$FIELD_TABLES{$f}}} = (1, 1, 1) if ref $FIELD_TABLES{$f};
    }
    
    croak "taxonomy: no valid fields specified\n" unless @result;
    
    return @result;
}



my (%STATUS_FILTER) = ( valid => "t.accepted_no = t.synonym_no",
			senior => "t.accepted_no = t.orig_no",
			junior => "t.accepted_no = t.synonym_no and t.orig_no <> t.synonym_no",
			invalid => "t.accepted_no <> t.synonym_no",
		        any => '1=1',
		        all => '1=1');

sub simple_filters {
    
    my ($taxonomy, $options, $tables_ref) = @_;
    
    my @filters;
    
    if ( $options->{status} )
    {
	my $filter = $STATUS_FILTER{$options->{status}};
	if ( defined $filter )
	{
	    push @filters, $filter unless $filter eq '1=1';
	}
	else
	{
	    push @filters, "t.status = 'NOTHING'";
	}
    }
    
    if ( $options->{min_rank} || $options->{max_rank} )
    {
	my $min = $options->{min_rank} > 0 ? $options->{min_rank} + 0 : $TAXON_RANK{lc $options->{min_rank}};
	my $max = $options->{max_rank} > 0 ? $options->{max_rank} + 0 : $TAXON_RANK{lc $options->{max_rank}};
	
	if ( $min && $max )
	{
	    push @filters, $min == $max ? "t.rank = $min" : "t.rank between $min and $max";
	}
	
	elsif ( $min )
	{
	    push @filters, "t.rank >= $min";
	}
	
	elsif ( $max )
	{
	    push @filters, "t.rank <= $max";
	}
	
	else
	{
	    push @filters, "t.rank = 0";
	}
    }
    
    if ( defined $options->{extant} && $options->{extant} ne '' )
    {
	$tables_ref->{v} = 1;
	
	if ( $options->{extant} )
	{
	    push @filters, "v.is_exant";
	}
	
	else
	{
	    push @filters, "not v.is_extant";
	}
    }
    
    return @filters;
}


sub simple_order {
    
    my ($taxonomy, $options, $tables_ref) = @_;
    
    my $order = $options->{order};
    
    return '' unless $order;
    
    if ( $order eq 'name' or $order eq 'name.asc' )
    {
	return $tables_ref->{use_a} ? "ORDER BY a.taxon_name" : "ORDER BY t.name";
    }
    
    elsif ( $order eq 'name.desc' )
    {
	return $tables_ref->{use_a} ? "ORDER BY a.taxon_name desc" : "ORDER BY t.name desc";
    }
    
    elsif ( $order eq 'lft' or $order eq 'lft.asc' )
    {
	return "ORDER BY t.left";
    }
    
    elsif ( $order eq 'size' or $order eq 'size.desc' )
    {
	return "ORDER BY v.size desc";
	$tables_ref->{v} = 1;
    }
    
    elsif ( $order eq 'size.asc' )
    {
	return "ORDER BY v.size asc";
	$tables_ref->{v} = 1;
    }
    
    elsif ( $order eq 'match' )
    {
	return '';
    }
    
    else
    {
	croak "taxonomy: invalid order '$order'";
    }
}


sub simple_limit {

    my ($taxonomy, $options) = @_;
    
    my $limit_string = '';
    
    if ( $options->{limit} && $options->{limit} ne '' )
    {
	my $limit = $options->{limit} + 0;
	$limit_string = "LIMIT $limit";
    }
    
    if ( $options->{offset} && $options->{offset} ne '' )
    {
	my $offset = $options->{offset} + 0;
	$limit_string = "OFFSET $offset " . $limit_string if $offset > 0;
    }
    
    return $limit_string;
}


sub simple_joins {

    my ($taxonomy, $mt, $tables_hash) = @_;
    
    my $joins = '';
    
    $joins .= "\t\tLEFT JOIN $taxonomy->{INTS_TABLE} as ph on ph.ints_no = $mt.ints_no\n"
	if $tables_hash->{ph};
    $joins .= "\t\tLEFT JOIN $taxonomy->{LOWER_TABLE} as pl on pl.orig_no = $mt.orig_no\n"
	if $tables_hash->{pl};
    $joins .= "\t\tLEFT JOIN $taxonomy->{COUNTS_TABLE} as pc on pc.orig_no = $mt.orig_no\n"
	if $tables_hash->{pc};
    $joins .= "\t\tLEFT JOIN $taxonomy->{ATTRS_TABLE} as v on v.orig_no = $mt.orig_no\n"
	if $tables_hash->{v};
    $joins .= "\t\tLEFT JOIN $taxonomy->{AUTH_TABLE} as a on a.taxon_no = t.spelling_no\n"
	if ($tables_hash->{a} || $tables_hash->{r}) && ! $tables_hash->{use_a};
    $joins .= "\t\tLEFT JOIN $taxonomy->{REFS_TABLE} as r on r.reference_no = a.reference_no\n"
	if $tables_hash->{r};
    
    return $joins;
}


sub order_result_list {
    
    my ($taxonomy, $result, $base_list) = @_;
    
    my (%base_list, @base_nos, %uniq);
    
    return unless ref $base_list eq 'ARRAY';
    
    foreach my $r ( @$result )
    {
	push @{$base_list{$r->{base_no}}}, $r;
    }
    
    @$result = ();
    
    if ( ref $base_list->[0] )
    {
	@base_nos = grep { $uniq{$_} ? 0 : ($uniq{$_} = 1) }
	    map { $_->{taxon_no} || $_->{orig_no} } @$base_list;
    }
    
    else
    {
	@base_nos = grep { $uniq{$_} ? 0 : ($uniq{$_} = 1) } @$base_list;
    }
    
    foreach my $b ( @base_nos )
    {
	push @$result, @{$base_list{$b}} if $base_list{$b};
    }
}


# compute_ancestry ( base_nos )
# 
# Use the ancestry scratch table to compute the set of common parents of the
# specified taxa (a stringified list of identifiers).
# 
# This function is only necessary because MySQL stored procedures cannot work
# on temporary tables.  :(

sub compute_ancestry {

    my ($taxonomy, $base_string) = @_;
    
    my $dbh = $taxonomy->{dbh};
    my $AUTH_TABLE = $taxonomy->{AUTH_TABLE};
    my $TREE_TABLE = $taxonomy->{TREE_TABLE};
    my $SCRATCH_TABLE = $taxonomy->{SCRATCH_TABLE};
    
    my $result;
    
    # Create a temporary table by which we can extract information from
    # $scratch_table and convey it past the table locks.
    
    $result = $dbh->do("DROP TABLE IF EXISTS ancestry_temp");
    $result = $dbh->do("CREATE TEMPORARY TABLE ancestry_temp (
				orig_no int unsigned primary key,
				is_base tinyint unsigned) Engine=MyISAM");
    
    # Lock the tables that will be used by the stored procedure
    # "compute_ancestry".
    
    $result = $dbh->do("LOCK TABLES $SCRATCH_TABLE write,
				    $SCRATCH_TABLE as s write,
				    $AUTH_TABLE read,
				    $TREE_TABLE read,
				    ancestry_temp write");
    
    # We need a try block to make sure that the table locks are released
    # no matter what else happens.
    
    try
    {
	# Fill the scratch table with the requested ancestry list.
	
	$result = $dbh->do("CALL compute_ancestry('$AUTH_TABLE','$TREE_TABLE', '$base_string')");
	
	# Now copy the information out of the scratch table to a temporary
	# table so that we can release the locks.
	
	$result = $dbh->do("INSERT INTO ancestry_temp SELECT * FROM $SCRATCH_TABLE"); 
    }
    
    finally {
	$dbh->do("UNLOCK TABLES");
	die $_[0] if defined $_[0];
    };
    
    # There is no need to return anything, since the results of this function
    # are in the rows of the 'ancestry_temp' table.  But we can stop here on
    # debugging.
    
    my $a = 1;
}


our (%FIELD_LIST) = ( ID => ['t.orig_no'],
		      SIMPLE => ['t.spelling_no as taxon_no', 't.orig_no', 't.name as taxon_name',
				 't.rank as taxon_rank', 't.status', 't.parent_no',
				 't.senpar_no'],
		      AUTH_SIMPLE => ['a.taxon_no', 'a.orig_no', 'a.taxon_name', 'a.taxon_rank',
				      't.lft', 't.senpar_no'],
		      SEARCH => ['t.orig_no', 't.name as taxon_name', 't.rank as taxon_rank',
				 't.lft', 't.rgt', 't.senpar_no'],
		      DATA => ['t.spelling_no as taxon_no', 't.orig_no', 't.name as taxon_name',
				 't.rank as taxon_rank', 't.lft', 't.status', 't.accepted_no', 't.parent_no', 
				 't.senpar_no', 'a.common_name', 'a.reference_no', 'v.is_extant'],
		      RANGE => ['t.orig_no', 't.rank as taxon_rank', 't.lft', 't.rgt'],
		      LINK => ['t.synonym_no', 't.accepted_no', 't.parent_no', 't.senpar_no'],
		      APP => ['v.first_early_age as firstapp_ea', 
			      'v.first_late_age as firstapp_la',
			      'v.last_early_age as lastapp_ea',
			      'v.last_late_age as lastapp_la'],
		      ATTR => ['if(a.refauth, r.author1last, a.author1last) as a_al1',
			       'if(a.refauth, r.author2last, a.author2last) as a_al2',
			       'if(a.refauth, r.otherauthors, a.otherauthors) as a_ao',
			       'if(a.refauth, r.pubyr, a.pubyr) as a_pubyr'],
		      PARENT => ['pa.taxon_name as parent_name', 'pa.taxon_rank as parent_rank'],
		      SIZE => ['v.taxon_size as size', 'v.extant_size', 'v.n_occs'],
		      PHYLO => ['ph.kingdom_no', 'ph.kingdom', 'ph.phylum_no', 'ph.phylum', 
				'ph.class_no', 'ph.class', 'ph.order_no', 'ph.order', 
				'ph.family_no', 'ph.family'],
		      COUNTS => ['pc.phylum_count', 'pc.class_count', 'pc.order_count', 
				 'pc.family_count', 'pc.genus_count', 'pc.species_count'],
		      family_no => ['ph.family_no'],
		      image_no => ['v.image_no'],
		    );

our (%FIELD_TABLES) = ( DATA => ['v', 'a'],
			APP => ['v'], 
			ATTR => ['r'],
			SIZE => ['v'],
			PHYLO => ['ph'],
			COUNTS => ['pc'],
			PARENT => ['pa'],
			image_no => ['v'],
		        family_no => ['ph'] );

1;

