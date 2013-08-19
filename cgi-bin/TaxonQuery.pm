#
# TaxonQuery
# 
# A class that returns information from the PaleoDB database about a single
# taxon or a category of taxa.  This is a subclass of DataQuery.
# 
# Author: Michael McClennen

package TaxonQuery;

use strict;
use base 'DataQuery';
use Carp qw(carp croak);

use Taxonomy;


our (%OUTPUT, %PROC);

$OUTPUT{single} = $OUTPUT{list} = 
   [
    { rec => 'taxon_no', dwc => 'taxonID', com => 'oid',
	doc => "A positive integer that uniquely identifies this taxonomic name"},
    { rec => 'orig_no', com => 'gid',
        doc => "A positive integer that uniquely identifies the taxonomic concept"},
    { rec => 'record_type', com => 'typ', com_value => 'txn', dwc_value => 'Taxon', value => 'taxon',
        doc => "The type of this object: {value} for a taxonomic name" },
    { rec => 'rank', dwc => 'taxonRank', com => 'rnk', 
	doc => "The taxonomic rank of this name" },
    { rec => 'taxon_name', dwc => 'scientificName', com => 'nam',
	doc => "The scientific name of this taxon" },
    { rec => 'common_name', dwc => 'vernacularName', com => 'nm2',
        doc => "The common (vernacular) name of this taxon, if any" },
    { rec => 'attribution', dwc => 'scientificNameAuthorship', show => 'attr', com => 'att', 
	doc => "The attribution (author and year) of this taxonomic name" },
    { rec => 'parent_no', dwc => 'parentNameUsageID', com => 'par', 
	doc => "The identifier of the parent taxonomic concept, if any" },
    { rec => 'synonym_no', dwc => 'acceptedNameUsageID', pbdb => 'senior_no', com => 'snr', dedup => 'orig_no',
        doc => "The identifier of the senior synonym of this taxonomic concept, if any" },
    { rec => 'pubref', com => 'ref', dwc => 'namePublishedIn', show => 'ref', json_list => 1,
	doc => "The reference from which this name was entered into the database (as formatted text)" },
    { rec => 'reference_no', com => 'rid', json_list => 1,
	doc => "The identifier of the primary reference associated with the taxon" },
    { rec => 'extant', com => 'ext', dwc => 'isExtant',
        doc => "True if this taxon is extant on earth today, false if not, not present if unrecorded" },
    { rec => 'size', com => 'siz', show => 'size',
        doc => "The total number of taxa in the database that are contained within this taxon, including itself" },
    { rec => 'extant_size', com => 'exs', show => 'size',
        doc => "The total number of extant taxa in the database that are contained within this taxon, including itself" },
    { rec => 'firstapp_ei', com => 'fei', dwc => 'firstAppearanceEarlyInterval', show => 'applong',
        doc => "The name of the interval for the first appearance of this taxon in this database" },
    { rec => 'firstapp_li', com => 'fli', dwc => 'firstAppearanceLateIneterval', show => 'applong', 
        dedup => 'firstapp_ei',
        doc => "The end of the interval range for the first appearance of this taxon in this database" },
    { rec => 'lastapp_ei', com => 'lei', dwc => 'lastAppearanceEarlyInterval', show => 'applong',
        doc => "The name of the interval for the last appearance of this taxon in this database" },
    { rec => 'lastapp_li', com => 'lli', dwc => 'lastAppearanceLateInterval', show => 'applong', 
        dedup => 'lastapp_ei',
        doc => "The end of the interval range for the last appearance of this taxon in this database" },
    { rec => 'firstapp_ea', com => 'fea', dwc => 'firstAppearanceEarlyAge', show => 'applong',
        doc => "The early age bound for the first appearance of this taxon in this database" },
    { rec => 'firstapp_la', com => 'fla', dwc => 'firstAppearanceLateAge', show => 'applong', 
        doc => "The late age bound for the first appearance of this taxon in this database" },
    { rec => 'lastapp_ea', com => 'lea', dwc => 'lastAppearanceEarlyAge', show => 'applong',
        doc => "The early age bound for the last appearance of this taxon in this database" },
    { rec => 'lastapp_la', com => 'lla', dwc => 'lastAppearanceLateAge', show => 'applong', 
        doc => "The late age bound for the last appearance of this taxon in this database" },
   ];

$PROC{attr} = 
   [
    { rec => 'a_al1', set => 'attribution', use_main => 1, code => \&DataQuery::generateAttribution },
    { rec => 'a_pubyr', set => 'pubyr' },
   ];

$PROC{ref} =
   [
    { rec => 'r_al1', set => 'pubref', use_main => 1, code => \&DataQuery::generateReference },
   ];

my $child_rule = [ { rec => 'taxon_no', com => 'oid', dwc => 'taxonID' },
		  { rec => 'orig_no', com => 'gid' },
		  { rec => 'record_type', com => 'typ', com_value => 'txn' },
		  { rec => 'taxon_rank', com => 'rnk', dwc => 'taxonRank' },
		  { rec => 'taxon_name', com => 'nam', dwc => 'scientificName' },
		  { rec => 'synonym_no', com => 'snr', pbdb => 'senior_no', 
			dwc => 'acceptedNameUsageID', dedup => 'orig_no' },
		  { rec => 'size', com => 'siz' },
		  { rec => 'extant_size', com => 'exs' },
		  { rec => 'firstapp_ea', com => 'fea' },
		];

$OUTPUT{nav} =
   [
    { rec => 'parent_name', com => 'prl', dwc => 'parentNameUsage',
        doc => "The name of the parent taxonomic concept, if any" },
    { rec => 'parent_rank', com => 'prr', doc => "The rank of the parent taxonomic concept, if any" },
    { rec => 'kingdom_no', com => 'kgn', doc => "The identifier of the kingdom in which this taxon occurs" },
    { rec => 'kingdom', com => 'kgl', doc => "The name of the kingdom in which this taxon occurs" },
    { rec => 'phylum_no', com => 'phn', doc => "The identifier of the phylum in which this taxon occurs" },
    { rec => 'phylum', com => 'phl', doc => "The name of the phylum in which this taxon occurs" },
    { rec => 'phylum_count', com => 'phc', doc => "The number of phyla within this taxon" },
    { rec => 'class_no', com => 'cln', doc => "The identifier of the class in which this taxon occurs" },
    { rec => 'class', com => 'cll', doc => "The name of the class in which this taxon occurs" },
    { rec => 'class_count', com => 'clc', doc => "The number of classes within this taxon" },
    { rec => 'order_no', com => 'odn', doc => "The identifier of the order in which this taxon occurs" },
    { rec => 'order', com => 'odl', doc => "The name of the order in which this taxon occurs" },
    { rec => 'order_count', com => 'odc', doc => "The number of orders within this taxon" },
    { rec => 'family_no', com => 'fmn', doc => "The identifier of the family in which this taxon occurs" },
    { rec => 'family', com => 'fml', doc => "The name of the family in which this taxon occurs" },
    { rec => 'family_count', com => 'fmc', doc => "The number of families within this taxon" },
    { rec => 'genus_count', com => 'gnc', doc => "The number of genera within this taxon" },
    
    { rec => 'children', com => 'chl', use_each => 1,
        doc => "The immediate children of this taxonomic concept, if any",
        rule => $child_rule },
    { rec => 'phylum_list', com => 'phs', use_each => 1,
        doc => "A list of the phyla within this taxonomic concept",
        rule => $child_rule },
    { rec => 'class_list', com => 'cls', use_each => 1,
        doc => "A list of the classes within this taxonomic concept",
        rule => $child_rule },
    { rec => 'order_list', com => 'ods', use_each => 1,
        doc => "A list of the orders within this taxonomic concept",
        rule => $child_rule },
    { rec => 'family_list', com => 'fms', use_each => 1,
        doc => "A list of the families within this taxonomic concept",
        rule => $child_rule },
    { rec => 'genus_list', com => 'gns', use_each => 1,
        doc => "A list of the genera within this taxonomic concept",
        rule => $child_rule },
    { rec => 'subgenus_list', com => 'sgs', use_each => 1,
        doc => "A list of the subgenera within this taxonomic concept",
        rule => $child_rule },
    { rec => 'species_list', com => 'sps', use_each => 1,
        doc => "A list of the species within this taxonomic concept",
        rule => $child_rule },
     { rec => 'subspecies_list', com => 'sss', use_each => 1,
        doc => "A list of the subspecies within this taxonomic concept",
        rule => $child_rule },
  ];


# fetchSingle ( )
# 
# Query for all relevant information about the requested taxon.
# 
# Options may have been set previously by methods of this class or of the
# parent class DataQuery.
# 
# Returns true if the fetch succeeded, false if an error occurred.

