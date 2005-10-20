#
# This module build and builds, maintains and accesses two tables (taxa_tree_cache,taxa_list_cache)
# for the purposes of speeding up taxonomic lookups (both of children and parents of a taxon).  The
# taxa_tree_cache holds a modified preorder traversal tree, and the taxa_list_cache holds a 
# adjacency list.  The modified preorder traversal tree is used to trees of children of a taxon
# in constant time, while the adjacency list is used to get parents of a taxon in constant time
#
# PS 09/22/2005
#

package TaxaCache;

use Data::Dumper;
use CGI::Carp;
use TaxonInfo;

use strict;

my $DEBUG = 0;

# This function rebuilds the entire cache from scratch, meant to 
# first use, when the cache gets screwed up, or perhaps weekly to be safe
# (at a time when no opinions are likely to be entered, opinions/authorities entered
# concurrently when this is running might be left out)
sub rebuildCache {
    my $dbt = shift;
    my $dbh = $dbt->dbh;
    my $result;

    my $sql = "SELECT taxon_no FROM authorities";
    my $sth = $dbh->prepare($sql);
    $sth->execute();

    # Now do the main loop
    my @rows = ();
    while (my $row = $sth->fetchrow_hashref()) {
        push @rows,$row;
    }

    # We're going to create a brand new table from scratch, then swap it
    # to be the normal table once its complete
    $result = $dbh->do("DROP TABLE IF EXISTS taxa_tree_cache_new");
    $result = $dbh->do("CREATE TABLE taxa_tree_cache_new (taxon_no int(10) unsigned NOT NULL default '0',lft int(10) unsigned NOT NULL default '0',rgt int(10) unsigned NOT NULL default '0', spelling_no int(10) unsigned NOT NULL default '0', synonym_no int(10) unsigned NOT NULL default '0', PRIMARY KEY  (taxon_no), KEY lft (lft), KEY rgt (rgt), KEY synonym_no (synonym_no)) TYPE=MyISAM");

    # Keep track of which nodes we've processed
    my $next_lft = 1;
    my %processed;

    foreach my $row (@rows) {
        if (!$processed{$row->{'taxon_no'}}) {
            my $ancestor_no = TaxonInfo::getOriginalCombination($dbt,$row->{'taxon_no'});
            # Get the topmost ancestor     
            for(my $i=0;$i<100;$i++) { # max out at 100;
                my $opinion = TaxonInfo::getMostRecentParentOpinion($dbt,$ancestor_no);
                if ($opinion && $opinion->{'parent_no'}) {
                    $ancestor_no=$opinion->{'parent_no'};
                } else {
                    last;
                }
            }
            print "found ancestor $ancestor_no for $row->{taxon_no}<BR>\n" if ($DEBUG);

            # Now insert that topmost ancestor, which will recursively insert all its children as well
            # marking them as processed to boot, so we won't readd them later
            $next_lft = rebuildAddChild($dbt,$ancestor_no,$next_lft,\%processed);
            $next_lft++;
        }
    }
    $result = $dbh->do("RENAME TABLE taxa_tree_cache TO taxa_tree_cache_old, taxa_tree_cache_new TO taxa_tree_cache");
    $result = $dbh->do("DROP TABLE taxa_tree_cache_old");
    undef %processed;

    # Now build the taxa_list_cache
    $result = $dbh->do("DROP TABLE IF EXISTS taxa_list_cache_new");
    $result = $dbh->do("CREATE TABLE taxa_list_cache_new (parent_no int(10) unsigned NOT NULL default '0',child_no int(10) unsigned NOT NULL default '0', PRIMARY KEY  (child_no,parent_no), KEY parent_no (parent_no)) TYPE=MyISAM");
    my %link_cache = ();
    my %spellings = ();
    foreach my $row (@rows) {
        my $orig_no = TaxonInfo::getOriginalCombination($dbt,$row->{'taxon_no'});
        my $child_no = ($orig_no) ? $orig_no : $row->{'taxon_no'};
        my %visits = ();
        my %syns = ();
        for(my $i=0;$child_no;$i++) {
            if ($i > 100) {
                print STDERR "i > 100 for $child_no\n"; last;
            }
            # bail if we've already gotten this hiearchy on a previous run
            last if (exists $link_cache{$child_no});
            # bail if we have a loop due to circular synonyms
            last if ($visits{$child_no});
            $visits{$child_no} = 1; 

            # Belongs to should always point to original combination
            my $parent_row = TaxonInfo::getMostRecentParentOpinion($dbt,$child_no);

            my ($parent_no,$status);
            if ($parent_row) {
                if ($parent_row->{'child_spelling_no'} != $parent_row->{'child_no'}) {
                    $spellings{$parent_row->{'child_no'}} = $parent_row->{'child_spelling_no'};
                }
                $parent_no  = $parent_row->{'parent_no'};
                $status = $parent_row->{'status'};
            } else {
                # No parent was found. This means we're at end of classification, 
                $parent_no=0;
                $status = "";
            }

            if ($status =~ /^(?:repl|subj|obje|hom)/o) {
                $syns{$child_no} = $parent_no;
            } else {
                $link_cache{$child_no} = $parent_no;
            }
            # Already climbed this part
            last if (exists $link_cache{$parent_no});
            $child_no = $parent_no;
        }
        while (my ($junior,$senior) = each %syns) {
            my $i = 0;
            while ($syns{$senior} && $i < 10) {
                $senior = $syns{$senior};
                $i++;
            }
            $link_cache{$junior} = $link_cache{$senior};
        }
    
        if ($orig_no && $row->{'taxon_no'} != $orig_no) {
            $link_cache{$row->{'taxon_no'}} = $link_cache{$orig_no};
        }

        my $taxon_no = $row->{'taxon_no'};
        my @parents = ();
        %visits = ();
        while ($link_cache{$taxon_no}) {
            last if ($visits{$taxon_no});
            $visits{$taxon_no} = 1; 
            push @parents, $link_cache{$taxon_no};
            $taxon_no = $link_cache{$taxon_no};
        }
        if (@parents) {
            $sql = "INSERT IGNORE INTO taxa_list_cache_new (parent_no,child_no) VALUES ";
            foreach my $parent_no (@parents) {
                my $parent_spelling = ($spellings{$parent_no}) ? $spellings{$parent_no} : $parent_no;
                $sql .= "($parent_spelling,$row->{taxon_no}),";
            }
            $sql =~ s/,$//;
            print $sql."<BR>\n" if ($DEBUG);
            $dbh->do($sql);
        }
    }

    # Now swap out and destroy the old, swap in the new
    $result = $dbh->do("RENAME TABLE taxa_list_cache TO taxa_list_cache_old, taxa_list_cache_new TO taxa_list_cache");
    $result = $dbh->do("DROP TABLE taxa_list_cache_old");
}


