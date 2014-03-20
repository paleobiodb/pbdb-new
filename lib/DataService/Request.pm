#
# DataService::Query
# 
# A base class that implements a data service for the PaleoDB.  This can be
# subclassed to produce any necessary data service.  For examples, see
# TaxonQuery.pm and CollectionQuery.pm. 
# 
# Author: Michael McClennen

use strict;

package Web::DataService::Request;

use Scalar::Util qw(reftype);


# CLASS METHODS
# -------------

# new ( dbh, attrs )
# 
# Generate a new query object, using the given database handle and any other
# attributes that are specified.

sub new {
    
    my ($class, $attrs) = @_;
    
    # Now create a query record.
    
    my $self = { };
    
    if ( ref $attrs eq 'HASH' )
    {
	foreach my $key ( %$attrs )
	{
	    $self->{$key} = $attrs->{$key};
	}
    }
    
    # Bless it into the proper class and return it.
    
    bless $self, $class;
    return $self;
}


# get_config ( )
# 
# Get the Dancer configuration object, providing access to the configuration
# directives for this data service.

sub get_config {
    
    return Web::DataService->get_config;
}


# get_dbh ( )
# 
# Get a database handle, assuming that the proper directives are present in
# the config.yml file to allow a connection to be made.

sub get_dbh {
    
    my ($self) = @_;
    
    return $self->{dbh} if ref $self->{dbh};
    
    $self->{dbh} = Web::DataService->get_dbh;
    return $self->{dbh};
}


# define_valueset ( name, specification... )
# 
# Define a list of parameter values, with optional "internal" values and
# documentation.  This can be used to automatically generate a validator
# function and parameter documentation, using the routines below.
# 
# The names of valuesets must be unique within a single data service.

sub define_set {
    
    my $self = shift;
    goto &Web::DataService::define_set;
}


# document_valueset ( )
# 
# Return a string in POD format documenting the values listed in the named
# valueset.  Values can be excluded from the documentation by placing !# at
# the beginning of the documentation string.

sub document_set {
    
    my $self = shift;
    goto &Web::DataService::document_set;
}


# get_validator ( name )
# 
# Return a reference to a validator routine (a closure, actually) which will
# accept the list of values defined in the named valueset.

sub valid_set {

    my $self = shift;
    goto &Web::DataService::valid_set;
}


# define_block ( name, specification... )
# 
# Define an output block, using the default data service instance.  This must be
# called as a class method!

sub define_block {
    
    my $self = shift;
    goto &Web::DataService::define_block;
}


# define_output_map ( dummy )

sub define_output_map {
    
    my $self = shift;
    goto &Web::DataService::define_set;
}

# INSTANCE METHODS
# ----------------

# configure_output ( )
# 
# Determine the list of selection, processing and output rules for this query,
# based on the list of selected output sections, the operation, and the output
# format.

sub configure_output {
    
    my $self = shift;
    my $ds = $self->{ds};
    
    return $ds->configure_output($self);
}


# configure_block ( block_name )
# 
# Set up a list of processing and output steps for the given section.

sub configure_block {
    
    my ($self, $block_name) = @_;
    my $ds = $self->{ds};
    
    return $ds->configure_block($self, $block_name);
}


# add_output_block ( block_name )
# 
# Add the specified block to the output configuration for the current request.

sub add_output_block {
    
    my ($self, $block_name) = @_;
    my $ds = $self->{ds};
    
    return $ds->add_output_block($self, $block_name);
}


# output_key ( key )
# 
# Return true if the specified output key was selected for this request.

sub output_key {

    return $_[0]->{block_keys}{$_[1]};
}


# output_block ( name )
# 
# Return true if the named block is selected for the current request.

sub block_selected {

    return $_[0]->{block_hash}{$_[1]};
}


# select_list ( subst )
# 
# Return a list of strings derived from the 'select' records passed to
# define_output.  The parameter $subst, if given, should be a hash of
# substitutions to be made on the resulting strings.

sub select_list {
    
    my ($self, $subst) = @_;
    
    my @fields = @{$self->{select_list}} if ref $self->{select_list} eq 'ARRAY';
    
    if ( defined $subst && ref $subst eq 'HASH' )
    {
	foreach my $f (@fields)
	{
	    $f =~ s/\$(\w+)/$subst->{$1}/g;
	}
    }
    
    return @fields;
}


# select_hash ( subst )
# 
# Return the same set of strings as select_list, but in the form of a hash.

sub select_hash {

    my ($self, $subst) = @_;
    
    return map { $_ => 1} $self->select_list($subst);
}


# select_string ( subst )
# 
# Return the select list (see above) joined into a comma-separated string.

sub select_string {
    
    my ($self, $subst) = @_;
    
    return join(', ', $self->select_list($subst));    
}


