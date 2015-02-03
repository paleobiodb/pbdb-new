# -*-mode: CPerl; -*-
# 
# PBDB LIB Taxonomy.pm
# --------------------
# 
# Test the module Taxonomy.pm.  This file tests the method 'list_refs'.

use strict;

use lib 'lib';
use lib 't';

use Test::More tests => 11;
use Test::Deep;
use Carp qw(carp croak);

use CoreFunction qw(connectDB configData);
use Taxonomy;

use Data::Dumper;


# We turn off warnings for uninitialized variables and non-numeric
# comparisons, because we don't want to clutter up our testing code with
# "defined $t1 && $t1->{foo} eq ...

no warnings 'uninitialized';
no warnings 'numeric';



my ($dbh, $taxonomy);

eval {
    $dbh = connectDB("config.yml");
    $taxonomy = Taxonomy->new($dbh, 'taxon_trees');
};

unless ( ok(defined $dbh && defined $taxonomy, "dbh acquired and taxonomy instantiated") )
{
    diag("message was: $@");
    BAIL_OUT;
}


my $NAME1 = 'Stegosauria';
my $ID1 = '38798';
my $TX1 = '147919';

my $REF1a = '34277';
my $PUB1a = 'Species concept in North American stegosaurs';

my $NAME2 = 'Stegosauridae';
my $ID2 = '38803';

my $NAME3 = 'Dascillidae';
my $ID3 = '69296';

my $REF3a = '36942';
my $PUB3a = 'Miocene insects and spiders from Shanwang, Shandong';
my $REF3b = '5170';

my $NAME4a = 'Dascillus';
my $ID4a = '71894';
my $REF4a = '16579';
my $PUB4a = 'Fossil Coleoptera from Florissant, with descriptions of several new species';
my $NAME4b = 'Dascyllus';
my $ID4b = '285777';
my $REF4b = '5167';
my $PUB4b = 'Fossil Insects From Shanwang, Shandong, China';

my $NAME5a = 'Stegosaurus';
my $ID5a = '38814';
my $NAME5b = 'Diracodon';
my $ID5b = '52992';


my $TREE_TABLE = $taxonomy->{TREE_TABLE};
my $AUTH_TABLE = $taxonomy->{AUTH_TABLE};
my $ATTRS_TABLE = $taxonomy->{ATTRS_TABLE};
my $INTS_TABLE = $taxonomy->{INTS_TABLE};
my $COUNTS_TABLE = $taxonomy->{COUNTS_TABLE};
my $REFS_TABLE = $taxonomy->{REFS_TABLE};

# my (%SIMPLE_T, %SIMPLE_A, %DATA_T, %DATA_A);
# my (%LINK, %APP, %ATTR, %PARENT, %SIZE, %PHYLO, %COUNTS, %CRMOD);
# my (%image_no);

my (%REF_DATA, %TAXON_DATA, %EXACT_DATA);

subtest 'test data' => sub {
    
    eval {
	
	my ($sql, $result);
	
	$sql = "SELECT r.reference_no, r.author1init as r_ai1, r.author1last as r_al1, 
		   r.author2init as r_ai2, r.author2last as r_al2, r.otherauthors as r_oa, 
		   r.pubyr as r_pubyr, r.reftitle as r_reftitle, r.pubtitle as r_pubtitle, 
		   r.editors as r_editors, r.pubvol as r_pubvol, r.pubno as r_pubno, 
		   r.firstpage as r_fp, r.lastpage as r_lp, r.publication_type as r_pubtype, 
		   r.language as r_language, r.doi as r_doi
	    FROM refs as r
	    WHERE r.reference_no in ($REF3a, $REF3b, $REF4a, $REF4b)";
    
	%REF_DATA = hash_by_refno($dbh, $sql);
	
	$sql = "SELECT a.taxon_no, a.orig_no, a.reference_no, a.taxon_name, 'A' as type
		FROM authorities as a
		WHERE a.orig_no in ($ID4a, $ID4b)";
	
	%TAXON_DATA = hash_by_taxon($dbh, $sql);
    };

    ok( !$@, 'got test data' ) or diag("message was: $@");
    
    ok( $REF_DATA{$REF3a}{reference_no}, "found data for '\%REF_DATA'" );
};


subtest 'list_refs basic calls' => sub {
    
    my ($r1, @r1, $sth1, $r2, @r2, $count, @r3, @w1, @w2, @w3);
    
    eval {
	@r1 = $taxonomy->list_refs('all_children', $ID3);
	@w1 = $taxonomy->list_warnings;
	$r1 = $taxonomy->list_refs('all_children', $ID3, { return => 'listref' });
	@w2 = $taxonomy->list_warnings;
	$sth1 = $taxonomy->list_refs('all_children', $ID3, { return => 'stmt', count => 1 });
	@w3 = $taxonomy->list_warnings;
	
	$count = $taxonomy->get_count;
	
	while ( ref $sth1 && ($r2 = $sth1->fetchrow_hashref()) )
	{
	    push @r2, $r2;
	}
	
	@r3 = $taxonomy->list_refs('all_children', $ID3, { return => 'id' });
    };
    
    unless ( ok( !$@, 'eval OK' ) )
    {
	diag("message was: $@");
	BAIL_OUT("basic calls failed");
    }
    
    cmp_ok( scalar(@r1), '>', 5, "found references for '$NAME3'" );
    is( ref $r1 && scalar(@$r1), scalar(@r1), "return => 'listref' gives same result set" );
    is( scalar(@r2), scalar(@r1), "return => 'stmt' gives same result set" );
    is( $count, scalar(@r1), "count => 1 returns proper rowcount" );
    
    is( scalar(@w1), 0, "no warnings for correct call" );
    is( scalar(@w2), 0, "no warnings for correct call with 'listref'" );
    is( scalar(@w3), 0, "no warnings for correct call with 'stmt'" );
    
    my (%name1, %name2, %id3, @id_bad);
    
    foreach my $r (@r1)
    {
	$name1{$r->{r_pubtitle}} = 1;
    }
    
    foreach my $r (@r2)
    {
	$name2{$r->{r_pubtitle}} = 1;
    }
    
    ok( $name1{$PUB3a}, "found '$PUB3a' in default result list" );
    ok( $name2{$PUB3a}, "found '$PUB3a' in 'stmt' result list" );
    
    foreach my $r (@r3)
    {
	if ( $r =~ qr{^[0-9]+$} )
	{
	    $id3{$r} = 1;
	}
	else
	{
	    push @id_bad, $r;
	}
    }
    
    ok( $id3{$REF3a}, "found '$REF3a' in 'id' result list" );
    ok( $id3{$REF3b}, "found '$REF3b' in 'id' result list" );
    
    ok( ! @id_bad, "found bad value '$id_bad[0]' in 'id' result list" );
    
    eval {
	@r1 = $taxonomy->list_refs('bad_value', $ID3);
    };
    
    ok( $@, 'error with bad relationship' );
    
    eval {
	@r1 = $taxonomy->list_refs('current', $ID1, $ID2);
    };
    
    ok( $@, 'error with bad third argument' );
    
    eval {
	@r1 = $taxonomy->list_refs('current', $ID1, { status => 'valid', bad_option => 1 });
    };
    
    ok( $@, 'error with bad option name' );
};