# Utility function meant to be used by rebuildCache above only
# Adds a taxon_no into the cache with left value lft.  $processed is a hash reference to
# a hash which keeps track of which taxon_nos have been processed already, so we don't reprocess them
# Note that spelling_no is the taxon_no of the most recent spelling of the SENIOR synonym
sub rebuildAddChild {
    my ($dbt,$taxon_no,$lft,$processed) = @_;
    my $dbh = $dbt->dbh;

    # Loop prevention
    if ($processed->{$taxon_no}) {
        print "Seemed to encounter a loop with $taxon_no, skipping<BR>\n" if ($DEBUG);
        return $lft;
    } else {
        $processed->{$taxon_no} = 1;
    }

    # get an list of children for the current node. 
    my $sql = "SELECT DISTINCT o.child_no FROM opinions o WHERE o.parent_no=$taxon_no"; 
    my @results = @{$dbt->getData($sql)};
    my @children = ();
    foreach my $row (@results) {
        next if ($processed->{$row->{'child_no'}});
        my $opinion = TaxonInfo::getMostRecentParentOpinion($dbt,$row->{'child_no'});
        # Note theres no distinction between synonyms and belongs to - both just considered children
        if ($opinion && $opinion->{'parent_no'} == $taxon_no) {
            push @children,$row->{'child_no'};
        }
    }
    print "list of children for $taxon_no: ".join(",",@children)."<BR>\n" if ($DEBUG);

    # Now add all those children
    my $next_lft = $lft + 1;
    foreach my $child_no (@children) {
        $next_lft = rebuildAddChild($dbt,$child_no,$next_lft,$processed);
        $next_lft++;
    }
    my $rgt=$next_lft;

    print "rebuildAddChild: $taxon_no $lft $rgt<BR>\n" if ($DEBUG);

    # now get recombinations, and corrections for current child and insert at the same 
    # place as the child.  $taxon_no should already be the senior synonyms if there are synonyms
    my %all_taxa = ($taxon_no=>1);

    # Get a list of alternative names of existing taxa as well
    $sql = "SELECT DISTINCT child_spelling_no FROM opinions WHERE child_no=$taxon_no";
    @results = @{$dbt->getData($sql)};
    foreach my $row (@results) {
        $all_taxa{$row->{'child_spelling_no'}} = 1;
    }
    $sql = "SELECT DISTINCT child_no FROM opinions WHERE child_spelling_no=$taxon_no";
    @results = @{$dbt->getData($sql)};
    foreach my $row (@results) {
        $all_taxa{$row->{'child_no'}} = 1;
    } 

    # Find the name that was last used so we can mark it
    my $spelling_no=$taxon_no;
    my $correct_row = TaxonInfo::getMostRecentParentOpinion($dbt,$taxon_no);
    if ($correct_row && $correct_row->{'child_spelling_no'}) {
        $spelling_no = $correct_row->{'child_spelling_no'};
    }

    my $synonym_no = TaxonInfo::getOriginalCombination($dbt,$taxon_no);
    if ($synonym_no) {
        $synonym_no = TaxonInfo::getSeniorSynonym($dbt,$synonym_no);
    } else {
        $synonym_no = TaxonInfo::getSeniorSynonym($dbt,$taxon_no);
    }
    $correct_row = TaxonInfo::getMostRecentParentOpinion($dbt,$synonym_no);
    if ($correct_row && $correct_row->{'child_spelling_no'}) {
        $synonym_no = $correct_row->{'child_spelling_no'};
    }

    # Now insert all the names
    # This is insert ignore instead of inserto to deal with bad records
    $sql = "INSERT IGNORE INTO taxa_tree_cache_new (taxon_no,lft,rgt,spelling_no,synonym_no) VALUES ";
    foreach my $t (keys %all_taxa) {
        $sql .= "($t,$lft,$rgt,$spelling_no,$synonym_no),";
        $processed->{$t} = 1;
    }    
    $sql =~ s/,$//;
    print "$sql<BR>\n" if ($DEBUG);
    $dbh->do($sql);

    return $next_lft;
}


