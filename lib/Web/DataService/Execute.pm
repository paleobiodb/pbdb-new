#
# Web::DataService::Execute
# 
# This module provides a role that is used by 'Web::DataService'.  It implements
# routines for executing requests.
# 
# Author: Michael McClennen

use strict;

package Web::DataService::Execute;

use Carp 'croak';
use Scalar::Util qw(reftype weaken);

use Moo::Role;



# new_request ( outer, attrs )
# 
# Generate a new request object, using the given attributes.  $outer should be
# a reference to an "outer" request object that was generated by the
# underlying framework (i.e. Dancer or Mojolicious) or undef if there is
# none.

sub new_request {

    my ($ds, $outer, $attrs) = @_;
    
    # First check the arguments to this method.
    
    croak "new_request: second argument must be a hashref\n"
	if defined $attrs && ref $attrs ne 'HASH';
    
    $attrs ||= {};
    
    # If this was called as a class method rather than as an instance method,
    # then call 'select' to figure out the appropriate data service.
    
    unless ( ref $ds eq 'Web::DataService' )
    {
	$ds = Web::DataService->select($outer);
    }
    
    # Grab the request parameters from the foundation plugin.
    
    my $request_params = $Web::DataService::FOUNDATION->get_params($outer, 'query');
    
    # If "path" was not specified as an attribute, determine it from the request
    # parameters and path.
    
    unless ( defined $attrs->{path} )
    {
	my $request_path = $Web::DataService::FOUNDATION->get_request_path($outer, 'query');
	
	$attrs->{path} = $ds->_determine_path($request_path, $request_params);
    }
    
    # Now set the other required attributes, and create an object to represent
    # this request.
    
    $attrs->{outer} = $outer;
    $attrs->{ds} = $ds;
    $attrs->{http_method} = $Web::DataService::FOUNDATION->get_http_method($outer) || 'UNKNOWN';
    $attrs->{datainfo_url} = $Web::DataService::FOUNDATION->get_request_url($outer);
    
    my $request = Web::DataService::Request->new($attrs);
    
    # Make sure that the outer object is linked back to this request object.
    # The link from the "inner" object to the "outer" must be weakened,
    # so that garbage collection works properly.
    
    weaken($request->{outer}) if ref $request->{outer};
    $Web::DataService::FOUNDATION->store_inner($outer, $request);
    
    # Return the new request object.
    
    return $request;
}


# _determine_path ( url_path, params )
# 
# Given the request URL path and parameters, determine what the request path
# should be.

sub _determine_path {
    
    my ($ds, $request_path, $request_params) = @_;
    
    # If the special parameter 'path' is active, then we determine the result
    # from its value.  If this parameter was not specified in the request, it
    # defaults to ''.
    
    if ( my $path_param = $ds->{special}{path} )
    {
	my $path = $request_params->{$path_param} // '';
	return $path;
    }
    
    # Otherwise, we use the request path.  In this case, if the data service
    # has a path regexp, use it to trim the path.
    
    elsif ( defined $request_path )
    {
	if ( defined $ds->{path_re} && $request_path =~ $ds->{path_re} )
	{
	    return $1 // '';
	}
	
	else
	{
	    return $request_path;
	}
    }
    
    # Otherwise, return the empty string.
    
    else
    {
	return '';
    }
}


# handle_request ( request )
# 
# Generate a new request object, match it to a data service node, and then execute
# it.  This is a convenience routine.

sub handle_request {

    my ($ds, $outer, $attrs) = @_;
    
    # If this was called as a class method rather than as an instance method,
    # then call 'select' to figure out the appropriate data service.
    
    unless ( ref $ds eq 'Web::DataService' )
    {
	$ds = Web::DataService->select($outer);
    }
    
    # Generate a new request object, then execute it.
    
    my $request = $ds->new_request($outer, $attrs);
    return $ds->execute_request($request);
}


# execute_request ( request )
# 
# Execute a request.  Depending upon the request path, it may either be
# interpreted as a request for documentation or a request to execute some
# operation and return a result.