# tables_hash ( )
# 
# Return a hashref whose keys are the values of the 'tables' attributes in
# 'select' records passed to define_output.

sub tables_hash {
    
    my ($self) = @_;
    
    return $self->{tables_hash};
}


# add_table ( name )
# 
# Add the specified name to the table hash.

sub add_table {

    my ($self, $table_name, $real_name) = @_;
    
    if ( defined $real_name )
    {
	if ( $self->{tables_hash}{"\$$table_name"} )
	{
	    $self->{tables_hash}{$real_name} = 1;
	}
    }
    else
    {
	$self->{tables_hash}{$table_name} = 1;
    }
}


# filter_hash ( )
# 
# Return a hashref derived from 'filter' records passed to define_output.

sub filter_hash {
    
    my ($self) = @_;
    
    return $self->{filter_hash};
}


# clean_param ( name )
# 
# Return the cleaned value of the named parameter, or the empty string if it
# doesn't exist.

sub clean_param {
    
    my ($self, $name) = @_;
    
    return '' unless ref $self->{valid};
    return $self->{valid}->value($name) // '';
}


# clean_param_list ( name )
# 
# Return a list of all the cleaned values of the named parameter, or the empty
# list if it doesn't exist.

sub clean_param_list {
    
    my ($self, $name) = @_;
    
    return unless ref $self->{valid};
    my $value = $self->{valid}->value($name);
    return @$value if ref $value eq 'ARRAY';
    return unless defined $value;
    return $value;
}


# debug ( )
# 
# Return true if we are in debug mode.

sub debug {
    
    my ($self) = @_;
    
    return $self->{ds}{DEBUG};
}


# process_record ( record, steps )
# 
# Process the specified record using the specified steps.

sub process_record {
    
    my ($self, $record, $steps) = @_;
    my $ds = $self->{ds};
    
    return $ds->process_record($self, $record, $steps);
}


# result_limit ( )
#
# Return the result limit specified for this request, or undefined if
# it is 'all'.

sub result_limit {
    
    return $_[0]->{result_limit} ne 'all' && $_[0]->{result_limit};
}


# result_offset ( will_handle )
# 
# Return the result offset specified for this request, or zero if none was
# specified.  If the parameter $will_handle is true, then auto-offset is
# suppressed.

sub result_offset {
    
    my ($self, $will_handle) = @_;
    
    $self->{offset_handled} = 1 if $will_handle;
    
    return $self->{result_offset} || 0;
}


# sql_limit_clause ( will_handle )
# 
# Return a string that can be added to an SQL statement in order to limit the
# results in accordance with the parameters specified for this request.  If
# the parameter $will_handle is true, then auto-offset is suppressed.

sub sql_limit_clause {
    
    my ($self, $will_handle) = @_;
    
    $self->{offset_handled} = $will_handle ? 1 : 0;
    
    my $limit = $self->{result_limit};
    my $offset = $self->{result_offset} || 0;
    
    if ( $offset > 0 )
    {
	$offset += 0;
	$limit = $limit eq 'all' ? 100000000 : $limit + 0;
	return "LIMIT $offset,$limit";
    }
    
    elsif ( defined $limit and $limit ne 'all' )
    {
	return "LIMIT " . ($limit + 0);
    }
    
    else
    {
	return '';
    }
}


# sql_count_clause ( )
# 
# Return a string that can be added to an SQL statement to generate a result
# count in accordance with the parameters specified for this request.

sub sql_count_clause {
    
    return $_[0]->{display_counts} ? 'SQL_CALC_FOUND_ROWS' : '';
}


# sql_count_rows ( )
# 
# If we were asked to get the result count, execute an SQL statement that will
# do so.

sub sql_count_rows {
    
    my ($self) = @_;
    
    if ( $self->{display_counts} )
    {
	($self->{result_count}) = $self->{dbh}->selectrow_array("SELECT FOUND_ROWS()");
    }
    
    return $self->{result_count};
}


# set_result_count ( count )
# 
# This method should be called if the backend database does not implement the
# SQL FOUND_ROWS() function.  The database should be queried as to the result
# count, and the resulting number passed as a parameter to this method.

sub set_result_count {
    
    my ($self, $count) = @_;
    
    $self->{result_count} = $count;
}


# add_warning ( message )
# 
# Add a warning message to this request object, which will be returned as part
# of the output.

sub add_warning {

    my $self = shift;
    
    foreach my $m (@_)
    {
	push @{$self->{warnings}}, $m if defined $m && $m ne '';
    }
}


# warnings
# 
# Return any warning messages that have been set for this request object.

sub warnings {

    my ($self) = @_;
    
    return unless ref $self->{warnings} eq 'ARRAY';
    return @{$self->{warnings}};
}


# output_format
# 
# Return the output format for this request

sub output_format {
    
    return $_[0]->{format};    
}