# This will add a new taxonomic name to the datbaase that doesn't currently 
# belong anywhere.  Should be called when creating a new authority (Taxon.pm) 
# and Opinion.pm (when creating a new spelling on fly)
sub addName {
    my ($dbt,$taxon_no) = @_;
    my $dbh = $dbt->dbh;
   
    my $sql = "SELECT max(rgt) m FROM taxa_tree_cache";
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my $row = $sth->fetchrow_arrayref();
    my $lft = $row->[0] + 1; 
    my $rgt = $row->[0] + 2; 
   
    $sql = "INSERT IGNORE INTO taxa_tree_cache (taxon_no,lft,rgt,spelling_no,synonym_no) VALUES ($taxon_no,$lft,$rgt,$taxon_no,$taxon_no)";
    print "Adding name: $taxon_no: $sql<BR>\n" if ($DEBUG);
    $dbh->do($sql); 
    $sql = "SELECT * FROM taxa_tree_cache WHERE taxon_no=$taxon_no";
    my $row = ${$dbt->getData($sql)}[0];
    return $row;
}

# This wil do its best to synchronize the two taxa_cache tables with the opinions table
# This function should be called whenever a new opinion is added into the database, whether
# its from Taxon.pm or Opinion.pm.  Its smart enough not to move stuff around if it doesn't have
# to.  The code is broken into two main sections.  The first section combines any alternate
# spellings that have with the original combination, and the second section deals with the
# the taxon changing parents and thus shifting its left and right values.
# Also add newly entered names with this.  Procedure is addName(taxon_no) .. insert opinion into db .. updateCache(taxon_no);
#
# Arguments:
#   $child_no is the taxon_no of the child to be updated (if necessary)
sub updateCache {
    my ($dbt,$child_no) = @_;
    my $dbh=$dbt->dbh;

    my $sql;
    my @updateListCache;

    # don't forget this - emulate transactions
    $dbh->do("LOCK TABLES taxa_tree_cache READ"); 
    $dbh->do("LOCK TABLES taxa_tree_cache WRITE, opinions AS o WRITE, refs AS r WRITE"); 

    # New most recent opinion
    $sql = "SELECT taxon_no,lft,rgt,spelling_no,synonym_no FROM taxa_tree_cache WHERE taxon_no=$child_no";
    my $cache_row = ${$dbt->getData($sql)}[0];
    if (!$cache_row) {
        $cache_row = addName($dbt,$child_no);
    }

    # First section: combine any new spellings that have been added into the original combination
    $sql = "SELECT DISTINCT o.child_spelling_no FROM opinions o WHERE o.child_spelling_no != o.child_no AND o.child_no=$child_no";
    my @results = @{$dbt->getData($sql)};
    my @upd_rows = ();
    foreach my $row (@results) {
        my $spelling_no = $row->{'child_spelling_no'};

        $sql = "SELECT taxon_no,lft,rgt,spelling_no,synonym_no FROM taxa_tree_cache WHERE taxon_no=$spelling_no";
        my $spelling_row = ${$dbt->getData($sql)}[0];
        if (!$spelling_row) {
            $spelling_row = addName($dbt,$spelling_no);
        }
        
        # If a spelling no hasn't been combined yet, combine it now
        if ($spelling_row->{'lft'} != $cache_row->{'lft'}) {
            # Now after they're combined, make sure the spelling_no and synonym_nos get updated as well
            $sql = "UPDATE taxa_tree_cache SET lft=$cache_row->{lft}, rgt=$cache_row->{rgt} WHERE lft=$spelling_row->{lft}";
            print "Combining spelling $spelling_no with $child_no: $sql<BR>\n" if ($DEBUG);
            $dbh->do($sql);

            my ($upd_lft,$upd_rgt) = ($cache_row->{'lft'},$cache_row->{'rgt'});
            push @upd_rows,[$upd_lft,$upd_rgt];

            # if the alternate spelling had children (not too likely), move them now as well
            if (($spelling_row->{'rgt'} - $spelling_row->{'lft'}) > 2) {
                my $old_children_lft = $spelling_row->{'lft'} + 1;
                my $old_children_rgt = $spelling_row->{'rgt'} - 1;
                my ($upd_lft,$upd_rgt) = moveChildren($dbt,$old_children_lft,$old_children_rgt,$child_no);
                push @upd_rows,[$upd_lft,$upd_rgt];
            } 
            # Reset synonym nos of moved children, this will probably never come up
            $sql = "UPDATE taxa_tree_cache SET synonym_no=$cache_row->{synonym_no} WHERE lft=$cache_row->{lft} OR (lft >= $cache_row->{lft} AND rgt <= $cache_row->{rgt} AND synonym_no=$spelling_row->{synonym_no})"; 
            $dbh->do($sql);
        }
    }

    # New most recent opinion
    my $mrpo = TaxonInfo::getMostRecentParentOpinion($dbt,$child_no);
    my $spelling_no = ($mrpo) ? $mrpo->{'child_spelling_no'} : $child_no;

    # Refresh he cache row from the db since it may have been chagned above
    $sql = "SELECT taxon_no,lft,rgt,spelling_no,synonym_no FROM taxa_tree_cache WHERE taxon_no=$child_no";
    $cache_row = ${$dbt->getData($sql)}[0];
       
    # Change the most current spelling_no
    $sql = "UPDATE taxa_tree_cache SET spelling_no=$spelling_no WHERE lft=$cache_row->{lft}"; 
    print "Updating spelling with $spelling_no: $sql<BR>\n" if ($DEBUG);
    $dbh->do($sql);

    # Change it so the senior synonym no points to the senior synonym's most correct name
    # for this taxa and any of ITs junior synonyms
    my $senior_synonym_no = TaxonInfo::getSeniorSynonym($dbt,$child_no);
    my $correct_row = TaxonInfo::getMostRecentParentOpinion($dbt,$senior_synonym_no);
    if ($correct_row && $correct_row->{'child_spelling_no'}) {
        $senior_synonym_no = $correct_row->{'child_spelling_no'};
    }
    $sql = "UPDATE taxa_tree_cache SET synonym_no=$senior_synonym_no WHERE lft=$cache_row->{lft} OR (lft >= $cache_row->{lft} AND rgt <= $cache_row->{rgt} AND synonym_no=$cache_row->{synonym_no})"; 
    print "Updating synonym with $senior_synonym_no: $sql<BR>\n" if ($DEBUG);
    $dbh->do($sql);

    $dbh->do("UNLOCK TABLES");
    # (may take some time) and b/c there may be setting of spelling/no synonym_no after the first
    # section of code that needs to take place before this function should be called
    if (@upd_rows) {
        foreach my $lft_rgt (@upd_rows) {
            updateListCache($dbt,$lft_rgt->[0],$lft_rgt->[1]);
        }
    }

    # don't forget this - emulate transactions till we actually have them
    $dbh->do("LOCK TABLES taxa_tree_cache READ"); 
    $dbh->do("LOCK TABLES taxa_tree_cache WRITE, opinions AS o WRITE, refs AS r WRITE"); 

    # Second section: Now we check if the parents have been chagned by a recent opinion, and only update
    # it if that is the case
    $sql = "SELECT spelling_no parent_no FROM taxa_tree_cache WHERE lft < $cache_row->{lft} AND rgt > $cache_row->{rgt} ORDER BY lft DESC LIMIT 1";
    # BUG: may be multiple parents, compare most recent spelling:
    my $row = ${$dbt->getData($sql)}[0];
    my ($upd_lft,$upd_rgt) = ("","");
    my $new_parent_no = ($mrpo && $mrpo->{'parent_no'}) ? $mrpo->{'parent_no'} : 0;
    if ($new_parent_no) {
        # Compare most recent spellings of the names, for consistency
        my $correct_row = TaxonInfo::getMostRecentParentOpinion($dbt,$new_parent_no);
        if ($correct_row && $correct_row->{'child_spelling_no'}) {
            $new_parent_no = $correct_row->{'child_spelling_no'};
        }
    }
    my $old_parent_no = ($row && $row->{'parent_no'}) ? $row->{'parent_no'} : 0;
    if ($new_parent_no != $old_parent_no) {
        print "Parents have been changed: new parent $new_parent_no: $sql<BR>\n" if ($DEBUG);
        
        if ($cache_row) {
            ($upd_lft,$upd_rgt) = moveChildren($dbt,$cache_row->{'lft'},$cache_row->{'rgt'},$new_parent_no);
        } else {
            carp "Missing child_no from taxa_tree_cache: child_no: $child_no";
        }
    }
    $dbh->do("UNLOCK TABLES");
    if ($upd_lft) {
        updateListCache($dbt,$upd_lft,$upd_rgt);
    }

}