sub fetchSingle {

    my ($self) = @_;
    
    my $dbh = $self->{dbh};
    my $taxonomy = $self->{taxonomy};
    my $taxon_no;
    
    # Then figure out which taxon we are looking for.  If we have a taxon_no,
    # we can use that.
    
    my $not_found_msg = '';
    
    if ( $self->{params}{id} )
    {    
	$taxon_no = $self->{params}{id};
	$not_found_msg = "Taxon number $taxon_no was not found in the database";
    }
    
    # Otherwise, we must have a taxon name.  So look for that.
    
    elsif ( defined $self->{params}{name} )
    {
	$not_found_msg = "Taxon '$self->{params}{name}' was not found in the database";
	my $name_select = { order => 'size.desc', spelling => 'exact', return => 'id' };
	
	if ( defined $self->{params}{rank} )
	{
	    $name_select->{rank} = $self->{params}{rank};
	    $not_found_msg .= " at rank '$self->{base_taxon_rank}'";
	}
	
	($taxon_no) = $taxonomy->getTaxaByName($self->{params}{name}, $name_select);
    }
    
    # If we haven't found a record, the result set will be empty.
    
    unless ( defined $taxon_no and $taxon_no > 0 )
    {
	return;
    }
    
    # Now add the fields necessary to show the requested info.
    
    my $options = {};
    
    my @fields;
    
    push @fields, 'link' if $self->{show}{nav};
    push @fields, 'parent' if $self->{show}{nav};
    push @fields, 'phylo' if $self->{show}{nav};
    push @fields, 'counts' if $self->{show}{nav};
    push @fields, 'ref' if $self->{show}{ref};
    push @fields, 'attr' if $self->{show}{attr};
    push @fields, 'size' if $self->{show}{size};
    push @fields, 'app' if $self->{show}{app};
    push @fields, 'appfirst' if $self->{show}{appfirst};
    push @fields, 'applong' if $self->{show}{applong};
    push @fields, 'kingdom' if $self->{show}{code};
    
    $options->{fields} = \@fields;
    
    # If we were asked for the senior synonym, choose it.
    
    my $rel = $self->{params}{senior} ? 'senior' : 'self';
    
    # Next, fetch basic info about the taxon.
    
    ($self->{main_record}) = $taxonomy->getRelatedTaxon($rel, $taxon_no, $options);
    
    # If we were asked for 'nav' info, also show the various categories
    # of subtaxa.
    
    if ( $self->{show}{nav} )
    {
	my $r = $self->{main_record};
	
	unless ( $r->{phylum_no} or (defined $r->{rank} && $r->{rank} <= 20) )
	{
	    $r->{phylum_list} = [ $taxonomy->getTaxa('all_children', $taxon_no, 
						     { limit => 10, order => 'size.desc', rank => 20, fields => ['size', 'appfirst'] } ) ];
	}
	
	unless ( $r->{class_no} or $r->{rank} <= 17 )
	{
	    $r->{class_list} = [ $taxonomy->getTaxa('all_children', $taxon_no, 
						    { limit => 10, order => 'size.desc', rank => 17, fields => ['size', 'appfirst'] } ) ];
	}
	
	unless ( $r->{order_no} or $r->{rank} <= 13 )
	{
	    my $order = $r->{order_count} < 100 ? 'size.desc' : undef;
	    $r->{order_list} = [ $taxonomy->getTaxa('all_children', $taxon_no, 
						    { limit => 10, order => $order, rank => 13, fields => ['size', 'appfirst'] } ) ];
	}
	
	unless ( $r->{family_no} or $r->{rank} <= 9 )
	{
	    my $order = $r->{order_count} < 100 ? 'size.desc' : undef;
	    $r->{family_list} = [ $taxonomy->getTaxa('all_children', $taxon_no, 
						     { limit => 10, order => $order, rank => 9, fields => ['size', 'appfirst'] } ) ];
	}
	
	if ( $r->{rank} > 5 )
	{
	    my $order = $r->{order_count} < 100 ? 'size.desc' : undef;
	    $r->{genus_list} = [ $taxonomy->getTaxa('all_children', $taxon_no,
						    { limit => 10, order => $order, rank => 5, fields => ['size', 'appfirst'] } ) ];
	}
	
	if ( $r->{rank} == 5 )
	{
	    $r->{subgenus_list} = [ $taxonomy->getTaxa('all_children', $taxon_no,
						       { limit => 10, order => 'size.desc', rank => 4, fields => ['size', 'appfirst'] } ) ];
	}
	
	if ( $r->{rank} == 5 or $r->{rank} == 4 )
	{
	    $r->{species_list} = [ $taxonomy->getTaxa('all_children', $taxon_no,
						       { limit => 10, order => 'size.desc', rank => 3, fields => ['size', 'appfirst'] } ) ];
	}
	
	$r->{children} = 
	    [ $taxonomy->getTaxa('children', $taxon_no, { limit => 10, order => 'size.desc', fields => ['size', 'appfirst'] } ) ];
    }
    
    return 1;
}


# fetchMultiple ( )
# 
# Query the database for basic info about all taxa satisfying the conditions
# previously specified by a call to setParameters.
# 
# Returns true if the fetch succeeded, false if an error occurred.

sub fetchMultiple {

    my ($self) = @_;
    
    my $dbh = $self->{dbh};
    my $taxonomy = $self->{taxonomy};
    my $taxon_no;
    
    # First, figure out what info we need to provide
    
    my $options = {};
    
    my @fields = ('link');
    
    push @fields, 'ref' if $self->{show}{ref};
    push @fields, 'attr' if $self->{show}{attr};
    push @fields, 'size' if $self->{show}{size};
    push @fields, 'app' if $self->{show}{app};
    push @fields, 'applong' if $self->{show}{applong};
    push @fields, 'appfirst' if $self->{show}{appfirst};
    push @fields, 'kingdom' if $self->{show}{code};
    
    $options->{fields} = \@fields;
    
    # Specify the other query options according to the query parameters.
    
    $options->{exact} = 1 if $self->{params}{exact};
    
    my $limit = $self->{params}{limit};
    my $offset = $self->{params}{offset};
    
    $options->{limit} = $limit if defined $limit;
    $options->{offset} = $offset if defined $offset;
    
    # If the parameter 'name' was given, then we are listing taxa by name.
    
    if ( $self->{params}{name} )
    {
	my $name = $self->{params}{name};
	
	my @result_list = $taxonomy->getTaxaByName($name, $options);
	return unless @result_list;
	
	$self->{main_result} = \@result_list;
	$self->{result_count} = scalar(@result_list);
	return 1;
    }
    
    # Otherwise, if the parameter 'id' was given, then we are listing
    # taxa by relationship.
    
    elsif ( $self->{params}{id} or $self->{params}{rel} eq 'all_taxa' )
    {
	$options->{return} = 'stmt';
	my $id_list = $self->{params}{id};
	my $rel = $self->{params}{rel} || 'self';
	
	if ( defined $self->{params}{rank} )
	{
	    $options->{rank} = $self->{params}{rank};
	}
	
	($self->{main_sth}) = $taxonomy->getTaxa($rel, $id_list, $options);
	return $self->{main_sth};
    }
    
    # Otherwise, we have an empty result.
    
    else
    {
	return;
    }
}


# validNameSpec ( name )
# 
# Returns true if the given value is a valid taxonomic name specifier.  We
# allow not only single names, but also lists of names and extra modifiers as
# follows: 
# 
# valid_spec:	name_spec [ , name_spec ... ]
# 
# name_spec:	[ single_name : ] general_name [ < exclude_list > ]
# 
# single_name:	no spaces, but may include wildcards
# 
# general_name: may include up to four components, second component may
#		include parentheses, may include wildcards
# 
# exclude_list:	general_name [ , general_name ]

sub validNameSpec {
    
    my ($value, $context) = @_;
    
    return;	# for now
    
}


sub validRankSpec {
    
    my ($value, $context) = @_;
    
    return;
}


# This routine will be called if necessary in order to properly process the
# results of a query for taxon parents.