sub execute_request {
    
    my ($ds, $request) = @_;
    
    my $path = $request->node_path;
    my $format = $request->output_format;
    
    # Fetch the request method and the hash of allowed methods for this node. If none were
    # specified, default to GET and HEAD.
    
    my $http_method = $request->http_method;
    my $allow_method = $ds->node_attr($request, 'allow_method') || { GET => 1, HEAD => 1 };
    
    # If this was called as a class method rather than as an instance method,
    # then call 'select' to figure out the appropriate data service.
    
    unless ( ref $ds eq 'Web::DataService' )
    {
	$ds = Web::DataService->select($request->outer);
    }
    
    # Now that we have selected a data service instance, check to see if this
    # program is in diagnostic mode.  If so, then divert this request to the
    # module Web::DataService::Diagnostic, and then exit the program when it
    # is done.
    
    if ( Web::DataService->is_mode('diagnostic') )
    {
	$ds->diagnostic_request($request);
	exit;
    }
    
    # If the request HTTP method was 'OPTIONS', then return a list of methods
    # allowed for this node path.
    
    if ( $http_method eq 'OPTIONS' )
    {
	my @methods = ref $allow_method eq 'HASH' ? keys %$allow_method : @Web::DataService::DEFAULT_METHODS;
	
	$ds->_set_cors_header($request);
	$ds->_set_response_header($request, 'Access-Control-Allow-Methods', join(',', @methods));
	return;
    }
    
    # Otherwise, this is a standard request. We must start by configuring the hooks for this
    # request.
    
    if ( ref $ds->{hook_enabled} eq 'HASH' )
    {
	foreach my $hook_name ( keys %{$ds->{hook_enabled}} )
	{
	    if ( my $hook_list = $ds->node_attr($path, $hook_name) )
	    {
		$request->{hook_enabled}{$hook_name} = $hook_list;
	    }
	}
    }
    
    # If the request has been tagged as an invalid path, then return a 404 error right away unless
    # an invalid_request_hook has been called. This hook has the option of rewriting the path and
    # clearing the is_invalid_request flag.
    
    if ( $request->{is_invalid_request} )
    {
	$ds->_call_hooks($request, 'invalid_request_hook')
	    if $request->{hook_enabled}{invalid_request_hook};
	
	die "404\n" if $request->{is_invalid_request};
    }
    
    # If a 'before_execute_hook' was defined for this request, call it now.
    
    $ds->_call_hooks($request, 'before_execute_hook')
	if $request->{hook_enabled}{before_execute_hook};
    
    # If the request has been tagged as a "documentation path", then show the
    # documentation. The only allowed methods for documentation are GET and HEAD.
    
    if ( $request->{is_node_path} && $request->{is_doc_request} && $ds->has_feature('documentation') )
    {
	unless ( $http_method eq 'GET' || $http_method eq 'HEAD' )
	{
	    die "405 Method Not Allowed\n";
	}
	
	return $ds->generate_doc($request);
    }
    
    # If the 'is_file_path' attribute is set, we should be sending a file.  Figure out the path
    # and send it. We don't currently allow uploading files, so the only allowed methods are GET
    # and HEAD.
    
    elsif ( $request->{is_file_path} && $ds->has_feature('send_files') )
    {
	unless ( $http_method eq 'GET' || $http_method eq 'HEAD' )
	{
	    die "405 Method Not Allowed\n";
	}
	
	return $ds->send_file($request);
    }
    
    # If the selected node has an operation, execute it and return the result. But we first have
    # to check if the request method is allowed. 
    
    elsif ( $request->{is_node_path} && $ds->node_has_operation($path) )
    {
	# Always allow HEAD if GET is allowed. But otherwise reject any request that doesn't have
	# an allowed method.
	
	my $check_method = $http_method eq 'HEAD' ? 'GET' : $http_method;
	
	unless ( $allow_method->{$http_method} || $allow_method->{$check_method} )
	{
	    die "405 Method Not Allowed\n";
	}
	
	# Almost all requests will go through this branch of the code. This leads to the actual
	# execution of data service operations.
	
	$ds->configure_request($request);
	return $ds->generate_result($request);
    }
    
    # If the request cannot be satisfied in any of these ways, then return a 404 error.
    
    die "404\n";
}


# send_file ( request )
# 
# Send a file using the attributes specified in the request node.

sub send_file {

    my ($ds, $request) = @_;
    
    die "404\n" if $request->{is_invalid_request};
    
    my $rest_path = $request->{rest_path};
    my $file_dir = $ds->node_attr($request, 'file_dir');
    my $file_path;
    
    # How we handle this depends upon whether 'file_dir' or 'file_path' was
    # set.  With 'file_dir', an empty file name will always return a 404
    # error, since the only other logical response would be a list of the base
    # directory and we don't want to provide that for security reasons.
    
    if ( $file_dir )
    {
	die "404\n" unless defined $rest_path && $rest_path ne '';
	
	# Concatenate the path components together, using the foundation plugin so
	# that this is done in a file-system-independent manner.
	
	$file_path = $Web::DataService::FOUNDATION->file_path($file_dir, $rest_path);
    }
    
    # Otherwise, $rest_path must be empty or else we send back a 404 error.
    
    else
    {
	die "404\n" if defined $rest_path && $rest_path ne '';
	
	$file_path = $ds->node_attr($request, 'file_path');
    }
    
    # If this file does not exist, return a 404 error.  This is necessary so
    # that the error handling will by done by Web::DataService rather than by
    # Dancer.  If the file exists but is not readable, return a 500 error.
    # This is not a permission error, it is an internal server error.
    
    unless ( $Web::DataService::FOUNDATION->file_readable($file_path) )
    {
	die "500" if $Web::DataService::FOUNDATION->file_exists($file_path);
	die "404\n"; # otherwise
    }
    
    # Otherwise, send the file.
    
    return $Web::DataService::FOUNDATION->send_file($request->outer, $file_path);
}