# This is a utility function that moves a block of children in the taxa_tree_cache from
# their old parent to their new parent.  We specify the lft and rgt values of the 
# children we want ot move rather than just passing in the child_no to make this function
# a bit more flexible (it can move blocks of children and their descendents instead of 
# just one child).  The general steps are:
#   * Create a new open space where we're going to be moving the children
#   * Add the difference between the old location and new location to the children
#     so all their values get adjusted to be in the new spot
#   * Remove the old "vacuum" where the children used to be
sub moveChildren {
    my ($dbt,$lft,$rgt,$parent_no) = @_;
    my $dbh = $dbt->dbh;
    my $sql;
    my $p_row;
    if ($parent_no) {
        $sql = "SELECT lft,rgt,spelling_no FROM taxa_tree_cache WHERE taxon_no=$parent_no";
        $p_row = ${$dbt->getData($sql)}[0];
    }

    my $child_tree_size = 1+$rgt-$lft;
    print "moveChildren called: lft $lft rgt $rgt parent $parent_no<BR>" if ($DEBUG);

    # Find out where we're going to insert the new child. Just add it as the last child of the parent,
    # or put it at the very end if there is no parent
    my $insert_point;
    if ($parent_no) {
        $insert_point = $p_row->{'rgt'};

        # Now add a space at the location of the new nodes will be and
        # These have to be separate queries
        $sql = "UPDATE taxa_tree_cache SET rgt=rgt+$child_tree_size WHERE rgt >= $insert_point";
        print "moveChildren: create new spot at $p_row->{rgt}, sql1 ($sql)<BR>\n" if ($DEBUG);
        $dbh->do($sql);
        $sql = "UPDATE taxa_tree_cache SET lft=lft+$child_tree_size WHERE lft >= $insert_point";
        print "moveChildren: create new spot at $p_row->{rgt}, sql2 ($sql)<BR>\n" if ($DEBUG);
        $dbh->do($sql);
    } else {
        $sql = "SELECT max(rgt) m FROM taxa_tree_cache";
        my $sth = $dbh->prepare($sql);
        $sth->execute();
        my $row = $sth->fetchrow_arrayref();
        $insert_point = $row->[0] + 1;
        print "moveChildren: create spot at end, blank parent, $insert_point<BR>\n" if ($DEBUG);
    }

    # The child's lft and rgt values may be been just been adjusted by the update ran above, so
    # adjust accordingly
    my $child_rgt = ($insert_point < $lft) ? $rgt + $child_tree_size : $rgt;
    my $child_lft  = ($insert_point < $lft) ? $lft + $child_tree_size : $lft;
    # Adjust their lft and rgt values accordingly by adding/subtracting the difference between where the
    # children and are where we're moving them
    my $diff = abs($insert_point - $child_lft);
    my $sign = ($insert_point < $child_lft) ? "-" : "+";
    $sql = "UPDATE taxa_tree_cache SET lft=lft $sign $diff, rgt=rgt $sign $diff WHERE lft >= $child_lft AND rgt <= $child_rgt";
    print "moveChildren: move to new spot: $sql<BR>\n" if ($DEBUG);
    $dbh->do($sql);

    # Now shift everything down into the old space thats now vacant
    # These have to be separate queries
    $sql = "UPDATE taxa_tree_cache SET lft=lft-$child_tree_size WHERE lft > $child_lft";
    print "moveChildren: remove old spot1: $sql<BR>\n" if ($DEBUG);
    $dbh->do($sql);
    $sql = "UPDATE taxa_tree_cache SET rgt=rgt-$child_tree_size WHERE rgt > $child_lft";
    print "moveChildren: remove old spot2: $sql<BR>\n" if ($DEBUG);
    $dbh->do($sql);

    # Think about this some more
    # Pass back where we moved them to
    my $new_lft = ($insert_point > $child_lft) ? ($insert_point-$child_tree_size) : $insert_point;
    my $new_rgt = ($insert_point > $child_lft) ? ($insert_point-1) : ($insert_point+$child_tree_size-1);
    return ($new_lft,$new_rgt);
}