sub processResultSet {
    
    my ($self, $rowlist) = @_;
    
    # Run through the parent list and note when we reach the last
    # kingdom-level taxon.  Any entries before that point are dropped 
    # [see TaxonInfo.pm, line 1252 as of 2012-06-24]
    # 
    # If the leaf entry is of rank subgenus or lower, we may need to rewrite the
    # last few entries so that their names properly match the higher level entries.
    # [see TaxonInfo.pm, lines 1232-1271 as of 2012-06-24]
    
    my @new_list;
    my ($genus_name, $subgenus_name, $species_name, $subspecies_name);
    
    for (my $i = 0; $i < scalar(@$rowlist); $i++)
    {
	# Only keep taxa from the last kingdom-level entry on down.
	
    	@new_list = () if $rowlist->[$i]{taxon_rank} eq 'kingdom';
	
	# Skip junior synonyms, we only want a list of 'belongs to' entries.
	
	next unless $rowlist->[$i]{status} eq 'belongs to';
	
	# Note genus, subgenus, species and subspecies names, and rewrite as
	# necessary anything lower than genus in order to match the genus, etc.
	
	my $taxon_name = $rowlist->[$i]{taxon_name};
	my $taxon_rank = $rowlist->[$i]{taxon_rank};
	
	if ( $taxon_rank eq 'genus' )
	{
	    $genus_name = $taxon_name;
	}
	
	elsif ( $taxon_rank eq 'subgenus' )
	{
	    if ( $taxon_name =~ /^(\w+)\s*\((\w+)\)/ )
	    {
		$subgenus_name = "$genus_name ($2)";
		$rowlist->[$i]{taxon_name} = $subgenus_name;
	    }
	}
	
	elsif ( $taxon_rank eq 'species' )
	{
	    if ( $taxon_name =~ /^(\w+)\s*(\(\w+\)\s*)?(\w+)/ )
	    {
		$species_name = $subgenus_name || $genus_name;
		$species_name .= " $3";
		$rowlist->[$i]{taxon_name} = $species_name;
	    }
	}
	
	elsif ( $taxon_rank eq 'subspecies' )
	{
	    if ( $taxon_name =~ /^(\w+)\s*(\(\w+\)\s*)?(\w+)\s+(\w+)/ )
	    {
		$subspecies_name = "$species_name $4";
		$rowlist->[$i]{taxon_name} = $subspecies_name;
	    }
	}
	
	# Now add the (possibly rewritten) entry to the list
	
	push @new_list, $rowlist->[$i];
    }
    
    # Now substitute the processed list for the raw one.
    
    @$rowlist = @new_list;
}


# processRecord ( row )
# 
# This routine takes a hash representing one result row, and does some
# processing before the output is generated.  The information fetched from the
# database needs to be refactored a bit in order to match the Darwin Core
# standard we are using for output.

sub oldProcessRecord {
    
    my ($self, $row) = @_;
    
    # The strings stored in the author fields of the database are encoded in
    # utf-8, and need to be decoded (despite the utf-8 configuration flag).
    
    $self->decodeFields($row);
    
    # Interpret the status info based on the code stored in the database.  The
    # code as stored in the database encompasses both taxonomic and
    # nomenclatural status info, which needs to be separated out.  In
    # addition, we need to know whether to report an "acceptedUsage" taxon
    # (i.e. senior synonym or proper spelling).
    
    my ($taxonomic, $report_accepted, $nomenclatural) = interpretStatusCode($row->{status});
    
    # Override the status code if the synonym_no is different from the
    # taxon_no.  This is necessary because sometimes the opinion record that
    # was used to build this part of the hierarchy indicates a 'belongs to'
    # relationship (which normally indicates a valid taxon) but the
    # taxa_tree_cache record indicates a different synonym number.  In this
    # case, the taxon is in fact no valid but is a junior synonym or
    # misspelling.  If spelling_no and synonym_no are equal, it's a
    # misspelling.  Otherwise, it's a junior synonym.
    
    if ( $taxonomic eq 'valid' && $row->{synonym_no} ne $row->{taxon_no} )
    {
	if ( $row->{spelling_no} eq $row->{synonym_no} )
	{
	    $taxonomic = 'invalid' unless $row->{spelling_reason} eq 'recombination';
	    $nomenclatural = $row->{spelling_reason};
	}
	else
	{
	    $taxonomic = 'synonym';
	}
    }
    
    # Put the two status strings into the row record.  If no value exists,
    # leave it blank.
    
    $row->{taxonomic} = $taxonomic || '';
    $row->{nomenclatural} = $nomenclatural || '';
    
    # Determine the nomenclatural code that has jurisidiction, if that was
    # requested.
    
    if ( $self->{show_code} and defined $row->{lft} )
    {
	$self->determineNomenclaturalCode($row);
    }
    
    # Determine the first appearance data, if that was requested.
    
    if ( $self->{show_firstapp} )
    {
	$self->determineFirstAppearance($row);
    }
    
    # Create a publication reference if that data was included in the query
    
    if ( exists $row->{r_pubtitle} )
    {
	$self->generateReference($row);
    }
    
    # Create an attribution if that data was incluced in the query
    
    if ( exists $row->{a_pubyr} )
    {
	$self->generateAttribution($row);
    }
}


# getCodeRanges ( )
# 
# Fetch the ranges necessary to determine which nomenclatural code (i.e. ICZN,
# ICN) applies to any given taxon.  This is only done if that information is
# asked for.

