#
# DataService.pm
# 
# This is a first cut at a data service application framework, built on top of
# Dancer.pm.
# 
# Author: Michael McClennen <mmcclenn@geology.wisc.edu>


use strict;

require 5.012;

package Web::DataService;

use Carp qw( croak );
use Scalar::Util qw( reftype blessed weaken );

use Web::DataService::Request;
use Web::DataService::Output;
use Web::DataService::PodParser;
use Web::DataService::JSON qw(json_list_value);

use HTTP::Validate qw( :validators );

HTTP::Validate->VERSION(0.34);

#use Dancer qw( :syntax );
use Dancer::Plugin;
use Dancer::Plugin::Database;
use Dancer::Plugin::StreamData;

BEGIN {
    our (@KEYWORDS) = qw(define_vocab valid_vocab document_vocab
			 define_format document_format
			 define_path document_path path_defined
			 define_ruleset define_output_map define_block
			 initialize_class can_execute_path execute_path error_result);
    
    our (@EXPORT_OK) = (@KEYWORDS, @HTTP::Validate::VALIDATORS);
    
    our (%EXPORT_TAGS) = (
	keywords => \@KEYWORDS,
        validators => \@HTTP::Validate::VALIDATORS
    );
}


# Create a default instance, for when this module is used in a
# non-object-oriented fashion.

my $DEFAULT_INSTANCE = __PACKAGE__->new({ name => 'Default' });

my $DEFAULT_COUNT = 0;

# Methods
# =======

# new ( class, attrs )
# 
# Create a new data service instance.  If the second argument is provided, it
# must be a hash ref specifying options for the service as a whole.

sub new {
    
    my ($class, $options) = @_;
    
    # Determine option values.  Start from the Dancer configuration file.
    
    my $config = Dancer::config;
    
    my $path_prefix = $options->{path_prefix} || '/';
    my $public_access = $options->{public_access} || $config->{public_access};
    my $default_limit = $options->{default_limit} || $config->{default_limit} || 500;
    my $streaming_threshold = $options->{streaming_threshold} || $config->{streaming_threshold} || 20480;
    my $name = $options->{name} || $config->{name};
    
    unless ( $name )
    {
	$DEFAULT_COUNT++;
	$name = 'Data Service' . ( $DEFAULT_COUNT > 1 ? " $DEFAULT_COUNT" : "" );
    }
    
    # Create a new HTTP::Validate object so that we can do parameter
    # validations.
    
    my $validator = HTTP::Validate->new();
    
    $validator->validation_settings(allow_unrecognized => 1) if $options->{allow_unrecognized};
    
    # Create a new DataService object, and return it:
    
    my $instance = {
		    name => $name,
		    path_prefix => $path_prefix,
		    validator => $validator,
		    public_access => $public_access,
		    default_limit => $default_limit,
		    # streaming_available => server_supports_streaming,
		    streaming_threshold => $streaming_threshold,
		    path_attrs => {},
		    vocab => { 'default' => 
			       { name => 'default', use_field_names => 1, _default => 1,
				 doc => "The default vocabulary consists of the underlying field names" } },
		    vocab_list => [ 'default' ],
		    format => {},
		    format_list => [],
		   };
    
    $instance->{DEBUG} = 1 if $config->{ds_debug};
    
    # Return the new instance
    
    bless $instance, $class;
    return $instance;
}


# accessor methods for the various attributes:

sub get_path_prefix {
    
    return $_[0]->{path_prefix};
}

sub get_attr {
    
    return $_[0]->{$_[1]};
}


# define_path ( path, attrs... )
# 
# Set up a "path" entry, representing a complete or partial URL path.  This
# path should have a documentation page, but if one is not defined a template
# page will be used along with any documentation strings given in this call.
# Any path which represents an operation must be given an 'op' attribute.
# 
# An error will be signalled unless the "parent" path is already defined.  In
# other words, you cannot define 'a/b/c' unless 'a/b' is defined first.

sub define_path {
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    my $self = $_[0]->isa('Web::DataService') ? shift : $DEFAULT_INSTANCE;
    
    my ($package, $filename, $line) = caller;
    
    my ($last_node);
    
    # Now we go through the rest of the arguments.  Hashrefs define new
    # directories, while strings add to the documentation of the directory
    # whose definition they follow.
    
    foreach my $item (@_)
    {
	# A hashref defines a new directory.
	
	if ( ref $item eq 'HASH' )
	{
	    croak "define_path: a path definition must include the attribute 'path'"
		unless defined $item->{path} and $item->{path} ne '';
	    
	    $last_node = $self->create_path_node($item, $filename, $line)
		unless defined $item->{disabled};
	}
	
	elsif ( not ref $item )
	{
	    $self->add_node_doc($last_node, $item);
	}
	
	else
	{
	    croak "define_path: arguments must be hashrefs and strings";
	}
    }
    
    croak "define_path: arguments must include at least one hashref of attributes"
	unless $last_node;
}

register 'define_path' => \&define_path;