# Updates the taxa_list_cache for a range of children getting a list
# of parents of those children, adding them into the db, and deleting
# any old parents that the children might have had
sub updateListCache {
    my ($dbt,$lft,$rgt) = @_; 
    my $dbh = $dbt->dbh;

    print "updateListCache called lft $lft rgt $rgt<BR>\n" if ($DEBUG);

    # Update the other cache
    my $sql = "SELECT taxon_no FROM taxa_tree_cache WHERE lft < $lft AND rgt > $rgt AND synonym_no=taxon_no";
    my @parents = map {$_->{'taxon_no'}} @{$dbt->getData($sql)};

    $sql = "SELECT taxon_no FROM taxa_tree_cache WHERE lft >= $lft AND rgt <= $rgt"; 
    my @children = map {$_->{'taxon_no'}} @{$dbt->getData($sql)};

    print "updateListCache children(".join(", ",@children).") parents(".join(", ",@parents).")<BR>\n" if ($DEBUG);

    if (@children) {
        if (@parents) {
            $sql = "INSERT IGNORE INTO taxa_list_cache (parent_no,child_no) VALUES ";
            foreach my $parent_no (@parents) {
                foreach my $child_no (@children) {
                    $sql .= "($parent_no,$child_no),";
                }
            }
            $sql =~ s/,$//;
            print "updateListCache insert sql: ".$sql."<BR>\n" if ($DEBUG);
            $dbh->do($sql);
        }

        # Since we're updating the trees for a big pile of children potentially, some children can be parents of 
        # other children. Don't delete those links, just delete higher ordered ones
        $sql = "DELETE FROM taxa_list_cache WHERE child_no IN (".join(",",@children).") AND parent_no NOT IN (".join(",",@children,@parents).")";
        print "updateListCache: delete sql: ".$sql."<BR>\n" if ($DEBUG);
        $dbh->do($sql);
    } 
}