# node_has_operation ( path )
# 
# If this class has both a role and a method defined, then return the method
# name.  Return undefined otherwise.  This method can be used to determine
# whether a particular path is valid for executing a data service operation.

sub node_has_operation {
    
    my ($ds, $path) = @_;
    
    my $role = $ds->node_attr($path, 'role');
    my $method = $ds->node_attr($path, 'method');
    
    return $method if $role && $method;
}


# configure_request ( request )
# 
# Determine the attributes necessary for executing the data service operation
# corresponding to the specified request.

sub configure_request {
    
    my ($ds, $request) = @_;
    
    my $path = $request->node_path;
    
    die "404\n" if $request->{is_invalid_request} || $ds->node_attr($path, 'disabled');
    
    $request->{_configured} = 1;
    
    # If we are in 'one request' mode, initialize this request's primary
    # role.  If we are not in this mode, then all of the roles will have
    # been previously initialized.
    
    if ( $Web::DataService::ONE_REQUEST )
    {
	my $role = $ds->node_attr($path, 'role');
	$ds->initialize_role($role);
    }
    
    # If a before_config_hook was specified for this node, call it now.
    
    $ds->_call_hooks($request, 'before_config_hook')
	if $request->{hook_enabled}{before_config_hook};
    
    # Get the raw parameters for this request, if they have not already been gotten.
    
    $request->{raw_params} //= $Web::DataService::FOUNDATION->get_params($request, 'query');
    
    # Check to see if there is a ruleset corresponding to this path.  If
    # so, then validate the parameters according to that ruleset.
    
    my $rs_name = $ds->node_attr($path, 'ruleset');
    
    $rs_name //= $ds->determine_ruleset($path);
    
    if ( $rs_name )
    {
	my $context = { ds => $ds, request => $request };
	
	my $result = $ds->{validator}->check_params($rs_name, $context, $request->{raw_params});
	
	if ( $result->errors )
	{
	    die $result;
	}
	
	elsif ( $result->warnings )
	{
	    $request->add_warning($result->warnings);
	}
	
	$request->{clean_params} = $result->values;
	$request->{valid} = $result;
	$request->{ruleset} = $rs_name;
	
	if ( $ds->debug )
	{
	    my $dsname = $ds->name;
	    print STDERR "---------------\nOperation $dsname '$path'\n";
	    foreach my $p ( $result->keys )
	    {
		my $value = $result->value($p);
		$value = join(', ', @$value) if ref $value eq 'ARRAY';
		$value ||= '[ NO GOOD VALUES FOUND ]';
		print STDERR "$p = $value\n";
	    }
	}
    }
    
    # Otherwise, just pass the raw parameters along with no validation or
    # processing.
    
    else
    {
	print STDERR "No ruleset could be determined for path '$path'\n" if $ds->debug;
	$request->{valid} = undef;
	$request->{clean_params} = $request->{raw_params};
    }
    
    # Now that the parameters have been processed, we can configure all of
    # the settings that might be specified or affected by parameter values:
    
    # If the output format is not already set, then try to determine what
    # it should be.
    
    unless ( $request->output_format )
    {
	# If the special parameter 'format' is enabled, check to see if a
	# value for that parameter was given.
	
	my $format;
	my $format_param = $ds->{special}{format};
	
	if ( $format_param )
	{
	    $format = $request->{clean_params}{$format_param};
	}
	
	# If we still don't have a format, and there is a default format
	# specified for this path, use that.
	
	$format //= $ds->node_attr($path, 'default_format');
	
	# Otherwise, use the first format defined.
	
	$format //= ${$ds->{format_list}}[0];
	
	# If we have successfully determined a format, then set the result
	# object's output format attribute.
	
	$request->output_format($format) if $format;
    }
    
    # Next, determine the result limit and offset, if any.  If the special
    # parameter 'limit' is active, then see if this request included it.
    # If we couldn't get a parameter value, see if a default limit was
    # specified for this node or for the data service as a whole.
    
    my $limit_value = $request->special_value('limit') //
	$ds->node_attr($path, 'default_limit');
    
    $request->result_limit($limit_value) if defined $limit_value;
    
    # If the special parameter 'offset' is active, then see if this result
    # included it.
    
    my $offset_value = $request->special_value('offset');
    
    $request->result_offset($offset_value) if defined $offset_value;
    
    # Determine whether we should show the optional header information in
    # the result.
    
    my $header_value = $request->special_value('header') //
	$ds->node_attr($path, 'default_header');
    
    $request->display_header($header_value) if defined $header_value;
    
    my $source_value = $request->special_value('datainfo') //
	$ds->node_attr($path, 'default_datainfo');
    
    $request->display_datainfo($source_value) if defined $source_value;
    
    my $count_value = $request->special_value('count') //
	$ds->node_attr($path, 'default_count');
    
    $request->display_counts($count_value) if defined $count_value;
    
    my $output_linebreak = $request->special_value('linebreak') ||
	$ds->node_attr($path, 'default_linebreak') || 'crlf';
    
    $request->output_linebreak($output_linebreak);
    
    my $save_specified = $request->special_given('save');
    my $save_value = $request->special_value('save') || '';
    
    if ( $save_specified )
    {
	if ( $save_value =~ qr{ ^ (?: no | off | 0 | false ) $ }xsi )
	{
	    $request->save_output(0);
	}
	
	else
	{
	    $request->save_output(1);
	    $request->save_filename($save_value) if $save_value ne '' &&
		$save_value !~ qr{ ^ (?: yes | on | 1 | true ) $ }xsi;
	}
    }
    
    # Determine which vocabulary to use.  If the special parameter 'vocab' is
    # active, check that first.
    
    my $vocab_value = $request->special_value('vocab');
    
    $request->output_vocab($vocab_value) if defined $vocab_value;
    
    my $a = 1;	# we can stop here when debugging
}