our (%NODE_DEF) = ( path => 'ignore',
		    class => 'single',
		    method => 'single',
		    ruleset => 'single',
		    base_output => 'list',
		    doc_output => 'list',
		    uses_dbh => 'single',
		    version => 'single',
		    public_access => 'single',
		    also_initialize => 'set',
		    output_param => 'single',
		    vocab_param => 'single',
		    limit_param => 'single',
		    offset_param => 'single',
		    count_param => 'single',
		    no_head_param => 'single',
		    linebreak_param => 'single',
		    default_limit => 'single',
		    streaming_theshold => 'single',
		    allow_format => 'set',
		    allow_vocab => 'set',
		    doc_file => 'single',
		    doc_title => 'single' );

# create_path_node ( attrs, filename, line )
# 
# Create a new node representing the specified path.  Attributes are
# inherited, as follows: 'a/b/c' inherits from 'a/b', while 'a' inherits the
# defaults set for the data service as a whole.

sub create_path_node {

    my ($self, $new_attrs, $filename, $line) = @_;
    
    my $path = $new_attrs->{path};
    
    # Make sure this path was not already defined by a previous call.
    
    if ( defined $self->{path_attrs}{$path} )
    {
	my $filename = $self->{path_attrs}{$path}{_filename};
	my $line = $self->{path_attrs}{$path}{_line};
	croak "define_path: '$path' was already defined at line $line of $filename";
    }
    
    # Create a new node to hold the path attributes.
    
    my $path_attrs = { _filename => $filename, _line => $line };
    
    # If the path has a valid prefix, start with the prefix path's attributes
    # as a base.  Assume the attribute values are all valid, since they were
    # checked when the prefix path was defined (not sure if this is always
    # going to be a correct assumption).  Throw an error if the prefix path is
    # not already defined, except that we do not require the root '/' to be
    # explicitly defined.
    
    my $parent_attrs;
    
    if ( $path =~ qr{ ^ (.+) / [^/]+ }x )
    {
	$parent_attrs = $self->{path_attrs}{$1};
	croak "define_path: '$path' is not a valid path because '$1' must be defined first"
	    unless reftype $parent_attrs && reftype $parent_attrs eq 'HASH';
    }
    
    elsif ( $path =~ qr{ ^ [^/]+ $ }x )
    {
	$parent_attrs = $self->{path_attrs}{'/'};
    }
    
    elsif ( $path ne '/' )
    {
	croak "invalid path '$path'";
    }
    
    # If no parent attributes are found we start with some defaults.
    
    $parent_attrs ||= { vocab_param => 'vocab', 
			output_param => 'show',
			limit_param => 'limit',
			offset_param => 'offset',
			count_param => 'count',
			no_head_param => 'noheader',
			linebreak_param => 'linebreak' };
    
    # Now go through the parent attributes and copy into the new node.  We
    # only need to copy one level down, since the attributes are not going to
    # be any deeper than that (this may need to be revisited if the attribute
    # system gets more complicated).
    
    foreach my $key ( keys %$parent_attrs )
    {
	next unless defined $NODE_DEF{$key};
	
	if ( $NODE_DEF{$key} eq 'single' )
	{
	    $path_attrs->{$key} = $parent_attrs->{$key};
	}
	
	elsif ( $NODE_DEF{$key} eq 'set' and ref $parent_attrs->{$key} eq 'HASH' )
	{
	    $path_attrs->{$key} = { %{$parent_attrs->{$key}} };
	}
	
	elsif ( $NODE_DEF{$key} eq 'list' and ref $parent_attrs->{$key} eq 'ARRAY' )
	{
	    $path_attrs->{$key} = [ @{$parent_attrs->{$key}} ];
	}
    }
    
    # Then apply the newly specified attributes, overriding or modifying any
    # equivalent attributes inherited from the parent.
    
    foreach my $key ( keys %$new_attrs )
    {
	croak "define_path: unknown attribute '$key'"
	    unless $NODE_DEF{$key};
	
	my $value = $new_attrs->{$key};
	
	next unless defined $value;
	
	# If the attribute takes a single value, then set the value as
	# specified.
	
	if ( $NODE_DEF{$key} eq 'single' )
	{
	    $path_attrs->{$key} = $value;
	}
	
	# If the attribute takes a set value, then turn a string value into a
	# hash whose keys are the individual values.  If the value begins with + or
	# -, then add or delete values as indicated.  Otherwise, substitute
	# the given set.
	
	elsif ( $NODE_DEF{$key} eq 'set' )
	{
	    my @values = ref $value eq 'ARRAY' ? @$value : split( qr{\s*,\s*}, $value );
	    
	    if ( $value =~ qr{ ^ [+-] }x )
	    {
		foreach my $v (@values)
		{
		    next unless defined $v && $v ne '';
		    
		    croak "define_path: invalid value '$v', must start with + or -"
			unless $v =~ qr{ ^ ([+-]) (.*) }x;
		    
		    if ( $1 eq '-' )
		    {
			delete $path_attrs->{$key}{$2};
		    }
		    
		    else
		    {
			$path_attrs->{$key}{$2} = 1;
		    }
		}
	    }
	    
	    else
	    {
		foreach my $v (@values)
		{
		    next unless defined $v && $v ne '';
		    
		    croak "define_path: invalid value '$v', cannot start with + or -"
			if $v =~ qr{ ^\+ | ^\- }x;
		    
		    $path_attrs->{$key}{$v} = 1;
		}
	    }
	}
	
	# If the attribute takes a list value, then turn a string value into a
	# list.  If the value begins with + or -, then add or delete values as
	# indicated.  Otherwise, substitute the given list.
	
	elsif ( $NODE_DEF{$key} eq 'list' )
	{
	    my @values = ref $value eq 'ARRAY' ? @$value : split( qr{\s*,\s*}, $value );
	    
	    if ( $value =~ qr{ ^ [+-] }x )
	    {
		foreach my $v (@values)
		{
		    next unless defined $v && $v ne '';
		    
		    croak "define_path: invalid value '$v', must start with + or -"
			unless $v =~ qr{ ^ ([+-]) (.*) }x;
		    
		    if ( $1 eq '-' )
		    {
			$path_attrs->{$key} = [ grep { $_ ne $2 } @{$path_attrs->{$key}} ];
		    }
		    
		    else
		    {
			push @{$path_attrs->{$key}}, $2
			    unless grep { $_ eq $2 } @{$path_attrs->{$key}};
		    }
		}
	    }
	    
	    else
	    {
		$path_attrs->{$key} = [];
		
		foreach my $v (@values)
		{
		    next unless defined $v && $v ne '';
		    
		    croak "define_path: invalid value '$v', cannot start with + or -"
			if $v =~ qr{ ^\+ | ^\- }x;
		    
		    push @{$path_attrs->{$key}}, $v;
		}
	    }
	}
    }
    
    # Now check the attributes to make sure they are consistent:
    
    # Throw an error if 'class' doesn't specify an existing subclass of
    # Web::DataService::Request.
    
    my $class = $path_attrs->{class};
    
    croak "define_path: invalid class '$class', must be a subclass of 'Web::DataService::Request'"
	if defined $class and not $class->isa('Web::DataService::Request');
    
    # Throw an error if 'op' doesn't specify an existing method of this class.
    
    my $op = $path_attrs->{op};
    
    croak "define_path: invalid op '$op', must be a method of class '$class'"
	if defined $op and not $class->can($op);
    
    # Throw an error if any of the specified formats fails to match an
    # existing format.  If any of the formats has a default vocabulary, add it
    # to the vocabulary list.
    
    if ( ref $path_attrs->{allow_format} )
    {
	foreach my $f ( keys %{$path_attrs->{allow_format}} )
	{
	    croak "define_path: invalid value '$f' for format, no such format has been defined for this data service"
		unless ref $self->{format}{$f};

	    my $dv = $self->{format}{$f}{default_vocab};
	    $path_attrs->{allow_vocab}{$dv} = 1 if $dv;
	}
    }
    
    # Throw an error if any of the specified vocabularies fails to match an
    # existing vocabulary.
    
    if ( ref $path_attrs->{allow_vocab} )
    {
	foreach my $v ( keys %{$path_attrs->{vocab}} )
	{
	    croak "define_path: invalid value '$v' for vocab, no such vocabulary has been defined for this data service"
		unless ref $self->{vocab}{$v};
	}
    }
    
    # Install the node.
    
    $self->{path_attrs}{$path} = $path_attrs;
    
    # If one of the attributes is 'class', make sure that the class is
    # initialized unless we are in "one request" mode.
    
    if ( $path_attrs->{class} and not $self->{ONE_REQUEST} )
    {
	$self->initialize_class($path_attrs->{class})
    }
    
    # Now return the new node.
    
    return $path_attrs;
}