# Returns all the descendents of a taxon in various forms.  
#  return_type may be:
#    tree - a sorted tree structure, returns the root note (TREE_NODE datastructure, described below)
#       TREE_NODE is a hash with the following keys:
#       TREE_NODE: hash: { 
#           'taxon_no'=> integer, taxon_no of most current name
#           'taxon_name'=> most current name of taxon
#           'children'=> ref to array of TREE_NODEs
#           'synonyms'=> ref to array of TREE_NODEs
#           'spellings'=> ref to array of TREE_NODEs 
#       }
#    array - *default* - an array of taxon_nos, in no particular order
sub getChildren {
    my $dbt = shift;
    my $taxon_no = shift;
    my $return_type = shift;

    if ($return_type eq 'tree') {
        # Ordering is very important. 
        # The ORDER BY tc2.lft makes sure results are returned in hieracharical order, so we can build the tree in one pass below
        # The (tc2.taxon_no != tc2.spelling_no) term ensures the most recent name always comes first (this simplfies later algorithm)
        my $sql = "SELECT tc2.taxon_no, a1.taxon_rank, a1.taxon_name, tc2.spelling_no, tc2.lft, tc2.rgt, tc2.synonym_no FROM taxa_tree_cache tc1, taxa_tree_cache tc2, authorities a1 WHERE tc1.taxon_no=$taxon_no AND a1.taxon_no=tc2.taxon_no AND tc2.lft >= tc1.lft and tc2.rgt <= tc1.rgt ORDER BY tc2.lft, (tc2.taxon_no != tc2.spelling_no)";
        my @results = @{$dbt->getData($sql)};

        my $root = shift @results;
        $root->{'children'}  = [];
        $root->{'synonyms'}  = [];
        $root->{'spellings'} = [];
        my @parents = ($root);
        foreach my $row (@results) {
            last if (!@parents);
            my $p = $parents[0];

            if ($row->{'lft'} == $p->{'lft'}) {
                # This is a correction/recombination/rank change
                push @{$p->{'spellings'}},$row;
#                print "New spelling of parent $p->{taxon_name}: $row->{taxon_name}\n";
            } else {
                $row->{'children'}  = [];
                $row->{'synonyms'}  = [];
                $row->{'spellings'} = [];

                while ($row->{'rgt'} > $p->{'rgt'}) {
                    shift @parents;
                    last if (!@parents);
                    $p = $parents[0];
                }
                if ($row->{'synonym_no'} != $row->{'spelling_no'}) {
                    push @{$p->{'synonyms'}},$row;
#                    print "New synonym of parent $p->{taxon_name}: $row->{taxon_name}\n";
                } else {
                    push @{$p->{'children'}},$row;
#                    print "New child of parent $p->{taxon_name}: $row->{taxon_name}\n";
                }
                unshift @parents, $row;
            }
        }

        # Now go through and sort stuff in tree
        my @nodes_to_sort = ($root);
        while(@nodes_to_sort) {
            my $node = shift @nodes_to_sort;
            my @children = sort {$a->{'taxon_name'} cmp $b->{'taxon_name'}} @{$node->{'children'}};
            $node->{'children'} = \@children;
            unshift @nodes_to_sort,@children;
        }
        return $root;
    } else {
        my $sql = "SELECT tc2.taxon_no FROM taxa_tree_cache tc1, taxa_tree_cache tc2 WHERE tc1.taxon_no=$taxon_no AND tc2.lft >= tc1.lft and tc2.rgt <= tc1.rgt";
        #my $sql = "SELECT l.child_no FROM taxa_list_cache l WHERE l.parent_no=$taxon_no";
        my @taxon_nos = map {$_->{'taxon_no'}} @{$dbt->getData($sql)};
        return @taxon_nos;
    }
}