# generate_result ( request )
# 
# Execute the operation corresponding to the attributes of the node selected
# by the given request, and return the resulting data.  This routine is, in
# many ways, the core of this entire project.

sub generate_result {
    
    my ($ds, $request) = @_;
    
    croak "generate_result: you must first call the method 'configure'\n"
	unless $request->{_configured};
    
    my $path = $request->node_path;
    my $format = $request->output_format;
    
    my $method = $ds->node_attr($path, 'method');
    my $arg = $ds->node_attr($path, 'arg');
    
    # First determine the class that corresponds to this request's primary role
    # and bless the request into that class.
    
    my $role = $ds->node_attr($request, 'role');
    bless $request, $ds->execution_class($role);
    
    # If a before_setup_hook is defined for this path, call it.
    
    $ds->_call_hooks($request, 'before_setup_hook')
	if $request->{hook_enabled}{before_setup_hook};
    
    # First check to make sure that the specified format is valid for the
    # specified path.
    
    unless ( $ds->valid_format_for($path, $format) )
    {
	die "415\n";
    }
    
    #	defined $format && ref $ds->{format}{$format} &&
    #	 ! $ds->{format}{$format}{disabled} &&
    #	 $attrs->{allow_format}{$format} )
    
    # Then we need to make sure that an output vocabulary is selected.  If no
    # vocabulary was explicitly specified, then try the default for the
    # selected format.  As a backup, we use the first vocabulary defined for
    # the data service, which will be the default vocabulary if none were
    # explicitly defined.
    
    unless ( my $vocab_value = $request->output_vocab )
    {
	$vocab_value = $ds->{format}{$format}{default_vocab} ||
	    $ds->{vocab_list}[0];
	
	$request->output_vocab($vocab_value);
    }
    
    # Now that we know the format, we can set the response headers.
    
    $ds->_set_cors_header($request);
    $ds->_set_content_type($request);
    
    # If the format indicates that the output should be returned as an
    # attachment (which tells the browser to save it to disk), note this fact.
    
    my $save_flag = $request->save_output;
    my $disp = $ds->{format}{$format}{disposition};
    
    if ( defined $save_flag && $save_flag eq '0' )
    {
	#$ds->_set_content_disposition($request, 'inline');
	$ds->_set_content_type($request, 'text/plain') if $ds->{format}{$format}{is_text};
	$request->{content_type_is_text} = 1;
    }
    
    elsif ( ( defined $disp && $disp eq 'attachment' ) ||
	    $save_flag )
    {
	$ds->_set_content_disposition($request, 'attachment', $request->save_filename);
    }
    
    # Then set up the output.  This involves constructing a list of
    # specifiers that indicate which fields will be included in the output
    # and how they will be processed.
    
    $ds->_setup_output($request);
    
    # If a summary block has been specified for this request, configure it as
    # well. 
    
    if ( my $summary_block = $ds->node_attr($request, 'summary') )
    {
	if ( $ds->configure_block($request, $summary_block) )
	{
	    $request->{summary_field_list} = $request->{block_field_list}{$summary_block};
	}
	else
	{
	    $request->add_warning("Summary block '$summary_block' not found");
	}
    }
    
    # If a before_operation_hook is defined for this path, call it.
    # Also check for post_configure_hook, for backward compatibility.
    
    $ds->_call_hooks($request, 'post_configure_hook')
	if $request->{hook_enabled}{post_configure_hook};
    
    $ds->_call_hooks($request, 'before_operation_hook')
	if $request->{hook_enabled}{before_operation_hook};
    
    # Prepare to time the query operation.
    
    my (@starttime) = Time::HiRes::gettimeofday();
    
    # Now execute the query operation.  This is the central step of this
    # entire routine; everything before and after is in support of this call.
	
    $request->$method($arg);
    
    # Determine how long the query took.
    
    my (@endtime) = Time::HiRes::gettimeofday();
    $request->{elapsed} = Time::HiRes::tv_interval(\@starttime, \@endtime);
    
    # If a before_output_hook is defined for this path, call it.
    
    $ds->_call_hooks($request, 'before_output_hook')
	if $request->{hook_enabled}{before_output_hook};
    
    # Then we use the output configuration and the result of the query
    # operation to generate the actual output.  How we do this depends
    # upon how the operation method chooses to return its data.  It must
    # set one of the following fields in the request object, as described:
    # 
    # main_data		A scalar, containing data which is to be 
    #			returned as-is without further processing.
    # 
    # main_record	A hashref, representing a single record to be
    #			returned according to the output format.
    # 
    # main_result	A list of hashrefs, representing multiple
    #			records to be returned according to the output
    # 			format.
    # 
    # main_sth		A DBI statement handle, from which all 
    #			records that can be read should be returned
    #			according to the output format.
    # 
    # It is okay for main_result and main_sth to both be set, in which
    # case the records in the former will be sent first and then the
    # latter will be read.
    
    if ( ref $request->{main_record} )
    {
	$ds->_check_output_config($request);
	return $ds->_generate_single_result($request);
    }
    
    elsif ( ref $request->{main_sth} or ref $request->{main_result} )
    {
	$ds->_check_output_config($request);
	
	my $threshold = $ds->node_attr($path, 'streaming_threshold')
	    unless $request->{do_not_stream};
	
	# If the result set requires processing before output, then call
	# _generate_processed_result.  Otherwise, call
	# _generate_compound_result.  One of the conditions that can cause
	# this to happen is if record counts are requested and generating them
	# requires processing (i.e. because a 'check' rule was encountered).
	
	$request->{preprocess} = 1 if $request->display_counts && $request->{process_before_count};
	
	if ( $request->{preprocess} )
	{
	    return $ds->_generate_processed_result($request, $threshold);
	}
	
	else
	{
	    return $ds->_generate_compound_result($request, $threshold);
	}
    }
    
    elsif ( defined $request->{main_data} )
    {
	return $request->{main_data};
    }
    
    # If none of these fields are set, then the result set is empty.
    
    else
    {
	$ds->_check_output_config($request);
	return $ds->_generate_empty_result($request);
    }
}