# display_header
# 
# Return true if we should display optional header material, false
# otherwise.  The text formats respect this setting, but JSON does not.

sub display_header {
    
    return $_[0]->{display_header};
}


# display_source
# 
# Return true if the data soruce should be displayed, false otherwise.

sub display_source {
    
    return $_[0]->{display_source};    
}


# display_counts
# 
# Return true if the result count should be displayed along with the data,
# false otherwise.

sub display_counts {

    return $_[0]->{display_counts};
}


# get_data_source
# 
# Return the following pieces of information:
# - The name of the data source
# - The license under which the data is made available

sub get_data_source {
    
    return Web::DataService->get_data_source;
}


# get_request_url
# 
# Return the raw (unparsed) request URL

sub get_request_url {

    return Web::DataService->get_request_url;
}


# get_request_path
# 
# Return the URL path for this request (just the path, no format suffix or
# parameters)

sub get_request_path {
    
    my $ds = $_[0]->{ds};
    
    return $ds->{path_prefix} . $_[0]->{path};
}


# params_for_display
# 
# Return a list of (parameter, value) pairs for use in constructing response
# headers.  These are the cleaned parameter values, not the raw ones.

sub params_for_display {
    
    my $self = $_[0];
    my $ds = $self->{ds};
    my $validator = $ds->{validator};
    my $rs_name = $self->{rs_name};
    my $path = $self->{path};
    
    # First get the list of all parameters allowed for this result.  We will
    # then go through them in order to ensure a known order of presentation.
    
    my @param_list = list_ruleset_params($validator, $rs_name, {});
    
    # Now filter this list.  For each parameter that has a value, add its name
    # and value to the display list.
    
    my @display;
    
    foreach my $p ( @param_list )
    {
	# Skip parameters that don't have a value.
	
	next unless defined $self->{params}{$p};
	
	# Skip the 'showsource' parameter itself, plus a few more.
	
	next if $p eq $ds->{path_attrs}{$path}{showsource_param} ||
	    $p eq $ds->{path_attrs}{$path}{textresult_param} ||
		$p eq $ds->{path_attrs}{$path}{linebreak_param} ||
		    $p eq $ds->{path_attrs}{$path}{count_param} ||
			$p eq $ds->{path_attrs}{$path}{nohead_param};
	
	# Others get included along with their value(s).
	
	push @display, $p, $self->{params}{$p};
    }
    
    return @display;
}


sub list_ruleset_params {
    
    my ($validator, $rs_name, $uniq) = @_;
    
    return if $uniq->{$rs_name}; $uniq->{$rs_name} = 1;
    
    my $rs = $validator->{RULESETS}{$rs_name};
    return unless ref $rs eq 'HTTP::Validate::Ruleset';
    
    my @params;
    
    foreach my $rule ( @{$rs->{rules}} )
    {
	if ( $rule->{type} eq 'param' )
	{
	    push @params, $rule->{param};
	}
	
	elsif ( $rule->{type} eq 'include' )
	{
	    foreach my $name ( @{$rule->{ruleset}} )
	    {
		push @params, list_ruleset_params($validator, $name, $uniq);
	    }
	}
    }
    
    return @params;
}


# result_counts
# 
# Return a hashref containing the following values:
# 
# found		the total number of records found by the main query
# returned	the number of records actually returned
# offset	the number of records skipped before the first returned one
# 
# These counts reflect the values given for the 'limit' and 'offset' parameters in
# the request, or whichever substitute parameter names were configured for
# this data service.
# 
# If no counts are available, empty strings are returned for all values.

sub result_counts {

    my ($self) = @_;
    
    # Start with a default hashref with empty fields.  This is what will be returned
    # if no information is available.
    
    my $r = { found => $self->{result_count} // '',
	      returned => $self->{result_count} // '',
	      offset => $self->{result_offset} // '' };
    
    # If no result count was given, just return the default hashref.
    
    return $r unless defined $self->{result_count};
    
    # Otherwise, figure out the start and end of the output window.
    
    my $window_start = defined $self->{result_offset} && $self->{result_offset} > 0 ?
	$self->{result_offset} : 0;
    
    my $window_end = $self->{result_count};
    
    # If the offset and limit together don't stretch to the end of the result
    # set, adjust the window end.
    
    if ( defined $self->{result_limit} && $self->{result_limit} ne 'all' &&
	 $window_start + $self->{result_limit} < $window_end )
    {
	$window_end = $window_start + $self->{result_limit};
    }
    
    # The number of records actually returned is the length of the output
    # window. 
    
    $r->{returned} = $window_end - $window_start;
    
    return $r;
}


# linebreak_cr
# 
# Return true if the linebreak sequence should be a single carriage return
# instead of the usual carriage return/linefeed combination.

sub linebreak_cr {

    return $_[0]->{linebreak_cr};
}


1;