sub getCodeRanges {

    my ($self) = @_;
    my ($dbh) = $self->{dbh};
    
my @codes = ('Metazoa', 'Animalia', 'Plantae', 'Biliphyta', 'Metaphytae',
	     'Fungi', 'Cyanobacteria');

my $codes = { Metazoa => { code => 'ICZN'}, 
	      Animalia => { code => 'ICZN'},
	      Plantae => { code => 'ICN'}, 
	      Biliphyta => { code => 'ICN'},
	      Metaphytae => { code => 'ICN'},
	      Fungi => { code => 'ICN'},
	      Cyanobacteria => { code => 'ICN' } };

    $self->{code_ranges} = $codes;
    $self->{code_list} = \@codes;
    
    my $code_name_list = "'" . join("','", @codes) . "'";
    
    my $code_range_query = $dbh->prepare("
	SELECT taxon_name, lft, rgt
	FROM taxa_tree_cache join authorities using (taxon_no)
	WHERE taxon_name in ($code_name_list)");
    
    $code_range_query->execute();
    
    while ( my($taxon, $lft, $rgt) = $code_range_query->fetchrow_array() )
    {
	$codes->{$taxon}{lft} = $lft;
	$codes->{$taxon}{rgt} = $rgt;
    }
}


# determineNomenclaturalCode ( row )
# 
# Determine which nomenclatural code the given row's taxon falls under

sub determineNomenclaturalCode {
    
    my ($self, $row) = @_;

    my ($lft) = $row->{lft} || return;
    
    # Anything with a rank of 'unranked clade' falls under PhyloCode.
    
    if ( defined $row->{taxon_rank} && $row->{taxon_rank} eq 'unranked clade' )
    {
	$row->{nom_code} = 'PhyloCode';
	return;
    }
    
    # For all other taxa, we go through the list of known ranges in
    # taxa_tree_cache and use the appropriate code.
    
    foreach my $taxon (@{$self->{code_list}})
    {
	my $range = $self->{code_ranges}{$taxon};
	
	if ( $lft >= $range->{lft} && $lft <= $range->{rgt} )
	{
	    $row->{nom_code} = $range->{code};
	    last;
	}
    }
    
    # If this taxon does not fall within any of the ranges, we leave the
    # nom_code field empty.
}


# determineFirstAppearance ( row )
# 
# Calculate the first appearance of this taxon.

sub determineFirstAppearance {
    
    my ($self, $row) = @_;
    
    my $dbh = $self->{dbh};
    
    # Generate a parameter hash to pass to calculateFirstAppearance().
    
    my $params = { taxonomic_precision => $self->{firstapp_precision},
		   types_only => $self->{firstapp_types_only},
		   traces => $self->{firstapp_include_traces},
		 };
    
    # Get the results.
    
    my $results = calculateFirstAppearance($dbh, $row->{taxon_no}, $params);
    return unless ref $results eq 'HASH';
    
    # Check for error
    
    if ( $results->{error} )
    {
	$self->{firstapp_error} = "An error occurred while calculating the first apperance";
	return;
    }
    
    # If we got results, copy each field into the row.
    
    foreach my $field ( keys %$results )
    {
	$row->{$field} = $results->{$field};
    }
}


# calculateFirstAppearance ( dbh, taxon_no, params )
# 
# Calculate the first appearance data for the specified taxon, using the
# specified parameters.  The first parameter must be either a valid session
# record, which is used to determine which collections we have access to, or
# else a dbh (when this routine is called from the data service
# application). In the latter case, we must generate a dummy session record.

sub calculateFirstAppearance {
    
    my ($dbh, $taxon_no, $params) = @_;
    
    # If we were given a session record, look up the dbt and dbh.  Otherwise,
    # generate a dummy session record.
    
    # my ($s, $dbt, $dbh);
    
    # if ( ref $session_param eq 'Session' )
    # {
    # 	$s = $session_param;
    # 	$dbt = $s->{dbt};
    # 	$dbh = $s->{dbt}{dbh};
    # }
    
    # else
    # {
    # 	$dbh = $session_param;
    # 	$dbt = DBTransactionManager->new($dbh);
    # 	$s = bless { logged_in => 0, dbt => $dbt }, 'Session';
    # }
    
    # Figure default parameter values.
    
    $params ||= {};
    $params->{taxonomic_precision} ||= 'any';
    
    # Determine excluded taxa, if any.
    
    # my ($sql, $field, $name, $exclude);
    
    # if ( $params->{exclude} )
    # {
    # 	my $names = $params->{exclude};
    # 	$names =~ s/[^A-Za-z]/ /g;
    # 	$names =~ s/  / /g;
    # 	$names =~ s/  / /g;
    # 	$names =~ s/ /','/g;
    # 	$sql = "SELECT a.taxon_no,a.taxon_name,lft,rgt FROM authorities a,$TAXA_TREE_CACHE t WHERE a.taxon_name IN ('".$names."') AND a.taxon_no=t.spelling_no GROUP BY lft,rgt ORDER BY lft";
    # 	my @nos = @{$dbt->getData($sql)};
    # 	$exclude .= " AND (rgt<$_->{'lft'} OR lft>$_->{'rgt'})" foreach @nos;
    # }
    
    # First get all subtaxa.
    
    my $sql = " SELECT t.lft, t.rgt, a.taxon_rank, a.extant 
		FROM authorities as a JOIN taxa_tree_cache as t using (taxon_no)
		WHERE a.taxon_no = $taxon_no";
    
    my ($lft, $rgt, $rank, $extant) = $dbh->selectrow_array($sql);
    
    unless ( $lft )
    {
	return { error => 'No matching taxon found.' };
    }
    
    unless ( $rgt >= $lft + 1 or $rank =~ /genus|species/ )
    {
	return { error => 'No classified subtaxa found.' };
    }
    
    # Determine the proper query based on the parameters
    # 'taxonomic_precision', 'types_only', and 'type_body_part'.
    
    $sql = "SELECT a.taxon_no,taxon_name,taxon_rank,extant,preservation,type_locality,lft,rgt,synonym_no
		FROM authorities a JOIN taxa_tree_cache as t USING (taxon_no)
		WHERE lft>=".$lft." AND rgt<=".$rgt." ORDER BY lft";
    my @allsubtaxa = @{$dbh->selectall_arrayref($sql, { Slice => {} })};
    my @subtaxa;
    
    if ( $params->{taxonomic_precision} =~ /^any/ )
    {
	@subtaxa = @allsubtaxa;
    }
    
    elsif ( $params->{taxonomic_precision} =~ /species|genus|family/ )
    {
	my @ranks = ('subspecies','species');
	if ( $params->{taxonomic_precision} =~ /genus or species/ )	{
	    push @ranks , ('subgenus','genus');
	} elsif ( $params->{taxonomic_precision} =~ /family/ )	{
	    push @ranks , ('subgenus','genus','tribe','subfamily','family');
	}
	$sql = "SELECT a.taxon_no,taxon_name,type_locality,extant,preservation,lft,rgt
		FROM authorities as a join taxa_tree_cache as t using (taxon_no)
		WHERE a.taxon_no=t.taxon_no AND lft>".$lft." AND rgt<".$rgt." AND taxon_rank IN ('".join("','",@ranks)."')";
	
	if ( $params->{types_only} )
	{
	    $sql .= " AND type_locality>0";
	}
	
	if ( $params->{type_body_part} )
	{
	    my $parts;
	    if ( $params->{type_body_part} =~ /multiple teeth/i )	{
		$parts = "'skeleton','partial skeleton','skull','partial skull','maxilla','mandible','teeth'";
	    } elsif ( $params->{type_body_part} =~ /skull/i )	{
		$parts = "'skeleton','partial skeleton','skull','partial skull'";
	    } elsif ( $params->{type_body_part} =~ /skeleton/i )	{
		$parts = "'skeleton','partial skeleton'";
	    }
	    $sql .= " AND type_body_part IN (".$parts.")";
	}
	my $result = $dbh->selectall_arrayref($sql, { Slice => {} });
	@subtaxa = @$result;
    }
    
    else
    {
	warn "Invalid value '$params->{taxonomic_precision}' for parameter 'taxonomic_precision'";
	return { error => 'Internal error' }
    }
    
    # See if this taxon is extant (if either it or any of its subtaxa is so
    # marked). 
    
    if ( $extant ne 'yes' )	{
	for my $t ( @allsubtaxa )	{
	    if ( defined $t->{extant} and $t->{extant} eq 'yes' )
	    {
		$extant = "yes";
		last;
	    }
	}
    }
    
    # Remove trace fossils from @subtaxa, unless the parameter 'traces' is
    # true.  The 'preservation' attribute is inherited from parent to child if
    # no value is specified for the child.
    
    unless ( $params->{traces} )
    {
    	my %istrace;
    	for my $i ( 0..$#allsubtaxa )
    	{
    	    my $st = $allsubtaxa[$i];
    	    if ( defined $st->{preservation} and $st->{preservation} eq "trace" )
    	    {
    		$istrace{$st->{'taxon_no'}}++;
    		# find parents by descending
    		# overall parent is innocent until proven guilty
    	    } elsif ( ! $st->{'preservation'} && $st->{'lft'} >= $lft )	{
    		my $j = $i-1;
    		# first part means "not parent"
    		while ( ( $allsubtaxa[$j]->{'rgt'} < $st->{'lft'} || 
    			  ! $allsubtaxa[$j]->{'preservation'} ) && $j > 0 )
    		{
    		    $j--;
    		}
    		if ( defined $allsubtaxa[$j]{preservation} and $allsubtaxa[$j]{preservation} eq "trace" )
    		{
    		    $istrace{$st->{'taxon_no'}}++;
    		}
    	    }
    	}
    	my @nontraces;
    	for my $st ( @subtaxa )
    	{
    	    if ( ! $istrace{$st->{'taxon_no'}} )	{
    		push @nontraces , $st;
    	    }
    	}
    	@subtaxa = @nontraces;
    }
    
    # Now that we've got a good list of taxa, find all matching collections.
    
    my $taxa = join(',', map { $_->{taxon_no} } @subtaxa);
    
    $sql = "    SELECT c.collection_no, c.max_interval_no, c.min_interval_no
		FROM collections as c JOIN 
			(SELECT o.collection_no FROM occurrences as o
				LEFT JOIN reidentifications as re ON re.occurrence_no = o.occurrence_no
			WHERE re.reid_no is null and o.taxon_no in ($taxa)
			UNION 
			SELECT o.collection_no FROM occurrences as o
				JOIN reidentifications as re ON re.occurrence_no = o.occurrence_no
			WHERE re.most_recent='YES' and re.taxon_no in ($taxa)) as m
				ON c.collection_no = m.collection_no
		WHERE (c.access_level = 'the public' or c.release_date <= now())
		GROUP BY c.collection_no";
    
    my $colls = $dbh->selectall_arrayref($sql, { Slice => {} });
    
    # my $options = {};
    # if ( $params->{types_only} )
    # {
    # 	for my $st ( @subtaxa )	{
    # 	    if ( $st->{type_locality} > 0 ) { $options->{collection_list} .= ",".$st->{type_locality}; }
    # 	}
    # 	$options->{collection_list} =~ s/^,//;
    # 	$options->{'species_reso'} = ["n. sp."];
    # }
    
    # we could use getCollectionsSet but it would be overkill
    # my $fields = ['max_interval_no','min_interval_no','collection_no','collection_name','country','state','geogscale','formation','member','stratscale','lithification','minor_lithology','lithology1','lithification2','minor_lithology2','lithology2','environment'];
    
    # if ( ! $params->{Africa} || ! $params->{Antarctica} || ! $params->{Asia} || ! $params->{Australia} || ! $params->{Europe} || ! $params->{'North America'} || ! $params->{'South America'} )
    # {
    # 	my @list = grep $params->{$1}, ('Africa', 'Antarctica', 'Asia', 'Australia', 'Europe',
    # 					'North America', 'South America' );
    # 	$options->{'country'} = join(':', @list);
    # }
    
    # my @in_list = map $_->{taxon_no}, @subtaxa;
    # $options->{taxon_list} = \@in_list;
    
    # $options->{permission_type} = 'read';
    # $options->{geogscale} = $params->{geogscale};
    # $options->{stratscale} = $params->{stratscale};
    # if ( $params->{minimum_age} > 0 )	{
    # 	$options->{max_interval} = 999;
    # 	$options->{min_interval} = $params->{minimum_age};
    # }
    
    # my ($colls) = Collection::getCollections($dbt, $s, $options, $fields);
    unless ( @$colls )	{
	return { error =>  "No occurrences of this taxon match the search criteria" };
    }
    
    my @intervals = intervalData($dbh, $colls);
    my %interval_hash = map { ($_->{interval_no}, $_) } @intervals;
    
    if ( defined $params->{temporal_precision} )
    {
	my @newcolls;
	for my $coll (@$colls) 
	{
	    if ( $interval_hash{$coll->{'max_interval_no'}}->{'base_age'} -  $interval_hash{$coll->{'max_interval_no'}}->{'top_age'} <= $params->{temporal_precision} )	{
		push @newcolls , $coll;
	    }
	}
	$colls = \@newcolls;
    }
    
    if ( ! @$colls )
    {
	return { error => "No occurrences of this taxon have sufficiently precise age data" };
    }
    
    my $ncoll = scalar(@$colls);
    
    # AGE RANGE/CONFIDENCE INTERVAL CALCULATION
    
    my ($lb, $ub, $max_no, $minfirst, $maxlast, $min_no) = getAgeRange($dbh, $colls);
    my ($first_interval_top, @firsts, @rages, @ages, @gaps);
    my $TRIALS = int( 10000 / scalar(@$colls) );
    
    for my $coll (@$colls)
    {
	my ($collmax,$collmin,$last_name) = ("","","");
	$collmax = $interval_hash{$coll->{'max_interval_no'}}{'base_age'};
	# IMPORTANT: the collection's max age is truncated at the
	#   taxon's max first appearance
	if ( $collmax > $lb )	{
	    $collmax = $lb;
	}
	if ( $coll->{'min_interval_no'} == 0 )	{
	    $collmin = $interval_hash{$coll->{'max_interval_no'}}{'top_age'};
	    $last_name = $interval_hash{$coll->{'max_interval_no'}}{'interval_name'};
	} else	{
	    $collmin = $interval_hash{$coll->{'min_interval_no'}}{'top_age'};
	    $last_name = $interval_hash{$coll->{'min_interval_no'}}{'interval_name'};
	}
	# $coll->{'maximum Ma'} = $collmax;
	# $coll->{'minimum Ma'} = $collmin;
	# $coll->{'midpoint Ma'} = ( $collmax + $collmin ) / 2;
	if ( $minfirst == $collmin )	{
	    # if ( $coll->{'state'} && $coll->{'country'} eq "United States" )	{
	    # 	$coll->{'country'} = "US (".$coll->{'state'}.")";
	    # }
	    $first_interval_top = $last_name;
	    push @firsts , $coll;
	}
	# # randomization to break ties and account for uncertainty in
	# #  age estimates
	# for my $t ( 1..$TRIALS )
	# {
	#     push @{$rages[$t]} , rand($collmax - $collmin) + $collmin;
	# }
    }
    
    my $first_interval_base = $interval_hash{$max_no}{interval_name};
    my $last_interval = $interval_hash{$min_no}{interval_name};
    if ( $first_interval_base =~ /an$/ )	{
	$first_interval_base = "the ".$first_interval_base;
    }
    if ( $first_interval_top =~ /an$/ )	{
	$first_interval_top = "the ".$first_interval_top;
    }
    if ( $last_interval =~ /an$/ )	{
	$last_interval = "the ".$last_interval;
    }
    
    my $agerange = $lb - $ub;;
    if ( defined $params->{minimum_age} and $params->{minimum_age} > 0 )	{
	$agerange = $lb - $params->{minimum_age};
    }
    
    # for my $t ( 1..$TRIALS )	{
    # 	@{$rages[$t]} = sort { $b <=> $a } @{$rages[$t]};
    # }
    # for my $i ( 0..$#{$rages[1]} )	{
    # 	my $x = 0;
    # 	for my $t ( 1..$TRIALS )	{
    # 	    $x += $rages[$t][$i];
    # 	}
    # 	push @ages , $x / $TRIALS;
    # }
    # for my $i ( 0..$#ages-1 )	{
    # 	push @gaps , $ages[$i] - $ages[$i+1];
    # }
    # # shortest to longest
    # @gaps = sort { $a <=> $b } @gaps;
    
    # Now construct the output record.
    
    my $result = { firstapp_max => $first_interval_base,
		   firstapp_max_ma => sprintf("%.1f", $lb),
		   firstapp_min => $first_interval_top,
		   firstapp_min_ma => sprintf("%.1f", $minfirst),
		   lastapp => $last_interval,
		   lastapp_ma => sprintf("%.1f", $ub),
		   extant => $extant,
		   firstapp_ncoll => $ncoll,
		   firstapp_agerange => $agerange,
		 };
    
    # If more than one collection was found, add confidence intervals.
    
    # if ( $ncoll > 1 )
    # {
    # 	$result->{ci_labels} = [0.50, 0.90, 0.95, 0.99];
    # 	$result->{ci_continuous} = [Strauss2($lb, $ncoll, 0.50, 0.90, 0.95, 0.99)];
    # 	$result->{ci_percentile} = [percentile2($lb, \@gaps, 0.50, 0.90, 0.95, 0.99)];
    # 	$result->{ci_oldest_gap} = [Solow2($lb, \@ages, 0.50, 0.90, 0.95, 0.99)];
	
    # 	# Determine if there are rank-order correlations between time and gap size.
	
    # 	# convert to ranks by manipulating an array of objects
    # 	my @gapdata;
    # 	for my $i ( 0..$#ages-1 )
    # 	{
    # 	    $gapdata[$i]->{'age'} = $ages[$i];
    # 	    $gapdata[$i]->{'gap'} = $ages[$i] - $ages[$i+1];
    # 	}
    # 	@gapdata = sort { $b->{'age'} <=> $a->{'age'} } @gapdata;
    # 	for my $i ( 0..$#ages-1 )
    # 	{
    # 	    $gapdata[$i]->{'agerank'} = $i;
    # 	}
    # 	@gapdata = sort { $b->{'gap'} <=> $a->{'gap'} } @gapdata;
    # 	for my $i ( 0..$#ages-1 )
    # 	{
    # 		$gapdata[$i]->{'gaprank'} = $i;
    # 	}

    # 	my ($n,$mx,$my,$sx,$sy,$cov);
    # 	$n = $#ages;
    # 	if ( $n > 9 )
    # 	{
    # 	    for my $i ( 0..$#ages-1 )
    # 	    {
    # 		$mx += $gapdata[$i]->{'agerank'};
    # 		$my += $gapdata[$i]->{'gaprank'};
    # 	    }
    # 	    $mx /= $n;
    # 	    $my /= $n;
    # 	    for my $i ( 0..$#ages-1 )
    # 	    {
    # 		$sx += ($gapdata[$i]->{'agerank'} - $mx)**2;
    # 		$sy += ($gapdata[$i]->{'gaprank'} - $my)**2;
    # 		$cov += ($gapdata[$i]->{'agerank'} - $mx) * ( $gapdata[$i]->{'gaprank'} - $my);
    # 	    }
    # 	    $sx = sqrt( $sx / ( $n - 1 ) );
    # 	    $sy = sqrt( $sy / ( $n - 1 ) );
    # 	    my $r = $cov / ( ( $n - 1 ) * $sx * $sy );
    # 	    my $t = $r / sqrt( ( 1 - $r**2 ) / ( $n - 2 ) );
	    
    # 	    $result->{time_gap_r} = $r;
    # 	    $result->{time_gap_t} = $t;
    # 	    # for n > 9, the p < 0.001 critical values range from 3.291 to 4.587
    # 	}
    # }
    
    return $result;
}


sub intervalData {
    
    my ($dbh, $colls) = @_;
    
    my %is_no;
    $is_no{$_->{'max_interval_no'}}++ foreach @$colls;
    $is_no{$_->{'min_interval_no'}}++ foreach @$colls;
    delete $is_no{0};
    my $sql = "SELECT TRIM(CONCAT(i.eml_interval,' ',i.interval_name)) AS interval_name,i.interval_no,base_age,top_age FROM intervals i,interval_lookup l WHERE i.interval_no=l.interval_no AND i.interval_no IN (".join(',',keys %is_no).")";
    return @{$dbh->selectall_arrayref($sql, { Slice => {} })};
}


sub getAgeRange	{
	my ($dbh,$colls) = @_;
	
	return unless (@$colls);
	
	my $coll_list = join(',', map { $_ ->{'collection_no'} } @$colls);
	
	# get the youngest base age of any collection including this taxon
	# ultimately, the range's top must be this young or younger
	my $sql = "SELECT base_age AS maxtop FROM collections,interval_lookup WHERE max_interval_no=interval_no AND collection_no IN ($coll_list) ORDER BY base_age ASC LIMIT 1";
	my ($maxTop) = $dbh->selectrow_array($sql);
	
	# likewise the oldest top age
	# the range's base must be this old or older
	# the top is the top of the max_interval for collections having
	#  no separate max and min ages, but is the top of the min_interval
	#  for collections having different max and min ages
	$sql = "SELECT top_age AS minbase FROM ((SELECT top_age FROM collections,interval_lookup WHERE min_interval_no=0 AND max_interval_no=interval_no AND collection_no IN ($coll_list)) UNION (SELECT top_age FROM collections,interval_lookup WHERE min_interval_no>0 AND min_interval_no=interval_no AND collection_no IN ($coll_list))) AS ages ORDER BY top_age DESC LIMIT 1";
	my ($minBase) = $dbh->selectrow_array($sql);

	# now get the range top
	# note that the range top is the top of some collection's min_interval
	$sql = "SELECT MAX(top_age) top FROM ((SELECT top_age FROM collections,interval_lookup WHERE min_interval_no=0 AND max_interval_no=interval_no AND collection_no IN ($coll_list) AND top_age<$maxTop) UNION (SELECT top_age FROM collections,interval_lookup WHERE min_interval_no>0 AND min_interval_no=interval_no AND collection_no IN ($coll_list) AND top_age<$maxTop)) AS tops";
	my ($top) = $dbh->selectrow_array($sql);
	
	# and the range base
	$sql = "SELECT MIN(base_age) base FROM collections,interval_lookup WHERE max_interval_no=interval_no AND collection_no IN ($coll_list) AND base_age>$minBase LIMIT 1";
	my ($base) = $dbh->selectrow_array($sql);
	
	my (%is_max,%is_min);
	for my $c ( @$colls )	{
		$is_max{$c->{'max_interval_no'}}++;
		if ( $c->{'min_interval_no'} > 0 )	{
			$is_min{$c->{'min_interval_no'}}++;
		} else	{
			$is_min{$c->{'max_interval_no'}}++;
		}
	}

	# get the ID of the shortest interval whose base is equal to the
	#  range base and explicitly includes an occurrence
	$sql = "SELECT interval_no FROM interval_lookup WHERE interval_no IN (".join(',',keys %is_max).") AND base_age=$base ORDER BY top_age DESC LIMIT 1";
	my $oldest_interval_no = $dbh->selectrow_array($sql);

	# ditto for the shortest interval defining the top
	# only the ID number is needed
	$sql = "SELECT interval_no FROM interval_lookup WHERE interval_no IN (".join(',',keys %is_min).") AND top_age=$top ORDER BY base_age ASC LIMIT 1";
	my $youngest_interval_no = ${$dbh->selectcol_arrayref($sql)}[0];

	return($base,$top,$oldest_interval_no,$minBase,$maxTop,$youngest_interval_no);
}


# Generaterecord ( row, options )
# 
# Return a string representing one row of the result, in the selected output
# format.  The option 'is_first' indicates that this is the first
# record, which is significant for JSON output (it controls whether or not to
# output an initial comma, in that case).

sub generateRecord {

    my ($self, $row, %options) = @_;
    
    # If the content type is 'xml', then we need to check whether the result
    # includes a list of parents.  If so, because of the inflexibility of XML
    # and Darwin Core, we cannot output a hierarchical list.  The best we can
    # do is to output all of the parent records first, before the main record
    # (see http://eol.org/api/docs/hierarchy_entries).
    
    if ( $self->{output_format} eq 'xml' )
    {
	my $output = '';
	
	# If there are any parents, output them first with the "short record"
	# flag to indicate that many of the fields should be elided.  These
	# are not the primary object of the query, so less information needs
	# to be provided about them.
	
	if ( defined $self->{parents} && ref $self->{parents} eq 'ARRAY' )
	{
	    foreach my $parent_row ( @{$self->{parents}} )
	    {
		$output .= $self->emitTaxonXML($parent_row, 1);
	    }
	}
    
	# Now, we output the main record.
	
	$output .= $self->emitTaxonXML($row, 0);
	
	return $output;
    }
    
    # If the content type is 'txt', then we emit the record as a text line.
    
    elsif ( $self->{output_format} eq 'txt' or $self->{output_format} eq 'csv' )
    {
	my $output = $self->emitTaxonText($row);
	return $output;
    }
    
    # Otherwise, it must be JSON.  In that case, we need to insert a comma if
    # this is not the first record.  The subroutine emitTaxonJSON() will also
    # output the parent records, if there are any, as a sub-array.
    
    my $insert = ($options{is_first} ? '' : ',');
    
    return $insert . $self->emitTaxonJSON($row, $self->{parents});
}


# emitTaxonXML ( row, short_record )
# 
# Returns a string representing the given record (row) in Darwin Core XML
# format.  If 'short_record' is true, suppress certain fields.

my %fixbracket = ( '((' => '<', '))' => '>' );

sub emitTaxonXML {
    
    no warnings;
    
    my ($self, $row, $short_record) = @_;
    my $output = '';
    my @remarks = ();
    
    my $taxon_no = $self->{generate_urns}
	? DataQuery::generateURN($row->{taxon_no}, 'taxon_no')
	    : $row->{taxon_no};
    
    $output .= '  <dwc:Taxon>' . "\n";
    $output .= '    <dwc:taxonID>' . $taxon_no . '</dwc:taxonID>' . "\n";
    $output .= '    <dwc:taxonRank>' . $row->{taxon_rank} . '</dwc:taxonRank>' . "\n";
    
    # Taxon names shouldn't contain any invalid characters, but just in case...
    
    $output .= '    <dwc:scientificName>' . DataQuery::xml_clean($row->{taxon_name}) . 
	'</dwc:scientificName>' . "\n";
    
    # species have extra fields to indicate which genus, etc. they belong to
    
    if ( $row->{taxon_rank} =~ /species/ && !$short_record ) {
	my ($genus, $subgenus, $species, $subspecies) = interpretSpeciesName($row->{taxon_name});
	$output .= '    <dwc:genus>' . $genus . '</dwc:genus>' . "\n" if defined $genus;
	$output .= '    <dwc:subgenus>' . $subgenus . '</dwc:subgenus>' . "\n" if defined $subgenus;
	$output .= '    <dwc:specificEpithet>' . $species . '</dwc:specificEpithet>' . "\n" if defined $species;
	$output .= '    <dwc:infraSpecificEpithet>' . $subspecies . '</dwc:infraSpecificEpithet>' if defined $subspecies;
    }
    
    if ( defined $row->{parent_no} and $row->{parent_no} > 0 and not
	 ( $self->{suppress_synonym_parents} and defined $row->{accepted_no} ) and not
	 ( $self->{rooted_result} and ref $self->{root_taxa} and 
	   $self->{root_taxa}{$row->{taxon_no}} ) )
    {
	my $parent_no = $self->{generate_urns}
	    ? DataQuery::generateURN($row->{parent_no}, 'taxon_no')
		: $row->{parent_no};
	
	$output .= '    <dwc:parentNameUsageID>' . $parent_no . '</dwc:parentNameUsageID>' . "\n";
    }
    
    if ( defined $row->{parent_name} and $row->{parent_name} ne '' and $self->{show_parent_names} and not
	 ( $self->{suppress_synonym_parents} and defined $row->{accepted_no} ) and not
	 ( $self->{rooted_result} and ref $self->{root_taxa} and 
	   $self->{root_taxa}{$row->{taxon_no}} ) )
    {
    	$output .= '    <dwc:parentNameUsage>' . DataQuery::xml_clean($row->{parent_name}) . 
	    '</dwc:parentNameUsage>' . "\n";
    }
    
    if ( defined $row->{attribution} && $row->{attribution} ne '' )
    {
	$output .= '    <dwc:scientificNameAuthorship>' . DataQuery::xml_clean($row->{attribution}) .
	    '</dwc:scientificNameAuthorship>' . "\n";
    }
    
    if ( defined $row->{author1} && $row->{author1} ne '' ) {
	my $authorship = formatAuthorName($row->{author1}, $row->{author2}, $row->{otherauthors},
					  $row->{pubyr});
	$authorship = "($authorship)" if defined $row->{orig_no} &&
	    $row->{orig_no} > 0 && $row->{orig_no} != $row->{taxon_no};
	$authorship = DataQuery::xml_clean($authorship);
	$output .= '    <dwc:scientificNameAuthorship>' . $authorship . '</dwc:scientificNameAuthorship>' . "\n";
    }
    
    if ( defined $row->{taxonomic} ) {
	$output .= '    <dwc:taxonomicStatus>' . $row->{taxonomic} . '</dwc:taxonomicStatus>' . "\n";
    }
    
    if ( defined $row->{nomenclatural} ) {
	$output .= '    <dwc:nomenclaturalStatus>' . $row->{nomenclatural} . '</dwc:nomenclaturalStatus>' . "\n";
    }
    
    if ( defined $row->{nom_code} ) {
	$output .= '    <dwc:nomenclaturalCode>' . $row->{nom_code} . '</dwc:nomenclaturalCode>' . "\n";
    }
    
    if ( defined $row->{accepted_no} ) {
	my $accepted_no = $self->{generate_urns}
	    ? DataQuery::generateURN($row->{accepted_no}, 'taxon_no')
		: $row->{accepted_no};
	
	$output .= '    <dwc:acceptedNameUsageID>' . $accepted_no . '</dwc:acceptedNameUsageID>' . "\n";
    }
    
    if ( defined $row->{accepted_name} ) {
	# taxon names shouldn't contain any wide characters, but just in case...
	$output .= '    <dwc:acceptedNameUsage>' . DataQuery::xml_clean($row->{accepted_name}) . 
	    '</dwc:acceptedNameUsage>' . "\n";
    }
    
    if ( defined $row->{pubref} ) {
	my $pubref = DataQuery::xml_clean($row->{pubref});
	# We now need to translate, i.e. ((b)) to <b>.  This is done after
	# xml_clean, because otherwise <b> would be turned into &lt;b&gt;
	if ( $pubref =~ /\(\(/ )
	{
	    #$row->{pubref} =~ s/(\(\(|\)\))/$fixbracket{$1}/eg;
	    #actually, we're just going to take them out for now
	    $pubref =~ s/\(\(\/?\w*\)\)//g;
	}
	$output .= '    <dwc:namePublishedIn>' . $pubref . '</dwc:namePublishedIn>' . "\n";
    }
    
    if ( defined $row->{common_name} && $row->{common_name} ne '' ) {
	$output .= '    <dwc:vernacularName xml:lang="en">' . 
	    DataQuery::xml_clean($row->{common_name}) . '</dwc:vernacularName>' . "\n";
    }
    
    if ( defined $row->{extant} and $row->{extant} =~ /(yes|no)/i ) {
	push @remarks, "extant: $1";
    }
    
    if ( @remarks ) {
	my $remarks = join('; ', @remarks);
	$output .= '    <dwc:taxonRemarks>' . $remarks . '</dwc:taxonRemarks>' . "\n";
    }
    
    $output .= '  </dwc:Taxon>' . "\n";
}


# emitTaxonText ( row )
# 
# Return a string representing hte given record (row) in text format,
# according to a predetermined list of fields.

sub emitTaxonText {

    my ($self, $row) = @_;
    
    my (@output);
    
    # Now process each field one at a time, building up the output list as we go.
    
    foreach my $field (@{$self->{field_list}})
    {
	# First determine the value, according to the field name.
	
	my $value;
	
	if ( $field eq 'taxonID' )
	{
	    $value = $self->{generate_urns}
		? DataQuery::generateURN($row->{taxon_no}, 'taxon_no')
		    : $row->{taxon_no};
	}
	
	elsif ( $field eq 'taxonRank' )
	{
	    $value = $row->{taxon_rank};
	}
	
	elsif ( $field eq 'scientificName' )
	{
	    $value = DataQuery::xml_clean($row->{taxon_name})
		if defined $row->{taxon_name};
	    
	    # If we are generating the 'eol_core' format, we must include the
	    # attribution after the name.
	    
	    if ( $self->{eol_core} && defined $row->{attribution} )
	    {
		$value .= ' ' . DataQuery::xml_clean($row->{attribution});
	    }
	}
	
	elsif ( $field eq 'parentNameUsageID' )
	{
	    if ( defined $row->{parent_no} and $row->{parent_no} > 0 and not
		 ( $self->{suppress_synonym_parents} and defined $row->{accepted_no} ) and not
		 ( $self->{rooted_result} and ref $self->{root_taxa} and
		   $self->{root_taxa}{$row->{taxon_no}} ) )
	    {
		$value = $self->{generate_urns}
		    ? DataQuery::generateURN($row->{parent_no}, 'taxon_no')
			: $row->{parent_no};
	    }
	}
	
	elsif ( $field eq 'parentNameUsage' )
	{
	    if ( defined $row->{parent_name} and $row->{parent_name} ne '' and not
		 ( $self->{suppress_synonym_parents} and defined $row->{accepted_no} ) and not
		 ( $self->{rooted_result} and ref $self->{root_taxa} and
		   $self->{root_taxa}{$row->{taxon_no}} ) )
	    {
		$value = DataQuery::xml_clean($row->{parent_name});
	    }
	}
	
	elsif ( $field eq 'acceptedNameUsageID' )
	{
	    if ( defined $row->{accepted_no} and $row->{accepted_no} > 0 )
	    {
		$value = $self->{generate_urns}
		    ? DataQuery::generateURN($row->{accepted_no}, 'taxon_no')
			: $row->{accepted_no};
	    }
	}
	
	elsif ( $field eq 'acceptedNameUsage' )
	{
	    if ( defined $row->{accepted_name} and $row->{accepted_name} ne '' )
	    {
		$value = DataQuery::xml_clean($row->{accepted_name});
	    }
	}
	
	elsif ( $field eq 'taxonomicStatus' )
	{
	    $value = $row->{taxonomic};
	}
	
	elsif ( $field eq 'nomenclaturalStatus' )
	{
	    $value = $row->{nomenclatural};
	}
	
	elsif ( $field eq 'nomenclaturalCode' )
	{
	    $value = $row->{nom_code};
	}
	
	elsif ( $field eq 'nameAccordingTo' )
	{
	    $value = DataQuery::xml_clean($row->{attribution})
		if defined $row->{attribution};
	}
	
	elsif ( $field eq 'namePublishedIn' )
	{
	    $value = DataQuery::xml_clean($row->{pubref})
		if defined $row->{pubref};
	    
	    # We now need to translate, i.e. ((b)) to <b>.  This is done after
	    # xml_clean, because otherwise <b> would be turned into &lt;b&gt;
	    if ( defined $value and $value =~ /\(\(/ )
	    {
		$value =~ s/(\(\(|\)\))/$fixbracket{$1}/eg;
	    }
	}
	
	elsif ( $field eq 'vernacularName' )
	{
	    $value = DataQuery::xml_clean($row->{common_name}) 
		if defined $row->{common_name};
	}
	
	elsif ( $field eq 'extant' )
	{
	    $value = $row->{extant} if defined $row->{extant};
	}
	
	elsif ( $field eq 'taxonRemarks' )
	{
	    if ( defined $row->{extant} && $row->{extant} =~ /\w/ )
	    {
		$value = "extant: $row->{extant}";
	    }
	}
	
	elsif ( $field eq 'firstAppearanceMinMa' )
	{
	    $value = $row->{firstapp_min_ma} if defined $row->{firstapp_min_ma};
	}
	
	elsif ( $field eq 'firstAppearanceMin' )
	{
	    $value = $row->{firstapp_min} if defined $row->{firstapp_min};
	}
	
	elsif ( $field eq 'firstAppearanceMaxMa' )
	{
	    $value = $row->{firstapp_max_ma} if defined $row->{firstapp_max_ma};
	}
	
	elsif ( $field eq 'firstAppearanceMax' )
	{
	    $value = $row->{firstapp_max} if defined $row->{firstapp_max};
	}
	
	elsif ( $field eq 'lastAppearanceMa' )
	{
	    $value = $row->{lastapp_ma} if defined $row->{lastapp_ma};
	}
	
	elsif ( $field eq 'lastAppearance' )
	{
	    $value = $row->{lastapp} if defined $row->{lastapp};
	}
	
	elsif ( $field eq 'appearanceNColl' )
	{
	    $value = $row->{firstapp_ncoll} if defined $row->{firstapp_ncoll};
	}
	
	elsif ( $field eq 'ageRange' )
	{
	    $value = $row->{firstapp_agerange} if defined $row->{firstapp_agerange};
	}
	
	# Then append the value to the output list, or the empty string if
	# there is no value (or if, for some reason, it is a reference).  This is
	# necessary because each line has to have the same fields in the same
	# columns, even if some values are missing.
	
	if ( defined $value and ref $value eq '' )
	{
	    push @output, $value;
	}
	
	else
	{
	    push @output, '';
	}
    }
    
    # Now generate and return a line of text from the @output array.
    
    my $line = $self->generateTextLine(@output);
    return $line;
}

# emitTaxonJSON ( row, parents, short_record )
# 
# Return a string representing the given taxon record (row) in JSON format.
# If 'parents' is specified, it should be an array of hashes each representing
# a parent taxon record.  If 'short_record' is true, then some fields will be
# suppressed.

sub emitTaxonJSON {
    
    no warnings;
    
    my ($self, $row, $parents, $short_record) = @_;
    
    my $output = '';
    
    $output .= '{"taxonID":"' . $row->{taxon_no} . '"'; 
    $output .= ',"taxonRank":"' . $row->{taxon_rank} . '"';
    $output .= ',"scientificName":"' . DataQuery::json_clean($row->{taxon_name}) . '"';
    
    if ( defined $row->{attribution} && $row->{attribution} ne '' )
    {
	$output .= ',"scientificNameAuthorship":"' . DataQuery::json_clean($row->{attribution}) . '"';
    }
    
    if ( defined $row->{author1} && $row->{author1} ne '' ) {
	my $authorship = formatAuthorName($row->{author1}, $row->{author2}, $row->{otherauthors},
					  $row->{pubyr});
	$authorship = "($authorship)" if defined $row->{orig_no} &&
	    $row->{orig_no} > 0 && $row->{orig_no} != $row->{taxon_no};
	$output .= ',"scientificNameAuthorship":"' . DataQuery::json_clean($authorship) . '"';
    }
    
    if ( defined $row->{parent_no} && $row->{parent_no} > 0 and not
	 ( $self->{suppress_synonym_parents} and defined $row->{accepted_no} ) and not
	 ( $self->{rooted_result} and ref $self->{root_taxa} and
	   $self->{root_taxa}{$row->{taxon_no}} ) )
    {
	$output .= ',"parentNameUsageID":"' . $row->{parent_no} . '"';
    }
    
    if ( defined $row->{parent_name} and $row->{parent_name} ne '' and $self->{show_parent_names} and not
	 ( $self->{suppress_synonym_parents} and defined $row->{accepted_no} ) and not
	 ( $self->{rooted_result} and ref $self->{root_taxa} and
	   $self->{root_taxa}{$row->{taxon_no}} ) )
    {
	$output .= ',"parentNameUsage":"' . DataQuery::json_clean($row->{parent_name}) . '"';
    }
    
    if ( defined $row->{taxonomic} ) {
	$output .= ',"taxonomicStatus":"' . $row->{taxonomic} . '"';
    }
    
    if ( defined $row->{nomenclatural} ) {
	$output .= ',"nomenclaturalStatus":"' . $row->{nomenclatural} . '"';
    }
    
    if ( defined $row->{nom_code} ) {
	$output .= ',"nomenclaturalCode":"' . $row->{nom_code} . '"';
    }
    
    if ( defined $row->{accepted_no} ) {
	$output .= ',"acceptedNameUsageID":"' . $row->{accepted_no} . '"';
    }
    
    if ( defined $row->{accepted_name} ) {
	$output .= ',"acceptedNameUsage":"' . DataQuery::json_clean($row->{accepted_name}) . '"';
    }
    
    if ( defined $row->{pubref} )
    {
	$output .= ',"namePublishedIn":"' . DataQuery::json_clean($row->{pubref}) . '"';
    }
    
    if ( defined $row->{common_name} ne '' && $row->{common_name} ne '' ) {
	$output .= ',"vernacularName":"' . DataQuery::json_clean($row->{common_name}) . '"';
    }
    
    if ( defined $row->{extant} and $row->{extant} =~ /(yes|no)/i ) {
	$output .= ',"extant":"' . $1 . '"';
    }
    
    if ( defined $row->{firstapp_min} )
    {
	$output .= ',"firstAppearanceMin":"' . $row->{firstapp_min} . '"';
	$output .= ',"firstAppearanceMinMa":"' . $row->{firstapp_min_ma} . '"';
    }
    
    if ( defined $row->{firstapp_max} )
    {
	$output .= ',"firstAppearanceMax":"' . $row->{firstapp_max} . '"';
	$output .= ',"firstAppearanceMaxMa":"' . $row->{firstapp_max_ma} . '"';
    }
    
    if ( defined $row->{lastapp} )
    {
	$output .= ',"lastAppearance":"' . $row->{lastapp} . '"';
	$output .= ',"lastAppearanceMa":"' . $row->{lastapp_ma} . '"';
    }
    
    if ( defined $row->{lastapp_min} )
    {
	$output .= ',"lastAppearanceMin":"' . $row->{lastapp_min} . '"';
	$output .= ',"lastAppearanceMinMa":"' . $row->{lastapp_min_ma} . '"';
    }
    
    if ( defined $row->{lastapp_max} )
    {
	$output .= ',"lastAppearanceMin":"' . $row->{lastapp_max} . '"';
	$output .= ',"lastAppearanceMinMa":"' . $row->{lastapp_max_ma} . '"';
    }
    
    if ( defined $row->{firstapp_ncoll} )
    {
	$output .= ',"appearanceNColl":"' . $row->{firstapp_ncoll} . '"';
    }
    
    if ( defined $row->{firstapp_agerange} )
    {
	$output .= ',"ageRange":"' . $row->{firstapp_agerange} . '"';
    }
    
    if ( defined $row->{firstapp_oldest_gap} )
    {
	$output .= ',"oldestGap":"' . $row->{firstapp_oldest_gap} . '"';
    }
    
    if ( defined $parents && ref $parents eq 'ARRAY' )
    {
	my $is_first_parent = 1;
	$output .= ',"ancestors":[';
	
	foreach my $parent_row ( @{$self->{parents}} )
	{
	    $output .= ( $is_first_parent ? "\n" : "\n," );
	    $output .= $self->emitTaxonJSON($parent_row);
	    $is_first_parent = 0;
	}
	
	$output .= ']';
    }
    
    $output .= "}";
    return $output;
}


# formatAuthorName ( author1last, author2last, otherauthors, pubyr, orig_no )
# 
# Format the given info into a single string that can be output as the
# attribution of a taxon.

sub formatAuthorName {
    
    no warnings;
    
    my ($author1last, $author2last, $otherauthors, $pubyr) = @_;
    
    my $a1 = defined $author1last ? $author1last : '';
    my $a2 = defined $author2last ? $author2last : '';
    
    $a1 =~ s/( Jr)|( III)|( II)//;
    $a1 =~ s/\.$//;
    $a1 =~ s/,$//;
    $a1 =~ s/\s*$//;
    $a2 =~ s/( Jr)|( III)|( II)//;
    $a2 =~ s/\.$//;
    $a2 =~ s/,$//;
    $a2 =~ s/\s*$//;
    
    my $shortRef = $a1;
    
    if ( $otherauthors ne '' ) {
        $shortRef .= " et al.";
    } elsif ( $a2 ) {
        # We have at least 120 refs where the author2last is 'et al.'
        if ( $a2 !~ /^et al/i ) {
            $shortRef .= " and $a2";
        } else {
            $shortRef .= " et al.";
        }
    }
    if ($pubyr) {
	$shortRef .= " " . $pubyr;
    }
    
    return $shortRef;
}


# interpretSpeciesName ( taxon_name )
# 
# Separate the given name into genus, subgenus, species and subspecies.

sub interpretSpeciesName {

    my ($taxon_name) = @_;
    my @components = split(/\s+/, $taxon_name);
    
    my ($genus, $subgenus, $species, $subspecies);
    
    # If the first character is a space, the first component will be blank;
    # ignore it.
    
    shift @components if @components && $components[0] eq '';
    
    # If there's nothing left, we were given bad input-- return nothing.
    
    return unless @components;
    
    # The first component is always the genus.
    
    $genus = shift @components;
    
    # If the next component starts with '(', it is a subgenus.
    
    if ( @components && $components[0] =~ /^\((.*)\)$/ )
    {
	$subgenus = $1;
	shift @components;
    }
    
    # The next component must be the species
    
    $species = shift @components if @components;
    
    # The last component, if there is one, must be the subspecies.  Strip
    # parentheses if there are any.
    
    $subspecies = shift @components if @components;
    
    if ( defined $subspecies && $subspecies =~ /^\((.*)\)$/ ) {
	$subspecies = $1;
    }
    
    return ($genus, $subgenus, $species, $subspecies);
}


# The following hashes map the status codes stored in the opinions table of
# PaleoDB into taxonomic and nomenclatural status codes in compliance with
# Darwin Core.  The third one, %REPORT_ACCEPTED_TAXON, indicates which status
# codes should trigger the "acceptedUsage" and "acceptedUsageID" fields in the
# output.

our (%TAXONOMIC_STATUS) = (
	'belongs to' => 'valid',
	'subjective synonym of' => 'heterotypic synonym',
	'objective synonym of' => 'homotypic synonym',
	'invalid subgroup of' => 'invalid',
	'misspelling of' => 'invalid',
	'replaced by' => 'invalid',
	'nomen dubium' => 'invalid',
	'nomen nudum' => 'invalid',
	'nomen oblitum' => 'invalid',
	'nomen vanum' => 'invalid',
);


our (%NOMENCLATURAL_STATUS) = (
	'invalid subgroup of' => 'invalid subgroup',
	'misspelling of' => 'misspelling',
	'replaced by' => 'replaced by',
	'nomen dubium' => 'nomen dubium',
	'nomen nudum' => 'nomen nudum',
	'nomen oblitum' => 'nomen oblitum',
	'nomen vanum' => 'nomen vanum',
);


our (%REPORT_ACCEPTED_TAXON) = (
	'subjective synonym of' => 1,
	'objective synonym of' => 1,
	'misspelling of' => 1,
	'replaced by' => 1,
);


# interpretStatusCode ( pbdb_status )
# 
# Use the hashes given above to interpret a status code from the opinions
# table of PaleoDB.  Returns: taxonomic status, whether we should report an
# "acceptedUsage" taxon, and the nomenclatural status.

sub interpretStatusCode {

    my ($pbdb_status) = @_;
    
    # If the status is empty, return nothing.
    
    unless ( defined $pbdb_status and $pbdb_status ne '' )
    {
	return '', '', '';
    }
    
    # Otherwise, interpret the status code according to the mappings specified
    # above.
    
    return $TAXONOMIC_STATUS{$pbdb_status}, $REPORT_ACCEPTED_TAXON{$pbdb_status}, 
	$NOMENCLATURAL_STATUS{$pbdb_status};
}


1;