subtest 'limit, offset, count' => sub {
    
    my (@r1, @r2, @r3, $sth1, $count, @w1, @w2, @w3, $r);
    
    eval {
	@r1 = $taxonomy->list_refs('all_children', $ID1, { limit => 10 });
	@w1 = $taxonomy->list_warnings;
	@r2 = $taxonomy->list_refs('all_children', $ID1, { limit => 20, offset => 5 });
	@w2 = $taxonomy->list_warnings;
	$sth1 = $taxonomy->list_refs('all_children', $ID1, { return => 'stmt', limit => 20, offset => 5 });
	@w3 = $taxonomy->list_warnings;
	
	$count = $taxonomy->get_count;
	
	while ( ref $sth1 && ( $r = $sth1->fetchrow_hashref() ) )
	{
	    push @r3, $r;
	}
    };
    
    ok( !$@, "eval OK" ) or diag("message was: $@");
    
    is( scalar(@r1), 10, "simple limit" );
    is( scalar(@r2), 20, "limit with offset" );
    cmp_ok( $r1[8]{reference_no}, '>', 0, "found taxon with limit" );
    is( $r1[8]{reference_no}, $r2[3]{reference_no}, "offset matches up" );
    is( $r1[8]{reference_no}, $r3[3]{reference_no}, "offset matches with return => 'stmt'" );
    is( scalar(@r3), scalar(@r2), "count matches with return => 'stmt'" );
    
    is( scalar(@w1), 0, "no warnings for correct call with 'limit'" );
    is( scalar(@w2), 0, "no warnings for correct call with 'offset'" );
    is( scalar(@w3), 0, "no warnings for correct call with 'stmt', 'limit', 'offset'" );
    
    eval {
	@r1 = $taxonomy->list_refs('all_children', $ID1);
	@w1 = $taxonomy->list_warnings;
	@r2 = $taxonomy->list_refs('all_children', $ID1, { limit => 'foo' });
	@w2 = $taxonomy->list_warnings;
	@r3 = $taxonomy->list_refs('all_children', $ID1, { limit => 'all' });
	@w3 = $taxonomy->list_warnings;
    };
    
    ok( !$@, "non-numeric limits" ) or diag("message was: $@");
    
    is( scalar(@w1), 0, "no warnings for correct call with no options" );
    is( scalar(@w2), 1, "one warning with bad limit" );
    is( scalar(@r2), 0, "no results with bad limit" );
    is( scalar(@r3), scalar(@r1), "proper result set with limit 'all'" );
    is( scalar(@w3), 0, "no warnings for limit 'all'" );
};


subtest 'list_refs basic 2' => sub {
    
    my (@r1, @r2, @r3);
    
    eval {
	@r1 = $taxonomy->list_refs('all_children', $ID3);
	@r2 = $taxonomy->list_refs('all_children', $ID3, { min_rank => 5, max_rank => 5 });
	@r3 = $taxonomy->list_refs('all_children', $ID3, { depth => 1 });
    };
    
    ok( !$@, "eval OK" ) or diag("message was: $@");
    
    my ($rcount, $bad_count);
    
    foreach my $r (@r1)
    {
	my $rn = $r->{reference_no};
	if ( $rn && $REF_DATA{$rn}{reference_no} )
	{
	    cmp_deeply( $r, superhashof($REF_DATA{$rn}), "REF_DATA $rn" );
	    $rcount++;
	}
    }
    
    foreach my $r (@r1, @r2)
    {
	$bad_count++ unless $r->{reference_no} && $r->{r_al1} && $r->{taxon_count};
	$bad_count++ unless defined $r->{type} && $r->{type} =~ qr{^[AOC,]+$};
    }
    
    cmp_ok($rcount, '>', 0, "found REF_DATA data");
    cmp_ok(scalar(@r2), '>', 0, "got data with filter");
    cmp_ok(scalar(@r1), '>', scalar(@r2), "filters reduce size of result set");
    cmp_ok( $bad_count || 0, '==', 0, "each record has a proper reference_no, r_al1, taxon_count, and type" );
    
    my (%found2);
    
    foreach my $r (@r2)
    {
	my $rn = $r->{reference_no};
	if ( $rn && $REF_DATA{$rn}{reference_no} )
	{
	    cmp_deeply( $r, superhashof($REF_DATA{$rn}), "REF_DATA $rn" );
	    $found2{$rn} = 1;
	}
    }
    
    ok($found2{$REF3b}, "found REF_DATA for $REF3b with rank filter");
    ok(!$found2{$REF3a}, "did not find REF_DATA for $REF3b with rank filter");
    
    cmp_ok( scalar(@r3), '>', 0, "found results with depth => 1" );
    cmp_ok( scalar(@r3), '<', scalar(@r1), "smaller result set with depth => 1" );
};