# _call_hooks ( request, hook )
# 
# If the specified hook has been defined for the specified path, call each of
# the defined values.  If the value is a code reference, call it with the
# request as the only parameter.  If it is a string, call it as a method of
# the request object.

sub _call_hooks {
    
    my ($ds, $request, $hook_name, @args) = @_;

    # Look up the list of hooks, if any, defined for this node.
    
    my $hook_list = $request->{hook_enabled}{$hook_name} || return;
    
    # If a list of hooks is defined, then call each hook in turn. The return value will be the return
    # value of the hook last called, which will be the one that is defined furthest down in the
    # hierarchy.

    if ( ref $hook_list eq 'ARRAY' )
    {
	foreach my $hook ( @$hook_list )
	{
	    if ( ref $hook eq 'CODE' )
	    {
		&$hook($request, @args);
	    }
	    
	    elsif ( defined $hook )
	    {
		$request->$hook(@args);
	    }
	}
    }

    # Otherwise, if we have one hook then just call it.
    
    elsif ( ref $hook_list eq 'CODE' )
    {
	&$hook_list($request, @args);
    }

    elsif ( defined $hook_list )
    {
	$request->$hook_list(@args);
    }
}


# sub _call_hook_list {
    
#     my ($ds, $hook_list, $request, @args) = @_;
    