# path_defined ( path )
# 
# Return true if the specified path has been defined, false otherwise.

sub path_defined {

    my ($self, $path);
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    if ( ref $_[0] && blessed $_[0] )
    {
	($self, $path) = @_;
    }
    
    else
    {
	$self = $DEFAULT_INSTANCE;
	($path) = @_;
    }
    
    return $self->{path_attrs}{$path};
}

register 'path_defined' => \&path_defined;


# get_path_attr ( path, key )
# 
# Return the specified attribute for the given path.

sub get_path_attr {
    
    my ($self, $path, $key) = @_;
    
    return unless defined $key;
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    if ( ref $_[0] && blessed $_[0] )
    {
	($self, $path, $key) = @_;
    }
    
    else
    {
	$self = $DEFAULT_INSTANCE;
	($path, $key) = @_;
    }
    
    # If the path is defined and has the specified key, return the
    # corresponding value.
    
    return $self->{path_attrs}{$path}{$key};
}


# define_vocab ( attrs... )
# 
# Define one or more vocabularies of field names for data service responses.

sub define_vocab {

    my ($self);
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    if ( blessed $_[0] && $_[0]->isa('Web::DataService') )
    {
	$self = shift;
    }
    
    else
    {
	$self = $DEFAULT_INSTANCE;
    }
    
    #my ($package, $filename, $line) = caller;
    my ($last_node);
    
    # Now we go through the rest of the arguments.  Hashrefs define new
    # vocabularies, while strings add to the documentation of the vocabulary
    # whose definition they follow.
    
    foreach my $item (@_)
    {
	# A hashref defines a new vocabulary.
	
	if ( ref $item eq 'HASH' )
	{
	    # Make sure the attributes include 'name'.
	    
	    my $name = $item->{name}; 
	    
	    croak "could not define vocabulary: you must include the attribute 'name'" unless $name;
	    
	    # Make sure this vocabulary was not already defined by a previous call,
	    # and set the attributes as specified.
	    
	    croak "vocabulary '$name' was already defined" if defined $self->{vocab}{$name}
		and not $self->{vocab}{$name}{_default};
	    
	    # Remove the default vocabulary, because it is only used if no
	    # other vocabularies are defined.
	    
	    if ( $self->{vocab}{default}{_default} and not $item->{disabled} )
	    {
		delete $self->{vocab}{default};
		shift @{$self->{vocab_list}};
	    }
	    
	    # Now install the new vocabulary.  But don't add it to the list if
	    # the 'disabled' attribute is set.
	    
	    $self->{vocab}{$name} = $item;
	    push @{$self->{vocab_list}}, $name unless $item->{disabled};
	    $last_node = $item;
	}
	
	# A scalar is taken to be a documentation string.
	
	elsif ( not ref $item )
	{
	    $self->add_node_doc($last_node, $item);
	}
	
	else
	{
	    croak "the arguments to 'define_vocab' must be hashrefs and strings";
	}
    }
    
    croak "the arguments must include a hashref of attributes"
	unless $last_node;
}


