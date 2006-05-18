package Reclassify;


use URI::Escape;

# written by JA 31.3, 1.4.04
# in memory of our dearly departed Ryan Poling

# start the process to get to the reclassify occurrences page
# modelled after startAddEditOccurrences
sub startReclassifyOccurrences	{
	my ($q,$s,$dbh,$dbt,$hbo) = @_;

	if (!$s->isDBMember()) {
	    # have to be logged in
		$s->enqueue( $dbh, "action=startStartReclassifyOccurrences" );
		main::displayLoginPage( "Please log in first." );
	} elsif ( $q->param("collection_no") )	{
        # if they have the collection number, they'll immediately go to the
        #  reclassify page
		&displayOccurrenceReclassify($q,$s,$dbh,$dbt);
	} else	{
        my $html = $hbo->populateHTML('search_reclassify_form', [ '', '', ''], [ 'research_group', 'eml_max_interval', 'eml_min_interval'], []);

        my $javaScript = main::makeAuthEntJavaScript();
        $html =~ s/%%NOESCAPE_enterer_authorizer_lists%%/$javaScript/;
        my $authorizer_reversed = $s->get("authorizer_reversed");
        $html =~ s/%%authorizer_reversed%%/$authorizer_reversed/;
        my $enterer_reversed = $s->get("enterer_reversed");
        $html =~ s/%%enterer_reversed%%/$enterer_reversed/;

        # Spit out the HTML
        print main::stdIncludes( "std_page_top" );
        main::printIntervalsJava(1);
        print $html;
        print main::stdIncludes("std_page_bottom");  
    }
}