#     foreach my $hook ( @$hook_list )
#     {
# 	if ( ref $hook eq 'CODE' )
# 	{
# 	    &$hook($request, @args);
# 	}
	
# 	elsif ( defined $hook )
# 	{
# 	    $request->$hook(@args);
# 	}
#     }
# }


sub _set_cors_header {
    
    my ($ds, $request, $arg) = @_;
    
    # If this is a public-access data service, we add a universal CORS header.
    # At some point we need to add provision for authenticated access.
    
    if ( (defined $arg && $arg eq '*') || $ds->node_attr($request, 'public_access') )
    {
	$Web::DataService::FOUNDATION->set_header($request->outer, "Access-Control-Allow-Origin", "*");
    }
}


sub _set_response_header {

    my ($ds, $request, $header, $value) = @_;
    
    # Set the specified response header, with the given value.
    
    $Web::DataService::FOUNDATION->set_header($request->outer, $header, $value);
}


sub _set_content_type {

    my ($ds, $request, $ct) = @_;
    
    # If the content type was not explicitly given, choose it based on the
    # output format.
    
    unless ( $ct )
    {
	my $format = $request->output_format;
	$ct = $ds->{format}{$format}{content_type} || 'text/plain';
    }
    
    $Web::DataService::FOUNDATION->set_content_type($request->outer, $ct);
}


sub _set_content_disposition {
    
    my ($ds, $request, $disp, $filename) = @_;
    
    # If we were given a disposition of 'inline', then set that.
    
    if ( $disp eq 'inline' )
    {
	$Web::DataService::FOUNDATION->set_header($request->outer, 'Content-Disposition' => 'inline');
	return;
    }
    
    # If we weren't given an explicit filename, check to see if one was set
    # for this node.
    
    $filename //= $ds->node_attr($request, 'default_save_filename');
    
    # If we still don't have a filename, return without doing anything.
    
    return unless $filename;
    
    # Otherwise, set the appropriate header.  If the filename does not already
    # include a suffix, add the format.
    
    unless ( $filename =~ qr{ [^.] [.] \w+ $ }xs )
    {
	$filename .= '.' . $request->output_format;
    }
    
    $Web::DataService::FOUNDATION->set_header($request->outer, 'Content-Disposition' => 
					 qq{attachment; filename="$filename"});
}


# valid_format_for ( path, format )
# 
# Return true if the specified format is valid for the specified path, false
# otherwise. 

sub valid_format_for {
    
    my ($ds, $path, $format) = @_;
    
    my $allow_format = $ds->node_attr($path, 'allow_format');
    return unless ref $allow_format eq 'HASH';
    return $allow_format->{$format};
}


# determine_ruleset ( )
# 
# Determine the ruleset that should apply to this request.  If a ruleset name
# was explicitly specified for the request path, then use that if it is
# defined or throw an exception if not.  Otherwise, try the path with slashes
# turned into commas and the optional ruleset_prefix applied.

sub determine_ruleset {
    
    my ($ds, $path) = @_;
    
    my $validator = $ds->{validator};
    my $ruleset = $ds->node_attr($path, 'ruleset');
    
    # If a ruleset name was explicitly given, then use that or throw an
    # exception if not defined.
    
    if ( defined $ruleset && $ruleset ne '' )
    {
	croak "unknown ruleset '$ruleset' for path $path"
	    unless $validator->ruleset_defined($ruleset);
	
	return $ruleset;
    }
    
    # If the ruleset was explicitly specified as '', do not process the
    # parameters for this path.
    
    return if defined $ruleset;
    
    # If the path is either empty or the root node '/', likewise return false.
    
    return unless defined $path && $path ne '' && $path ne '/';
    
    # Otherwise, try the path with / replaced by :.  If that is not defined,
    # then return empty.  The parameters for this path will not be processed.
    
    $path =~ s{/}{:}g;
    
    $path = $ds->{ruleset_prefix} . $path
	if defined $ds->{ruleset_prefix} && $ds->{ruleset_prefix} ne '';
    
    return $path if $validator->ruleset_defined($path);
}


# determine_output_names {
# 
# Determine the output block(s) and/or map(s) that should be used for this
# request.  If any output names were explicitly specified for the request
# path, then use them or throw an error if any are undefined.  Otherwise, try
# the path with slashes turned into colons and either ':default' or
# ':default_map' appended.