# validate_vocab ( )
# 
# Return a code reference (actually a reference to a closure) that can be used
# in a parameter rule to validate a vocaubulary-selecting parameter.  All
# non-disabled vocabularies are included.

sub valid_vocab {
    
    my ($self) = @_;
    
    # The ENUM_VALUE subroutine is defined by HTTP::Validate.pm.
    
    return ENUM_VALUE(@{$self->{vocab_list}});
}


# document_vocab ( name )
# 
# Return a string containing POD documentation of the vocabulary
# possibilities.  If a name is specified, return the documentation string for
# that vocabulary only.

sub document_vocab {
    
    my ($self, $name) = @_;
    
    # Otherwise, if a single vocabulary name was given, return its
    # documentation string if any.
    
    if ( $name )
    {
	return $self->{vocab}{$name}{doc};
    }
    
    # Otherwise, document the entire list of enabled vocabularies in POD
    # format.
    
    my $doc = "=over 4\n\n";
    
    $doc .= "=for pp_table_no_header Name* | Documentation\n\n";
    
    foreach my $v (@{$self->{vocab_list}})
    {
	my $vrec = $self->{vocab}{$v};
	
	$doc .= "=item $vrec->{name}\n\n";
	$doc .= "$vrec->{doc}\n\n" if $vrec->{doc};
    }
    
    $doc .= "=back\n\n";
    
    return $doc;
}

our (%FORMAT_DEF) = (name => 'ignore',
		     default_vocab => 'single',
		     content_type => 'single',
		     module => 'single',
		     doc => 'single',
		     disabled => 'single');

our (%FORMAT_CT) = (json => 'application/json',
		    txt => 'text/plain',
		    tsv => 'text/tab-separated-values',
		    csv => 'text/csv',
		    xml => 'text/xml');

our (%FORMAT_CLASS) = (json => 'Web::DataService::JSON',
		       txt => 'Web::DataService::Text',
		       tsv => 'Web::DataService::Text',
		       csv => 'Web::DataService::Text',
		       xml => 'Web::DataService::XML');

# define_format ( attrs... )
# 
# Define one or more formats for data service responses.