# print a list of the taxa in the collection with pulldowns indicating
#  alternative classifications
sub displayOccurrenceReclassify	{

	my $q = shift;
	my $s = shift;
	my $dbh = shift;
	my $dbt = shift;
    my $collections_ref = shift;
    my @collections = @$collections_ref;

	print main::stdIncludes("std_page_top");

    my @occrefs;
    if (@collections) {
	    print "<center><h3>Classification of ".$q->param('taxon_name')."</h3>";
        my ($genus,$subgenus,$species,$subspecies) = Taxon::splitTaxon($q->param('taxon_name'));
        my @names = ($dbh->quote($genus));
        if ($subgenus) {
            push @names, $dbh->quote($subgenus);
        }
        my $names = join(", ",@names);
        my $sql = "(SELECT 0 reid_no, o.authorizer_no, o.occurrence_no,o.taxon_no, o.genus_reso, o.genus_name, o.subgenus_reso, o.subgenus_name, o.species_reso, o.species_name, c.collection_no, c.collection_name, c.country, c.state, c.max_interval_no, c.min_interval_no FROM occurrences o, collections c WHERE o.collection_no=c.collection_no AND c.collection_no IN (".join(", ",@collections).") AND (o.genus_name IN ($names) OR o.subgenus_name IN ($names))";
        if ($species) {
            $sql .= " AND o.species_name LIKE ".$dbh->quote($species);
        }
        $sql .= ")";
        $sql .= " UNION ";
        $sql .= "( SELECT re.reid_no, re.authorizer_no,re.occurrence_no,re.taxon_no, re.genus_reso, re.genus_name, re.subgenus_reso, re.subgenus_name, re.species_reso, re.species_name, c.collection_no, c.collection_name, c.country, c.state, c.max_interval_no, c.min_interval_no FROM reidentifications re, occurrences o, collections c WHERE re.occurrence_no=o.occurrence_no AND o.collection_no=c.collection_no AND c.collection_no IN (".join(", ",@collections).") AND (re.genus_name IN ($names) OR re.subgenus_name IN ($names))";
        if ($species) {
            $sql .= " AND re.species_name LIKE ".$dbh->quote($species);
        }
        $sql .= ") ORDER BY occurrence_no ASC, reid_no ASC";
        main::dbg("Reclassify sql:".$sql);
        @occrefs = @{$dbt->getData($sql)};
    } else {
	    my $sql = "SELECT collection_name FROM collections WHERE collection_no=" . $q->param('collection_no');
	    my $coll_name = ${$dbt->getData($sql)}[0]->{collection_name};
	    print "<center><h3>Classification of taxa in collection ",$q->param('collection_no')," ($coll_name)</h3>";

        # get all the occurrences
        my $collection_no = int($q->param('collection_no'));
        $sql = "(SELECT 0 reid_no,authorizer_no, occurrence_no,taxon_no,genus_reso,genus_name,subgenus_reso,subgenus_name,species_reso,species_name FROM occurrences WHERE collection_no=$collection_no)".
               " UNION ".
               "(SELECT reid_no,authorizer_no, occurrence_no,taxon_no,genus_reso,genus_name,subgenus_reso,subgenus_name,species_reso,species_name FROM reidentifications WHERE collection_no=$collection_no)".
               " ORDER BY occurrence_no ASC,reid_no ASC";
        main::dbg("Reclassify sql:".$sql);
        @occrefs = @{$dbt->getData($sql)};
    }

	# tick through the occurrences
	# NOTE: the list will be in data entry order, nothing fancy here
	if ( @occrefs )	{
		print "<form method=\"post\">\n";
		print "<input id=\"action\" type=\"hidden\" name=\"action\" value=\"startProcessReclassifyForm\">\n";
        if (@collections) {
            print "<input type=\"hidden\" name=\"taxon_name\" value=\"".$q->param('taxon_name')."\">";
		    print "<table border=0 cellpadding=0 cellspacing=0>\n";
            print "<tr><th colspan=2>Collection</th><th>Classificaton based on</th></tr>";
        } else {
            print "<input type=\"hidden\" name=\"collection_no\" value=\"".$q->param('collection_no')."\">";
		    print "<table border=0 cellpadding=0 cellspacing=0>\n";
            print "<tr><th>Taxon name</th><th>Classification based on</th></tr>";
        }
	}

    # Make non-editable links not changeable
    my $p = Permissions->new($s,$dbt);
    my %is_modifier_for = %{$p->getModifierList()};

	my $rowcolor = 0;
    my $nonEditableCount = 0;
    my @badoccrefs;
    my $nonExact = 0;
	for my $o ( @occrefs )	{
        my $editable = ($s->get("superuser") || $is_modifier_for{$o->{'authorizer_no'}} || $o->{'authorizer_no'} == $s->get('authorizer_no')) ? 1 : 0;
        my $disabled = ($editable) ?  '' : 'DISABLED';
        my $authorizer = ($editable) ? '' : '(<b>Authorizer:</b> '.Person::getPersonName($dbt,$o->{'authorizer_no'}).')';
        $nonEditableCount++ if (!$editable);

		# if the name is informal, add it to the list of
		#  unclassifiable names
		if ( $o->{genus_reso} =~ /informal/ )	{
			push @badoccrefs , $o;
		}
		# otherwise print it
		else	{
			# compose the taxon name
			my $taxon_name = $o->{genus_name};
			if ( $o->{species_reso} !~ /informal/ && $o->{species_name} !~ /^sp\./ && $o->{species_name} !~ /^indet\./)	{
				$taxon_name .= " " . $o->{species_name};
			}
            @all_matches = Taxon::getBestClassification($dbt,$o->{'genus_reso'},$o->{'genus_name'},$o->{'subgenus_reso'},$o->{'subgenus_name'},$o->{'species_reso'},$o->{'species_name'});

			# now print the name and the pulldown of authorities
			if ( @all_matches )	{
				if ( $rowcolor % 2 )	{
					print "<tr>";
				} else	{
					print "<tr class='darkList'>";
				}

                my $collection_string = "";
                if ($o->{'collection_no'}) {
                    my $tsql = "SELECT interval_name FROM intervals WHERE interval_no=" . $o->{max_interval_no};
                    my $maxintname = @{$dbt->getData($tsql)}[0];
                    $collection_string = "<b>".$o->{'collection_name'}."</b> ";
                    $collection_string .= "<span class=\"tiny\">"; 
                    $collection_string .= $maxintname->{interval_name};
                    if ( $o->{min_interval_no} > 0 )  {
                        $tsql = "SELECT interval_name FROM intervals WHERE interval_no=" . $o->{min_interval_no};
                        my $minintname = @{$dbt->getData($tsql)}[0];
                        $collection_string .= "/" . $minintname->{interval_name};
                    }

                    $collection_string .= " - ";
                    if ( $o->{"state"} )  {
                        $collection_string .= $o->{"state"};
                    } else  {
                        $collection_string .= $o->{"country"};
                    }
                    $collection_string .= " $authorizer";
                    $collection_string .= "</span>";

                    print "<td style=\"padding-right: 1.5em; padding-left: 1.5em;\"><a href=\"bridge.pl?action=displayCollectionDetails&collection_no=$o->{collection_no}\">$o->{collection_no}</a></td><td>$collection_string</td>";
                }
				print "<td nowrap>&nbsp;&nbsp;\n";

				# here's the name
				my $formatted = "";
				if ( $o->{'species_name'} !~ /^indet\./ )	{
					$formatted .= "<i>";
				}
				$formatted .= "$o->{genus_reso} $o->{genus_name}";
                if ($o->{'subgenus_name'}) {
                    $formatted .= " $o->{subgenus_reso} ($o->{subgenus_name})";
                }
                $formatted .= " $o->{species_reso} $o->{species_name}";
				if ( $o->{'species_name'} !~ /^indet\./ )	{
					$formatted .= "</i>";
				}

				# need a hidden recording the old taxon number
                $collection_string .= ": " if ($collection_string);
                 
				if ( ! $o->{reid_no} )	{
					print "<input type=\"hidden\" $disabled name=\"old_taxon_no\" value=\"$o->{'taxon_no'}\">";
                    print "<input type=\"hidden\" $disabled name=\"occurrence_description\" value=\"".uri_escape($collection_string.$formatted)."\">\n";
					print "<input type=\"hidden\" $disabled name=\"occurrence_no\" value=\"" , $o->{occurrence_no}, "\">\n";
				} else	{
					print "<input type=\"hidden\" $disabled name=\"old_reid_taxon_no\" value=\"$o->{taxon_no}\">\n";
                    print "<input type=\"hidden\" $disabled name=\"reid_description\" value=\"".uri_escape($collection_string.$formatted)."\">\n";
					print "<input type=\"hidden\" $disabled name=\"reid_no\" value=\"" , $o->{reid_no}, "\">\n";
					print "&nbsp;&nbsp;<span class='small'><b>reID =</b></span>&nbsp;";
				}

				print $formatted;
				print "</td>\n";

				# start the select list
				# the name depends on whether this is
				#  an occurrence or reID
				if ( ! $o->{reid_no} )	{
					print "<td>&nbsp;&nbsp;\n<select $disabled name='taxon_no'>\n";
				} else	{
					print "<td>&nbsp;&nbsp;\n<select $disabled name='reid_taxon_no'>\n";
				}
				# populate the select list of authorities
				foreach my $m ( @all_matches)	{
                    my $t = TaxonInfo::getTaxa($dbt,{'taxon_no'=>$m->{'taxon_no'}},['taxon_no','taxon_name','taxon_rank','author1last','author2last','otherauthors','pubyr']);
					# have to format the authority data
					my $authority = "$t->{taxon_name}";
                    my $pub_info = Reference::formatShortRef($t);
                    if ($pub_info =~ /[A-Za-z0-9]/) {
                        $authority .= ", $pub_info";
                    }
                	# needed by Classification
                    my %master_class=%{TaxaCache::getParents($dbt, [$t->{'taxon_no'}],'array_full')};

					my @parents = @{$master_class{$t->{'taxon_no'}}};
                    if (@parents) {
						$authority .= " [";
                        my $foundParent = 0;
                        foreach (@parents) {
                            if ($_->{'taxon_rank'} =~ /^(?:family|order|class)$/) {
                                $foundParent = 1;
                                $authority .= $_->{'taxon_name'}.", ";
                                last;
                            }
                        }
                        $authority =~ s/, $//;
                        if (!$foundParent) {
                            $authority .= $parents[0]->{'taxon_name'};
                        }
                        $authority .= "]";
                    }
					if ( $authority !~ /[A-Za-z]/ )	{
						$authority = "taxon number " . $t->{taxon_no};
					}
					# clean up in case there's a
					#  classification but no author
					$authority =~ s/^ //;

					if ($m->{'match_level'} < 30)	{
						$nonExact++;
					}

					print "<option value='" , $t->{taxon_no} , "+" , $authority , "'";
					if ( $t->{taxon_no} eq $o->{taxon_no} )	{
						print " selected";
					}
					print ">";
					print $authority , "\n";
				}
				if ( $o->{taxon_no} )	{
					print "<option value='0'>leave unclassified\n";
				} else	{
					print "<option value='0' selected>leave unclassified\n";
				}
				print "</select>&nbsp;&nbsp;</td>\n";
				print "</tr>\n";
				$rowcolor++;
			} else	{
				push @badoccrefs , $o;
			}
		}
	}
	if ( @occrefs )	{
		print "</table>\n";
		print "<p><input type=submit value='Reclassify'></p>\n";
		print "</form>\n";
	}
	print "<p>\n";
	if ( $nonExact)	{
		print "<p><div class=\"warning\">Exact formal classifications for some taxa could not be found, so approximate matches were used.  For example, a species might not be formally classified but its genus is.</div></p>\n";
	}
    if ( $nonEditableCount) {
        print "<p><div class=\"warning\">Some occurrences can't be reclassified because they have a different authorizer</div></p>\n";
    }

	# print the informal and otherwise unclassifiable names
	if ( @badoccrefs )	{
		print "<hr>\n";
		print "<h4>Taxa that cannot be classified</h4>";
		print "<p><i>Check these names for typos and/or create new taxonomic authority records for them</i></p>\n";
		print "<table border=0 cellpadding=0 cellspacing=0>\n";
	}
	$rowcolor = 0;
	for my $b ( @badoccrefs )	{
		if ( $rowcolor % 2 )	{
			print "<tr>";
		} else	{
			print "<tr class='darkList'>";
		}
		print "<td align='left'>&nbsp;&nbsp;";
		if ( $b->{'species_name'} !~ /^indet\./)	{
			print "<i>";
		}
		print "$b->{genus_reso} $b->{genus_name}";
        if ($b->{'subgenus_name'}) {
            print " $b->{subgenus_reso} ($b->{subgenus_name})";
        }
        print " $b->{species_reso} $b->{species_name}\n";
		if ( $b->{'species_name'} !~ /^indet\./)	{
			print "</i>";
		}
		print "&nbsp;&nbsp;</td></tr>\n";
		$rowcolor++;
	}
	if ( @badoccrefs )	{
		print "</table>\n";
	}

	print "<p>\n";
	print "</center>\n";

	print main::stdIncludes("std_page_bottom");

}