sub determine_output_names {

    my ($self) = @_;
    
    my $ds = $self->{ds};
    my $path = $self->{path};
    my @output_list = @{$self->{attrs}{output}} if ref $self->{attrs}{output} eq 'ARRAY';
    
    # If any output names were explicitly given, then check to make sure each
    # one corresponds to a known block or set.  Otherwise, throw an exception.
    
    foreach my $output_name ( @output_list )
    {
	croak "the string '$output_name' does not correspond to a defined output block or map"
	    unless ref $ds->{set}{$output_name} eq 'Web::DataService::Set' ||
		ref $ds->{block}{$output_name} eq 'Web::DataService::Block';
    }
    
    # Return the list.
    
    return @output_list;
}


# determine_output_format ( outer, inner )
# 
# This method is called by the error reporting routine if we do not know the
# output format.  We are given (possibly) both types of objects and need to
# determine the appropriate output format based on the data service
# configuration and the request path and parameters.
# 
# This method need only return a value if that value is not 'html', because
# that is the default.

sub determine_output_format {

    my ($ds, $outer, $inner) = @_;
    
    # If the data service has the feature 'format_suffix', then check the
    # URL path.  If no format is specified, we return the empty string.
    
    if ( $ds->{feature}{format_suffix} )
    {
	my $path = $Web::DataService::FOUNDATION->get_request_path($outer);
	
	$path =~ qr{ [.] ( [^.]+ ) $ }xs;
	return $1 || '';
    }
    
    # Otherwise, if the special parameter 'format' is enabled, check to see if
    # a value for that parameter was given.
    
    if ( my $format_param = $ds->{special}{format} )
    {
	# If the parameters have already been validated, check the cleaned
	# parameter values.
	
	if ( ref $inner && reftype $inner eq 'HASH' && $inner->{clean_params} )
	{
	    return $inner->{clean_params}{$format_param}
		if $inner->{clean_params}{$format_param};
	}
	
	# Otherwise, check the raw parameter values.
	
	else
	{
	    my $params = $Web::DataService::FOUNDATION->get_params($outer, 'query');
	    
	    return lc $params->{$format_param} if $params->{$format_param};
	}
    }
    
    # If no parameter value was found, see if we have identified a data
    # service node for this request.  If so, check to see if a default format
    # was established.
    
    if ( ref $inner && $inner->isa('Web::DataService::Request') )
    {
	my $default_format = $ds->node_attr($inner, 'default_format');
	
	return $default_format if $default_format;
    }
    
    # If we really can't tell, then return the empty string which will cause
    # the format to default to 'html'.
    
    return '';
}


my %CODE_STRING = ( 400 => "Bad Request", 
		    401 => "Authentication Required",
		    404 => "Not Found",
		    415 => "Invalid Media Type",
		    422 => "Cannot be processed",
		    500 => "Server Error" );

# error_result ( error, request )
# 
# Send an error response back to the client.  This routine is designed to be
# as flexible as possible about its arguments.  At minimum, it only needs a
# request object - either the one generated by the foundation framework or
# the one generated by Web::DataService.