sub define_format {

    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    my $self = $_[0]->isa('Web::DataService') ? shift : $DEFAULT_INSTANCE;
    
    my ($last_node);
    
    # Now we go through the rest of the arguments.  Hashrefs define new
    # vocabularies, while strings add to the documentation of the vocabulary
    # whose definition they follow.
    
    foreach my $item (@_)
    {
	# A hashref defines a new vocabulary.
	
	if ( ref $item eq 'HASH' )
	{
	    # Make sure the attributes include 'name'.
	    
	    my $name = $item->{name}; 
	    
	    croak "define_format: the attributes must include 'name'" unless defined $name;
	    
	    # Make sure this format was not already defined by a previous call.
	    
	    croak "define_format: '$name' was already defined" if defined $self->{format}{$name};
	    
	    # Create a new record to represent this format and check the attributes.
	    
	    my $record = bless { name => $name }, 'Web::DataService::Format';
	    
	    $record->{is_complex} = 1 if $name eq 'json';
	    $record->{is_flat} = 1 if $name eq 'csv' || $name eq 'tsv' || $name eq 'txt' || $name eq 'xml';
	    
	    foreach my $k ( keys %$item )
	    {
		croak "define_format: invalid attribute '$k'" unless $FORMAT_DEF{$k};
		
		my $v = $item->{$k};
		
		if ( $k eq 'default_vocab' )
		{
		    croak "define_format: unknown vocabulary '$v'"
			unless ref $self->{vocab}{$v};
		    
		    croak "define_format: cannot default to disabled vocabulary '$v'"
			if $self->{vocab}{$v}{disabled} and not $item->{disabled};
		}
		
		$record->{$k} = $item->{$k};
	    }
	    
	    $record->{content_type} ||= $FORMAT_CT{$name};
	    
	    croak "define_format: you must specify an HTTP content type for format '$name' using the attribute 'content_type'"
		unless $record->{content_type};
	    
	    $record->{module} ||= $FORMAT_CLASS{$name};
	    
	    croak "define_format: you must specify a class to implement format '$name' using the attribute 'module'"
		unless $record->{module};
	    
	    # Make sure that the module is loaded, unless the format is disabled.
	    
	    unless ( $record->{disabled} )
	    {
		my $filename = $record->{module};
		$filename =~ s{::}{/}g;
		$filename .= '.pm' unless $filename =~ /\.pm$/;
		
		require $filename;
	    }
	    
	    # Now store the record as a response format for this data service.
	    
	    $self->{format}{$name} = $record;
	    push @{$self->{format_list}}, $name unless $record->{disabled};
	    $last_node = $record;
	}
	
	# A scalar is taken to be a documentation string.
	
	elsif ( not ref $item )
	{
	    $self->add_node_doc($last_node, $item);
	}
	
	else
	{
	    croak "define_format: the arguments to this routine must be hashrefs and strings";
	}
    }    
    
    croak "define_format: you must include at least one hashref of attributes"
	unless $last_node;
}


# document_format ( name )
# 
# Return a string containing POD documentation of the response formats that
# have been defined for this data service.  If a format name is given, return
# just the documentation for that format.

sub document_format {
    
    my ($self, $name) = @_;
    
    # If no formats have been defined, return undef.
    
    return unless ref $self->{format_list} eq 'ARRAY';
    
    # Otherwise, if a single format name was given, return its
    # documentation string if any.
    
    if ( $name )
    {
	return $self->{format}{$name}{doc};
    }
    
    # Otherwise, document the entire list of formats in POD format.
    
    my $doc = "=over 4\n\n";
    
    $doc .= "=for pp_table_no_header Name* | Documentation\n\n";
    
    foreach my $f (@{$self->{format_list}})
    {
	my $frec = $self->{format}{$f};
	
	$doc .= "=item $frec->{name}\n\n";
	$doc .= "fvrec->{doc}\n\n" if $frec->{doc};
    }
    
    $doc .= "=back\n\n";
    
    return $doc;
}


# define_ruleset ( name, rule... )
# 
# Define a ruleset under the given name.  This is just a wrapper around the
# subroutine HTTP::Validate::ruleset.

sub define_ruleset {
    
    my $self = $_[0]->isa('Web::DataService') ? shift : $DEFAULT_INSTANCE;
    
    unshift @_, $self->{validator};
    
    goto &HTTP::Validate::define_ruleset;
}


# add_node_doc ( node, doc_string )
# 
# Add the specified documentation string to the specified node.

sub add_node_doc {
    
    my ($self, $node, $doc) = @_;
    
    return unless defined $doc and $doc ne '';
    
    croak "only strings may be added to documentation: '$doc' is not valid"
	if ref $doc;
    
    $node->{doc} = '' unless defined $node->{doc};
    $node->{doc} .= "\n" if $node->{doc} ne '';
    $node->{doc} .= $doc;
}


# initialize_class ( class )
# 
# If the specified class has an 'initialize' method, call it.  Recursively
# initialize its parent class as well.  But make sure that the initialization
# method is called only once for any particular class.  It is passed a
# reference to the data service, a database handle, and the Dancer
# configuration hash.

sub initialize_class {
    
    my ($self, $class) = @_;
    
    no strict 'refs';
    
    # If we have already initialized this class, there is nothing else we need
    # to do.
    
    return if ${"${class}::_INITIALIZED"};
    ${"${class}::_INITIALIZED"} = 1;
    
    # If this class has an immediate parent which is a subclass of
    # Web::DataService::Request, initialize it first (unless, of course, it
    # has already been initialized).  Also record the relationship so that we
    # can search for inherited output sections.
    
    foreach my $super ( @{"${class}::ISA"} )
    {
	if ( $super->isa('Web::DataService::Request') )
	{
	    $self->{super_class}{$class} = $super;
	    $self->initialize_class($super) unless $super eq 'Web::DataService::Request';;
	    last;
	}
    }
    
    # If the class has an initialization method, call it.
    
    if ( $class->can('initialize') )
    {
	print STDERR "Initializing $class for data service $self->{name}\n" if $self->{DEBUG};
	$class->initialize($self, Dancer::config, database());
    }
}