sub processReclassifyForm	{

	my $q = shift;
	my $s = shift;
	my $dbh = shift;
	my $dbt = shift;
	my $exec_url = shift;

    print "<BR>";
	print main::stdIncludes("std_page_top");

	print "<center>\n\n";

    if ($q->param('collection_no')) {
        my $sql = "SELECT collection_name FROM collections WHERE collection_no=" . $q->param('collection_no');
        my $coll_name = ${$dbt->getData($sql)}[0]->{collection_name};
        print "<h3>Taxa reclassified in collection " , $q->param('collection_no') ," (" , $coll_name , ")</h3>\n\n";
	    print "<table border=0 cellpadding=2 cellspacing=0>\n";
        print "<tr><th>Taxon</th><th>Classification based on</th></tr>";
    } else {
        print "<h3>Taxa reclassified for " , $q->param('taxon_name') ,"</h3>\n\n";
	    print "<table border=0 cellpadding=2 cellspacing=0>\n";
        print "<tr><th colspan=2>Collection</th><th>Classification based on</th></tr>";
    }

	# get lists of old and new taxon numbers
	# WARNING: taxon names are stashed in old numbers and authority info
	#  is stashed in new numbers
	my @old_taxa = $q->param('old_taxon_no');
	my @new_taxa = $q->param('taxon_no');
	my @occurrences = $q->param('occurrence_no');
	my @occurrence_descriptions = $q->param('occurrence_description');
	my @reid_descriptions = $q->param('reid_description');
	my @old_reid_taxa = $q->param('old_reid_taxon_no');
	my @new_reid_taxa = $q->param('reid_taxon_no');
	my @reids = $q->param('reid_no');

	my $rowcolor = 0;

	# first tick through the occurrence taxa and update as appropriate
    my $seen_reclassification = 0;
	foreach my $i (0..$#old_taxa)	{
		my $old_taxon_no = $old_taxa[$i];
        my $occurrence_description = uri_unescape($occurrence_descriptions[$i]);
		my ($new_taxon_no,$authority) = split /\+/,$new_taxa[$i];
		if ( $old_taxa[$i] != $new_taxa[$i] )	{
            $seen_reclassification++;

		# update the occurrences table
			my $sql = "UPDATE occurrences SET taxon_no=".$new_taxon_no.
                   ", modifier=".$dbh->quote($s->get('enterer')).
			       ", modifier_no=".$s->get('enterer_no');
			if ( $old_taxon_no > 0 )	{
				$sql .= " WHERE taxon_no=" . $old_taxon_no;
			} else	{
				$sql .= " WHERE taxon_no=0";
			}
			$sql .= " AND occurrence_no=" . $occurrences[$i];
			$dbt->getData($sql);

		# print the taxon's info
			if ( $rowcolor % 2 )	{
				print "<tr>";
			} else	{
				print "<tr class='darkList'>";
			}
			print "<td>&nbsp;&nbsp;$occurrence_description</td><td style=\"padding-left: 1em;\"> $authority&nbsp;&nbsp;</td>\n";
			print "</tr>\n";
			$rowcolor++;
		}
	}

	# then tick through the reidentification taxa and update as appropriate
	# WARNING: this isn't very slick; all the reIDs always come after
	#  all the occurrences
	foreach my $i (0..$#old_reid_taxa)	{
		my $old_taxon_no = $old_reid_taxa[$i];
        my $reid_description = uri_unescape($reid_descriptions[$i]);
		my ($new_taxon_no,$authority) = split /\+/,$new_reid_taxa[$i];
		if ( $old_reid_taxa[$i] != $new_reid_taxa[$i] )	{
            $seen_reclassification++;

		# update the reidentifications table
			my $sql = "UPDATE reidentifications SET taxon_no=".$new_taxon_no.
                   ", modifier=".$dbh->quote($s->get('enterer')).
			       ", modifier_no=".$s->get('enterer_no');
			if ( $old_taxon_no > 0 )	{
				$sql .= " WHERE taxon_no=" . $old_taxon_no;
			} else	{
				$sql .= " WHERE taxon_no=0";
			}
			$sql .= " AND reid_no=" . $reids[$i];
			$dbt->getData($sql);

		# print the taxon's info
			if ( $rowcolor % 2 )	{
				print "<tr>";
			} else	{
				print "<tr class='darkList'>";
			}
			print "<td>&nbsp;&nbsp;$reid_description</td><td style=\"padding-left: 1em;\"> $authority&nbsp;&nbsp;</td>\n";
			print "</tr>\n";
			$rowcolor++;
		}
	}

	print "</table>\n\n";
    if (!$seen_reclassification) {
        print "<div align=\"center\">No taxa reclassified</div>";
    }

	print "<p><a href=\"$exec_url?action=startStartReclassifyOccurrences&collection_no=";
	print $q->param('collection_no');
	print "\"><b>Reclassify this collection</b></a> - ";
	print "<a href=\"$exec_url?action=startStartReclassifyOccurrences\"><b>Reclassify another collection</b></a></p>\n\n";

	print "<center>\n\n";

	print main::stdIncludes("std_page_bottom");

}


1;