subtest 'list_refs select' => sub {
    
    my (@r0, @r1, @r2, @r3, @r4, @r5, @r12);
    
    eval {
	@r0 = $taxonomy->list_refs('all_children', $ID1);
	@r1 = $taxonomy->list_refs('all_children', $ID1, { select => 'authority' });
	@r2 = $taxonomy->list_refs('all_children', $ID1, { select => 'classification' });
	@r3 = $taxonomy->list_refs('all_children', $ID1, { select => 'both' });
	@r4 = $taxonomy->list_refs('all_children', $ID1, { select => 'opinions' });
	@r5 = $taxonomy->list_refs('all_children', $ID1, { select => 'all' });
    };
    
    ok( !$@, "eval OK" ) or diag("message was: $@");
    
    cmp_ok( scalar(@r1), '>', 0, "found refs with 'authority'" );
    cmp_ok( scalar(@r2), '>', 0, "found refs with 'classification'" );
    cmp_ok( scalar(@r3), '>', 0, "found refs with 'both'" );
    cmp_ok( scalar(@r4), '>', 0, "found refs with 'opinions'" );
    cmp_ok( scalar(@r5), '>', 0, "found refs with 'all'" );
    
    cmp_deeply( \@r0, \@r3, "default select is 'both'" );
    
    my %type1 = extract_field('type', @r1);
    my %type2 = extract_field('type', @r2);
    my %type3 = extract_field('type', @r3);
    my %type4 = extract_field('type', @r4);
    my %type5 = extract_field('type', @r5);
    
    cmp_deeply( \%type1, { A => 1 }, "authority result has type A" );
    cmp_deeply( \%type2, { C => 1 }, "classification result has type C" );
    cmp_deeply( \%type3, { A => 1, C => 1 }, "both result has type A,C" );
    cmp_deeply( \%type4, { C => 1, O => 1 }, "opinions result has type C,O" );
    cmp_deeply( \%type5, { A => 1, C => 1, O => 1 }, "all result has type A,C,O" );
    
    my %ref1 = extract_field('reference_no', @r1);
    my %ref2 = extract_field('reference_no', @r2);
    my %ref3 = extract_field('reference_no', @r3);
    my %ref4 = extract_field('reference_no', @r4);
    my %ref5 = extract_field('reference_no', @r5);
    
    my %ref12 = (%ref1, %ref2);
    my %ref14 = (%ref1, %ref4);
    
    cmp_deeply( \%ref3, \%ref12, "both is authority + classification" );
    cmp_deeply( \%ref5, \%ref14, "all is authority + opinions" );
    cmp_deeply( \%ref3, subhashof(\%ref4), "classification is a subset of opinions" );
    cmp_deeply( \%ref4, subhashof(\%ref5), "opinions is a subset of all" );
    
    my %title1 = extract_field('r_reftitle', @r1);
    my %title2 = extract_field('r_reftitle', @r2);
    my %title3 = extract_field('r_reftitle', @r3);
    my %title4 = extract_field('r_reftitle', @r4);
    my %title5 = extract_field('r_reftitle', @r5);

    my %title12 = (%title1, %title2);
    my %title14 = (%title1, %title4);
    
    cmp_deeply( \%title3, \%title12, "both is authority + classification with titles" );
    cmp_deeply( \%title5, \%title14, "all is authority + opinions with titles" );
    cmp_deeply( \%title3, subhashof(\%title4), "classification is a subset of opinions with titles" );
    cmp_deeply( \%title4, subhashof(\%title5), "opinions is a subset of all with titles" );
    
    ok( $title5{$PUB1a}, "found title '$PUB1a'" );
    
    my (@b1);
    
    eval {
	@b1 = $taxonomy->list_refs('all_children', $ID1, { select => 'foo' });
    };
    
    ok( $@, "error with select => 'foo'" );
};


subtest 'list_refs variants, exact, current' => sub {
    
    my (@r1, @r2, @r3);
    
    eval {
	@r1 = $taxonomy->list_refs('variants', $ID4a, { select => 'all' });
	@r2 = $taxonomy->list_refs('variants', $ID4b, { select => 'all' });
	@r3 = $taxonomy->list_refs('all_children', $ID3, { all_variants => 1, select => 'all' });
    };
    
    ok( !$@, "eval OK" ) or diag("message was: $@");
    
    cmp_deeply( \@r1, \@r2, "same result set from two different variants" );
    
    my %ref1 = extract_field('reference_no', @r1);
    my %ref3 = extract_field('reference_no', @r3);
    my %title1 = (extract_field('r_reftitle', @r1), extract_field('r_pubtitle', @r1));
    
    cmp_deeply( \%ref1, subhashof(\%ref3), "variants are subset of all_children with all_variants" );
    ok( $title1{$PUB4a}, "found title '$PUB4a'" );
    ok( $title1{$PUB4b}, "found title '$PUB4b'" );
    
    my (@r4, @r5, @r6, @r7);
    
    eval {
	@r4 = $taxonomy->list_refs('exact', $ID4a, { select => 'authority' });
	@r5 = $taxonomy->list_refs('exact', $ID4b, { select => 'authority' });
	@r6 = $taxonomy->list_refs('current', $ID4a, { select => 'authority' });
	@r7 = $taxonomy->list_refs('current', $ID4b, { select => 'authority' });
    };

    ok( !$@, "eval 2 OK" ) or diag("message was: $@");
    
    cmp_ok( scalar(@r4), '==', 1, "exact gives one result with a" );
    cmp_ok( scalar(@r5), '==', 1, "exact gives one result with b" );
    cmp_ok( scalar(@r6), '==', 1, "current gives one result with a" );
    cmp_ok( scalar(@r7), '==', 1, "current gives one result with b" );
    cmp_deeply( $r4[0], superhashof($REF_DATA{$REF4a}), "exact a gives proper result" );
    cmp_deeply( $r5[0], superhashof($REF_DATA{$REF4b}), "exact a gives proper result" );
    cmp_deeply( $r6[0], superhashof($REF_DATA{$REF4a}), "exact a gives proper result" );
    cmp_deeply( $r7[0], superhashof($REF_DATA{$REF4a}), "exact a gives proper result" );
};


