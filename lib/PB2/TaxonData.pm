#
# TaxonData
# 
# A class that returns information from the PaleoDB database about a single
# taxon or a category of taxa.  This is a subclass of DataService::Base.
# 
# Author: Michael McClennen

use strict;

use lib '..';

package PB2::TaxonData;

use HTTP::Validate qw(:validators);
use Carp qw(carp croak);
use Try::Tiny;

use TaxonDefs qw(%TAXON_TABLE %TAXON_RANK %RANK_STRING %TAXONOMIC_STATUS %NOMENCLATURAL_STATUS);
use TableDefs qw($PHYLOPICS $PHYLOPIC_NAMES %IDP VALID_IDENTIFIER);
use Taxonomy;

use Moo::Role;


our (@REQUIRES_ROLE) = qw(PB2::CommonData PB2::ReferenceData PB2::IntervalData);

our (%DB_FIELD);

our (@BASIC_MAP);

# This routine is called by the data service in order to initialize this
# class.

sub initialize {
    
    my ($class, $ds) = @_;
    
    # First define an output map to specify which output blocks are going to
    # be used to generate output from the operations defined in this class.
    
    @BASIC_MAP = (
	{ value => 'app', maps_to => '1.2:taxa:app' },
	    "The age of first and last appearance of this taxon from the occurrences",
	    "recorded in this database.",
	{ value => 'common' },
	    "The common name of this taxon, if one is entered in the database.",
	{ value => 'parent', maps_to => '1.2:taxa:parent' },
	    "If the classification of this taxon has been entered into the database,",
	    "the name of the parent taxon, or its senior synonym if there is one.",
	{ value => 'immparent', maps_to => '1.2:taxa:immpar' },
	    "You can use this isntead of C<parent> if you wish to know the immediate",
	    "parent taxon.  If the immediate parent is a junior synonym, both it and",
	    "its senior synonym will be displayed.", 
	{ value => 'size', maps_to => '1.2:taxa:size' },
	    "The number of subtaxa appearing in this database, including the taxon itself.",
	{ value => 'class', maps_to => '1.2:taxa:phylo' },
	    "The classification of this taxon: kingdom, phylum, class, order, family.",
	    "This information is also included in the C<nav> block, so do not specify both at once.",
	{ value => 'phylo', maps_to => '1.2:taxa:phylo', undocumented => 1 },
	{ value => 'genus', maps_to => '1.2:taxa:genus', undocumented => 1 },
	    "The genus into which this taxon is classified, if its rank is genus or below.",
	{ value => 'subgenus', maps_to => '1.2:taxa:genus', undocumented => 1 },
	    "The genus into which this taxon is classified, including the subgenus if any.",
	{ value => 'subcounts', maps_to => '1.2:taxa:subcounts' },
	    "The number of subtaxa known to this database, summarized by rank.",
	{ value => 'ecospace', maps_to => '1.2:taxa:ecospace' },
	    "Information about ecological space that this organism occupies or occupied.",
	    "This has only been filled in for a relatively few taxa.  Here is a",
	    "L<list of values|node:taxa/ecotaph_values>.",
	{ value => 'taphonomy', maps_to => '1.2:taxa:taphonomy' },
	    "Information about the taphonomy of this organism.  Here is a",
	    "L<list of values|node:taxa/ecotaph_values>.",
	{ value => 'etbasis', maps_to => '1.2:taxa:etbasis' },
	    "Annotates the output block C<ecospace>, indicating at which",
	    "taxonomic level each piece of information was entered.",
	{ value => 'nav', maps_to => '1.2:taxa:nav' },
	    "Additional information for the PBDB Navigator taxon browser.",
	    "This block should only be selected if the output format is C<json>.",
	{ value => 'img', maps_to => '1.2:taxa:img' },
	    "The identifier of the image (if any) associated with this taxon.",
	    "These images are sourced from L<phylopic.org>.",
	{ value => 'ent', maps_to => '1.2:common:ent' },
	    "The identifiers of the people who authorized, entered and modified this record",
	{ value => 'entname', maps_to => '1.2:common:entname' },
	    "The names of the people who authorized, entered and modified this record",
        { value => 'crmod', maps_to => '1.2:common:crmod' },
	    "The C<created> and C<modified> timestamps for the collection record");
    
    $ds->define_output_map('1.2:taxa:output_map' =>
	{ value => 'attr', maps_to => '1.2:taxa:attr' },
	    "The attribution of this taxon (author and year)",
	@BASIC_MAP);
    
    # Now define all of the output blocks that were not defined elsewhere.
    
    $ds->define_block('1.2:taxa:basic' =>
	{ select => ['DATA'] },
	{ set => '*', code => \&process_pbdb, if_vocab => 'pbdb' },
	{ set => '*', code => \&process_com, if_vocab => 'com' },
	{ output => 'orig_no', dwc_name => 'taxonID', com_name => 'oid' },
	    "A unique identifier for this taxonomic name",
	{ output => 'taxon_no', com_name => 'vid', not_field => 'no_variant' },
	    "A unique identifier for the selected variant",
	    "of this taxonomic name.  By default, this is the variant currently",
	    "accepted as most correct.",
	{ output => 'record_type', com_name => 'typ', value => $IDP{TXN}, dwc_value => 'Taxon' },
	    "The type of this object: C<$IDP{TXN}> for an occurrence.",
	{ output => 'exclude', com_name => 'exc' },
	    "This field will have a true value if the taxon represents an excluded group within another taxon.",
	{ set => 'taxon_rank', if_vocab => 'pbdb,dwc', lookup => \%RANK_STRING },
	{ output => 'taxon_rank', dwc_name => 'taxonRank', com_name => 'rnk' },
	    "The rank of this taxon, ranging from subspecies up to kingdom",
	{ output => 'taxon_name', dwc_name => 'scientificName', com_name => 'nam' },
	    "The scientific name of this taxon",
	#{ set => 'attribution', if_field => 'a_al1', from => '*', 
	#  code => \&PB2::CommonData::generateAttribution },
	{ output => 'attribution', if_block => 'attr', 
	  dwc_name => 'scientificNameAuthorship', com_name => 'att' },
	    "The attribution (author and year) of this taxonomic name",
	{ output => 'pubyr', if_block => 'attr', 
	  dwc_name => 'namePublishedInYear', com_name => 'pby' },
	    "The year in which this name was published",
	{ output => 'common_name', dwc_name => 'vernacularName', com_name => 'nm2', if_block => 'common' },
	    "The common (vernacular) name of this taxon, if any",
	{ output => 'status', com_name => 'sta' },
	    "The taxonomic status of this name",
	{ set => 'tax_status', from => 'status', lookup => \%TAXONOMIC_STATUS, if_vocab => 'dwc' },
	{ output => 'tax_status', dwc_name => 'taxonomicStatus', if_vocab => 'dwc' },
	    "The taxonomic status of this name, in the Darwin Core vocabulary.",
	    "This field only appears if that vocabulary is selected.",
	{ set => 'nom_status', from => 'status', lookup => \%NOMENCLATURAL_STATUS, if_vocab => 'dwc' },
	{ output => 'nom_status', dwc_name => 'nomenclaturalStatus', if_vocab => 'dwc' },
	    "The nomenclatural status of this name, in the Darwin Core vocabulary.",
	    "This field only appears if that vocabulary is selected.",
	{ output => 'accepted_no', dwc_name => 'acceptedNameUsageID', pbdb_name => 'accepted_no', 
	  com_name => 'acc', dedup => 'orig_no' },
	    "If this name is either a junior synonym or an invalid name, the identifier",
	    "of the accepted name to be used in its place.",
	{ output => 'accepted_name', dwc_name => 'acceptedNameUsage', pbdb_name => 'accepted_name',
	  com_name => 'acn', dedup => 'taxon_name' },
	    "If this name is either a junior synonym or an invalid name, the accepted name",
	    "that should be used in its place.",
	{ output => 'senpar_no', dwc_name => 'parentNameUsageID', com_name => 'par' }, 
	    "The identifier of the parent taxon, or of its senior synonym if there is one.",
	    "This field and those following are only available if the classification of",
	    "this taxon is known to the database.",
	{ output => 'senpar_name', com_name => 'prl', pbdb_name => 'senpar_name', if_block => 'parent,immparent' },
	    "The name of the parent taxon, or of its senior synonym if there is one.",
	{ output => 'parent_no', dwc_name => 'parentNameUsageID', com_name => 'ipn',
	  pbdb_name => 'immpar_no', if_block => 'immparent', dedup => 'senpar_no' },
	    "The identifier of the immediate parent taxon, even if it is a junior synonym.",
	{ output => 'immpar_name', dwc_name => 'parentNameUsageID', com_name => 'ipl',
	  if_block => 'immparent', dedup => 'senpar_name' },
	    "The name of the immediate parent taxon, even if it is a junior synonym.",
	{ output => 'reference_no', com_name => 'rid', show_as_list => 1 },
	    "A list of identifiers indicating the source document(s) from which this name was entered.",
	{ output => 'is_extant', com_name => 'ext', dwc_name => 'isExtant' },
	    "True if this taxon is extant on earth today, false if not, not present if unrecorded",
	{ output => 'n_occs', com_name => 'noc' },
	    "The number of fossil occurrences in this database that are identified",
	    "as belonging to this taxon or any of its subtaxa.");
    
    $ds->define_block('1.2:taxa:attr' =>
	{ select => 'ATTR' });
    
    $ds->define_block('1.2:taxa:parent' =>
	{ select => 'SENPAR' });
    
    $ds->define_block('1.2:taxa:immpar' =>
	{ select => 'SENPAR,IMMPAR' });
    
    $ds->define_block('1.2:taxa:size' =>
	{ select => 'SIZE' },
	{ output => 'n_occs', com_name => 'noc' },
	    "The number of occurrences in the database that are identified as being contained within",
	    "this taxon",
	{ output => 'taxon_size', com_name => 'siz' },
	    "The total number of taxa in the database that are contained within this taxon, including itself",
	{ output => 'extant_size', com_name => 'exs' },
	    "The total number of extant taxa in the database that are contained within this taxon, including itself");
    
    $ds->define_block('1.2:taxa:app' =>
	{ select => 'APP' },
	{ output => 'firstapp_ea', name => 'first_max_ma', com_name => 'fea', dwc_name => 'firstAppearanceEarlyAge', 
	  if_block => 'app' },
	    "The early age bound for the first appearance of this taxon in the database",
	{ output => 'firstapp_la', name => 'first_min_ma', com_name => 'fla', dwc_name => 'firstAppearanceLateAge', 
	  if_block => 'app' }, 
	    "The late age bound for the first appearance of this taxon in the database",
	{ output => 'lastapp_ea', name => 'last_max_ma', com_name => 'lea', dwc_name => 'lastAppearanceEarlyAge',
	  if_block => 'app' },
	    "The early age bound for the last appearance of this taxon in the database",
	{ output => 'lastapp_la', name => 'last_min_ma', com_name => 'lla', dwc_name => 'lastAppearanceLateAge',
	  if_block => 'app' }, 
	    "The late age bound for the last appearance of this taxon in the database",
	{ output => 'early_interval', com_name => 'eal' },
	    "The name of the interval in which this taxon first appears, or the start of its range.",
	{ output => 'late_interval', com_name => 'lal', dedup => 'early_interval' },
	    "The name of the interval in which this taxon last appears, if different from C<early_interval>.");
    
    $ds->define_block('1.2:taxa:occapp' =>
	{ output => 'firstocc_ea', name => 'firstocc_max_ma', com_name => 'foa', dwc_name => 'firstAppearanceEarlyAge' },
	    "The early age bound for the first appearance of this taxon in the set of",
	    "occurrences being analyzed.",
	{ output => 'firstocc_la', name => 'first_min_ma', com_name => 'fpa', dwc_name => 'firstAppearanceLateAge' }, 
	    "The late age bound for the first appearance of this taxon in the set of",
	    "occurrences being analyzed.",
	{ output => 'lastocc_ea', name => 'last_max_ma', com_name => 'loa', dwc_name => 'lastAppearanceEarlyAge' },
	    "The early age bound for the last appearance of this taxon in the set of",
	    "occurrences being analyzed.",
	{ output => 'lastocc_la', name => 'last_min_ma', com_name => 'lpa', dwc_name => 'lastAppearanceLateAge' }, 
	    "The late age bound for the last appearance of this taxon in the set of",
	    "occurrences being analyzed.",
	{ output => 'occ_early_interval', com_name => 'eol' },
	    "The name of the interval in which this taxon first appears, or the start of its range.",
	{ output => 'occ_late_interval', com_name => 'lol', dedup => 'early_interval' },
	    "The name of the interval in which this taxon last appears, if different from C<early_interval>.");
    
    $ds->define_block('1.2:taxa:subtaxon' =>
	{ output => 'orig_no', com_name => 'oid', dwc_name => 'taxonID' },
	{ output => 'taxon_no', com_name => 'vid', not_field => 'no_variant' },
	{ output => 'record_type', com_name => 'typ', com_value => 'txn' },
	{ output => 'taxon_rank', com_name => 'rnk', dwc_name => 'taxonRank' },
	{ output => 'taxon_name', com_name => 'nam', dwc_name => 'scientificName' },
	{ output => 'accepted_no', com_name => 'acc', dwc_name => 'acceptedNameUsageID', dedup => 'orig_no' },
	{ output => 'taxon_size', com_name => 'siz' },
	{ output => 'extant_size', com_name => 'exs' },
	{ output => 'firstapp_ea', com_name => 'fea' });
    
    $ds->define_block('1.2:taxa:phylo' =>
	{ select => 'CLASS' },
	{ output => 'kingdom', com_name => 'kgl' },
	    "The name of the kingdom in which this taxon occurs",
	{ output => 'phylum', com_name => 'phl' },
	    "The name of the phylum in which this taxon occurs",
	{ output => 'class', com_name => 'cll' },
	    "The name of the class in which this taxon occurs",
	{ output => 'order', com_name => 'odl' },
	    "The name of the order in which this taxon occurs",
	{ output => 'family', com_name => 'fml' },
	    "The name of the family in which this taxon occurs");
    
    $ds->define_block('1.2:taxa:genus' =>
	{ select => 'GENUS' },
	{ set => '*', code => \&process_subgenus, if_block => 'subgenus' },
	{ output => 'genus', com_name => 'gnl' },
	    "The name of the genus in which this taxon occurs.  If the block C<subgenus>",
	    "was included, the value of this field will include the subgenus if any.");
    
    $ds->define_block('1.2:taxa:subcounts' => 
	{ select => 'COUNTS' },
	{ output => 'n_orders', com_name => 'odc' },
	    "The number of orders within this taxon.  For lists of taxa derived",
	    "from a set of occurrences, this will be the number of orders that",
	    "appear within that set.  Otherwise, this will be the total number",
	    "of orders within this taxon that are known to the database.",
	{ output => 'n_families', com_name => 'fmc' },
	    "The number of families within this taxon, according to the same rules",
	    "as C<n_orders> above.",
	{ output => 'n_genera', com_name => 'gnc' },
	    "The number of genera within this taxon, according to the same rules",
	    "as C<n_orders> above.",
	{ output => 'n_species', com_name => 'spc' },
	    "The number of species within this taxon, according to the same rules",
	    "as C<n_orders> above.");
    
    $ds->define_block('1.2:taxa:nav' =>
	{ select => ['SENPAR', 'IMMPAR', 'CLASS', 'COUNTS'] },
	{ output => 'senpar_name', com_name => 'prl' },
	    "The name of the parent taxon or its senior synonym if any",
	{ output => 'senpar_rank', com_name => 'prr' },
	    "The rank of the parent taxon or its senior synonym if any",
	{ output => 'immpar_name', com_name => 'ipl', dedup => 'prl' },
	    "The name of the immediate parent taxon if it is a junior synonym",
	{ output => 'parent_txn', com_name => 'prt', sub_record => '1.2:taxa:subtaxon' },
	{ output => 'kingdom_no', com_name => 'kgn' },
	    "The identifier of the kingdom in which this taxon occurs",
	{ output => 'kingdom', com_name => 'kgl' },
	    "The name of the kingdom in which this taxon occurs",
	{ output => 'kingdom_txn', com_name => 'kgt', sub_record => '1.2:taxa:subtaxon' },
	{ output => 'phylum_no', com_name => 'phn' },
	    "The identifier of the phylum in which this taxon occurs",
	{ output => 'phylum', com_name => 'phl' },
	    "The name of the phylum in which this taxon occurs",
	{ output => 'phylum_txn', com_name => 'pht', sub_record => '1.2:taxa:subtaxon' },
	{ output => 'phylum_count', com_name => 'phc' },
	    "The number of phyla within this taxon",
	{ output => 'class_no', com_name => 'cln' },
	    "The identifier of the class in which this taxon occurs",
	{ output => 'class', com_name => 'cll' },
	    "The name of the class in which this taxon occurs",
	{ output => 'class_txn', com_name => 'clt', sub_record => '1.2:taxa:subtaxon' },
	{ output => 'class_count', com_name => 'clc' },
	    "The number of classes within this taxon",
	{ output => 'order_no', com_name => 'odn' },
	    "The identifier of the order in which this taxon occurs",
	{ output => 'order', com_name => 'odl' },
	    "The name of the order in which this taxon occurs",
	{ output => 'order_txn', com_name => 'odt', sub_record => '1.2:taxa:subtaxon' },
	{ output => 'order_count', com_name => 'odc' },
	    "The number of orders within this taxon",
	{ output => 'family_no', com_name => 'fmn' },
	    "The identifier of the family in which this taxon occurs",
	{ output => 'family', com_name => 'fml' },
	    "The name of the family in which this taxon occurs",
	{ output => 'family_txn', com_name => 'fmt', sub_record => '1.2:taxa:subtaxon' },
	{ output => 'family_count', com_name => 'fmc' },
	    "The number of families within this taxon",
	{ output => 'genus_count', com_name => 'gnc' },
	    "The number of genera within this taxon",
    
	{ output => 'children', com_name => 'chl', sub_record => '1.2:taxa:subtaxon' },
	    "The immediate children of this taxonomic concept, if any",
	{ output => 'phylum_list', com_name => 'phs', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the phyla within this taxonomic concept",
	{ output => 'class_list', com_name => 'cls', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the classes within this taxonomic concept",
	{ output => 'order_list', com_name => 'ods', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the orders within this taxonomic concept",
	{ output => 'family_list', com_name => 'fms', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the families within this taxonomic concept",
	{ output => 'genus_list', com_name => 'gns', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the genera within this taxonomic concept",
	{ output => 'subgenus_list', com_name => 'sgs', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the subgenera within this taxonomic concept",
	{ output => 'species_list', com_name => 'sps', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the species within this taxonomic concept",
 	{ output => 'subspecies_list', com_name => 'sss', sub_record => '1.2:taxa:subtaxon' },
	    "A list of the subspecies within this taxonomic concept");
    
    $ds->define_block('1.2:taxa:img' =>
	{ select => 'image_no' },
	{ output => 'image_no', com_name => 'img' },
    	    "If this value is non-zero, you can use it to construct image URLs",
	    "using L<taxa/thumb|node:taxa/thumb> and L<taxa/icon|node:taxa/icon>.");
    
    $ds->define_block('1.2:taxa:reftaxa' =>
	{ select => ['REFTAXA_DATA'] },
	{ set => '*', code => \&process_pbdb, if_vocab => 'pbdb' },
	{ set => '*', code => \&process_com, if_vocab => 'com' },
	{ output => 'reference_no', com_name => 'rid' },
	    "The identifier of a reference in which this taxonomic name was listed.",
	{ output => 'orig_no', dwc_name => 'taxonID', com_name => 'tid' },
	    "A unique identifier for this taxonomic name",
	{ output => 'taxon_no', com_name => 'vid', not_field => 'no_variant' },
	    "A unique identifier for the variant of this taxonomic name that was actually",
	    "mentioned in the reference.",
	{ output => 'record_type', com_name => 'typ', value => $IDP{TXN}, dwc_value => 'Taxon' },
	    "The type of this object: C<$IDP{TXN}> for an occurrence.",
	{ set => 'taxon_rank', if_vocab => 'pbdb,dwc', lookup => \%RANK_STRING },
	{ output => 'taxon_rank', dwc_name => 'taxonRank', com_name => 'rnk' },
	    "The rank of this taxon as mentioned in the reference, ranging from subspecies up to kingdom",
	{ output => 'taxon_name', dwc_name => 'scientificName', com_name => 'nam' },
	    "The taxonomic name actually mentioned in the reference.",
	{ output => 'attribution', if_block => 'attr', 
	  dwc_name => 'scientificNameAuthorship', com_name => 'att' },
	    "The attribution (author and year) of this taxonomic name",
	{ output => 'pubyr', if_block => 'attr', 
	  dwc_name => 'namePublishedInYear', com_name => 'pby' },
	    "The year in which this name was published",
	{ output => 'common_name', dwc_name => 'vernacularName', com_name => 'nm2', if_block => 'common' },
	    "The common (vernacular) name of this taxon, if any",
	{ output => 'status', com_name => 'sta', if_block => 'full' },
	    "The taxonomic status of this name",
	{ set => 'tax_status', from => 'status', lookup => \%TAXONOMIC_STATUS, if_vocab => 'dwc', 
	  if_block => 'full' },
	{ output => 'tax_status', dwc_name => 'taxonomicStatus', if_vocab => 'dwc', if_block => 'full' },
	    "The taxonomic status of this name, in the Darwin Core vocabulary.",
	    "This field only appears if that vocabulary is selected.",
	{ set => 'nom_status', from => 'status', lookup => \%NOMENCLATURAL_STATUS, if_vocab => 'dwc',
	  if_block => 'full' },
	{ output => 'nom_status', dwc_name => 'nomenclaturalStatus', if_vocab => 'dwc', if_block => 'full' },
	    "The nomenclatural status of this name, in the Darwin Core vocabulary.",
	    "This field only appears if that vocabulary is selected.",
	{ output => 'accepted_no', dwc_name => 'acceptedNameUsageID', pbdb_name => 'accepted_no', 
	  com_name => 'acc', dedup => 'orig_no' },
	    "If this name is either a junior synonym or an invalid name, the identifier",
	    "of the accepted name to be used in its place.",
	{ output => 'accepted_name', dwc_name => 'acceptedNameUsage', pbdb_name => 'accepted_name',
	  com_name => 'acn', dedup => 'taxon_name' },
	    "If this name is either a junior synonym or an invalid name, the accepted name",
	    "that should be used in its place.",
	{ output => 'senpar_no', dwc_name => 'parentNameUsageID', com_name => 'par', if_block => 'full' }, 
	    "The identifier of the parent taxon, or of its senior synonym if there is one.",
	    "This field and those following are only available if the classification of",
	    "this taxon is known to the database.",
	{ output => 'senpar_name', com_name => 'prl', pbdb_name => 'senpar_name', if_block => 'parent,immparent' },
	    "The name of the parent taxon, or of its senior synonym if there is one.",
	{ output => 'parent_no', dwc_name => 'parentNameUsageID', com_name => 'ipn', if_block => 'full',
	  pbdb_name => 'immpar_no', if_block => 'immparent', dedup => 'senpar_no' },
	    "The identifier of the immediate parent taxon, even if it is a junior synonym.",
	{ output => 'immpar_name', dwc_name => 'parentNameUsageID', com_name => 'ipl',
	  if_block => 'immparent', dedup => 'senpar_name' },
	    "The name of the immediate parent taxon, even if it is a junior synonym.",
	{ output => 'is_extant', com_name => 'ext', dwc_name => 'isExtant', if_block => 'full' },
	    "True if this taxon is extant on earth today, false if not, not present if unrecorded",
	{ output => 'n_occs', com_name => 'noc', if_block => 'full' },
	    "The number of fossil occurrences in this database that are identified",
	    "as belonging to this taxon or any of its subtaxa.");
    
    $ds->define_block('1.2:taxa:auto' =>
	{ output => 'taxon_no', dwc_name => 'taxonID', com_name => 'oid' },
	    "A positive integer that uniquely identifies this taxonomic name",
	{ output => 'record_type', com_name => 'typ', com_value => 'txn', dwc_value => 'Taxon', value => 'taxon' },
	    "The type of this object: {value} for a taxonomic name",
	{ set => 'taxon_rank', if_vocab => 'com', lookup => \%TAXON_RANK },
	{ output => 'taxon_rank', dwc_name => 'taxonRank', com_name => 'rnk' },
	    "The taxonomic rank of this name",
	{ output => 'taxon_name', dwc_name => 'scientificName', com_name => 'nam' },
	    "The scientific name of this taxon",
	{ output => 'misspelling', com_name => 'msp' },
	    "If this name is marked as a misspelling, then this field will be included with the value '1'",
	{ output => 'n_occs', com_name => 'noc' },
	    "The number of occurrences of this taxon in the database");
    
    $ds->define_block('1.2:taxa:imagedata' =>
	{ select => [ 'image_no', 'uid', 'modified', 'credit', 'license' ] },
	{ output => 'image_no', com_name => 'oid' },
	    "A unique identifier for this image, generated locally by this database",
	{ output => 'type', value => 'image', com_name => 'typ', com_value => 'img' },
	    "The type of this record: 'img' for an image",
	{ output => 'taxon_no', com_name => 'tid' },
	    "The identifier of the taxon with which this image is associated.  This",
	    "field will only appear in results generated by L<taxa/list_images|node:taxa/list_images>.",
	{ output => 'taxon_name', com_name => 'tna' },
	    "The taxonomic name with which this image is associated.  This field",
	    "will only appear in results generated by L<taxa/list_images|node:taxa/list_images>.",
	{ output => 'uid', com_name => 'uid' },
	    "A unique identifier for this image generated by phylopic.org",
	{ output => 'modified', com_name => 'dmd' },
	    "The date and time at which this image was last modified on phylopic.org",
	{ output => 'credit', com_name => 'crd' },
	    "The name to which this image should be credited if used",
	{ output => 'license', com_name => 'lic' },
	    "A URL giving the license terms under which this image may be used");
    
    $ds->define_block('1.2:taxa:ecospace' =>
	{ select => 'ECOSPACE' },
	# { output => 'environment', com_name => 'jnv', disabled => 1 },
	#     "The general environment or environments in which this life form is found.",
	#     "Here is a L<list of values|node:taxa/ecotaph_values>.",
	{ output => 'motility', com_name => 'jmo' },
	    "Whether the organism is motile, attached and/or epibiont, and its",
	    "mode of locomotion if any.",
	{ output => 'motility_basis', com_name => 'jmc',
	  if_block => 'etbasis', if_format => ['txt', 'csv', 'tsv'] },
	    "Specifies the taxon for which the motility information was set.",
	    "For L<JSON|node:formats/json> responses, the fields 'jmb' and 'jmn'",
	    "give the taxon identifier and taxon name respectively, while for",
	    "L<text|node:formats/text> responses, the field 'motility_basis'",
	    "provides both.  These fields are only included if the C<ecospace> output",
	    "block is also included.  Similar annotation fields are included",
	    "for the following, if the C<etbasis> output block is included.",
	{ output => 'motility_basis_no', com_name => 'jmb',
	  if_block => 'etbasis', if_format => 'json' },
	{ output => 'motility_basis_name', com_name => 'jmn',
	  if_block => 'etbasis', if_format => 'json' },
	{ output => 'life_habit', com_name => 'jlh' },
	    "The general life mode and locality of this organism.",
	{ output => 'life_habit_basis', com_name => 'jhc',
	  if_block => 'etbasis', if_format => ['txt', 'csv', 'tsv'] },
	    "Specifies the taxon for which the life habit information was set.",
	    "See B<motility_basis> above.  These fields are only included if the",
	    "C<ecospace> block is also included.",
	{ output => 'life_habit_basis_no', com_name => 'jhb',
	  if_block => 'etbasis', if_format => 'json' },
	{ output => 'life_habit_basis_name', com_name => 'jhn',
	  if_block => 'etbasis', if_format => 'json' },
	{ output => 'diet', com_name => 'jdt' },
	    "The general diet or feeding mode of this organism.",
	{ output => 'diet_basis', com_name => 'jdc',
	  if_block => 'etbasis', if_format => ['txt', 'csv', 'tsv'] },
	    "Specifies the taxon for which the diet information was set.",
	    "See B<motility_basis> above.  These fields are only included if the",
	    "C<ecospace> block is also included.",
	{ output => 'diet_basis_no', com_name => 'jdb',
	  if_block => 'etbasis', if_format => 'json' },
	{ output => 'diet_basis_name', com_name => 'jdn',
	  if_block => 'etbasis', if_format => 'json' });
    
    $ds->define_block('1.2:taxa:taphonomy' =>
	{ select => 'TAPH' },
	{ output => 'composition', com_name => 'jco' },
	    "The composition of the skeletal parts of this organism.",
	{ output => 'architecture', com_name => 'jsa' },
	    "An indication of the internal skeletal architecture.",
	{ output => 'thickness', com_name => 'jth' },
	    "An indication of the relative thickness of the skeleton.",
	{ output => 'reinforcement', com_name => 'jsr' },
	    "An indication of the skeletal reinforcement, if any.",
	{ output => 'taphonomy_basis', com_name => 'jtc',
	  if_block => 'etbasis', if_format => ['txt', 'csv', 'tsv'] },
	    "Specifies the taxon for which the taphonomy information was set.",
	    "See B<motility_basis> above.  These fields are only included if the",
	    "C<taphonomy> block is also included.",
	{ output => 'taphonomy_basis_no', com_name => 'jtb',
	  if_block => 'etbasis', if_format => 'json' },
	{ output => 'taphonomy_basis_name', com_name => 'jtn',
	  if_block => 'etbasis', if_format => 'json' });
    
    $ds->define_block('1.2:taxa:etbasis' =>
	# { output => 'environment_basis_no', com_name => 'jnb',
	#   if_block => 'etbasis', if_format => 'json' },
	#     "Specifies the taxon for which the ",
	# { output => 'environment_basis_name', com_name => 'jnn',
	#   if_block => 'etbasis', if_format => 'json' },
	# { output => 'environment_basis', com_name => 'jnc',
	#   if_block => 'etbasis', if_format => ['txt', 'csv', 'tsv'] },
	{ set => '*', code => \&consolidate_basis, if_format => ['txt', 'csv', 'tsv'] });
    
    # Now define output blocks for opinions
    
    $ds->define_output_map('1.2:opinions:output_map' =>
	{ value => 'basis' },
	    "The basis of the opinion, which will be one of the following:",
	    "=over", "=item stated with evidence", "=item stated without evidence",
	    "=item implied", "=item second hand", "=back",
	{ value => 'ent', maps_to => '1.2:common:ent' },
	    "The identifiers of the people who authorized, entered and modified this record",
	{ value => 'entname', maps_to => '1.2:common:entname' },
	    "The names of the people who authorized, entered and modified this record",
	{ value => 'crmod', maps_to => '1.2:common:crmod' },
	    "The C<created> and C<modified> timestamps for the opinion record");
    
    our (%pbdb_opinion_code) = ( 'C' => 'classify', 'U' => 'unselected', 'X' => 'suppressed' );
    
    $ds->define_block('1.2:opinions:basic' =>
	{ select => [ 'OP_DATA' ] },
	{ set => '*', code => \&process_pbdb, if_vocab => 'pbdb' },
	{ set => '*', code => \&process_com, if_vocab => 'com' },
	{ output => 'opinion_no', com_name => 'oid' },
	    "A unique identifier for this opinion record.",
	{ output => 'record_type', com_name => 'typ', value => 'opinion', com_value => 'opn' },
	    "The type of this record.",
	{ output => 'opinion_type', com_name => 'otp' },
	    "The type of opinion represented: B<C> for a",
	    "classification opinion, B<U> for an opinion which was not selected",
	    "as a classification opinion.",
	{ set => 'opinion_type', lookup => \%pbdb_opinion_code, if_vocab => 'pbdb' },
	{ output => 'author', com_name => 'att' },
	    "The author(s) of this opinion.",
	{ output => 'pubyr', com_name => 'pby' },
	    "The year in which the opinion was published.",
	{ output => 'taxon_name', com_name => 'nam' },
	    "The taxonomic name that is the subject of this opinion.",
	{ output => 'orig_no', com_name => 'tid' },
	    "The identifier of the taxonomic name that is the subject of this opinion.",
	{ output => 'child_name', dedup => 'taxon_name', com_name => 'cnm' },
	    "The particular variant of the name that is the subject of this opinion,",
	    "if different from the currently accepted one.",
	{ output => 'child_spelling_no', com_name => 'vid', not_field => 'no_variant' },
	    "The identifier of the particular variant that is the subject of this opinion.",
	{ output => 'taxon_rank', com_name => 'rnk' },
	    "The rank to which this opinion assigns the taxonomic name that is the subject of",
	    "this opinion.",
	{ set => 'taxon_rank', if_vocab => 'pbdb,dwc', lookup => \%RANK_STRING },
	{ output => 'status', com_name => 'sta' },
	    "The taxonomic status of this name, as expressed by this opinion.",
	{ output => 'parent_name', com_name => 'prl' },
	    "The taxonomic name under which the subject is being placed (the \"parent\" taxonomic name).",
	    "Note that the value of this field is the particular variant of the name that was given",
	    "in the opinion, not necessarily the currently accepted variant.",
	{ output => 'parent_no', com_name => 'par' },
	    "The identifier of the parent taxonomic name.",
	{ output => 'parent_spelling_no', com_name => 'pva' },
	    "The identifier of the variant of the parent name that was given in the opinion,",
	    "if this is different from the currently accepted variant of that name.",
	{ output => 'spelling_reason', com_name => 'spl' },
	    "An indication of why this name was given.",
	{ output => 'basis', com_name => 'bas', if_block => 'basis' },
	    "The basis of the opinion, see above for a list.");
    
    # Finally, we define some rulesets to specify the parameters accepted by
    # the operations defined in this class.
    
    $ds->define_ruleset('1.2:taxa:specifier' => 
	{ param => 'name', valid => \&PB2::TaxonData::validNameSpec, 
	  alias => 'taxon_name' },
	    "Return information about the most fundamental taxonomic name matching this string.",
	    "The C<%> and C<_> characters may be used as wildcards.",
	{ param => 'id', valid => VALID_IDENTIFIER('TID'), 
	  alias => 'taxon_id', bad_value => '-1' },
	    "Return information about the taxonomic name corresponding to this identifier.",
	{ at_most_one => ['name', 'id'] },
	    "You may not specify both C<name> and C<id> in the same query.");
    
    $ds->define_set('1.2:taxa:rel' =>
	{ value => 'current' },
	    "Select the currently accepted variant of the specified taxonomic name(s).  This is the default.",
	{ value => 'exact' },
	    "Select the exact taxonomic name(s) actually specified, whether or not they are the currently",
	    "accepted variants.",
	{ value => 'accepted' },
	    "Select the closest matching accepted name(s) to the specified taxon or taxa.",
	    "If a specified taxon is a junior synonym, its senior synonym will be returned.",
	    "If a specified taxon is an invalid name (i.e. nomen dubium) then the",
	    "corresponding valid name will be returned.",
	{ value => 'synonyms' },
	    "Select all synonyms of the specified taxonomic name(s) which are known to this database.",
	{ value => 'variants' },
	    "Select all variants of the specified taxonomic name(s) that are known to this",
	    "database.  These may be variant spellings, or previous ranks.  For example",
	    "a taxon currently ranked as a suborder might have been previously ranked",
	    "as an order, which would count as a different variant.",
	{ value => 'children' },
	    "Select the taxa immediately contained within the specified taxon or taxa",
	    "and within all synonymous taxa.",
	{ value => 'all_children' },
	    "Select all taxa contained within the specified taxon or taxa and within all",
	    "synonymous taxa.  This selects an entire subtree of the taxonomic hierarchy.",
	{ value => 'parent' },
	    "Select the taxa immediately containing the specified taxon or taxa.",
	{ value => 'senpar' },
	    "Select the senior synonyms of the taxa immediately containing the",
	    "specified taxon or taxa.",
	{ value => 'all_parents' },
	    "Select all taxa that contain the specfied taxon or taxa.  The senior",
	    "synonym of each name will be returned.",
	{ value => 'common_ancestor', undocumented => 1 },
	{ value => 'common' },
	    "Select the most specific taxon that contains all of the specified taxa.",
	{ value => 'crown', undocumented => 1 },
	    "Select the taxon corresponding to the crown-group of the specified taxa",
	{ value => 'pan', undocumented => 1 },
	    "Select the taxon corresponding to the pan-group of the specified taxa",
	{ value => 'stem', undocumented => 1 },
	    "Select all of the highest-level taxa that make up the stem-group",
	    "of the specified taxa",
	{ value => 'all_taxa' },
	    "Select all of the taxa in the database.  In this case you do not have",
	    "to specify C<name> or C<id>.  Use with caution, because the maximum",
	    "data set returned may be as much as 80 MB if you do not include any",
	    "filtering parameters.  You can use the special",
	    "parameters C<limit> and C<offset> to return this data in smaller chunks.",
	    "Note also that there is a default limit on the number of results returned.");
    
    $ds->define_set('1.2:taxa:status' =>
	{ value => 'all' },
	    "Select all taxonomic names matching the other specified criteria.  This",
	    "is the default.",
	{ value => 'valid' },
	    "Select only taxonomically valid names",
	{ value => 'senior' },
	    "Select only taxonomically valid names that are not junior synonyms",
	{ value => 'junior' },
	    "Select only taxonomically valid names that are junior synonyms",
	{ value => 'invalid' },
	    "Select only taxonomically invalid names, e.g. nomina dubia");
    
    $ds->define_set('1.2:taxa:refselect' =>
	{ value => 'auth' },
	    "Select the references associated with the authority records for these taxa.",
	{ value => 'class' },
	    "Select the references associated with the classification opinions for these taxa",
	{ value => 'taxonomy' },
	    "Select the references associated with both the authority records and the classification",
	    "opinions for these taxa.  This is the default.",
	{ value => 'opinions' },
	    "Select the references associated with all opinions on these taxa, including",
	    "those not used for classification.",
	{ value => 'occs' },
	    "Select the references associated with occurrences of these taxa.",
	{ value => 'colls' },
	    "Select the references associated with collections that contain occurrences of these taxa.",
	{ value => 'all' },
	    "Select all of the above.");
    
    $ds->define_set('1.2:taxa:opselect' =>
	{ value => 'class' },
	    "Select only the classification opinions for these taxa.  This is the default.",
	{ value => 'all' },
	    "Select all opinions for these taxa, including those that are not used",
	    "as classification opinions.",
	{ value => 'valid' },
	    "Select all opinions that classify these taxa as valid names, whether",
	    "or not they are used as classification opinions.",
	{ value => 'senior' },
	    "Select all opinions that classify these taxa as 'belongs to',",
	    "whether or not they are used as classification opinions.",
	{ value => 'junior' },
	    "Select all opinions that classify these taxa as junior synonyms,",
	    "whether or not they are used as classification opinions.",
	{ value => 'invalid' },
	    "Select all opinions that classify these taxa as invalid names,",
	    "whether or not they are used as classification opinions.");
    
    $ds->define_set('1.2:taxa:variants' =>
	{ value => 'current' },
	    "Select only the references associated with the currently accepted variant of each taxonomic name",
	{ value => 'all' },
	    "Select the references associated with all variants of each taxonomic name");
    
    $ds->define_set('1.2:taxa:summary_rank' =>
	{ value => 'ident' },
	    "Group occurrences together by their taxonomic identification, ignoring modifiers.",
	    "This is the default.",
	{ value => 'exact' },
	    "Group occurrences together by their exact taxonomic identification, including",
	    "modifiers such as 'sensu lato' or 'n. sp.'.",
	">If you choose any of the following values, then all occurrences whose identified",
	"taxon has not been entered into this database will be skipped.",
	{ value => 'taxon' },
	    "Group occurrences together if they are identified as belonging to the same taxon,",
	    "ignoring synonymy.",
	{ value => 'synonym' },
	    "Group occurrences together if they are identified as belonging to synonymous taxa.",
	    "All of the following options also take synonymy into account.",
	{ value => 'species' },
	    "Group occurrences together if they are identified as belonging to the same species",
	{ value => 'genus' },
	    "Group occurrences together if they are identified as belonging to the same genus",
	{ value => 'family' },
	    "Group occurrences together if they are identified as belonging to the same family",
	{ value => 'order' },
	    "Group occurrences together if they are identified as belonging to the same order",
	{ value => 'class' },
	    "Group occurrences together if they are identified as belonging to the same class",
	{ value => 'phylum' },
	    "Group occurrences together if they are identified as belonging to the same phylum",
	{ value => 'kingdom' },
	    "Group occurrences together if they are identified as belonging to the same kingdom");
    
    $ds->define_set('1.2:taxa:order' =>
	{ value => 'hierarchy' },
	    "Results are ordered hierarchically by taxonomic identification.",
	    "The order of sibling taxa is arbitrary, but children will always follow",
	    "after parents.  This is the default.",
	{ value => 'hierarchy.asc', undocumented => 1 },
	{ value => 'hierarchy.desc', undocumented => 1 },
	{ value => 'name' },
	    "Results are ordered alphabetically by taxon name.",
	{ value => 'name.asc', undocumented => 1 },
    	{ value => 'name.desc', undocumented => 1 },
	{ value => 'firstapp' },
	    "Results are ordered chronologically by first appearance, oldest to youngest unless you add C<.asc>",
	{ value => 'firstapp.asc', undocumented => 1 },
	{ value => 'firstapp.desc', undocumented => 1 },
	{ value => 'lastapp' },
	    "Results are ordered chronologically by last appearance, oldest to youngest unless you add C<.asc>",
	{ value => 'lastapp.asc', undocumented => 1 },
	{ value => 'lastapp.desc', undocumented => 1 },
	{ value => 'agespan' },
	    "Results are ordered based on the difference between the first and last appearances, starting",
	    "with occurrences with the smallest spread (most precise temporal resolution) unless you add C<.desc>",
	{ value => 'agespan.asc', undocumented => 1 },
	{ value => 'agespan.desc', undocumented => 1 },
	{ value => 'n_occs' },
	    "Results are ordered by the number of fossil occurrences of this taxon entered in this database,",
	    "largest to smallest unless you add C<.asc>",
	{ value => 'n_occs.asc', undocumented => 1 },
	{ value => 'n_occs.desc', undocumented => 1 },
	{ value => 'pubyr' },
	    "Results are ordered by the year in which the name was first published, oldest first unless",
	    "you add C<.asc>",
	{ value => 'pubyr.asc', undocumented => 1 },
	{ value => 'pubyr.desc', undocumented => 1 },
	{ value => 'author' },
	    "Results are ordered alphabetically by the last name of the primary author",
	{ value => 'author.asc', undocumented => 1 },
	{ value => 'author.desc', undocumented => 1 },
	{ value => 'rank', undocumented => 1 },
	    "Results are ordered by the number of associated records, highest first unless you add C<.asc>.",
	    "This is only useful when querying for taxa associated with occurrences, etc.",
	{ value => 'rank.asc', undocumented => 1 },
	{ value => 'rank.desc', undocumented => 1 },
	{ value => 'size' },
	    "Results are ordered by the number of contained subtaxa, largest to smallest unless you add C<.asc>",
	{ value => 'size.asc', undocumented => 1 },
	{ value => 'size.desc', undocumented => 1 },
	{ value => 'extant_size' },
	    "Results are ordered by the number of extant subtaxa, largest to smallest unless you add C<.asc>",
	{ value => 'extsize.asc', undocumented => 1 },
	{ value => 'extsize.desc', undocumented => 1 },
	{ value => 'extant' },
	    "Results are ordered by whether or not the taxon is extant, with extant ones first unless you add C<.asc>",
	{ value => 'extant.asc', undocumented => 1 },
	{ value => 'extant.desc', undocumented => 1 },
	{ value => 'created' },
	    "Results are ordered by the date the record was created, most recent first",
	    "unless you add C<.asc>.",
	{ value => 'created.asc', undocumented => 1 },
	{ value => 'created.desc', undocumented => 1 },
	{ value => 'modified' },
	    "Results are ordered by the date the record was last modified",
	    "most recent first unless you add C<.asc>",
	{ value => 'modified.asc', undocumented => 1 },
	{ value => 'modified.desc', undocumented => 1 });
    
    $ds->define_set('1.2:opinions:order' =>
	{ value => 'hierarchy' },
	    "Results are ordered hierarchically by taxonomic identification.",
	    "The order of sibling taxa is arbitrary, but children will always follow",
	    "after parents.  This is the default.",
	{ value => 'hierarchy.asc', undocumented => 1 },
	{ value => 'hierarchy.desc', undocumented => 1 },
	{ value => 'name' },
	    "Results are ordered alphabetically by taxon name.",
	{ value => 'name.asc', undocumented => 1 },
    	{ value => 'name.desc', undocumented => 1 },
	{ value => 'pubyr' },
	    "Results are ordered by the year in which the opinion was published,",
	    "newest first unless you add '.asc'",
	{ value => 'pubyr.asc', undocumented => 1 },
	{ value => 'pubyr.desc', undocumented => 1 },
	{ value => 'author' },
	    "Results are ordered alphabetically by the last name of the primary author.",
	{ value => 'author.asc', undocumented => 1 },
	{ value => 'author.desc', undocumented => 1 },
	{ value => 'basis' },
	    "Results are ordered according to the basis of the opinion, highest first.",
	{ value => 'basis.asc', undocumented => 1 },
	{ value => 'basis.desc', undocumented => 1 },
	{ value => 'created' },
	    "Results are ordered by the date the record was created, most recent first",
	    "unless you add C<.asc>.",
	{ value => 'created.asc', undocumented => 1 },
	{ value => 'created.desc', undocumented => 1 },
	{ value => 'modified' },
	    "Results are ordered by the date the record was last modified",
	    "most recent first unless you add C<.asc>",
	{ value => 'modified.asc', undocumented => 1 },
	{ value => 'modified.desc', undocumented => 1 });
    
    $ds->define_ruleset('1.2:taxa:selector' =>
	"The following parameters are used to select the base set of taxonomic names to return.",
	"If you wish to download the entire taxonomy, use C<rel=all_taxa> and see also the",
	"L<limit|node:special#limit> parameter.",
	{ param => 'name', valid => \&PB2::TaxonData::validNameSpec, 
	  alias => 'taxon_name' },
	    "Select the all taxa matching each of the specified name(s).",
	    "To specify more than one, separate them by commas.",
	    "The C<%> character may be used as a wildcard.",
	{ param => 'base_name', valid => \&PB2::TaxonData::validNameSpec },
	    "Selects the most closely matching valid taxon or taxa, plus",
	    "all subtaxa.  You can specify more than one name, separated by",
	    "commas.  This is a shortcut, equivalent to specifying C<name>",
	    "and C<rel=all_children>.",
	{ param => 'id', valid => VALID_IDENTIFIER('TID'), list => ',', bad_value => '-1' },
	    "Selects the taxa corresponding to the specified identifier(s).",
	    "You may specify more than one, separated by commas.",
	{ param => 'base_id', valid => VALID_IDENTIFIER('TID'), list => ',', bad_value => '-1' },
	    "Selects the most closely matching valid taxon or taxa, plus",
	    "all subtaxa.  You can specify more than one identifier, separated",
	    "by commas.  This is a shortcut, equivalent to specifying C<name> and",
	    "C<rel=all_children>.",
	{ optional => 'exclude_id', valid => VALID_IDENTIFIER('TID'), list => ',' },
	    "Excludes the taxonomic subtree(s) corresponding to the taxon or taxa",
	    "specified.  This is",
	    "only relevant with the use of either C<base_name>, C<base_id>,",
	    "C<rel=all_children>, or C<rel=subtree>.  If you are using C<base_name>,",
	    "you can also exclude subtaxa by name using the C<^> symbol, as in \"dinosauria ^aves\"",
	    "or \"osteichthyes ^tetrapoda\".",
	{ param => 'all_taxa', valid => FLAG_VALUE },
	    "Selects all taxa from the database.  This is equivalent to specifying",
	    "the parameter C<rel> with the value C<all_taxa>.  Be careful when using this, since",
	    "the full result set if you don't specify any other parameters can exceed",
	    "80 megabytes.  This parameter does not need any value.",
	">The following parameters indicate which related taxonomic names to return:",
	{ optional => 'rel', valid => '1.2:taxa:rel' },
	    "Indicates which taxa are to be selected.  Accepted values include:",
	{ optional => 'status', valid => '1.2:taxa:status', default => 'all' },
	    "Return only names that have the specified status.  The default is C<all>.",
	    "Accepted values include:");
    
    $ds->define_ruleset('1.2:taxa:filter' => 
	"The following parameters further filter the list of return values:",
	{ optional => 'rank', valid => \&PB2::TaxonData::validRankSpec },
	    "Return only taxonomic names at the specified rank, e.g. C<genus>.",
	{ optional => 'extant', valid => BOOLEAN_VALUE },
	    "Return only extant or non-extant taxa.",
	    "Accepted values are: C<yes>, C<no>, C<1>, C<0>, C<true>, C<false>.",
	{ optional => 'max_ma', valid => DECI_VALUE },
	    "Return only taxa which were extant more recently than the given age in Ma.  By using",
	    "the parameters C<max_ma> and C<min_ma> together, you can select only taxa",
	    "whose extancy overlaps a particular age range.  Note that this filtering",
	    "is done on the basis of first and last appearance dates and may",
	    "include taxa without an actual occurrence in that age range.  If you wish",
	    "to select only taxa which actually have a recorded occurrence in a particular",
	    "time range, or if you wish to use a time resolution rule other than C<overlap>,",
	    "use the L<occs/taxa|node:occs/taxa> operation instead.",
	{ optional => 'min_ma', valid => DECI_VALUE },
	    "Return only taxa which were extant before the given age in Ma.  See",
	    "C<max_ma> above.",
	{ optional => 'interval', valid => ANY_VALUE },
	    "Return only taxa which were extant during the specified time interval",
	    "or intervals, given by name.  You may give more than one interval name, separated either",
	    "by hyphens or commas.  No matter how many intervals you specify, the selected",
	    "taxa will be those that were extant at any time between the oldest and youngest",
	    "specified interval, inclusive.  In other words, this is equivalent to using ",
	    "the parameters C<max_ma> and C<min_ma> and providing the maximum and minimum",
	    "of the boundary ages of the given intervals.",
	{ optional => 'interval_id', valid => ANY_VALUE },
	    "Return only taxa which were extant during the specified time interval",
	    "or intervals, given by identifier.  These are evaluated based on the",
	    "same rules as the parameter C<interval>.",
	{ optional => 'depth', valid => POS_VALUE },
	    "Return only taxa no more than the specified number of levels above or",
	     "below the base taxa in the hierarchy");
    
    $ds->define_ruleset('1.2:taxa:aux_selector' =>
	{ param => 'taxon_name', valid => \&PB2::TaxonData::validNameSpec },
	    "Selects records associated directly with taxa matching each of the specified name(s).",
	    "To specify more than one, separate them by commas.",
	    "The C<%> character may be used as a wildcard.",
	{ param => 'base_name', valid => \&PB2::TaxonData::validNameSpec },
	    "Selects records associated with the named taxon or taxa, plus",
	    "all subtaxa.  You can specify more than one name, separated by",
	    "commas.  This is a shortcut, equivalent to specifying C<name>",
	    "and C<rel=all_children>.",
	{ param => 'taxon_id', valid => VALID_IDENTIFIER('TID'), list => ',', bad_value => '-1' },
	    "Selects records associated directly with the taxa corresponding",
	    "to the specified identifier(s).",
	    "You may specify more than one, separated by commas.",
	{ param => 'base_id', valid => VALID_IDENTIFIER('TID'), list => ',', bad_value => '-1' },
	    "Selects records associated with the identified taxa, plus",
	    "all subtaxa.  You can specify more than one identifier, separated",
	    "by commas.  This is a shortcut, equivalent to specifying C<taxon_id> and",
	    "C<rel=all_children>.",
	{ optional => 'exclude_id', valid => VALID_IDENTIFIER('TID'), list => ',' },
	    "Excludes the taxonomic subtree(s) corresponding to the taxon or taxa",
	    "specified.  If you are using C<base_name>, you can alternatively",
	    "exclude subtaxa by name using the C<^> symbol, as in \"dinosauria ^aves\"",
	    "or \"osteichthyes ^tetrapoda\".",
	{ param => 'all_taxa', valid => FLAG_VALUE },
	    "Selects records associated with all taxa from the database.  Be careful",
	    "when using this, since the full result set for opinions can exceed 150",
	    "megabytes and the full result set for references can exceed 40.  This",
	    "parameter does not need any value.",
	">The following parameters indicate which related taxonomic names to return:",
	{ param => 'rel', valid => '1.2:taxa:rel' },
	    "Indicates which taxa are to be selected.  Accepted values include:",
	{ param => 'status', valid => '1.2:taxa:status', default => 'all' },
	    "Return only records associated with taxa that have the specified status.  The default is C<all>.",
	    "Accepted values include:");
    
    $ds->define_ruleset('1.2:taxa:summary_selector' => 
	{ optional => 'rank', valid => '1.2:taxa:summary_rank', alias => 'summary_rank',
	  default => 'ident' },
	    "Summarize the results by grouping them as follows:");
    
    $ds->define_ruleset('1.2:taxa:display' => 
	"The following parameter indicates which information should be returned about each resulting name:",
	{ optional => 'show', valid => '1.2:taxa:output_map', list => ','},
	    "This parameter is used to select additional information to be returned",
	    "along with the basic record for each taxon.  Its value should be",
	    "one or more of the following, separated by commas:",
	{ optional => 'order', valid => '1.2:taxa:order', split => ',' },
	    "Specifies the order in which the results are returned.  You can specify multiple values",
	    "separated by commas, and each value may be appended with C<.asc> or C<.desc>.  Accepted values are:");
    
    $ds->define_ruleset('1.2:taxa:single' => 
	{ require => '1.2:taxa:specifier',
	  error => "you must specify either 'name' or 'id'" },
	{ allow => '1.2:taxa:display' }, 
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.");
    
    $ds->define_ruleset('1.2:taxa:list' => 
	{ require => '1.2:taxa:selector',
	  error => "you must specify one of 'name', 'id', 'base_name', 'base_id', or 'all_taxa'" },
	{ allow => '1.2:taxa:filter' },
	{ allow => '1.2:common:select_crmod' },
	{ allow => '1.2:common:select_ent' },
	{ allow => '1.2:taxa:display' }, 
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.");
    
    $ds->define_ruleset('1.2:taxa:refs' =>
	">You can use the following parameters if you wish to retrieve the references associated",
	"with a specified list of taxa.",
	"Only the records which also match the other parameters that you specify will be returned.",
	{ require => '1.2:taxa:aux_selector' },
	{ optional => 'variant', valid => '1.2:taxa:variants' },
	    "This parameter is relevant only when retrieving authority references.",
	    "It specifies whether to retrieve the reference for just the current variant",
	    "of each matching taxonomic name (the default) or for all variants.  The",
	    "accepted values include:",
	{ allow => '1.2:taxa:filter' },
	{ allow => '1.2:common:select_taxa_crmod' },
	{ allow => '1.2:common:select_taxa_ent' },
	">You can also specify any of the following parameters:",
	{ optional => 'select', valid => '1.2:taxa:refselect', list => ',' },
	    "You can use this parameter to specify which kinds of references to retrieve.",
	    "The value of this attribute can be one or more of the following, separated by commas:",
	{ allow => '1.2:common:select_crmod' },
	{ allow => '1.2:common:select_ent' },
	{ allow => '1.2:refs:filter' },
	{ allow => '1.2:refs:display' },
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.",
	">If the parameter C<order> is not specified, the results are sorted alphabetically by",
	"the name of the primary author.");
    
    $ds->define_ruleset('1.2:taxa:byref' =>
	{ require => '1.2:taxa:aux_selector' },
	{ optional => 'variant', valid => '1.2:taxa:variants' },
	    "You can use this parameter to specify which variants of the matching taxonomic name(s) to retrieve.",
	    "The accepted values include:",
	{ allow => '1.2:taxa:filter' },
	{ allow => '1.2:common:select_taxa_crmod' },
	{ allow => '1.2:common:select_taxa_ent' },
	">You can also specify any of the following parameters:",
	{ optional => 'select', valid => '1.2:taxa:refselect', list => ',' },
	    "You can use this parameter to specify which kinds of references to retrieve.",
	    "The value of this attribute can be one or more of the following, separated by commas:",
	{ allow => '1.2:common:select_crmod' },
	{ allow => '1.2:common:select_ent' },
	{ allow => '1.2:refs:filter' },
	{ allow => '1.2:refs:display' },
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.",
	">If the parameter C<order> is not specified, the results are sorted alphabetically by",
	"the name of the primary author.");
    
    $ds->define_ruleset('1.2:opinions:specifier' =>
	{ param => 'id', valid => VALID_IDENTIFIER('OPN'), alias => 'opinion_id' },
	    "Return information about the taxonomic opinion corresponding to this identifier.");
    
    $ds->define_ruleset('1.2:opinions:selector' =>
	{ param => 'id', valid => VALID_IDENTIFIER('OPN'), list => ',', bad_value => '-1',
	  alias => 'opinion_id' },
	    "Selects the opinions corresponding to the specified identifier(s).",
	    "You may provide more than one, separated by commas.");
    
    $ds->define_ruleset('1.2:opinions:aux_selector' =>
	{ param => 'opinion_id', valid => VALID_IDENTIFIER('OPN'), list => ',', bad_value => '-1' },
	    "Selects the opinions corresponding to the specified identifier(s).",
	    "You may provide more than one, separated by commas.");
    
    $ds->define_ruleset('1.2:opinions:filter' =>
	{ param => 'published_after', valid => POS_VALUE, alias => 'pubyr_before' },
	    "Selects only opinions published during or after the indicated year.",
	{ param => 'published_before', valid => POS_VALUE, alias => 'pubyr_after' },
	    "Selects only opinions published during or before the indicated year.",
	{ param => 'published', valid => ANY_VALUE, alias => 'pubyr' },
	    "Selects only opinions published during the indicated year or range of years.");
    
    $ds->define_ruleset('1.2:opinions:display' => 
	"The following parameter indicates which information should be returned about each resulting name:",
	{ optional => 'SPECIAL(show)', valid => '1.2:opinions:output_map', list => ','},
	    "This parameter is used to select additional information to be returned",
	    "along with the basic record for each taxon.  Its value should be",
	    "one or more of the following, separated by commas:",
	{ optional => 'order', valid => '1.2:opinions:order', split => ',' },
	    "Specifies the order in which the results are returned.  You can specify multiple values",
	    "separated by commas, and each value may be appended with C<.asc> or C<.desc>.  Accepted values are:");
    
    $ds->define_ruleset('1.2:taxa:opinions' =>
	">You can use the following parameters if you wish to select opinions associated",
	"with a specified list of taxa.  Only the records which also match the other",
	"parameters that you specify will be returned.",
	{ require => '1.2:taxa:aux_selector' },
	{ allow => '1.2:taxa:filter' },
	{ allow => '1.2:common:select_taxa_crmod' },
	{ allow => '1.2:common:select_taxa_ent' },
	">You can also specify any of the following parameters:",
	{ optional => 'select', valid => '1.2:taxa:opselect' },
	    "You can use this parameter to specify which kinds of opinions to retrieve.",
	    "The accepted values include:",
	{ allow => '1.2:common:select_crmod' },
	{ allow => '1.2:common:select_ent' },
	{ allow => '1.2:opinions:aux_selector' },
	{ allow => '1.2:opinions:filter' },
	{ allow => '1.2:opinions:display' },
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.",
	">If the parameter C<order> is not specified, the results are sorted alphabetically by",
	"the name of the primary author.");
    
    $ds->define_ruleset('1.2:taxa:match' =>
	{ param => 'name', valid => \&PB2::TaxonData::validNameSpec, list => ',', alias => 'taxon_name' },
	    "A valid taxonomic name, or a common abbreviation such as 'T. rex'.",
	    "The name may include the wildcard characters % and _.",
	{ optional => 'rank', valid => \&PB2::TaxonData::validRankSpec },
	    "Return only taxonomic names at the specified rank, e.g. <genus>.",
	{ optional => 'extant', valid => BOOLEAN_VALUE },
	    "Return only extant or non-extant taxa.",
	    "Accepted values are: C<yes>, C<no>, C<1>, C<0>, C<true>, C<false>.",
	{ param => 'status', valid => '1.2:taxa:status', default => 'all' },
	    "Return only names that have the specified status.  Accepted values include:",
	{ allow => '1.2:taxa:display' }, 
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.");
    
    $ds->define_ruleset('1.2:taxa:auto' =>
	{ param => 'name', valid => ANY_VALUE, alias => 'taxon_name' },
	    "A partial name or prefix.  It must have at least 3 significant characters, and may include both a genus",
	    "(possibly abbreviated) and a species.  Examples:\n    t. rex, tyra, rex", 
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.");
    
    $ds->define_ruleset('1.2:taxa:thumb' =>
	{ param => 'id', valid => POS_VALUE },
	    "A positive number identifying a taxon image",
	{ optional => 'SPECIAL(save)' },
	{ ignore => 'splat' });
    
    $ds->define_ruleset('1.2:taxa:icon' =>
	{ require => '1.2:taxa:thumb' });
    
    $ds->define_ruleset('1.2:taxa:list_images' =>
	{ param => 'name', valid => ANY_VALUE },
	    "List images belonging to the specified taxonomic name.  If multiple",
	    "names match what you specified, the images for all of them will be listed.",
	{ param => 'id', valid => VALID_IDENTIFIER('TID') },
	    "List images belonging to the taxonomic name corresponding to the specified",
	    "identifier.",
	{ at_most_one => ['id', 'name'] },
	    "You may not specify both C<name> and C<id> in the same query.",
	{ optional => 'rel', valid => ENUM_VALUE('all_children') },
	    "If this parameter is specified with the value C<all_children>, then",
	    "all images matching the specified taxon or any of its children are",
	    "returned.  In this case, the fields C<taxon_id> and C<taxon_name>",
	    "will be included in the result.",
	{ optional => 'depth', valid => POS_VALUE },
	    "Return only images whose depth in the tree is at most the specified",
	    "number of levels different from the base taxon or taxa.");
    
    $ds->define_ruleset('1.2:opinions:single' =>
	"The following parameter selects a record to retrieve:",
    	{ require => '1.2:opinions:specifier', 
	  error => "you must specify an opinion identifier, either in the URL or with the 'id' parameter" },
	">>You may also use the following parameter to specify what information you wish to retrieve:",
    	{ optional => 'SPECIAL(show)', valid => '1.2:opinions:output_map' },
    	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request");
    
    $ds->define_ruleset('1.2:opinions:list' =>
	{ allow => '1.2:opinions:selector' },
	{ allow => '1.2:opinions:filter' },
	{ allow => '1.2:common:select_crmod' },
	{ allow => '1.2:common:select_ent' },
	{ allow => '1.2:common:select_refs_crmod' },
	{ allow => '1.2:common:select_refs_ent' },
	{ require_any => ['1.2:opinions:selector', '1.2:opinions:filter', 
			  '1.2:common:select_crmod', '1.2:common:select_ent',
			  '1.2:common:select_refs_crmod', '1.2:common:select_refs_ent'] },
	{ allow => '1.2:opinions:display' }, 
	{ allow => '1.2:special_params' },
	"^You can also use any of the L<special parameters|node:special> with this request.",
	"If the parameter C<order> is not specified, the results are ordered by year of",
	"publication and the last name of the author.");
    
    # Determine which fields are available in this version of the database.
    
    my $dbh = $ds->get_connection;
    
    my $record;
    
    eval {
	$record = $dbh->selectrow_hashref("SELECT * from $TAXON_TABLE{taxon_trees}{search} LIMIT 1");
    };
    
    if ( ref $record eq 'HASH' )
    {
	$DB_FIELD{common} = 1 if exists $record->{common};
	$DB_FIELD{orig_no} = 1 if exists $record->{orig_no};
	$DB_FIELD{is_current} = 1 if exists $record->{is_current};
	$DB_FIELD{accepted_no} = 1 if exists $record->{accepted_no};
    }
}


# get_taxon ( )
# 
# Return a single taxon record, specified by name or identifier.  If name, then
# return the matching taxon with the largest number of occurrences.

sub get_taxon {

    my ($self) = @_;
    
    my $dbh = $self->get_connection;
    my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    my $taxon_no;
    
    # First determine the fields necessary to show the requested info.
    
    my $options = $self->generate_query_fields( 'taxa', { } );
    
    # Then figure out which taxon we are looking for.  If we have a taxon_no,
    # we can use that.
    
    my $not_found_msg = '';
    
    if ( $taxon_no = $self->clean_param('id') )
    {    
	$not_found_msg = "Taxon number $taxon_no was not found in the database";
    }
    
    # Otherwise, we must have a taxon name.  So look for that.
    
    elsif ( my $taxon_name = $self->clean_param('name') )
    {
	$not_found_msg = "Taxon '$taxon_name' was not found in the database";
	my $name_select = { return => 'id' };
	#my $name_select = { order => 'size.desc', spelling => 'exact', return => 'id', limit => 1 };
	
	if ( my $rank = $self->clean_param('rank') )
	{
	    $name_select->{rank} = $rank;
	    $not_found_msg .= " at rank '$rank'";
	}
	
	($taxon_no) = $taxonomy->resolve_names($taxon_name, $name_select);
	
	#($taxon_no) = $self->get_taxa_by_name($valid->value('name'), $name_select);
    }
    
    # If we haven't found a record, the result set will be empty.
    
    unless ( defined $taxon_no and $taxon_no > 0 )
    {
	return;
    }
    
    # Next, fetch the requested info about the taxon.
    
    my ($r);
    
    try {
	($r) = $taxonomy->list_taxa_simple($taxon_no, $options);
   }
    
    catch {
	print STDERR $taxonomy->last_sql . "\n\n" if $self->debug;
	die $_;
    };
    
    $self->single_result($r);
    $self->{main_sql} = $taxonomy->last_sql;
    print STDERR $self->{main_sql} . "\n\n" if $self->debug;
    
    return unless ref $r;
    
    # If we were asked for 'nav' info, add the necessary fields.
    
    if ( $self->has_block('nav') )
    {
	# First get taxon records for all of the relevant supertaxa.
	
	if ( $r->{kingdom_no} )
	{
	    $r->{kingdom_txn} = $taxonomy->get_taxon($r->{kingdom_no}, { fields => ['SIMPLE','SIZE'] });
	}
	
	if ( $r->{phylum_no} )
	{
	    $r->{phylum_txn} = $taxonomy->get_taxon($r->{phylum_no}, { fields => ['SIMPLE','SIZE'] });
	}
	
	if ( $r->{class_no} )
	{
	    $r->{class_txn} = $taxonomy->get_taxon($r->{class_no}, { fields => ['SIMPLE','SIZE'] });
	}
	
	if ( $r->{order_no} )
	{
	    $r->{order_txn} = $taxonomy->get_taxon($r->{order_no}, { fields => ['SIMPLE','SIZE'] });
	}
	
	if ( $r->{family_no} )
	{
	    $r->{family_txn} = $taxonomy->get_taxon($r->{family_no}, { fields => ['SIMPLE','SIZE'] });
	}
	
	if ( $r->{parsen_no} || $r->{parent_no} )
	{
	    my $parent_no = $r->{parsen_no} || $r->{parent_no};
	    $r->{parent_txn} = $taxonomy->get_taxon($parent_no, { fields => ['SIMPLE','SIZE'] });
	}
	
	# Then add the various lists of subtaxa.
	
	my $data = ['SIMPLE','SIZE','APP'];
	
	unless ( $r->{phylum_no} or (defined $r->{rank} && $r->{rank} <= 20) )
	{
	    $r->{phylum_list} = [ $taxonomy->list_taxa($taxon_no, 'all_children',
						     { limit => 10, order => 'size.desc', rank => 20, fields => $data } ) ];
	}
	
	unless ( $r->{class_no} or $r->{rank} <= 17 )
	{
	    $r->{class_list} = [ $taxonomy->list_taxa('all_children', $taxon_no, 
						    { limit => 10, order => 'size.desc', rank => 17, fields => $data } ) ];
	}
	
	unless ( $r->{order_no} or $r->{rank} <= 13 )
	{
	    my $order = defined $r->{order_count} && $r->{order_count} > 100 ? undef : 'size.desc';
	    $r->{order_list} = [ $taxonomy->list_taxa('all_children', $taxon_no, 
						    { limit => 10, order => $order, rank => 13, fields => $data } ) ];
	}
	
	unless ( $r->{family_no} or $r->{rank} <= 9 )
	{
	    my $order = defined $r->{family_count} && $r->{family_count} > 100 ? undef : 'size.desc';
	    $r->{family_list} = [ $taxonomy->list_taxa('all_children', $taxon_no, 
						     { limit => 10, order => $order, rank => 9, fields => $data } ) ];
	}
	
	if ( $r->{rank} > 5 )
	{
	    my $order = defined $r->{genus_count} && $r->{order_count}> 100 ? undef : 'size.desc';
	    $r->{genus_list} = [ $taxonomy->list_taxa('all_children', $taxon_no,
						    { limit => 10, order => $order, rank => 5, fields => $data } ) ];
	}
	
	if ( $r->{rank} == 5 )
	{
	    $r->{subgenus_list} = [ $taxonomy->list_taxa('all_children', $taxon_no,
						       { limit => 10, order => 'size.desc', rank => 4, fields => $data } ) ];
	}
	
	if ( $r->{rank} == 5 or $r->{rank} == 4 )
	{
	    $r->{species_list} = [ $taxonomy->list_taxa('all_children', $taxon_no,
						       { limit => 10, order => 'size.desc', rank => 3, fields => $data } ) ];
	}
	
	$r->{children} = 
	    [ $taxonomy->list_taxa('children', $taxon_no, { limit => 10, order => 'size.desc', fields => $data } ) ];
    }
    
    $self->delete_output_field('exclude');
    
    return 1;
}


# get_opinion ( )
# 
# Retrieve a single opinion record from the database, selected by identifier.

sub get_opinion {
    
    my ($request) = @_;
    
    my $dbh = $request->get_connection;
    my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
    # First figure out which opinion we are looking for.  If none was
    # specified (this shouldn't happen), then we use an invalid opinion_no to
    # select no records.
    
    my $opinion_no = $request->clean_param('id') || return;
    
    my $options = $request->generate_query_fields( 'opinions', { } );
    
    # Next fetch the requested info about the opinion.
    
    my ($r);
    
    try {
	($r) = $taxonomy->list_opinions($opinion_no, $options);
    }
    
    catch {
	print STDERR $taxonomy->last_sql . "\n\n" if $request->debug;
	die $_;
    };
    
    $request->single_result($r) if $r;
    $request->{main_sql} = $taxonomy->last_sql;
    print STDERR $request->{main_sql} . "\n\n" if $request->debug;
}


# list_taxa ( )
# 
# Query the database for basic info about all taxa matching the specified
# parameters.  If the argument 'refs' is given, then return matching
# references instead of matching taxa.

sub list_taxa {
    
    my ($request) = @_;
    
    my $dbh = $request->get_connection;
    my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
    # First, figure what field sare necessary to show the requested info.
    
    my $options = $request->generate_query_fields( 'taxa', { } );
    
    # Figure out the set of taxa we are being asked for.
    
    my ($rel, $base) = $request->generate_query_base($taxonomy);
    
    # Then generate the rest of the query options using the request parameters.
    
    $request->generate_query_options( 'taxa', $options );
    
    # For relationships that could return a long list of taxa, we ask for a
    # DBI statement handle.  For these operations, we remove the 'exclude'
    # field since excluded taxa will never appear in the result.
    
    if ( $rel eq 'all_children' || $rel eq 'all_taxa' )
    {
	$options->{return} = 'stmt';
	$request->delete_output_field('exclude');
    }
    
    # Otherwise, we ask for a list of taxon records.  For certain operations,
    # we leave the 'exclude' field in place so that excluded taxa can be
    # marked.  Otherwise, we remove it.
    
    elsif ( $rel eq 'self' || $rel eq 'exact' || $rel eq 'current' ||
	    $rel eq 'accepted' || $rel eq 'senior' )
    {
	$options->{return} = 'list';
    }
    
    else
    {
	$options->{return} = 'list';
	$request->delete_output_field('exclude');
    }
    
    # Now execute the query.
    
    try {
	my @result = $taxonomy->list_taxa($rel, $base, $options);
	my @warnings = $taxonomy->list_warnings;
	
	if ( $options->{return} eq 'stmt' )
	{
	    $request->sth_result($result[0]) if $result[0];
	}
	
	else
	{
	    $request->list_result(\@result);
	}
    }
    
    catch {
	print STDERR $request->last_sql . "\n\n" if $request->debug;
	die $_;
    };
    
    $request->set_result_count($taxonomy->last_rowcount) if $options->{count};
    $request->{main_sql} = $taxonomy->last_sql;
    print STDERR $request->{main_sql} . "\n\n" if $request->debug;
}


sub taxa_refs {

}


sub taxa_byref {


}


sub taxa_opinions {


}

# taxa_refs
# 
# 


# sub list {

#     my ($request, $arg) = @_;
    
#     my $dbh = $request->get_connection;
#     my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
#     # First, figure out what info we need to provide
    
#     my $options = $request->generate_query_options($arg);
#     my ($base, $rel) = $request->generate_query_base();
    
#     # Then, figure out which taxa we are looking for.
    
#     my $name_list = $request->clean_param('name');
#     my $id_list = $request->clean_param('id');
#     my $rel = $request->clean_param('rel') || 'self';
    
#     if ( my $base_name = $request->clean_param('base_name') )
#     {
# 	$name_list = $base_name;
# 	$rel = 'all_children';
#     }
    
#     elsif ( my $base_id = $request->clean_param('base_id') )
#     {
# 	$id_list = $base_id;
# 	$rel = 'all_children';
#     }
    
#     # If we are listing by name (as opposed to id) then go through each name and
#     # find the largest matching taxon.
    
#     if ( $name_list )
#     {
# 	my @names = ref $name_list eq 'ARRAY' ? @$name_list : $name_list;
# 	my (@taxa, @warnings);
	
# 	foreach my $name (@names)
# 	{
# 	    push @taxa, $taxonomy->resolve_names($name);
# 	    push @warnings, $taxonomy->list_warnings;
# 	}
	
# 	$request->add_warning(@warnings) if @warnings;
# 	return unless @taxa;
# 	$id_list = \@taxa;
#     }
    
#     # Now do the main query and return a result:
    
#     # If the argument is 'refs', then return matching references.
    
#     if ( defined $arg && $arg eq 'refs' )
#     {
# 	my $select = $request->clean_param('select');
# 	$select = join q{,}, @$select if ref $select eq 'ARRAY';
# 	$request->delete_output_field('n_occs') unless $select =~ qr{all|occs};
# 	$request->delete_output_field('n_colls') unless $select =~ qr{all|colls};
# 	$request->delete_output_field('n_opinions') unless $select =~ qr{all|taxonomy|opinions};
# 	$request->delete_output_field('n_class') unless $select =~ qr{all|taxonomy|class|opinions};
	
# 	if ( $rel eq 'self' )
# 	{
# 	    my @result = $taxonomy->list_refs('self', $id_list, $options);
# 	    $request->list_result(@result);
# 	    $request->delete_output_field('exclude') unless $name_list =~ qr{\^};
# 	}
	
# 	else
# 	{
# 	    $options->{return} = 'stmt';
	    
# 	    try {
# 		my $sth = $taxonomy->list_refs($rel, $id_list, $options);
# 		$request->sth_result($sth);
# 		$request->set_result_count($taxonomy->last_rowcount);
# 	    }
		
# 	    catch {
# 		print STDERR $taxonomy->last_sql . "\n\n";
# 		die $_;
# 	    };
# 	}
#     }
    
#     elsif ( defined $arg && $arg eq 'opinions' )
#     {
# 	$options->{return} = 'stmt';
	
# 	try {
# 	    my $sth = $taxonomy->taxa_opinions($rel, $id_list, $options);
# 	    $request->sth_result($sth);
# 	    $request->set_result_count($taxonomy->last_rowcount);
# 	}
	
# 	catch {
# 	    print STDERR $taxonomy->last_sql . "\n\n";
# 	    die $_;
# 	};
#     }
    
#     # Otherwise, return matching taxa.  If the relationship is 'self' (the
#     # default) then just return the list of matches.
    
#     elsif ( $rel eq 'self' )
#     {
# 	my @result = $taxonomy->list_taxa_simple($id_list, $options);
# 	$request->{main_result} = \@result;
#     }
    
#     # If the relationship is 'common_ancestor', we have just one result.
    
#     elsif ( $rel eq 'common_ancestor' || $rel eq 'common' ) # $$$
#     {
# 	$options->{return} = 'list';
	
# 	my ($taxon) = $taxonomy->list_taxa('common', $id_list, $options);
# 	$request->single_result($taxon) if $taxon;
# 	$request->delete_output_field('exclude');
#     }
    
#     # Otherwise, we just call list_taxa and return the result.
    
#     else
#     {
# 	$options->{return} = 'stmt';
# 	$rel ||= 'self';
	
# 	my $sth = $taxonomy->list_taxa($rel, $id_list, $options);
# 	$request->sth_result($sth) if $sth;
# 	$request->set_result_count($taxonomy->last_rowcount);
# 	$request->delete_output_field('exclude');
#     }
    
#     $request->{main_sql} = $taxonomy->last_sql;
#     print STDERR $request->{main_sql} . "\n\n" if $request->debug;
    
#     # Otherwise, we have an empty result.
    
#     return;
# }


# match ( )
# 
# Query the database for basic info about all taxa matching the specified name
# or names (as well as any other conditions specified by the parameters).

sub match {
    
    my ($self) = @_;
    
    my $dbh = $self->get_connection;
    my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
    # Make sure we have at least one valid name.
    
    my $name_list = $self->clean_param('name');
    
    return unless $name_list;
    
    # Figure out the proper query options.
    
    my $options = $self->generate_query_options();
    
    # Get the list of matches.
    
    my @name_matches = $taxonomy->resolve_names($name_list, $options);
    
    my $sql = $taxonomy->last_sql;
    my @warnings = $taxonomy->list_warnings;
    
    $self->add_warning(@warnings) if @warnings;
    
    print STDERR "$sql\n\n" if $sql;
    
    $self->list_result(@name_matches);
}


# sub get_opinion {
    
#     my ($request) = @_;
    
#     my $dbh = $request->get_connection;
#     my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
#     my $opinion_no = $request->clean_param('id');
    
#     unless ( defined $opinion_no && $opinion_no > 0 )
#     {
# 	return;
#     }
    
#     # Now add the fields necessary to show the requested info.
    
#     my $options = $request->generate_query_options('opinions');
    
#     # Next, fetch basic info about the taxon.
    
#     my $r;
    
#     try {
# 	($r) = $taxonomy->list_opinions($opinion_no, $options);
#     }
    
#     catch {
# 	print STDERR $taxonomy->last_sql . "\n\n";
# 	die $_;
#     };
    
#     return unless ref $r;
    
#     $request->single_result($r);
#     $request->{main_sql} = $taxonomy->last_sql;
    
#     print STDERR $request->{main_sql} . "\n\n" if $request->debug;
    
#     return 1;
# }


sub list_opinions {
    
    my ($request) = @_;
    
    my $dbh = $request->get_connection;
    my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
    my @opinion_nos = $request->clean_param_list('id');
    
    # return unless grep { $_ > 0 } @opinion_nos;
    
    my $options = $request->generate_query_options('opinions');
    
    $options->{return} = 'stmt';
    
    # Next, fetch the list of opinion records.
    
    my $sth;
    
    try {
	$sth = $taxonomy->list_opinions(\@opinion_nos, $options);
	$request->sth_result($sth);
	$request->set_result_count($taxonomy->last_rowcount);
    }
    
    catch {
	print STDERR $taxonomy->last_sql . "\n\n";
	die $_;
    };
    
    print STDERR $taxonomy->last_sql . "\n\n" if $request->debug;
}


# list_refs ( )
# 
# Query the database for basic info about all references associated with taxa
# that meet the specified parameters.

# sub list_refs {

#     my ($self) = @_;
    
#     my $dbh = $self->get_connection;
#     my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
#     # First, figure out what info we need to provide
    
#     my $options = $self->generate_query_options('ref');
    
#     my $rel = $self->clean_param('rel') || 'self';
    
#     # If the parameter 'name' was given, then fetch all matching taxa.  Order
#     # them in descending order by size.
    
#     my @taxon_list;
    
#     if ( $self->clean_param('name') )
#     {
# 	my $name = $self->clean_param('name');
# 	my $name_select = { order => 'size.desc', spelling => 'exact', return => 'id', limit => 1 };
	
# 	@taxon_list = $self->get_taxa_by_name($name, $name_select);
# 	return unless @taxon_list;
#     }
    
#     # Now do the main query and return a result:
    
#     # If a name was given and the relationship is 'self' (or not specified,
#     # being the default) then just return the list of matches.
    
#     if ( $self->clean_param('name') and $rel eq 'self' )
#     {
# 	my @result = $taxonomy->getTaxonReferences('self', \@taxon_list, $options);
# 	$self->{main_result} = \@result;
# 	$self->{main_sql} = $TaxonomyOld::SQL_STRING;
# 	$self->{result_count} = scalar(@result);
#     }
    
#     # If a name was given and some other relationship was specified, use the
#     # first matching name.
    
#     elsif ( $self->clean_param('name') )
#     {
# 	$options->{return} = 'stmt';
# 	my $id = $taxon_list[0];
# 	my $rel = $self->clean_param('rel') || 'self';
	
# 	($self->{main_sth}) = $taxonomy->getTaxonReferences($rel, $id, $options);
# 	$self->{main_sql} = $TaxonomyOld::SQL_STRING;
# 	$self->sql_count_rows;
#     }
    
#     # Otherwise, we just call getTaxa with a list of ids. 
    
#     elsif ( $self->clean_param('id') )
#     {
# 	$options->{return} = 'stmt';
# 	my $id_list = $self->clean_param('id');
	
#     }
    
#     # Otherwise, we have an empty result.
    
#     return;
# }


# get_taxa_by_name ( names, options )
# 
# Given a taxon name (or list of names), return either a list of ids or a
# range expression that can be used to select the corresponding taxa.

our ($NAME_SQL) = '';

sub get_taxa_by_name {

    my ($self, $names, $options) = @_;
    
    $options ||= {};
    my $dbh = $self->get_connection;
    
    # We start with some common query clauses, depending on the options.
    
    my (@clauses);
    my $order_string = 'ORDER BY v.taxon_size';
    my $limit_string = '';
    my $fields = 't.orig_no';
    
    # Do we accept common names?
    
    if ( $DB_FIELD{common} && defined $options->{common} && $options->{common} eq 'only' )
    {
	push @clauses, "common = 'EN'";
    }
    
    elsif ( $DB_FIELD{common} && $options->{common} )
    {
	push @clauses, "common = ''";
    }
    
    # Invalid names?
    
    my $status = $options->{status} // 'any';
    
    if ( $status eq 'valid' )
    {
	push @clauses, "status in ('belongs to', 'objective synonym of', 'subjective synonym of')";
    }
    
    elsif ( $status eq 'senior' )
    {
	push @clauses, "status in ('belongs to')";
    }
    
    elsif ( $status eq 'invalid' )
    {
	push @clauses, "status not in ('belongs to', 'objective synonym of', 'subjective synonym of')";
    }
    
    elsif ( $status ne 'any' && $status ne 'all' )
    {
	push @clauses, "status = 'bad_value'";
    }
    
    # Number of results
    
    unless ( $options->{all_names} )
    {
	$limit_string = "LIMIT 1";
    }
    
    # Result fields
    
    if ( $options->{return} eq 'range' )
    {
	$fields = "t.orig_no, t.name, t.lft, t.rgt";
    }
    
    elsif ( $options->{return} eq 'id' )
    {
	$fields = $options->{exact} ? 's.taxon_no' : 't.orig_no';
    }
    
    else
    {
	$fields = "s.taxon_name as match_name, t.orig_no, t.name as taxon_name, t.rank as taxon_rank, t.status, v.taxon_size, t.orig_no, t.trad_no as taxon_no";
    }
    
    # The names might be given as a list, a hash, or a single string (in which
    # case it will be split into comma-separated items).
    
    my @name_list;
    
    if ( ref $names eq 'ARRAY' )
    {
	@name_list = @$names;
    }
    
    elsif ( ref $names eq 'HASH' )
    {
	@name_list = keys %$names;
    }
    
    elsif ( ref $names )
    {
	croak "get_taxa_by_name: parameter 'names' may not be a blessed reference";
    }
    
    else
    {
	@name_list = split( qr{\s*,\s*}, $names );
    }
    
    # Now that we have a list, we evaluate the names one by one.
    
    my (@result);
    
 NAME:
    foreach my $tn ( @name_list )
    {
	my @filters;
	
	# We start by removing any bad characters and trimming leading and
	# trailing spaces.  Also translate all whitespace to a single space
	# and '.' to the wildcard '%'.  For example, "T.  rex" goes to
	# "T% rex";
	
	$tn =~ s/^\s+//;
	$tn =~ s/\s+$//;
	$tn =~ s/\s+/ /g;
	$tn =~ s/\./% /g;
	$tn =~ tr{a-zA-Z%_: }{}cd;
	
	# If we have a selection prefix, evaluate it and add the proper range
	# filter.
	
	if ( $tn =~ qr { [:] }xs )
	{
	    my $range = '';
	    
	    while ( $tn =~ qr{ ^ ([^:]+) : \s* (.*) }xs )
	    {
		my $prefix = $1;
		$tn = $2;
		
		# A prefix is only valid if it's a single word.  Otherwise, we
		# skip this name entirely because with an invalid prefix it cannot
		# evaluate to any actual name entry.
		
		if ( $prefix =~ qr{ ^ \s* ([a-zA-Z][a-zA-Z%]+) \s* $ }xs )
		{
		    $range = $self->get_taxon_range($1, $range);  
		}
		
		else
		{
		    next NAME;
		}
	    }
	    
	    # If we get here, we have evaluated all prefixes.  So add the
	    # resulting range to the list of filters.
	    
	    push @filters, $range if $range;
	}
	
	# Now, we determine the query necessary to find each name.
	
	# If we have a species name, we need to filter on both genus and
	# species name.  The name is not valid unless we have at least one
	# alphabetic character in the genus and one in the species.
	
	if ( $tn =~ qr{ ^ ([^\s]+) \s+ (.*) }xs )
	{
	    my $genus = $1;
	    my $species = $2;
	    
	    next unless $genus =~ /[a-zA-Z]/ && $species =~ /[a-zA-Z]/;
	    
	    # We don't have to quote these, because we have already eliminated
	    # all characters except alphabetic and wildcards.
	    
	    push @filters, "genus like '$genus'";
	    push @filters, "taxon_name like '$species'";
	}
	
	# If we have a higher taxon name, we just need to filter on that.  The
	# name is not valid unless it contains at least two alphabetic
	# characters. 
	
	elsif ( $tn =~ qr{ ^ ([^\s]+) $ }xs )
	{
	    my $higher = $1;
	    
	    next unless $higher =~ qr< [a-zA-Z]{2} >xs;
	    
	    push @filters, "taxon_name like '$higher' and taxon_rank >= 5";
	}
	
	# Otherwise, we have an invalid name so just skip it.
	
	else
	{
	    next NAME;
	}
	
	# Now, construct the query.
	
	my $filter_string = join(' and ', @clauses, @filters);
	$filter_string = '1=1' unless $filter_string;
	
	my $s_field = $DB_FIELD{orig_no} ? 'orig_no' : 'result_no';
	my $current_clause = $DB_FIELD{is_current} ? 's.is_current desc,' : '';
	
	$NAME_SQL = "
		SELECT $fields
		FROM taxon_search as s join taxon_trees as t on t.orig_no = s.$s_field
			join taxon_attrs as v on v.orig_no = t.orig_no
		WHERE $filter_string
		ORDER BY $current_clause v.taxon_size desc
		$limit_string";
	
	print STDERR $NAME_SQL . "\n\n" if $self->debug;
	
	my $records;
	
	if ( $options->{return} eq 'id' )
	{
	    $records = $dbh->selectcol_arrayref($NAME_SQL);
	}
	
	else
	{
	    $records = $dbh->selectall_arrayref($NAME_SQL, { Slice => {} });
	}
	
	push @result, @$records if ref $records eq 'ARRAY';
    }
    
    return @result;
}


sub get_taxon_range {
    
    my ($self, $name, $range) = @_;
    
    my $dbh = $self->get_connection;
    my $range_filter = $range ? "and $range" : "";
    
    my $sql = "
		SELECT t.lft, t.rgt
		FROM taxon_search as s JOIN taxon_trees as t on t.orig_no = s.synonym_no
			JOIN taxon_attrs as v on v.orig_no = t.orig_no
		WHERE s.taxon_name like '$name' $range_filter
		ORDER BY v.taxon_size LIMIT 1";
    
    my ($lft, $rgt) = $dbh->selectrow_array($sql);
    
    return $lft ? "t.lft between $lft and $rgt" : "t.lft = 0";
}


# generate_query_fields ( )
# 
# Add a 'fields' option to the specified query options hash, according to the
# request parameters.  Then return the options hashref.

sub generate_query_fields {

    my ($request, $operation, $options) = @_;
    
    my @fields = $request->select_list_for_taxonomy($operation);
    
    if ( $operation eq 'refs' )
    {
	push @fields, 'REF_COUNTS' if $request->has_block('counts');
    }
    
    $options->{fields} = \@fields;
    
    return $options;
}


# generate_query_options ( )
# 
# Return an options hash, based on the parameters, which can be passed to
# getTaxaByName or getTaxa.

sub generate_query_options {
    
    my ($request, $operation, $options) = @_;
    
    my $limit = $request->result_limit;
    my $offset = $request->result_offset(1);
    
    $options->{limit} = $limit if defined $limit;	# $limit may be 0
    $options->{offset} = $offset if $offset;
    $options->{count} = 1 if $request->display_counts;
    
    my $extant = $request->clean_param('extant');
    my $rank = $request->clean_param('rank');
    my $status = $request->clean_param('status');
    my @select = $request->clean_param_list('select');
    
    $options->{extant} = $extant if $extant ne '';	# $extant may be 0, 1, or undefined
    $options->{status} = $status if $status ne '';
    
    if ( $rank )
    {
	$options->{rank} = $rank;
    }
    
    if ( @select )
    {
	$options->{select} = \@select;
    }
    
    # If the user specified 'interval' or 'interval_id', then figure out the
    # corresponding max_ma and min_ma values.
    
    my ($int_max_ma, $int_min_ma) = $request->check_interval_params();
    
    # Check if the user specified these directly.  If so, they will override.
    
    my $max_ma = $request->clean_param('max_ma');
    my $min_ma = $request->clean_param('min_ma');
    
    if ( $max_ma ne '' )
    {
	die "400 bad value '$max_ma' for 'max_ma', must be greater than zero"
	    unless $max_ma > 0;
    }
    
    if ( $min_ma ne '' )
    {
	die "400 bad value '$min_ma' for 'min_ma', must be greater than or equal to zero"
	    unless $min_ma >= 0;
    }
    
    $max_ma = $int_max_ma if $max_ma eq '';
    $min_ma = $int_min_ma if $min_ma eq '';
    
    $options->{max_ma} = $max_ma if defined $max_ma && $max_ma > 0;
    $options->{min_ma} = $min_ma if defined $min_ma && $min_ma > 0;
    
    # Now check for author & publication date
    
    if ( $operation eq 'opinions' )
    {
	my $max_pubyr = $request->clean_param('published_before');
	my $min_pubyr = $request->clean_param('published_after');
	my $pubyr = $request->clean_param('published');
	my $author = $request->clean_param('author');
	
	if ( $pubyr =~ qr{ ^ ( \d\d\d\d ) (?: \s* - \s* ( \d+ ) )? $ }xs )
	{
	    $min_pubyr = $1;
	    $max_pubyr = $2 || $1;
	    
	    if ( length($max_pubyr) < 4 )
	    {
		$max_pubyr = substr($min_pubyr, 0, 4 - length($max_pubyr)) . $max_pubyr;
	    }
	}
	
	elsif ( $pubyr )
	{
	    die "400 the parameter 'published' must be a year or range of years (was '$pubyr')\n";
	}
	
	if ( $max_pubyr )
	{
	    $options->{op_max_pubyr} = $max_pubyr;
	}
	
	if ( $min_pubyr )
	{
	    $options->{op_min_pubyr} = $min_pubyr;
	}
	
	if ( $author )
	{
	    my @authors = split qr{\s*,\s*}, $author;
	    $options->{op_author} = \@authors;
	}
    }
    
    # Check for created, modified, authorized_by, etc.
    
    my @params = $request->param_keys();
    
    foreach my $key ( @params )
    {
	my $value = $request->clean_param($key);
	next unless $value ne '';
	
	if ( $key =~ $CommonData::COMMON_OPT_RE )
	{
	    if ( $1 eq '' )
	    {
		if ( $operation eq 'opinions' )
		{
		    $options->{"ops_$2"} = $value;
		}
		
		elsif ( $operation eq 'refs' )
		{
		    $options->{"refs_$2"} = $value;
		}
		
		else
		{
		    $options->{$2} = $value;
		}
	    }
	    
	    else
	    {
		$options->{$key} = $value;
	    }
	}
    }
    
    # If we have any ordering terms, then apply them.
    
    my (@orders);
	
    foreach my $term ( $request->clean_param_list('order') )
    {
	next unless $term;
	
	my $dir;
	
	if ( $term =~ /^(\w+)[.](asc|desc)$/ )
	{
	    $term = $1;
	    $dir = $2;
	}
	
	# The following options default to ascending.
	
	if ( $term eq 'hierarchy' || $term eq 'pubyr' || $term eq 'created' || $term eq 'modified' || $term eq 'name' ||
	     $term eq 'author' || $term eq 'pubyr' )
	{
	    $dir ||= 'asc';
	}
	
	# The following options default to descending.
	
	elsif ( $term eq 'firstapp' || $term eq 'lastapp' || $term eq 'agespan' || $term eq 'basis' ||
		$term eq 'size' || $term eq 'extant_size' || $term eq 'n_occs' || $term eq 'extant' )
	{
	    $dir ||= 'desc';
	}
	
	# If we find an unrecognized option, throw an error.
	
	else
	{
	    $request->add_warning("unrecognized order option '$term'");
	    next;
	}
	
	# Add the direction (asc or desc) if one was specified.
	
	push @orders, "$term.$dir";
    }
    
    $options->{order} = \@orders if @orders;
    
    return $options;
}


# select_list_for_taxonomy ( type )
# 
# Retrieve the selection list for the current request, and then translate any
# field names coming from this module into the proper field specifiers for the
# routines in Taxonomy.pm.
# 
# The parameter $type indicates what type of record is being requested.
# Allowed values are 'refs' for references, 'opinions' for opinions, or 'taxa' for
# taxa (the default if not specified).

sub select_list_for_taxonomy {

    my ($request, $operation) = @_;
    
    my @fields;
    
    $operation //= 'taxa';
    
    croak "bad value '$operation' for 'operation': must be 'refs', 'opinions', or 'taxa'"
	if $operation ne 'refs' && $operation ne 'opinions' && $operation ne 'taxa';
    
    foreach my $f ( $request->select_list )
    {
	if ( $f =~ qr{^\$cd\.created} )
	{
	    push @fields, $operation eq 'refs'     ? 'REF_CRMOD'
			: $operation eq 'opinions' ? 'OP_CRMOD'
					      : 'CRMOD';
	}
	
	elsif ( $f =~ qr{^\$cd\.authorizer_no} )
	{
	    push @fields, $operation eq 'refs'     ? 'REF_AUTHENT'
			: $operation eq 'opinions' ? 'OP_AUTHENT'
					      : 'AUTHENT';
	}
	
	elsif ( $f =~ qr{^r\.reference_no} )
	{
	    push @fields, 'REF_DATA';
	}
	
	elsif ( $f =~ qr{^rs\.n_taxa} || $f eq 'COUNTS' )
	{
	    push @fields, 'REF_COUNTS' if $operation eq 'refs';
	}
	
	elsif ( $f !~ qr{^\$cd\.|^r\.|^rs\.} )
	{
	    push @fields, $f;
	}
    }
    
    return @fields;
}


# generate_query_base ( taxonomy )
# 
# Generate the set of base taxon identifiers and the relationship code that
# will be used to satisfy the request for which this routine has been called.

sub generate_query_base {
    
    my ($request, $taxonomy) = @_;
    
    # First see which parameters were given.
    
    my $name_list = $request->clean_param('name');
    my $id_list = $request->clean_param('id');
    my $specified_rel = $request->clean_param('rel');
    my $rel;
    
    if ( my $base_name = $request->clean_param('base_name') )
    {
	$name_list = $base_name;
	$rel = $specified_rel || 'all_children';
    }
    
    elsif ( my $base_id = $request->clean_param('base_id') )
    {
	$id_list = $base_id;
	$rel = $specified_rel || 'all_children';
    }
    
    else
    {
	$rel = $specified_rel || 'current';
    }
    
    
    # If we are listing by name (as opposed to id) then go through each name and
    # find the largest matching taxon.
    
    if ( $name_list )
    {
	my @names = ref $name_list eq 'ARRAY' ? @$name_list : $name_list;
	my (@taxa, @warnings);
	
	foreach my $name (@names)
	{
	    push @taxa, $taxonomy->resolve_names($name);
	    push @warnings, $taxonomy->list_warnings;
	}
	
	$request->add_warning(@warnings) if @warnings;
	return unless @taxa;
	$id_list = \@taxa;
    }
    
    # Return the relationship and base taxa.
    
    return ($rel, $id_list);
}


# auto ( )
# 
# Return an auto-complete list, given a partial name.

sub auto {
    
    my ($self) = @_;
    
    my $dbh = $self->get_connection;
    my $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
    
    my $partial = $self->clean_param('name');
    
    my $search_table = $taxonomy->{SEARCH_TABLE};
    my $names_table = $taxonomy->{NAMES_TABLE};
    my $attrs_table = $taxonomy->{ATTRS_TABLE};
    
    my $sql;
    
    # Strip out any characters that don't appear in names.  But allow SQL wildcards.
    
    $partial =~ tr/[a-zA-Z_%. ]//dc;
    
    # Construct and execute an SQL statement.
    
    my $limit = $self->sql_limit_clause(1);
    my $calc = $self->sql_count_clause;
    
    my $result_field = $DB_FIELD{accepted_no} ? 's.accepted_no' : 's.synonym_no';
    my $match_field = $DB_FIELD{orig_no} ? 's.taxon_no' : 's.match_no';
    
    my $fields = "taxon_rank, $match_field as taxon_no, n_occs, if(spelling_reason = 'misspelling', 1, null) as misspelling";
    
    # If we are given a genus (possibly abbreviated), generate a search on
    # genus and species name.
    
    if ( $partial =~ qr{^([a-zA-Z_]+)(\.|[.%]? +)([a-zA-Z_]+)} )
    {
	my $genus = $2 ? $dbh->quote("$1%") : $dbh->quote($1);
	my $species = $dbh->quote("$3%");
	
	$sql = "SELECT $calc concat(genus, ' ', taxon_name) as taxon_name, $fields
		FROM $search_table as s JOIN $attrs_table as v on v.orig_no = $result_field
			JOIN $names_table as n on n.taxon_no = $match_field
		WHERE genus like $genus and taxon_name like $species ORDER BY n_occs desc $limit";
    }
    
    # If we are given a single name followed by one or more spaces and nothing
    # else, take it as a genus name.
    
    elsif ( $partial =~ qr{^([a-zA-Z]+)([.%])? +$} )
    {
	my $genus = $2 ? $dbh->quote("$1%") : $dbh->quote($1);
	
	$sql = "SELECT $calc concat(genus, ' ', taxon_name) as taxon_name, $fields
		FROM $search_table as s JOIN $attrs_table as v on v.orig_no = $result_field
			JOIN $names_table as n on n.taxon_no = $match_field
		WHERE genus like $genus ORDER BY n_occs desc $limit";
    }
    
    # Otherwise, if it has no spaces then just search for the name.  Turn all
    # periods into wildcards.
    
    elsif ( $partial =~ qr{^[a-zA-Z_%.]+$} )
    {
	return if length($partial) < 3;
	
	$partial =~ s/\./%/g;
	
	my $name = $dbh->quote("$partial%");
	
	$sql = "SELECT $calc if(genus <> '', concat(genus, ' ', taxon_name), taxon_name) as taxon_name, $fields
	        FROM $search_table as s JOIN $attrs_table as v on v.orig_no = $result_field
			JOIN $names_table as n on n.taxon_no = $match_field
	        WHERE taxon_name like $name ORDER BY n_occs desc $limit";
    }
    
    $self->{main_sql} = $sql;
    
    print STDERR $sql . "\n\n" if $self->debug;
    
    $self->{main_sth} = $dbh->prepare($sql);
    $self->{main_sth}->execute();
}


# get_image ( )
# 
# Given an id (image_no) value, return the corresponding image if the format
# is 'png', and information about it if the format is 'json'.

sub get_image {
    
    my ($self, $type) = @_;
    
    $type ||= '';
    
    my $dbh = $self->get_connection;
    my ($sql, $result);
    
    croak "invalid type '$type' for get_image"
	unless $type eq 'icon' || $type eq 'thumb';
    
    my $image_no = $self->clean_param('id');
    my $format = $self->output_format;
    
    # If the output format is 'png', then query for the image.  If found,
    # return it in $self->{main_data}.  Otherwise, we throw a 404 error.
    
    if ( $format eq 'png' )
    {
	$self->{main_sql} = "
		SELECT $type FROM $PHYLOPICS as p
		WHERE image_no = $image_no";
	
	print STDERR "$self->{main_sql}\n\n" if $self->debug;
	
	($self->{main_data}) = $dbh->selectrow_array($self->{main_sql});
	
	return if $self->{main_data};
	die "404 Image not found\n";	# otherwise
    }
    
    # If the output format is 'json' or one of the text formats, then query
    # for information about the image.  Return immediately regardless of
    # whether or not a record was found.  If not, an empty response will be
    # generated.
    
    else
    {
	my $fields = $self->select_string();
	
	$self->{main_sql} = "
		SELECT $fields FROM $PHYLOPICS
		WHERE image_no = $image_no";
	
	print STDERR "$self->{main_sql}\n\n" if $self->debug;
	
	$self->{main_record} = $dbh->selectrow_hashref($self->{main_sql});
	
	return;
    }
}


# list_images ( )
# 
# Return a list of images that meet the specified criteria.

sub list_images {

    my ($self) = @_;
    
    my $dbh = $self->get_connection;
    my $taxonomy = TaxonomyOld->new($dbh, 'taxon_trees');
    my ($sql, $result);
    
    my @filters;
    
    # If the parameter 'name' was given, then fetch all matching taxa.  Order
    # them in descending order by size.
    
    my @taxon_list;
    
    if ( my $name = $self->clean_param('name') )
    {
	my $name_select = { spelling => 'exact', return => 'id' };
	
	@taxon_list = $self->get_taxa_by_name($name, $name_select);
	return unless @taxon_list;
    }
    
    else
    {
	@taxon_list = $self->clean_param_list('id');
    }
    
    # Now add any other filters that were specified by the parameters.
    
    if ( $self->clean_param('rel') eq 'all_children' )
    {
	push @filters, '';
    }
    
    if ( my $depth = $self->clean_param('depth') )
    {
	push @filters, '';
    }
    
    # Construct a query. $$$
    
    my $fields = $self->select_string();
    
    $self->{main_sql} = "
	SELECT $fields FROM $PHYLOPICS as p JOIN $PHYLOPIC_NAMES as n using (uid)
		JOIN authorities as a using (taxon_name) #etc
	WHERE image_no = image_no";
	
	$self->{main_record} = $dbh->selectrow_hashref($self->{main_sql});
	
	return;
    
}


# SQL generation auxiliary routines
# ---------------------------------

# generate_filters ( tables_ref )
# 
# Generate a list of filters that will be used to compute the appropriate
# result set.  Any additional tables that are needed will be indicated in
# $tables_ref.

sub generate_filters {

    my ($self, $tables_ref) = @_;
    
    my @filters;
    
    my $extant = $self->clean_param('extant');
    
    if ( defined $extant && $extant ne '' )
    {
	push @filters, "at.is_extant = $extant";
	$tables_ref->{at} = 1;
    }
    
    my @taxon_ranks = $self->clean_param_list('taxon_rank');
    my $rank_list = $self->generate_rank_list(@taxon_ranks) if @taxon_ranks;
    
    if ( defined $rank_list )
    {
	push @filters, "t.rank in ($rank_list)";
    }
    
    return @filters;
}


# generate_summary_expr ( summary_rank, occs_table, tree_table, ints_table )
# 
# Generate an expression to compute the appropriate summary level.

sub generate_summary_expr {
    
    my ($self, $summary_rank, $o, $t, $i) = @_;
    
    if ( $summary_rank eq 'exact' )
    {
	return "concat_ws(' ', $o.genus_name, $o.genus_reso, if($o.subgenus_name <> '', concat('(', concat_ws(' ', $o.subgenus_name, $o.subgenus_reso), ')'), null), $o.species_name, $o.species_reso)";
    }
    
    elsif ( $summary_rank eq 'ident' )
    {
	return "concat_ws(' ', $o.genus_name, if($o.subgenus_name <> '', concat('(', $o.subgenus_name, ')'), null), $o.species_name)";
    }
    
    elsif ( $summary_rank eq 'taxon' )
    {
	return "$o.orig_no";
    }
    
    elsif ( $summary_rank eq 'synonym' )
    {
	return "$t.synonym_no";
    }
    
    elsif ( $summary_rank eq 'species' )
    {
	return "ifnull($t.species_no, 0)";
    }
    
    elsif ( $summary_rank eq 'genus' )
    {
	return "ifnull($t.genus_no, 0)";
    }
    
    else
    {
	return "ifnull($i.${summary_rank}_no, 0)";
    }
}


# generate_order_clause ( rank_table )
# 
# Generate an SQL order expression for the result set.

sub generate_order_clause {

    my ($self, $tables, $options) = @_;
    
    $options ||= {};
    
    my @terms = $self->clean_param_list('order');
    my @exprs;
    
    foreach my $term (@terms)
    {
	my $dir = '';
	next unless $term;
	
	if ( $term =~ /^(\w+)[.](asc|desc)$/ )
	{
	    $term = $1;
	    $dir = $2;
	}
	
	if ( $term eq 'hierarchy' )
	{
	    push @exprs, "t.lft $dir";
	}
	
	elsif ( $term eq 'name' )
	{
	    push @exprs, "taxon_name $dir";
	}
	
	elsif ( $term eq 'pubyr' )
	{
	    push @exprs, "a.pubyr $dir";
	}
	
	elsif ( $term eq 'created' )
	{
	    push @exprs, "a.created $dir";
	}
	
	elsif ( $term eq 'modified' )
	{
	    push @exprs, "a.modified $dir";
	}
	
	elsif ( $term eq 'firstapp' )
	{
	    $dir ||= 'desc';
	    push @exprs, "at.first_early_age $dir";
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'lastapp' )
	{
	    $dir ||= 'desc';
	    push @exprs, "at.last_late_age $dir";
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'agespan' )
	{
	    push @exprs, "(at.first_early_age - at.last_late_age) $dir",
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'size' )
	{
	    $dir ||= 'desc';
	    push @exprs, "at.taxon_size $dir";
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'extant_size' )
	{
	    $dir ||= 'desc';
	    push @exprs, "at.extant_size $dir";
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'extant' )
	{
	    push @exprs, "at.is_extant $dir";
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'n_occs' )
	{
	    $dir ||= 'desc';
	    push @exprs, "at.n_occs $dir";
	    $tables->{at} = 1;
	}
	
	elsif ( $term eq 'rank' )
	{
	    my $rank_table = $options->{rank_table};
	    
	    die "400 You cannot select the order option 'rank' with this request"
		unless $rank_table;
	    
	    $dir ||= 'desc';
	    push @exprs, "associated_records $dir";
	}
	
	else
	{
	    die "400 unrecognized order option '$term'";
	}
    }
    
    return join(', ', @exprs);
}


# Utility routines
# ----------------

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
    
    no warnings 'numeric';
    no warnings 'uninitialized';
    
    my ($value, $context) = @_;
    
    my @selectors = split qr{\s*,\s*}, $value;
    my @ranks;
    
    foreach my $s (@selectors)
    {
	next unless $s;		# skip any blank entries
	
	if ( $s =~ qr{ ^ ( \w+ ) (?: \s*-\s* ( \w+ ) )? $ }x )
	{
	    my $rank = ($1 > 0 || $1 eq '0') ? $1 + 0 : $TAXON_RANK{$1};
	    
	    return { error => "invalid taxonomic rank '$1'" }
		unless defined $rank && $rank ne '';
	    
	    if ( $2 )
	    {
		my $rank_max = ($2 > 0 || $2 eq '0') ? $2 + 0 : $TAXON_RANK{$2};
		
		return { error => "invalid taxonomic rank '$2'" }
		    unless defined $rank_max && $rank_max ne '';
		
		if ( $rank_max < $rank )
		{
		    my $temp = $rank_max; $rank_max = $rank; $rank = $temp;
		}
		
		foreach my $r ( $rank .. $rank_max )
		{
		    push @ranks, $r;
		}
	    }
	    
	    else
	    {
		push @ranks, $rank;
	    }
	}
    }
    
    if ( @ranks == 0 )
    {
	return { value => '' };
    }
    
    else
    {
	return { value => \@ranks };
    }
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


# For each record, do any necessary processing.

sub process_pbdb {
    
    my ($request, $record) = @_;
    
    $record->{is_extant} = ! defined $record->{is_extant} ? ''
			 : $record->{is_extant} eq '1'    ? 'extant'
			 : $record->{is_extant} eq '0'    ? 'extinct'
							  : '?';
    
    $record->{n_orders} = undef if defined $record->{n_orders} && 
	$record->{n_orders} == 0 && $record->{taxon_rank} <= 13;
    
    $record->{n_families} = undef if defined $record->{n_families} &&
	$record->{n_families} == 0 && $record->{taxon_rank} <= 9;
    
    $record->{n_genera} = undef if defined $record->{n_genera} &&
	$record->{n_genera} == 0 && $record->{taxon_rank} <= 5;
    
    $record->{n_species} = undef if defined $record->{n_species} &&
	$record->{n_species} == 0 && $record->{taxon_rank} <= 3;
}


sub process_com {
    
    my ($request, $record) = @_;
    
    $record->{no_variant} = 1 if defined $record->{orig_no} && defined $record->{taxon_no} &&
	$record->{orig_no} eq $record->{taxon_no};
    
    $record->{no_variant} = 1 if defined $record->{orig_no} && defined $record->{child_spelling_no} &&
	$record->{orig_no} eq $record->{child_spelling_no};    
    
    foreach my $f ( qw(orig_no child_no parent_no senpar_no accepted_no base_no) )
    {
	$record->{$f} = "$IDP{TXN}$record->{$f}" if defined $record->{$f};
    }
    
    foreach my $f ( qw(taxon_no child_spelling_no parent_spelling_no parent_current_no) )
    {
	$record->{$f} = "$IDP{VAR}$record->{$f}" if defined $record->{$f};
    }
    
    foreach my $f ( qw(opinion_no) )
    {
	$record->{$f} = "$IDP{OPN}$record->{$f}" if defined $record->{$f};
    }
    
    if ( ref $record->{reference_no} eq 'ARRAY' )
    {
	map { $_ = "rid$_" } @{$record->{reference_no}};
    }
    
    elsif ( defined $record->{reference_no} )
    {
	$record->{reference_no} = "$IDP{REF}$record->{reference_no}";
    }
    
    $record->{n_orders} = undef if defined $record->{n_orders} && 
	$record->{n_orders} == 0 && $record->{taxon_rank} <= 13;
    
    $record->{n_families} = undef if defined $record->{n_families} &&
	$record->{n_families} == 0 && $record->{taxon_rank} <= 9;
    
    $record->{n_genera} = undef if defined $record->{n_genera} &&
	$record->{n_genera} == 0 && $record->{taxon_rank} <= 5;
    
    $record->{n_species} = undef if defined $record->{n_species} &&
	$record->{n_species} == 0 && $record->{taxon_rank} <= 3;
}


sub process_subgenus {
    
    my ($request, $record) = @_;
    
    if ( $record->{subgenus} )
    {
	$record->{genus} = $record->{subgenus};
    }
}


# The following hashes map the status codes stored in the opinions table of
# PaleoDB into taxonomic and nomenclatural status codes in compliance with
# Darwin Core.  The third one, %REPORT_ACCEPTED_TAXON, indicates which status
# codes should trigger the "acceptedUsage" and "acceptedUsageID" fields in the
# output.

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


# consolidate_basis ( record )
# 
# Generate consolidated 'basis' values from the '_basis_no' and '_basis_name'
# fields.

sub consolidate_basis {
    
    my ($request, $record ) = @_;
    
    foreach my $f ( qw(motility life_habit diet taphonomy) )
    {
	my $basis_no = $record->{"${f}_basis_no"};
	my $basis_name = $record->{"${f}_basis_name"};
	
	$record->{"${f}_basis"} = "$basis_name ($basis_no)" if $basis_no;
    }
}


1;