# can_execute_path ( path, format )
# 
# Return true if the path can be used for a request, i.e. if it has a class
# and operation defined.  Return false otherwise.

sub can_execute_path {
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    my $self = $_[0]->isa('Web::DataService') ? shift : $DEFAULT_INSTANCE;
    
    my ($path) = @_;
    
    # Now check whether we have the necessary attributes.
    
    return defined $self->{path_attrs}{$path}{class} &&
	   defined $self->{path_attrs}{$path}{method};
}


# execute_path ( path, format )
# 
# Execute the operation corresponding to the attributes of the given path, and
# return the resulting data in the specified format.

sub execute_path {
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    my $self = $_[0]->isa('Web::DataService') ? shift : $DEFAULT_INSTANCE;
    
    my ($path, $format) = @_;
    
    # Do all of the processing in a try block, so that if an error occurs we
    # can respond with an appropriate error page.
    
    try {
	
	$DB::single = 1;
	
	# First check to see that the specified format is valid for the
	# specified path.
	
	my $path_attrs = $self->{path_attrs}{$path};
	
	unless ( defined $format && ref $self->{format}{$format} &&
		 ! $self->{format}{$format}{disabled} &&
		 $path_attrs->{allow_format}{$format} )
	{
	    return $self->error_result($path, $format, "415")
	}
	
	# Then do a basic sanity check to make sure that the operation is
	# valid.  This should always succeed, because the 'class' and 'method'

	# attributes were checked when the path was defined.
	
	my $class = $path_attrs->{class};
	my $method = $path_attrs->{method};
	my $arg = $path_attrs->{arg};
	
	croak "cannot execute path '$path': invalid class '$class' and method '$method'"
	    unless $class->isa('Web::DataService::Request') && $class->can($method);
	
	# If we are in 'one request' mode, initialize the class plus all of
	# the classes it requires.
	
	if ( $self->{ONE_REQUEST} )
	{
	    if ( ref $path_attrs->{also_initialize} eq 'ARRAY' )
	    {
		foreach my $c ( @{$path_attrs->{also_initialize}} )
		{
		    $self->initialize_class($c);
		}
	    }
	    
	    $self->initialize_class($class);
	}
	
	# Create a new object to represent this request, and bless it into the
	# correct class.  Add a database handle if the 'uses_dbh' attribute was
	# set.
	
	my $request = { ds => $self,
			path => $path,
			format => $format,
			method => $method,
			arg => $arg };
	
	$request->{dbh} = database() if $path_attrs->{uses_dbh};
	
	bless $request, $class;
	
	# Check to see if there is a ruleset corresponding to this path.  If
	# a ruleset name was explicitly provided, use that.
	
	my $validator = $self->{validator};
	my $ruleset = $self->determine_ruleset($path, $path_attrs->{ruleset});
	
	# 
	
	if ( $ruleset )
	{
	    my $result = $validator->check_params($ruleset, Dancer::params);
	    
	    if ( $result->errors )
	    {
		return $self->error_result($path, $format, $result);
	    }
	    
	    elsif ( $result->warnings )
	    {
		$request->add_warning($result->warnings);
	    }
	    
	    $request->{valid} = $result;
	    $request->{params} = $result->values;
	}
	
	# Determine the result limit and offset, if any.
	
	$request->{result_limit} = 
	    defined $request->{params}{$path_attrs->{limit_param}}
		? $request->{params}{$path_attrs->{limit_param}}
		    : $path_attrs->{default_limit} || $self->{default_limit} || 'all';
	
	$request->{result_offset} = 
	    defined $request->{params}{$path_attrs->{offset_param}}
		? $request->{params}{$path_attrs->{offset_param}} : 0;
	
	# Set the vocabulary and output section list using the validated
	# parameters, so that we can properly configure the output.
	
	my $output_param = $path_attrs->{output_param};
	
	$request->{vocab} = $request->{params}{$path_attrs->{vocab_param}} || 
	    $self->{format}{$format}{default_vocab} || $self->{vocab_list}[0];
	
	$request->{base_output} = $path_attrs->{base_output};
	$request->{extra_output} = $request->{params}{$output_param};
	
	# Determine whether we should show the optional header information in
	# the result.
	
	$request->{display_header} = $request->{params}{$path_attrs->{no_head_param}} ? 0 : 1;
	$request->{display_counts} = $request->{params}{$path_attrs->{count_param}} ? 1 : 0;
	$request->{linebreak_cr} = 
	    defined $request->{params}{$path_attrs->{linebreak_param}} &&
		$request->{params}{$path_attrs->{linebreak_param}} eq 'cr' ? 1 : 0;
	
	# Set the HTTP response headers appropriately for this request.
	
	$self->set_response_headers($path, $format);
	
	# Now that the parameters have been processed, we can configure the
	# output.  This tells us what information we have been requested
	# to display, and how to query for it.
	
	$DB::single = 1;
	
	$self->configure_output($request);
	
	# Now execute the query operation.  This is the central step of this
	# entire routine; everything before and after is in support of this
	# call.
	
	$request->$method();
	
	# Then we use the output configuration and the result of the query
	# operation to generate the actual output.  How we do this depends
	# upon how the query operation chooses to return its data.  It must
	# set one of the following fields in the request object, as described:
	# 
	# main_data		A scalar, containing data which is to be 
	#			returned as-is without further processing.
	# 
	# main_record		A hashref, representing a single record to be
	#			returned according to the output format.
	# 
	# main_result		A list of hashrefs, representing multiple
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
	    return $self->generate_single_result($request);
	}
	
	elsif ( ref $request->{main_sth} or ref $request->{main_result} )
	{
	    my $threshold = $self->{path_attrs}{$path}{streaming_threshold} || $self->{streaming_threshold}
		if $self->{streaming_available} and not $request->{do_not_stream};
	    
	    return $self->generate_compound_result($request, $threshold);
	}
	
	elsif ( ref $request->{main_data} )
	{
	    return $request->{main_data};
	}
	
	# If none of these fields are set, then the result set is empty.
	
	else
	{
	    return generate_empty_result($request);
	}
    }
    
    # If an error occurs, return an appropriate error response to the client.
    
    catch {

	return $self->error_result($path, $format, $_);
    };
};