# Returns an ordered array of ancestors for a given taxon_no. Doesn't return synonyms of those ancestors 
#  b/c that functionality not needed anywhere
# return type may be:
#   array_full - an array of hashrefs, in order by lowest to highest class. Hash ref has following keys:
#       taxon_no (integer), taxon_name (string), spellings (arrayref to array of same) synonyms (arrayref to array of same)
#   array - *default* - an array of taxon_nos, in order from lowest to higher class
sub getParents {
    my ($dbt,$taxon_nos_ref,$return_type) = @_;

    my %hash = ();
    foreach my $taxon_no (@$taxon_nos_ref) {
        if ($return_type eq 'array_full') {
            my $sql = "SELECT a.taxon_no,a.taxon_name,a.taxon_rank FROM taxa_list_cache l, taxa_tree_cache t, authorities a WHERE t.taxon_no=l.parent_no AND a.taxon_no=l.parent_no AND l.child_no=$taxon_no ORDER BY t.lft DESC";
            $hash{$taxon_no} = $dbt->getData($sql);
        } else {
            my $sql = "SELECT l.parent_no FROM taxa_list_cache l, taxa_tree_cache t WHERE t.taxon_no=l.parent_no AND l.child_no=$taxon_no ORDER BY t.lft DESC";
            my @taxon_nos = map {$_->{'parent_no'}} @{$dbt->getData($sql)};
            $hash{$taxon_no} = \@taxon_nos;
        }
    }
    return \%hash;
}

# Simplified version of the above function which just returns the most senior name of the most immediate
# parent, as a hashref
sub getParent {
    my $dbt = shift;
    my $taxon_no = shift;

    my $sql = "SELECT a.taxon_no,a.taxon_name,a.taxon_rank FROM taxa_list_cache l, taxa_tree_cache t, authorities a WHERE t.taxon_no=l.parent_no AND a.taxon_no=l.parent_no AND l.child_no=$taxon_no ORDER BY t.lft DESC LIMIT 1";
    return ${$dbt->getData($sql)}[0];
}

1;