sub error_result {

    my ($ds, $error, $request) = @_;
    
    # If we are in 'debug' mode, then print out the error message.
    
    if ( Web::DataService->is_mode('debug') )
    {
	unless ( defined $error )
	{
	    Dancer::debug("CAUGHT UNKNOWN ERROR");
	}
	
	elsif ( ! ref $error )
	{
	    Dancer::debug("CAUGHT ERROR: " . $error);
	}
	
	elsif ( $error->isa('HTTP::Validate::Result') )
	{
	    Dancer::debug("CAUGHT HTTP::VALIDATE RESULT");
	}
	
	elsif ( $error->isa('Dancer::Exception::Base') )
	{
	    Dancer::debug("CAUGHT ERROR: " . $error->message);
	}
	
	elsif ( $error->isa('Web::DataService::Exception') )
	{
	    Dancer::debug("CAUGHT EXCEPTION: " . $error->{message});
	}
	
	else
	{
	    Dancer::debug("CAUGHT OTHER ERROR");
	}
    }
    
    # Then figure out which kind of request object we have.
    
    my ($inner, $outer);
    
    # If we were given the 'inner' request object, we can retrieve the 'outer'
    # one from that.
    
    if ( ref $request && $request->isa('Web::DataService::Request') )
    {
	$inner = $request;
	$outer = $request->outer;
    }
    
    # If we were given the 'outer' object, ask the foundation framework to
    # tell us the corresponding 'inner' one.
    
    elsif ( defined $request )
    {
	$outer = $request;
	$inner = $Web::DataService::FOUNDATION->retrieve_inner($outer);
    }
    
    # Otherwise, ask the foundation framework to tell us the current request.
    
    else
    {
	$outer = $Web::DataService::FOUNDATION->retrieve_outer();
	$inner = $Web::DataService::FOUNDATION->retrieve_inner($outer);
    }
    
    # Get the proper data service instance from the inner request, in case we
    # were called as a class method.
    
    $ds = defined $inner && $inner->isa('Web::DataService::Request') ? $inner->ds
	: $Web::DataService::WDS_INSTANCES[0];
    
    # Next, try to determine the format of the result
    
    my $format;
    $format ||= $inner->output_format if $inner;
    $format ||= $ds->determine_output_format($outer, $inner);
    
    my ($code);
    my (@errors, @warnings, @cautions);
    
    if ( ref $inner && $inner->isa('Web::DataService::Request') )
    {
	@warnings = $inner->warnings;
	@errors = $inner->errors;
	@cautions = $inner->cautions;
    }
    
    # If the error is actually a response object from HTTP::Validate, then
    # extract the error and warning messages.  In this case, the error code
    # should be "400 bad request".
    
    if ( ref $error eq 'HTTP::Validate::Result' )
    {
	push @errors, $error->errors;
	push @warnings, $error->warnings;
	$code = "400";
    }
    
    elsif ( ref $error eq 'Web::DataService::Exception' )
    {
	push @errors, $error->{message} if ! @errors;
	$code = $error->{code};
    }
    
    # If the error message begins with a 3-digit number, then that should be
    # used as the code and the rest of the message as the error text.
    
    elsif ( $error =~ qr{ ^ (\d\d\d) \s+ (.+) }xs )
    {
	$code = $1;
	my $msg = $2;
	$msg =~ s/\n$//;
	push @errors, $msg;
    }
    
    elsif ( $error =~ qr{ ^ (\d\d\d) }xs )
    {
	$code = $1;
	
	if ( $code eq '404' )
	{
	    my $path = $Web::DataService::FOUNDATION->get_request_path($outer);
	    if ( defined $path && $path ne '' )
	    {
		push @errors, "The path '$path' was not found on this server.";
	    }
	    
	    else
	    {
		push @errors, "This request is invalid.";
	    }
	}
	
	elsif ( $CODE_STRING{$code} )
	{
	    push @errors, $CODE_STRING{$code};
	}
	
	else
	{
	    push @errors, "Error" unless @errors;
	}
    }
    
    # Otherwise, this is an internal error and all that we should report to
    # the user (for security reasons) is that an error occurred.  The actual
    # message is written to the server error log.
    
    else
    {
	$code = 500;
	warn $error;
	@errors = "A server error occurred.  Please contact the server administrator.";
    }
    
    # Cancel any content encoding that had been set.

    $Web::DataService::FOUNDATION->set_header($outer, 'Content-Encoding' => '');
    
    # If we know the format and if the corresponding format class knows how to
    # generate error messages, then take advantage of that functionality.
    
    my $format_class = $ds->{format}{$format}{package} if $format;
    
    if ( $format_class && $format_class->can('emit_error') )
    {
	my $error_body = $format_class->emit_error($code, \@errors, \@warnings, \@cautions);
	my $content_type = $ds->{format}{$format}{content_type} || 'text/plain';
	
	$Web::DataService::FOUNDATION->set_content_type($outer, $content_type);
	$Web::DataService::FOUNDATION->set_header($outer, 'Content-Disposition' => 'inline');
	$Web::DataService::FOUNDATION->set_cors_header($outer, "*");
	$Web::DataService::FOUNDATION->set_status($outer, $code);
	$Web::DataService::FOUNDATION->set_body($outer, $error_body);
    }
    
    # Otherwise, generate a generic HTML response (we'll add template
    # capability later...)
    
    else
    {
	my $text = $CODE_STRING{$code} || 'Error';
	my $error = "<ul>\n";
	my $warning = '';
	
	$error .= "<li>$_</li>\n" foreach @errors;
	$error .= "</ul>\n";
	
	shift @warnings unless $warnings[0];
	
	if ( @warnings )
	{
	    $warning .= "<h2>Warnings:</h2>\n<ul>\n";
	    $warning .= "<li>$_</li>\n" foreach @warnings;
	    $warning .= "</ul>\n";
	}
	
	my $body = <<END_BODY;
<html><head><title>$code $text</title></head>
<body><h1>$code $text</h1>
$error
$warning
</body></html>
END_BODY
    
	$Web::DataService::FOUNDATION->set_content_type($outer, 'text/html');
	$Web::DataService::FOUNDATION->set_header($outer, 'Content-Disposition' => 'inline');
	$Web::DataService::FOUNDATION->set_status($outer, $code);
	$Web::DataService::FOUNDATION->set_body($outer, $body);
    }
}


1;