register 'execute_path' => \&execute_path;


# document_path ( path, format )
# 
# Generate and return a documentation page corresponding to the specified
# path, in the specified format.  The accepted formats are 'html' and 'pod'.
# 
# If a documentation template corresponding to the specified path is found, it
# will be used.  Otherwise, a default template will be used.

sub document_path {
    
    # If we were called as a method, use the object on which we were called.
    # Otherwise, use the globally defined one.
    
    my $self = $_[0]->isa('Web::DataService') ? shift : $DEFAULT_INSTANCE;
    
    my ($path, $format) = @_;
    
    my $path_attrs = $self->{path_attrs}{$path};
    my $class = $self->{path_attrs}{$path}{class};
    
    $DB::single = 1;
    
    # If we are in 'one request' mode, initialize the class plus all of
    # the classes it requires.
    
    if ( $self->{ONE_REQUEST} )
    {
	if ( ref $path_attrs->{also_initialize} eq 'ARRAY' )
	{
	    foreach my $c ( @{$path_attrs->{also_initialize}} )
	    {
		$self->initialize_class($c);
	    }
	}
	
	$self->initialize_class($class);
    }
    
    # We start by determining the filename for the documentation template.  If
    # the filename was not explicitly specified, try the path with '_doc.tt'
    # appended.  If that does not exist, try appending '/index.tt'.
    
    my $viewdir = Dancer::config->{views};
    my $doc_file = $path_attrs->{doc_file};
    
    unless ( $doc_file )
    {
	if ( -e "$viewdir/doc/${path}_doc.tt" )
	{
	    $doc_file = "${path}_doc.tt";
	}
	
	elsif ( -e "$viewdir/doc/${path}/index.tt" )
	{
	    $doc_file = "${path}/index.tt";
	}
    }
    
    unless ( $doc_file && -r "$viewdir/doc/$doc_file" )
    {
	$doc_file = $path_attrs->{doc_error_file} || $self->{doc_error_file} || 'doc_error.tt';
    }
    
    # Then assemble the variables used to fill in the template:
    
    my $vars = { doc_title => $path_attrs->{doc_title},
		 ds_version => $path_attrs->{version} || $self->{version},
	         param_doc => '',
	         response_doc => '' };
    
    # Add the documentation for the parameters.  If no corresponding ruleset
    # is found, then state that no parameters are accepted.
    
    my $ruleset = $self->determine_ruleset($path, $path_attrs->{ruleset});

    $vars->{param_doc} = 
	$ruleset ? $self->{validator}->document_params($ruleset)
	         : "I<This path does not take any parameters>";
    
    # Add the documentation for the response.  If no 'allow_vocab' attribute
    # was given for this path, then all vocabularies are allowed.
    
    my $output_map = $self->determine_output_map($path, $path_attrs->{output_map});
    my $allow_vocab = $self->{path_attrs}{$path}{allow_vocab} || $self->{vocab};
    
    $vars->{response_doc} = $self->document_response($allow_vocab, $output_map) ||
	"I<This path does not implement any response>";
    
    # Now select the appropriate layout and execute the template.
    
    my $doc_layout = $path_attrs->{doc_layout} || $self->{doc_layout} || 'doc_main.tt';
    
    Dancer::set layout => $doc_layout;
    
    my $doc_string = Dancer::template( "doc/$doc_file", $vars );
    
    # All documentation is public, so set the maximally permissive CORS header.
    
    Dancer::header "Access-Control-Allow-Origin" => "*";
    
    # If POD format was requested, return the documentation as is.
    
    if ( defined $format && $format eq 'pod' )
    {
	Dancer::content_type 'text/plain';
	return $doc_string;
    }
    
    # Otherwise, convert the POD to HTML using the PodParser and return the result.
    
    else
    {
	my $parser = Web::DataService::PodParser->new();
	
	$parser->parse_pod($doc_string);
	
	my $doc_html = $parser->generate_html({ css => '/data/css/dsdoc.css', tables => 1 });
	
	Dancer::content_type 'text/html';
	return $doc_html;
    }
}