subtest 'list_refs synonyms, all_parents' => sub {
    
    my (@r1, @r2, @r3, @r4);
    
    eval {
	@r1 = $taxonomy->list_refs('synonyms', $ID5a);
	@r2 = $taxonomy->list_refs('synonyms', $ID5b);
	@r3 = $taxonomy->list_refs('all_parents', $ID1, { select => 'authority' });
	@r4 = $taxonomy->list_refs('synonyms', $ID1, { all_variants => 1 });
    };
    
    ok( !$@, "eval OK" ) or diag("message was: $@");
    
    cmp_deeply( \@r1, \@r2, "same result set from two different synonms" );
    cmp_ok( scalar(@r1), '>', 1, "more than one result with synonyms" );
    cmp_ok( scalar(@r4), '>', 1, "more than one result with all_variants" );
    cmp_ok( scalar(@r3), '>', 1, "more than one result with all_parents" );
    
    my $bad_count;
    
    foreach my $r (@r1, @r2, @r3, @r4)
    {
	$bad_count++ unless $r->{reference_no} && $r->{type};
    }
    
    ok( !$bad_count, "all results have a reference_no and type" );
};


subtest 'refs_taxa' => sub {
    
    my (@r1, @t1, @r2, @t2, @r3, @t3, @r4, @t4);
    my (@r5, @t5, @r6, @t6, @r7, @t7, @r8, @t8, @r9, @t9, @r10, @t10);
    
    eval {
	@r1 = $taxonomy->list_refs('all_children', $ID1, { min_rank => 5, max_rank => 5 });
	@t1 = $taxonomy->refs_taxa('all_children', $ID1, { min_rank => 5, max_rank => 5 });
	
	@r2 = $taxonomy->list_refs('variants', $ID1, { select => 'authority' });
	@t2 = $taxonomy->refs_taxa('variants', $ID1, { select => 'authority' });
	
	@r3 = $taxonomy->list_refs('exact', $ID4b, { select => 'all' });
	@t3 = $taxonomy->refs_taxa('exact', $ID4b, { select => 'all' });
	
	@r4 = $taxonomy->list_refs('current', $ID4b, { select => 'all' });
	@t4 = $taxonomy->refs_taxa('current', $ID4b, { select => 'all' });
	
	@r5 = $taxonomy->list_refs('synonyms', $ID5a, { select => 'opinions' });
	@t5 = $taxonomy->refs_taxa('synonyms', $ID5b, { select => 'opinions' });
	
	@r6 = $taxonomy->list_refs('accepted', $ID5a, { select => 'classification' });
	@t6 = $taxonomy->refs_taxa('accepted', $ID5b, { select => 'classification' });
	
	@r7 = $taxonomy->list_refs('children', $ID1, { select => 'both' });
	@t7 = $taxonomy->refs_taxa('children', $ID1, { select => 'both' });
	
	@r8 = $taxonomy->list_refs('all_parents', $ID1, { select => 'authority' });
	@t8 = $taxonomy->refs_taxa('all_parents', $ID1, { select => 'authority' });
	
	@r9 = $taxonomy->list_refs('all_parents', $ID1, { select => 'opinions' });
	@t9 = $taxonomy->refs_taxa('all_parents', $ID1, { select => 'opinions' });
	
	@r10 = $taxonomy->list_refs('all_children', $ID1, { all_variants => 1, depth => 2 });
	@t10 = $taxonomy->refs_taxa('all_children', $ID1, { all_variants => 1, depth => 2 });
    };
    
    unless ( ok( !$@, "eval OK" ) )
    {
	diag("message was: $@");
	return;
    }
    
    my %r1refno = extract_field('reference_no', @r1);
    my %t1refno = extract_field('reference_no', @t1);
    my %r1name = extract_field('taxon_name', @t1);
    my %r1tno = extract_field('taxon_no', @t1);
    
    cmp_ok( scalar(keys %t1refno), '>', 0, "got data from all_children with rank filter" );
    cmp_deeply( \%r1refno, \%t1refno, "refs_taxa gives same set of taxa as list_refs from all_children with rank filter" );
    ok( $r1name{$NAME5a}, "found '$NAME5a' from all_children with rank filter" );
    ok( $r1name{$NAME5b}, "found '$NAME5b' from all_children with rank filter" );
    ok( $r1tno{$ID5a}, "found '$ID5a' from all_children with rank filter" );
    ok( $r1tno{$ID5b}, "found '$ID5b' from all_children with rank filter" );
    
    my %r2refno = extract_field('reference_no', @r2);
    my %t2refno = extract_field('reference_no', @t2);
    my %r2name = extract_field('taxon_name', @t1);
    
    cmp_ok( scalar(keys %t2refno), '>', 0, "got data from all_children with rank filter" );
    cmp_deeply( \%r2refno, \%t2refno, "refs_taxa gives same set of taxa as list_refs from all_children with rank filter" );
    
    my %r3refno = extract_field('reference_no', @r3);
    my %t3refno = extract_field('reference_no', @t3);
    
    cmp_ok( scalar(keys %t3refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r3refno, \%t3refno, "refs_taxa matches list_refs with exact" );
    
    my %r4refno = extract_field('reference_no', @r4);
    my %t4refno = extract_field('reference_no', @t4);
    
    cmp_ok( scalar(keys %t4refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r4refno, \%t4refno, "refs_taxa matches list_refs with exact" );
    
    my %r5refno = extract_field('reference_no', @r5);
    my %t5refno = extract_field('reference_no', @t5);
    
    cmp_ok( scalar(keys %t5refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r5refno, \%t5refno, "refs_taxa matches list_refs with exact" );
    
    my %r6refno = extract_field('reference_no', @r6);
    my %t6refno = extract_field('reference_no', @t6);
    
    cmp_ok( scalar(keys %t6refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r6refno, \%t6refno, "refs_taxa matches list_refs with exact" );
    
    my %r7refno = extract_field('reference_no', @r7);
    my %t7refno = extract_field('reference_no', @t7);
    
    cmp_ok( scalar(keys %t7refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r7refno, \%t7refno, "refs_taxa matches list_refs with exact" );
    
    my %r8refno = extract_field('reference_no', @r8);
    my %t8refno = extract_field('reference_no', @t8);
    
    cmp_ok( scalar(keys %t8refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r8refno, \%t8refno, "refs_taxa matches list_refs with exact" );
    
    my %r9refno = extract_field('reference_no', @r9);
    my %t9refno = extract_field('reference_no', @t9);
    
    cmp_ok( scalar(keys %t9refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r9refno, \%t9refno, "refs_taxa matches list_refs with exact" );
    
    my %r10refno = extract_field('reference_no', @r10);
    my %t10refno = extract_field('reference_no', @t10);
    
    cmp_ok( scalar(keys %t10refno), '>', 0, "got data with exact" );
    cmp_deeply( \%r10refno, \%t10refno, "refs_taxa matches list_refs with exact" );
    
    my ($bad_count, $bad_t);
    
    foreach my $t (@t1, @t2, @t3, @t4, @t5, @t6, @t7, @t8, @t9, @t10)
    {
	my $bad;
	
	$bad++ unless $t->{reference_no} && $t->{taxon_no} && $t->{orig_no};
	$bad++ unless $t->{taxon_name};
	$bad++ unless defined $t->{type} && $t->{type} =~ qr{^[AOC]$};
	
	if ( $bad )
	{
	    $bad_count++;
	    $bad_t ||= $t;
	}
    }
    
    ok( !$bad_count, "each data record has a proper reference_no, taxon_no, orig_no and type" )
	or diag Data::Dumper::Dumper($bad_t);
};


subtest 'list_opinions' => sub {
    
    my (@o1, @o1a, @o1b, @o2, @o3);
    
    eval {
	@o1 = $taxonomy->list_opinions('all_children', $ID1);
	@o1a = $taxonomy->list_opinions('all_children', $ID1, { select => 'all' });
	@o1b = $taxonomy->list_opinions('all_children', $ID1, { select => 'classification' });
	@o2 = $taxonomy->list_opinions('all_children', $ID1, { max_rank => 3 });
    };
    
    ok( !$@, "eval OK" ) or diag("message was: $@");
    
    cmp_deeply( \@o1, \@o1b, "default value for select is classification" );
    
    my %op1 = extract_field('opinion_no', @o1);
    my %op1a = extract_field('opinion_no', @o1a);
    my %op2 = extract_field('opinion_no', @o2);
    
    cmp_deeply( \%op1, subhashof(\%op1a), "classification is a subset of all" );
    cmp_deeply( \%op2, subhashof(\%op1), "classification with rank filter gives subset" );
    
    my ($bad_count);
    
    foreach my $o (@o1a, @o1b, @o2)
    {
	$bad_count++ unless $o->{opinion_no} && $o->{orig_no};
	$bad_count++ unless $o->{child_spelling_no} && $o->{parent_spelling_no};
	$bad_count++ unless $o->{taxon_name} && $o->{child_name} && $o->{parent_name};
	$bad_count++ unless $o->{pubyr} && $o->{status} && $o->{reference_no};
	$bad_count++ unless $o->{author} && $o->{ri};
	$bad_count++ unless defined $o->{type} && $o->{type} =~ qr{^[OC]$};
    }
    
    cmp_ok( $bad_count || 0, '==', 0, "each data record has proper fields" );
    
    my %status1 = extract_field('status', @o1);
    my %spelling1 = extract_field('spelling_reason', @o1);
    my %status1a = extract_field('status', @o1a);
    my %spelling1a = extract_field('spelling_reason', @o1a);
    my %status2 = extract_field('status', @o2);
    my %spelling2 = extract_field('spelling_reason', @o2);
    
    cmp_deeply( \%status1, subhashof(\%status1a), "classification is a subset of all by status" );
    cmp_deeply( \%status2, subhashof(\%status1), "classification with rank filter gives subset by status" );
    
    my %test1 = ( 'nomen dubium', '1', 'nomen nudum', '1', 'belongs to', '1', 
		  'subjective synonym of', '1', 'replaced by', '1' );
    my %test1a = ( 'nomen dubium', '1', 'nomen nudum', '1', 'misspelling of', '1', 'belongs to', '1', 
		   'objective synonym of', '1', 'subjective synonym of', '1', 'replaced by', '1' );
    my %test2 = ( 'nomen dubium', '1', 'nomen nudum', '1', 'belongs to', '1', 'subjective synonym of', '1' );
    
    cmp_deeply( \%status1, superhashof(\%test1), "status codes for classification" );
    cmp_deeply( \%status1a, superhashof(\%test1a), "status codes for classification" );
    cmp_deeply( \%status2, superhashof(\%test2), "status codes for classification" );
    
    my %spt1 = ( 'recombination', '1', 'rank change', '1', 'misspelling', '1', 'original spelling', '1' );
    my %spt1a = ( 'correction', '1', 'recombination', '1', 'rank change', '1', 'misspelling', '1', 'original spelling', '1' );
    my %spt2 = ( 'recombination', '1', 'misspelling', '1', 'original spelling', '1' );
    
    cmp_deeply( \%spelling1, superhashof(\%spt1), "status codes for classification" );
    cmp_deeply( \%spelling1a, superhashof(\%spt1a), "status codes for classification" );
    cmp_deeply( \%spelling2, superhashof(\%spt2), "status codes for classification" );
};


subtest 'fields' => sub {
    
    ok(1, "placeholder");
};


# subtest 'rank, extant, status' => sub {
    
#     my (@t0, @t1, @t2, @t3, @t3a, @t4, @t5, @t6, @t7);
    
#     eval {
# 	@t0 = $taxonomy->list_refs('all_children', $ID1);
# 	@t1 = $taxonomy->list_refs('all_children', $ID1, { min_rank => 5, max_rank => 8 });
# 	@t2 = $taxonomy->list_refs('all_children', $ID1, { status => 'invalid' });
# 	@t3 = $taxonomy->list_refs('all_children', $ID1, { min_rank => 5, status => 'invalid' });
# 	@t3a = $taxonomy->list_refs('all_children', $ID1, { max_rank => 4, status => 'invalid' });
# 	@t4 = $taxonomy->list_refs('all_children', $ID1, { status => 'valid' });
# 	@t5 = $taxonomy->list_refs('all_children', $ID1, { status => 'junior' });
# 	@t6 = $taxonomy->list_refs('all_children', $ID1, { status => 'senior' });
# 	@t7 = $taxonomy->list_refs('all_children', $ID1, { status => 'all' });
#     };
    
#     ok( !$@, "list_refs: rank, status" ) or diag("message was: $@");
    
#     ok( scalar(@t0), "not empty with no filters" );
#     ok( scalar(@t1), "not empty with rank filter" );
#     ok( scalar(@t2), "not empty with status invalid" );
#     ok( scalar(@t3), "not empty with rank and status filters" );
#     ok( scalar(@t3a), "not empty with rank and status filters 2" );
#     ok( scalar(@t4), "not empty with status valid" );
#     ok( scalar(@t5), "not empty with status junior" );
#     ok( scalar(@t6), "not empty with status senior" );
#     is( scalar(@t7), scalar(@t0), "status all gives same result as no status filter" );
    
#     cmp_ok( scalar(@t1), '<', scalar(@t0), "fewer taxa with rank filter" );
#     cmp_ok( scalar(@t2), '<', scalar(@t0), "fewer taxa with status filter" );
#     is( scalar(@t3) + scalar(@t3a), scalar(@t2), "disjoint sets with rank filter" );
#     is( scalar(@t2) + scalar(@t4), scalar(@t0), "disjoint sets with status invalid/valid" );
#     is( scalar(@t5) + scalar(@t6), scalar(@t4), "disjoint sets with status junior/senior" );
    
#     my ($min1, $max1, %status2, %status4);
    
#     my $NOM = 'nomen dubium';
#     my $BEL = 'belongs to';
#     my $SUB = 'subjective synonym of';
    
#     foreach my $t (@t1)
#     {
# 	$max1 = $t->{taxon_rank} if !defined $max1 || $t->{taxon_rank} > $max1;
# 	$min1 = $t->{taxon_rank} if !defined $min1 || $t->{taxon_rank} < $min1;
#     }
    
#     is( $max1, 8, "max rank with restriction" );
#     is( $min1, 5, "min rank with restriction" );
    
#     foreach my $t (@t2)
#     {
# 	$status2{$t->{status}} = 1;
#     }
    
#     ok( $status2{$NOM}, "found status '$NOM' with 'invalid'" );
#     ok( !$status2{$BEL}, "no status '$BEL' with 'invalid'" );
#     ok( !$status2{$SUB}, "no status '$SUB' with 'invalid'" );
    
#     foreach my $t (@t4)
#     {
# 	$status4{$t->{status}} = 1;
#     }
    
#     ok( $status4{$BEL}, "found status '$BEL' with 'valid'" );
#     ok( $status4{$SUB}, "found status '$SUB' with 'valid'" );
#     ok( !$status4{$NOM}, "no status '$NOM' with 'valid'" );
# };


# subtest 'order' => sub {
    
#     my (@t1a, @t1b, @t2a, @t2b, @t2c);
#     my (@t3a, @t3b, @t4a, @t4b, @t5a, @t5b, @t6a, @t6b);
    
#     eval {
# 	@t1a = $taxonomy->list_refs('all_children', $ID1, { order => 'hierarchy', fields => 'RANGE' });
# 	@t1b = $taxonomy->list_refs('all_children', $ID1, { order => 'hierarchy.desc', fields => 'RANGE' });

# 	@t2a = $taxonomy->list_refs('synonyms', $ID9a, { order => 'name' });
# 	@t2b = $taxonomy->list_refs('synonyms', $ID9a, { order => 'name.asc' });
# 	@t2c = $taxonomy->list_refs('synonyms', $ID9a, { order => 'name.desc' });

# 	@t3a = $taxonomy->list_refs('all_children', $ID1, { order => 'n_occs', fields => 'DATA' });
# 	@t3b = $taxonomy->list_refs('all_children', $ID1, { order => 'n_occs.asc', fields => 'DATA' });
	
# 	@t4a = $taxonomy->list_refs('all_children', $ID1, { order => 'firstapp', fields => 'SIMPLE,APP' });
# 	@t4b = $taxonomy->list_refs('all_children', $ID1, { order => 'firstapp.asc', fields => 'SIMPLE,APP' });
	
# 	@t5a = $taxonomy->list_refs('all_children', $ID1, { order => 'lastapp', fields => 'SIMPLE,APP' });
# 	@t5b = $taxonomy->list_refs('all_children', $ID1, { order => 'lastapp.asc', fields => 'APP' });
	
# 	@t6a = $taxonomy->list_refs('all_children', $ID1, { order => 'agespan', fields => 'SIMPLE,APP' });
# 	@t6b = $taxonomy->list_refs('all_children', $ID1, { order => 'agespan.desc', fields => 'APP' });
#     };
    
#     ok( !$@, "list_refs: order exec OK" ) or diag("message was: $@");
    
#     check_order($taxonomy, \@t1a, 'lft', 'num', 'asc') or fail('order hierarchy default');
#     check_order($taxonomy, \@t1b, 'lft', 'num', 'desc') or fail('order hierarchy desc');

#     check_order($taxonomy, \@t2a, 'taxon_name', 'str', 'asc') or fail('order name default');
#     check_order($taxonomy, \@t2b, 'taxon_name', 'str', 'asc') or fail('order name asc');
#     check_order($taxonomy, \@t2c, 'taxon_name', 'str', 'desc') or fail('order name desc');
    
#     check_order($taxonomy, \@t3a, 'n_occs', 'num', 'desc') or fail('order n_occs default');
#     check_order($taxonomy, \@t3b, 'n_occs', 'num', 'asc') or fail('order n_occs asc');
    
#     check_order($taxonomy, \@t4a, 'firstapp_ea', 'num', 'desc') or fail('order firstapp default');
#     check_order($taxonomy, \@t4b, 'firstapp_ea', 'num', 'asc') or fail('order firstapp asc');
    
#     check_order($taxonomy, \@t5a, 'lastapp_la', 'num', 'desc') or fail('order lastapp default');
#     check_order($taxonomy, \@t5b, 'lastapp_la', 'num', 'asc') or fail('order lastapp asc');
    
#     foreach my $t (@t6a, @t6b)
#     {
# 	$t->{agespan} = int($t->{firstapp_ea} - $t->{lastapp_la} + 0.1)
# 	    if defined $t->{firstapp_ea};
#     }
    
#     check_order($taxonomy, \@t6a, 'agespan', 'num', 'asc') or fail('order agespan default');
#     check_order($taxonomy, \@t6b, 'agespan', 'num', 'desc') or fail('order agespan desc');
    
#     my (@t7a, @t7b, @t7c);
#     my (@t8a, @t8b);
#     my (@t9a, @t9b, @t10a, @t10b);
    
#     eval {
# 	@t7a = $taxonomy->list_refs('synonyms', $ID9a, { order => 'pubyr', fields => 'SIMPLE,ATTR' });
# 	@t7b = $taxonomy->list_refs('synonyms', $ID9a, { order => 'pubyr.asc', fields => 'SIMPLE, ATTR'});
# 	@t7c = $taxonomy->list_refs('synonyms', $ID9a, { order => 'pubyr.desc', fields => 'SIMPLE ,ATTR'});
	
# 	@t8a = $taxonomy->list_refs('synonyms', $ID9a, { order => 'author', fields => 'SIMPLE,ATTR' });
# 	@t8b = $taxonomy->list_refs('synonyms', $ID9a, { order => 'author.desc', fields => 'SIMPLE, ATTR'});
	
# 	@t9a = $taxonomy->list_refs('synonyms', $ID9a, { order => 'created', fields => 'SIMPLE,CRMOD' });
# 	@t9b = $taxonomy->list_refs('synonyms', $ID9a, { order => 'created.asc', fields => 'SIMPLE,CRMOD'});
	
# 	@t10a = $taxonomy->list_refs('synonyms', $ID9a, { order => 'modified', fields => 'SIMPLE,CRMOD' });
# 	@t10b = $taxonomy->list_refs('synonyms', $ID9a, { order => 'modified.asc', fields => 'SIMPLE,CRMOD'});
#     };
    
#     ok( !$@, "list_refs: order 2 exec OK" ) or diag("message was: $@");
    
#     check_order($taxonomy, \@t7a, 'pubyr', 'num', 'asc') or fail('order pubyr default');
#     check_order($taxonomy, \@t7b, 'pubyr', 'num', 'asc') or fail('order pubyr asc');
#     check_order($taxonomy, \@t7c, 'pubyr', 'num', 'desc') or fail('order pubyr desc');
    
#     foreach my $t (@t8a, @t8b)
#     {
# 	if ( defined $t->{attribution} )
# 	{
# 	    my $attr = $t->{attribution};
# 	    $attr =~ s/[()]//g;
# 	    $attr =~ s/\s+\d+$//;
# 	    $t->{author} = $attr;
# 	}
#     }
    
#     check_order($taxonomy, \@t8a, 'author', 'str', 'asc') or fail('order author default');
#     check_order($taxonomy, \@t8b, 'author', 'str', 'desc') or fail('order author desc');
    
#     check_order($taxonomy, \@t9a, 'created', 'str', 'desc') or fail('order created default');
#     check_order($taxonomy, \@t9b, 'created', 'str', 'asc') or fail('order created asc');
    
#     check_order($taxonomy, \@t10a, 'modified', 'str', 'desc') or fail('order modified default');
#     check_order($taxonomy, \@t10b, 'modified', 'str', 'asc') or fail('order modified desc');
    
#     my (@t11a, @t11b, @t12a, @t12b, @t13a, @t13b);
    
#     eval {
# 	@t11a = $taxonomy->list_refs('synonyms', $ID9b, { order => 'size', fields => 'SIMPLE,SIZE' });
# 	@t11b = $taxonomy->list_refs('synonyms', $ID9b, { order => 'size.asc', fields => 'SIMPLE,SIZE'});
	
# 	@t12a = $taxonomy->list_refs('synonyms', $ID9b, { order => 'extsize', fields => 'SIMPLE,SIZE' });
# 	@t12b = $taxonomy->list_refs('synonyms', $ID9b, { order => 'extsize.asc', fields => 'SIMPLE,SIZE'});
	
# 	@t13a = $taxonomy->list_refs('synonyms', $ID9b, { order => 'extant', fields => 'DATA' });
# 	@t13b = $taxonomy->list_refs('synonyms', $ID9b, { order => 'extant.asc', fields => 'DATA'});
#     };
    
#     ok( !$@, "list_refs: order 3 exec OK" ) or diag("message was: $@");
    
#     check_order($taxonomy, \@t11a, 'taxon_size', 'num', 'desc') or fail('order size default');
#     check_order($taxonomy, \@t11b, 'taxon_size', 'num', 'asc') or fail('order size desc');

#     check_order($taxonomy, \@t12a, 'extant_size', 'num', 'desc') or fail('order extsize default');
#     check_order($taxonomy, \@t12b, 'extant_size', 'num', 'asc') or fail('order extsize desc');
    
#     check_order($taxonomy, \@t13a, 'is_extant', 'num', 'desc') or fail('order extant default');
#     check_order($taxonomy, \@t13b, 'is_extant', 'num', 'asc') or fail('order extant desc');
# };


sub check_order {
    
    my ($taxonomy, $result, $field, $type, $dir) = @_;
    
    my $last;
    my $index = -1;
    
    foreach my $t ( @$result )
    {
	$index++;
	
	# Skip nulls
	
	next unless defined $t->{$field};
	
	# If this is the first value, save it for later comparison
	
	unless ( $last )
	{
	    $last = $t->{$field};
	    next;
	}
	
	# Otherwise, compare with the previous value.
	
	elsif ( $type eq 'num' )
	{
	    if ( $dir eq 'asc' )
	    {
		unless ( $t->{$field} >= $last )
		{
		    print STDERR "check_order: violated at ($index) orig_no = $t->{orig_no}";
		    return 0;
		}
	    }
	    
	    elsif ( $dir eq 'desc' )
	    {
		unless ( $t->{$field} <= $last )
		{
		    print STDERR "check_order: violated at ($index) orig_no = $t->{orig_no}";
		    return 0;
		}
	    }
	    
	    else
	    {
		croak "invalid dir '$dir'";
	    }
	    
	    $last = $t->{$field};
	}
	
	elsif ( $type eq 'str' )
	{
	    if ( $dir eq 'asc' )
	    {
		unless ( $t->{$field} ge $last )
		{
		    print STDERR "check_order: violated at ($index) orig_no = $t->{orig_no}";
		    return 0;
		}
	    }
	    
	    elsif ( $dir eq 'desc' )
	    {
		unless ( $t->{$field} le $last )
		{
		    print STDERR "check_order: violated at ($index) orig_no = $t->{orig_no}";
		    return 0;
		}
	    }
	    
	    else
	    {
		croak "invalid dir '$dir'";
	    }
	    
	    $last = $t->{$field};
	}
	
	else
	{
	    croak "invalid type '$type'";
	}
    }
    
    if ( defined $last )
    {
	return 1;
    }
    
    else
    {
	print STDERR "check_order: no results found";
	return 0;
    }
};


sub hash_by_refno {
    
    my ($dbh, $sql) = @_;
    
    my $result = $dbh->selectall_arrayref($sql, { Slice => {} });
    
    my %hash;
    
    foreach my $t ( @$result )
    {
	if ( $t->{reference_no} )
	{
	    $hash{$t->{reference_no}} ||= $t;
	}
    }
    
    return %hash;
};


sub hash_by_taxon {

    my ($dbh, $sql) = @_;
    
    my $result = $dbh->selectall_arrayref($sql, { Slice => {} });
    
    my %hash;
    
    foreach my $t ( @$result )
    {
	if ( $t->{taxon_no} )
	{
	    $hash{$t->{taxon_no}} ||= $t;
	}
	
	elsif ( $t->{orig_no} )
	{
	    $hash{$t->{orig_no}} ||= $t;
	}
    }
    
    return %hash;
};


sub hash_field_by_taxon {

    my ($dbh, $field, $sql) = @_;
    
    my $result = $dbh->selectall_arrayref($sql, { Slice => {} });
    
    my %hash;
    
    foreach my $t ( @$result )
    {
	if ( $t->{taxon_no} )
	{
	    $hash{$t->{taxon_no}} ||= $t->{$field};
	}
	
	elsif ( $t->{orig_no} )
	{
	    $hash{$t->{orig_no}} ||= $t->{$field};
	}
    }
    
    return %hash;
};


sub extract_field {
    
    my $field = shift;
    
    my %hash;
    
    foreach my $t (@_)
    {
	next unless $t->{$field};
	
	if ( $field eq 'type' )
	{
	    map { $hash{$_} = 1 } split(/,/, $t->{$field});
	}
	
	else
	{
	    $hash{$t->{$field}} = 1;
	}
    }
    
    return %hash;
};


sub extract_refnos {
    
    my %hash;
    
    foreach my $t (@_)
    {
	$hash{$t->{reference_no}} = 1;
    }
    
    return %hash;
};

# my_cmp_subset ( $got, $expected, $name )
# 
# This something that I was expecting to be in Test::Deep, but isn't there.
# The test passees if every element of @$got is eq_deeply to some element of
# @$expected, and fails otherwise.  The parameter $key must be a hash key
# which is present and has a unique value for each member of @$expected.

sub my_cmp_subset {
    
    my ($got, $expected, $name) = @_;
    
    croak "first parameter must be an array ref" unless ref $got eq 'ARRAY';
    croak "second parameter must be an array ref" unless ref $expected eq 'ARRAY';
    croak "you must provide a test name" unless $name;
    
    # Scan through @$got and compare each element in turn to every element of
    # @$expected until we find one that matches.  If we fail, then the test
    # fails. 
    
    my $fail = 0;
    my $fail_elt;
    
 ELT:
    foreach my $t (@$got)
    {
    CHECK:
	foreach my $c (@$expected)
	{
	    next ELT if eq_deeply($t, $c);
	    my $failure = 1;
	}
	
	$fail++;
	$fail_elt = $t;
    }
    
    return unless $fail;
    
    fail($name);
    diag("$fail elements did not match.  Example:");
    diag(Data::Dumper::Dumper($fail_elt));
}
    