register 'document_path' => \&document_path;


# determine_ruleset ( path, ruleset )
# 
# Determine the ruleset that should apply to the given path.  If $ruleset is
# given, then use that if it is defined or throw an exception if not.
# Otherwise, try the path with slashes turned into commas.

sub determine_ruleset {
    
    my ($self, $path, $ruleset) = @_;
    
    my $validator = $self->{validator};
    
    # If a ruleset name was explicitly given, then use that or throw an
    # exception if not defined.
    
    if ( defined $ruleset and $ruleset ne '' )
    {
	croak "unknown ruleset '$ruleset' for path $path"
	    unless $validator->ruleset_defined($ruleset);
	
	return $ruleset;
    }
    
    # If the ruleset was explicitly specified as '', do not process the
    # parameters for this path.
    
    elsif ( defined $ruleset )
    {
	return;
    }
    
    # Otherwise, try the path with / replaced by :.  If that is not defined,
    # then return empty.  The parameters for this path will not be processed.
    
    else
    {
	$path =~ s{/}{:}g;
	
	return $path if $validator->ruleset_defined($path);
	return; # empty if not defined.
    }
}


# determine_output_map {
# 
# If an explicit output_map is given, then use that if defined or throw an
# error.  Otherwise, try the path with slashes turned into colons and ':map'
# appended.

sub determine_output_map {

    my ($self, $path, $output_map) = @_;
    
    # If an output_set name was explicitly given, then use that or throw an
    # exception if not defined.
    
    if ( defined $output_map and $output_map ne '' )
    {
	croak "unknown output set '$output_map' for path $path"
	    unless ref $self->{set}{$output_map} eq 'Web::DataService::Set';
	
	return $output_map;
    }
    
    # If the outputset was explicitly specified as '', then this path does not
    # use one.
    
    elsif ( defined $output_map )
    {
	return;
    }
    
    # Otherwise, try the path with / changed to : but return empty if this is
    # not found.  Not all paths need an output set.
    
    else
    {
	$path =~ s{/}{:}g;
	$path .= ':map';
	
	return $path if ref $self->{set}{$path} eq 'Web::DataService::Set';
	return; # empty if not defined.
    }   
}


sub set_response_headers {
    
    my ($self, $path, $format) = @_;
    
    # If this is a public-access data service, we add a universal CORS header.
    # At some point we need to add provision for authenticated access.
    
    if ( $self->{public_access} )
    {
	Dancer::header "Access-Control-Allow-Origin" => "*";
    }
    
    # Set the content type based on the format.
    
    my $ct = $self->{format}{$format}{content_type};
    Dancer::content_type $ct if $ct;
    
    return;
}


my %CODE_STRING = ( 400 => "Bad Request", 
		    404 => "Not Found", 
		    415 => "Invalid Media Type",
		    500 => "Server Error" );

# error_result ( path, format, error )
# 
# Send an error response back to the client.

sub error_result {

    my ($self, $path, $format, $error) = @_;
    
    my ($code);
    my (@errors, @warnings);
    
    # If the error is actually a response object from HTTP::Validate, then
    # extract the error and warning messages.  In this case, the error code
    # should be "400 bad request".
    
    if ( ref $error eq 'HTTP::Validate::Result' )
    {
	@errors = $error->errors;
	@warnings = $error->warnings;
	$code = "400";
    }
    
    # If the error message begins with a 3-digit number, then that should be
    # used as the code and the rest of the message as the error text.
    
    elsif ( $error =~ qr{ ^ (\d\d\d) \s+ (.*) }xs )
    {
	$code = $1;
	@errors = $2;
    }
    
    # Otherwise, this is an internal error and all that we should report to
    # the user (for security reasons) is that an error occurred.  The actual
    # message is written to the server error log.
    
    else
    {
	$code = 500;
	#error("Error on path $path: $error");
	warn $error;
	@errors = "A server error occurred.  Please contact the server administrator.";
    }
    
    # If the format is 'json', render the response as a JSON object.
    
    if ( $format eq 'json' )
    {
	my $error = json_list_value("errors", @errors);
	$error .= ",\n" . json_list_value("warnings", @warnings) if @warnings;
	
	Dancer::content_type('application/json');
	Dancer::status($code);
	return "{ $error }";
    }
    
    # Otherwise, generate a generic HTML response (we'll add template
    # capability later...)
    
    else
    {
	my $text = $CODE_STRING{$code};
	my $error = "<ul>\n";
	my $warning = '';
	
	$error .= "<li>$_</li>\n" foreach @errors;
	$error .= "</ul>\n";
	
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
    
	Dancer::content_type('text/html');
	Dancer::status($code);
	return $body;
    }
}


register_plugin;

1;
