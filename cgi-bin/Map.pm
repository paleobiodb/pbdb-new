package Map;

use Debug qw(dbg);
use URI::Escape;                                                                                                                                            
use GD;
use CGI::Carp;
use Class::Date qw(date localdate gmdate now);
use Image::Magick;
use TimeLookup;
use Digest::MD5;
use Constants qw($READ_URL $WRITE_URL $DATAFILE_DIR);

# Flags and constants
my $dbt;    # The DBTransactionManager object
my $q;	    # Reference to the parameters
my $s;

my $GIF_HTTP_ADDR = "/public/maps";
my $COAST_DIR = $ENV{MAP_COAST_DIR};
my $GIF_DIR = $ENV{MAP_GIF_DIR};
my $TILE_DIR = $GIF_DIR;
$TILE_DIR =~ s/maps$/staticmaps/;
my $FONT = "$DATAFILE_DIR/fonts/orangeki.ttf";
my $PI = 3.14159265;
my $C72 = cos(72 * $PI / 180);
my $AILEFT = 100;
my $AITOP = 580;

# These mostly relate to the maps physical appearance and focus
my %map_defaults = (
    'projection'=>'equirectangular',
    'mapscale'=>'auto',
    'mapwidth'=>'100%',
    'mapsize'=>'100%',
    'maptime'=>'0', 
    'mapfocus'=>'standard (0,0)', 
    'mapresolution'=>'auto',
    'pointsize1'=>'medium', 'dotcolor1'=>'orange', 'pointshape1'=>'circles',  'dotborder1'=>'no', 
    'pointsize2'=>'medium', 'dotcolor2'=>'blue',   'pointshape2'=>'squares',  'dotborder2'=>'no', 
    'pointsize3'=>'medium', 'dotcolor3'=>'yellow', 'pointshape3'=>'triangles','dotborder3'=>'no', 
    'pointsize4'=>'medium', 'dotcolor4'=>'green',  'pointshape4'=>'diamonds', 'dotborder4'=>'no', 
    'usalinecolor'=>'gray', 'borderlinecolor'=>'gray', 'autoborders'=>'no',
    'mapbgcolor'=>'white', 'coastlinecolor'=>'black',
    'crustcolor'=>'none',  'crustedgecolor'=>'light gray', 'linethickness'=>'medium', 
    'gridsize'=>'30', 'gridcolor'=>'light gray', 'gridposition'=>'in back'
);
# These are all form params that don't relate to the maps physical appearance
#my @formParams = ('simple_map','research_group', 'authorizer', 'enterer', 'authorizer_reversed','enterer_reversed','modified_since', 'day_of_month', 'month', 'year', 'country', 'state', 'interval_name', 'group_formation_member', 'lithology1', 'environment', 'taxon_rank', 'taxon_name', 'mapsearchfields2', 'mapsearchterm2', 'mapsearchfields3', 'mapsearchterm3', 'mapsearchfields4', 'mapsearchterm4');

          
sub new {
    my $class = shift;
    $q = shift;
    $dbt = shift;
    $s = shift;
    unless ($q) {
        $q = new CGI;
    }

	# some functions that call Map do not pass a q or s object
	my $self = {plate=>[]};
	if ($q)	{
		if ($q->param('linecommand') =~ /[A-Za-z]/)	{
			$GIF_DIR =~ s/maps$//;
			$GIF_DIR .= "animations";
		}
	    $self->{'maptime'} = $q->param('maptime');
	    $self->{rotatemapfocus} = $q->param('rotatemapfocus');
	}

	$self->{'maptime'} ||= 0;
	bless $self, $class;
}

sub buildMap {
	my $self = shift;
    my %options = @_;

    # Load in default parameters
    while (my ($p,$def) = each %map_defaults) {
        if ($q->param($p) eq '') {
            $q->param($p=>$def);
        }
    }

    my $dataSets;
    if ($options{'dataSet'}) {
        $dataSets->[1] = $options{dataSet};
    } else {
        my ($errors,$warnings)  = $self->mapCheckParams();
        unless (ref $errors && @$errors) {
            ($dataSets,$errors2,$warnings2)  = $self->mapQueryDB();
            push @$errors, @$errors2;
            push @$warnings, @$warnings2;
        }
    }

    foreach my $i (1 .. 4) {
        if (ref $dataSets->[$i] && @{$dataSets->[$i]}) {
            $count += @{$dataSets->[$i]};
        }
    }
    if (!$count) {
        push @$errors, 'No matching collections found';
    }


    if (ref $errors && @$errors) {
        return "",$errors,$warnings;
    } 

	$self->mapSetScale($dataSets);
	$self->mapDefineOutlines();
	if ( $self->{'maptime'} > 0 )	{
		$self->mapGetRotations();
	}
    my $img_link = $self->mapSetupImage();

    foreach my $i (1 .. 4) {
        if (ref $dataSets->[$i] && @{$dataSets->[$i]}) {
            $self->mapDrawPoints($dataSets->[$i],$i);
        }
    }

    $self->mapFinishImage($dataSets);
    return ($img_link,$errors,$warnings);
}

# This makes sure some parameters (interval name, taxon name) are kosher.
# e.g. they exist in the db/aren't ambiguous. return errors if they aren't
sub mapCheckParams {
    my $self = shift;

    # For all four datasets (point types) ... 
    my @errors = ();
    my @warnings = ();
    foreach my $ptset (1..4) {
        my $interval_name = '';    
        my $taxon_name = 'taxon_name';
        if ($ptset > 1) {
            $extraField = $q->param('mapsearchfields'.$ptset);
            $extraFieldValue = $q->param('mapsearchterm'.$ptset);
            if ($extraField eq 'interval_name') {
                $interval_name = $extraFieldValue;
            } elsif ($extraField eq 'taxon_name') {
                $taxon_name = $extraFieldValue;
            }
        } elsif ($ptset == 1) {
            $interval_name = $q->param('interval_name');
            $taxon_name    = $q->param('taxon_name');
        }
        

        # Get EML values, check interval names
        if ($interval_name =~ /[a-zA-Z]/) {
            my ($eml, $name) = TimeLookup::splitInterval($interval_name);
            if (!Validation::checkInterval($dbt,$eml,$name)) {
                push @errors, "We have no record of $interval_name in the database";
            } 
        }

        # Generate warning for taxon with homonyms
        if ($taxon_name) {
            if($q->param('taxon_rank') ne "species") {
                my @taxa = TaxonInfo::getTaxa($dbt, {'taxon_name'=>$taxon_name,'remove_rank_change'=>1});
                if (scalar(@taxa)  > 1) {
                    push @errors, "The map can't be drawn because more than one taxon has the name '$taxon_name.' If this is a problem email <a href='mailto: alroy\@nceas.ucsb.edu'>John Alroy</a>."
                }
            }
        }
    }

    return (\@errors,\@warnings);
}

sub mapQueryDB {
    my $self = shift;
    my %options = $q->Vars();
    $options{'permission_type'} = 'read';
    $options{'calling_script'} = 'Map';
    my $fields = ['latdeg','latdec','latmin','latsec','latdir','lngdeg','lngdec','lngmin','lngsec','lngdir'];
   
    my @errors = ();
    my @warnings = ();
    foreach my $ptset (1..4) {
        if ($ptset > 1) {
            $extraField = $q->param('mapsearchfields'.$ptset);
            $extraFieldValue = $q->param('mapsearchterm'.$ptset);
            %toptions = %options;

            if ($extraField && $extraFieldValue) {
                $toptions{$extraField} = $extraFieldValue;
                # This makes is to both lithology1 and lithology2 get searched
                if ($toptions{'lithology1'}) {
                    $toptions{'lithologies'} = $toptions{'lithology1'};
                    delete $toptions{'lithology1'};
                }
                if ($toptions{'interval_name'}) {
                    ($toptions{'eml_max_interval'},$toptions{'max_interval'}) = TimeLookup::splitInterval($toptions{'interval_name'});
                }
                my ($dataRowsRef,$ofRows) = Collection::getCollections($dbt,$s,\%toptions,$fields);  
                $dataSets[$ptset] = $dataRowsRef;
            }
        } elsif ($ptset == 1) {
            # This makes is to both lithology1 and lithology2 get searched
            if ($options{'dataSet'}) {
                $dataSets[$ptset] = $options{'dataSet'};
            } else {
                if ($options{'lithology1'}) {
                    $options{'lithologies'} = $options{'lithology1'};
                    delete $options{'lithology1'};
                }
                if ($options{'interval_name'}) {
                    ($options{'eml_max_interval'},$options{'max_interval'}) = TimeLookup::splitInterval($options{'interval_name'});
                }
                my ($dataRowsRef,$ofRows,$warnings) = Collection::getCollections($dbt,$s,\%options,$fields);  
                push @warnings, @$warnings; 
                $dataSets[$ptset] = $dataRowsRef;
            }
        }
    }
    return \@dataSets,\@errors,\@warnings;
}


# This function prints footer for the image, makes clickable background tiles,
# converts and outputs the image to different formats, and closes up everything
sub mapFinishImage {
    my $self = shift;
    my @dataSets = @{$_[0]};


    # following lines taken out by JA 27.10.06 while re-implementing support
    #  for GIF format files, not sure what it does to IE browsers
    # do this only if the browser is not IE
    # this prevents errors with rendering of transparent pixels in PNG format
    if ( $q->param('browser') =~ /Microsoft/ || $q->param('linecommand') =~ /[A-Za-z]/ )	{
        $im->trueColorToPalette();
    }

    # this doesn't actually seem to work (see below), left in for posterity
    #print MAPGIF $im->gif;
    #close MAPGIF;
    #chmod 0664, "$GIF_DIR/$gifname";

    my $image = Image::Magick->new;

    open(PNG,">$GIF_DIR/$pngname");
    binmode(PNG);
    print PNG $im->png;
    close PNG;
    chmod 0664, "$GIF_DIR/$pngname";

    open(GIF,"<$GIF_DIR/$pngname");
    binmode(GIF);
    $image->Read(file=>\*GIF);

# horrible workaround required by screwy performance of GD on flatpebble
    close GIF;
    open GIF2,">$GIF_DIR/$gifname";
    $image->Write(file=>\*GIF2,filename=>"$GIF_DIR/$gifname");
    close GIF2;
    chmod 0664, "$GIF_DIR/$gifname";

    open JPG,">$GIF_DIR/$jpgname";
    $image->Write(file=>\*JPG,filename=>"$GIF_DIR/$jpgname");
    close JPG;
    chmod 0664, "$GIF_DIR/$jpgname";

    close GIF;
    
    open(AI,">$GIF_DIR/$ainame");
    open AIHEAD,"<./data/AI.header";
    while (<AIHEAD>)	{
        print AI $_;
    }
    close AIHEAD;

    print AI $ai;

    open(AIFOOT,"<./data/AI.footer");
    while (<AIFOOT>){
        print AI $_;
    }
    close AIFOOT;
    close AI;

    # make clickable background rectangles for repositioning the map
    my $clickstring = "$READ_URL?action=displayMapResults";
    unless($q->param("simple_map") =~ /YES/i){
        my %param;
        foreach ($q->param(),keys %map_defaults) {
            my $val = $q->param($_);
            if ($val ne '' && $map_defaults{$_} ne $val && $_ !~ /mapscale|maplng|maplat/) {
                $param{$_} = $q->param($_); 
            }
        }
        foreach my $k (sort keys %param) {
            $clickstring .= "&amp;$k=".uri_escape($param{$k});
        }

        # Crate a new cgi object cause the original may have been changed
        #my $q2 = new CGI;
        #for $p ( @params )	{
        #    if ( $q2->param($p) )	{
        #        $clickstring .= "&" . $p . "=" . $q2->param($p);
        #    }
        #}
#        if ($scale > 1) {
            for my $i ( 1..10 )	{
                for my $j ( 1..10 )	{
                    my $xbot = int(( $i - 1 ) / 10 * $width);
                    my $xtop = int($i / 10 * $width);
                    my $ybot = int(( $j - 1 ) / 10 * $height);
                    my $ytop = int($j / 10 * $height);
                    my $newlng = int($midlng + ( ( 360 / $scale ) * ( $i - 5 ) / 10 ));
                    my $newlat = int($midlat - ( ( 180 / $scale ) * ( $j - 5 ) / 10 ));
                    $latlngstring = "&maplng=" . $newlng;
                    $latlngstring .= "&maplat=" . $newlat;
                    # need this because mapscale is varied for the "Zoom"
                    #  buttons below
                    $latlngstring .= "&mapscale=" . $scale;
                    print MAPOUT qq|<area shape="rect" coords="$xbot,$ybot,$xtop,$ytop" href="$clickstring$latlngstring">\n|;
                }
            }
#        }
    }

    print MAPOUT "</map>\n";
    print MAPOUT "</table>\n";

    print MAPOUT "<table cellpadding=10>\n<tr>\n";
    print MAPOUT "<td valign=\"middle\">\n";
    print MAPOUT "<table cellpadding=0 cellspacing=1><tr>\n<td align=\"right\" valign=\"top\" bgcolor=\"black\">\n";
    print MAPOUT "<table cellpadding=5 cellspacing=1>\n";
    unless ($q->param("simple_map") =~ /YES/i){
        print MAPOUT "<tr><td width=110 valign=\"top\" bgcolor=\"white\" class=\"tiny\">";
        my %coll_count = ();
        foreach my $dataSet (@dataSets) {
            if ($dataSet) {
                foreach my $c (@$dataSet) {
                    $coll_count{$c->{'collection_no'}} = 1;
                }
            }
        }
        my $count = scalar(keys %coll_count);
        if ($count > 1)	{
            print MAPOUT "<b>$count&nbsp;collections</b> fall ";
        } elsif ($count == 1)	{
            print MAPOUT "<b>Exactly&nbsp;one collection</b> falls ";
        }  else	{
            # PM 09/13/02 Added bit about missing lat/long data to message
            print MAPOUT "<b>Sorry!</b> Either the collections were missing lat/long data, or no collections fall ";
        }
        print MAPOUT "within the mapped area, have lat/long data, and matched your query";
        print MAPOUT "</td>\n";

        if ($dotsizeterm eq "proportional")	{
            print MAPOUT "<tr><td width=100 valign=\"top\" bgcolor=\"white\" class=\"tiny\">";
            print MAPOUT "<br>Sizes of $dotshape are proportional to counts of collections at each point.\n"
        }

        print MAPOUT "<tr><td width=100 valign=\"top\" bgcolor=\"white\" class=\"tiny\">";
        print MAPOUT "You may download this map in ";
        print MAPOUT "<b><a href=\"$GIF_HTTP_ADDR/$ainame\">Adobe Illustrator</a></b>, ";
        print MAPOUT "<b><a href=\"$GIF_HTTP_ADDR/$gifname\">GIF</a></b>, ";
        print MAPOUT "<b><a href=\"$GIF_HTTP_ADDR/$jpgname\">JPEG</a></b>, ";
        print MAPOUT "or <b><a href=\"$GIF_HTTP_ADDR/$pngname\">PNG</a></b> format\n";
        print MAPOUT "</td></tr>\n";

        print MAPOUT "<tr><td width=100 valign=\"top\" bgcolor=\"white\" class=\"tiny\">";
        print MAPOUT "Click on a point to recenter the map\n";
        print MAPOUT "</td></tr>\n";

        $clickstring .= "&maplng=" . $midlng;
        $clickstring .= "&maplat=" . $midlat;

        $zoom1 = 2;
        while ( $scale + $zoom1 > 12 )	{
            $zoom1--;
        }
        $zoom2 = 2;
        while ( $scale - $zoom2 < 1 )	{
            $zoom2--;
        }

        print MAPOUT "<tr><td width=100 align=\"center\" valign=\"top\" bgcolor=\"white\" class=\"medium\">";
        $temp = $clickstring . "&mapscale=" . ( $scale + $zoom1 );
        print MAPOUT "<p class=\"medium\"><b><a href=\"$temp\">Zoom&nbsp;in</a></b></p>\n";
        print MAPOUT "</td></tr>\n";

        print MAPOUT "<tr><td width=100 align=\"center\" valign=\"top\" bgcolor=\"white\" class=\"medium\">";
        $temp = $clickstring . "&mapscale=" . ( $scale - $zoom2 );
        print MAPOUT "<p class=\"medium\"><b><a href=\"$temp\">Zoom&nbsp;out</a></b></p>\n";
        print MAPOUT "</td></tr>\n";

        print MAPOUT "<tr><td width=100 align=\"center\" valign=\"top\" bgcolor=\"white\" class=\"medium\">";
        if ($q->param('form_source') eq 'basic_map_form') {
            print MAPOUT "<p class=\"medium\"><b><a href='?action=displayBasicMapForm'>Search&nbsp;again</a></b></p>\n";
        } else {
            print MAPOUT "<p class=\"medium\"><b><a href='?action=displayMapForm'>Search&nbsp;again</a></b></p>\n";
        }
        print MAPOUT "</td></tr>\n";
    }
    print MAPOUT "</tr></table>\n";
    print MAPOUT "</td></tr></table>\n";
    print MAPOUT "</td>\n";

    print MAPOUT "<td align=\"center\"><img border=\"0\" alt=\"PBDB map\" height=\"$totalheight\" width=\"$width\" src=\"$GIF_HTTP_ADDR/$gifname\" usemap=\"#PBDBmap\" ismap>\n\n";
    print MAPOUT "</table>\n";

    # JA 26.4.06
    if ($q->param("simple_map") =~ /YES/i){
        print MAPOUT "<p>You may download this map in ";
        print MAPOUT "<b><a href=\"$GIF_HTTP_ADDR/$ainame\">Adobe Illustrator</a></b>, ";
        print MAPOUT "<b><a href=\"$GIF_HTTP_ADDR/$gifname\">GIF</a></b>, ";
        print MAPOUT "<b><a href=\"$GIF_HTTP_ADDR/$jpgname\">JPEG</a></b>, ";
        print MAPOUT "or <b><a href=\"$GIF_HTTP_ADDR/$pngname\">PNG</a></b> format.</p>\n";
    }

    close MAPOUT;
}


sub mapSetScale	{
    my $self = shift;
    my @dataSets = ();
    @dataSets = @{$_[0]} if ref $_[0];

    $scale = 1;
    if ($q->param("mapscale") =~ /auto/ && $self->{'maptime'} > 10) {
        # If we do a rotation we don't want to focus on where the old coordinates were
        # so just display the entire map.  Would have to reorganize the code in order
        # to fix this since John didn't separate the functions into ones that do paleo
        # rotations and projections.
        ($midlat,$midlng,$scale) = (0,0,1);
    } elsif ($q->param("mapscale") =~ /auto/) {
        ($midlat,$midlng,$scale) = calculateBounds(@dataSets);
        ($midlat,$midlng) = $self->snapToTile($midlat,$midlng,$scale);
    } else {
        $scale = $q->param('mapscale');
        $scale =~ s/x //i;

        # the user might enter a zero for one value or the other, so just one
        #  non-zero value is needed
        if ( $q->param('maplat') || $q->param('maplng') )	{
            $midlat = $q->param('maplat');
            $midlng = $q->param('maplng');
        } elsif ($q->param('mapfocus')) {
            ($cont,$coords) = split / \(/,$q->param('mapfocus');
            $coords =~ s/\)//;  # cut off the right parenthesis.
            ($midlat,$midlng) = split /,/,$coords;
        }
        $scale ||= 1;
    }

	$projection = $q->param('projection');

    if ($q->param('autoborders') =~ /yes/i) {
        if ($scale <= 3) {
            $q->param('usalinecolor'=>'none');
            $q->param('borderlinecolor'=>'none');
        }
    }

    $q->param('mapscale'=>$scale);
    $q->param('maplat'=>$midlat);
    $q->param('maplng'=>$midlng);

    if ($scale < 2) {
		$resostem = "075";
    } elsif ($scale < 4) {
		$resostem = "050";
    } elsif ($scale < 8) {
		$resostem = "025";
    } else {
		$resostem = "010";
    }

    # NOTE: shouldn't these be module globals??
    $offlng = 180 * ( $scale - 1 ) / $scale;
    $offlat = 90 * ( $scale - 1 ) / $scale;
}


sub calculateBounds {
    my @dataSets = @_;
    my ($lat1,$lng1,$lat2,$lng2);
    my ($lat_size,$lng_size) = (0,0);
    my ($midlat,$midlng,$scale);

    my $first_point = 1;
    foreach my $coll_set (@dataSets) {
        if (ref $coll_set) {
            foreach my $coll (@$coll_set) {
                my ($lat,$lng) = ($coll->{'latdeg'},$coll->{'lngdeg'});
                if ($lat !~ /\d/ || $lng !~ /\d/) {
                    next;
                }
                $lat *= -1 if ($coll->{'latdir'} eq 'South');
                $lng *= -1 if ($coll->{'lngdir'} eq 'West');
#                print "SEE LAT $lat, $lng LATB $lat1 to $lat2 LNGB $lng1 to $lng2<br>";
               
                if ($first_point) {
                    $lat1 = $lat;
                    $lat2 = $lat;
                    $lng1 = $lng;
                    $lng2 = $lng;
                    $first_point = 0;
                } else {
                    my $in_lat_box = 0;
                    if ($lat1 <= $lat2) {
                        if ($lat >= $lat1 && $lat <= $lat2) {
                            $in_lat_box = 1;
                        }
                    } else {
                        if (!($lat >= $lat1 && $lat <= $lat2)) {
                            $in_lat_box = 1;
                        }
                    }
                    my $in_lng_box = 0;
                    if ($lng1 <= $lng2) {
                        if ($lng >= $lng1 && $lng <= $lng2) {
                            $in_lng_box = 1;
                        }
                    } else {
                        if (!($lng >= $lng1 && $lng <= $lng2)) {
                            $in_lng_box = 1;
                        }
                    }
                    unless ($in_lat_box) {
                        $d1 = $lat1 - $lat;
                        if ($d1 < 0) { $d1 += 180; }
                        $d2 = $lat - $lat2;
                        if ($d2 < 0) { $d2 += 180; }
                        if ($d1 < $d2) {
                            $lat1 = $lat;
                        } else {
                            $lat2 = $lat;
                        }
                    }
                    unless ($in_lng_box) {
                        $d1 = $lng1 - $lng;
                        if ($d1 < 0) { $d1 += 360; }
                        $d2 = $lng - $lng2;
                        if ($d2 < 0) { $d2 += 360; }
                        if ($d1 < $d2) {
                            $lng1 = $lng;
                        } else {
                            $lng2 = $lng;
                        }
                    }
                }
            }
        }
    }
    my $lat_dist;
    if ($lat1 <= $lat2) {
        $lat_dist = $lat2 - $lat1;
    } else {
        $lat_dist = 180 + $lat2 - $lat1;
    }
    my $lng_dist;
    if ($lng1 <= $lng2) {
        $lng_dist = $lng2 - $lng1;
    } else {
        $lng_dist = 360 + $lng2 - $lng1;
    }
#        print "LNG DIST $lng_dist LAT_DIST $lat_dist<BR>";
    if ($lat_dist >= 90 || $lng_dist >= 180) {
        # If we cover more than 1/2 of the glove in either direction
        # Then just display the whole globe 
        $midlat = 0;
        $midlng = 0;
        $scale = 1;
    } else {
        $lat_ratio = 999;
        if ($lat2 != $lat1) {
            $lat_ratio = 180/$lat_dist;
        } 
        $lng_ratio = 999;
        if ($lng2 != $lng1) {
            $lng_ratio = 360/$lng_dist;
        }

        if ($lat_ratio < $lng_ratio) {
            $raw_scale = $lat_ratio;
        } else {
            $raw_scale = $lng_ratio;
        }
        # This adds a (minimum) %12.5 padding layer around each side, important to made things look good
        # and allow the tiling aglorithm to work. 
        $raw_scale *= .75;
        if ($raw_scale > 8) {
            $raw_scale = 8;
        } 
        if ($raw_scale < 1.5) {
            $scale = 1;
        } elsif ($raw_scale < 2) {
            $scale = 1.5;
        } else {
            $scale = int($raw_scale);
        }
        $midlat = $lat_dist/2 + $lat1;
        if ($midlat > 90) {
            $midlat -= 180;
        }
        $midlng = $lng_dist/2 + $lng1;
        if ($midlng > 180) {
            $midlng -= 360;
        }
    }
#    print "MID LAT $midlat MDLNG $midlng SCALE $scale<BR>";
    return ($midlat,$midlng,$scale);
}

# This function takes a scale, midlat, maplng and rounds midlat/maplng
# up or down to an "even" number so that the tile cache will be used.
# I don't literally mean even, how much much it rounds up or down is determined
# by the $scale.  a $scale of 9 means 360/9 or 40 degress per tile.  We then
# divide by 10 again so we have increments of 4 degrees.  When we autozoom we
# add a 10% buffer on each side so the image looks nice.  The tile can be 
# off by up to 5% from true center so this way things shouldn't look bad even
# with the coordinates "snapping" 5% left or right to hit the tile cache
sub snapToTile {
    my ($self,$lat,$lng,$scale) = @_;
    my ($newlat, $newlng);
    my $lat_tile_size = 180 / 5 / $scale;
    my $lng_tile_size = 360 / 5 / $scale;
    $newlat = sprintf("%.0f",(sprintf("%.0f",($lat/$lat_tile_size))*$lat_tile_size));
    $newlng = sprintf("%.0f",(sprintf("%.0f",($lng/$lng_tile_size))*$lng_tile_size));
#    $newlat =~ s/(\.\d)\d+$/$1/;
#    $newlng =~ s/(\.\d)\d+$/$1/;
    return ($newlat,$newlng);
}
        
sub readPlateIDs {
    my $self = shift;
    if ( ! open IDS,"<$COAST_DIR/plateidsv2.lst" ) {
        $self->htmlError ( "Couldn't open [$COAST_DIR/plateidsv2.lst]: $!" );
    }


    # skip the first line
    <IDS>;

    my %plate;
    my %cellage;
    # read the plate IDs: numbers are longitude, latitude, and ID number
    while (<IDS>)	{
        s/\n//;
        my ($x,$y,$z) = split /,/,$_;
        $plate{$x}{$y} = $z;
        # Andes correction: Scotese sometimes assigned 254 Ma ages to
        #  oceanic crust cells that are much younger, so those need to
        #  be eliminated JA 4.5.06
        if ( $z >= 900)	{
            $cellage{$x}{$y} = -1;
        }
    }
    close IDS;
    $self->{plate} = \%plate;
    $self->{cellage} = \%cellage;
}


# extract outlines taken from NOAA's NGDC Coastline Extractor
sub mapDefineOutlines	{
	my $self = shift;
	#if ( $q->param('mapresolution') eq "coarse" )	{
	#	$resostem = "075";
	#} elsif ( $q->param('mapresolution') eq "medium" )	{
	#	$resostem = "050";
	#} elsif ( $q->param('mapresolution') eq "fine" )	{
	#	$resostem = "025";
	#} elsif ( $q->param('mapresolution') eq "very fine" )	{
	#	$resostem = "010";
	#} else {
	#	$resostem = "025";
    #}

	# need to know the plate IDs to determine which cells are oceanic
	# necessary either if crust is being drawn, or if plates are being
	#  rotated
	# this code used to be near the top of mapGetRotations, but I moved
	#  it because the plate IDs are needed here to avoid the Andes bug
	#  JA 5.5.06
    my %plate;
    my %cellage;
	if ( $self->{maptime} > 0 || ( $q->param('crustcolor') ne "none" && $q->param('crustcolor') =~ /[A-Za-z]/ ) )	{
        $self->readPlateIDs();
        %plate = %{$self->{'plate'}};
        %cellage = %{$self->{'cellage'}};
	}

	# read grid cell ages
	if ( $self->{maptime} > 0 || ( $q->param('crustcolor') ne "none" && $q->param('crustcolor') =~ /[A-Za-z]/ ) )	{

		open MASK,"<$COAST_DIR/agev7.txt";
		my $lat = 90;
		while (<MASK>)	{
			s/\n//;
			my @crustages = split /\t/,$_;
			my $lng = -180;
			for $crustage (@crustages)	{
			# oceanic crust test: ages assigned to -1 if plate IDs
			#  are >= 900
				if ( $cellage{$lng}{$lat} != -1 )	{
					$cellage{$lng}{$lat} = $crustage;
					if ( $cellage{$lng}{$lat} == 254 )	{
						$cellage{$lng}{$lat} = 999;
					}
				}
				$lng++;
			}
			$lat--;
		}
		close MASK;

	}

	if ( ! open COAST,"<$COAST_DIR/noaa.coastlines.$resostem" ) {
		$self->htmlError ( "Couldn't open [$COAST_DIR/noaa.coastlines.$resostem]: $!" );
	}
	while (<COAST>)	{
		s/\n//;
		($a,$b) = split /\t/,$_;
		if ( $a >= 0 )	{
			$ia = int($a);
		} else	{
			$ia = int($a - 1);
		}
		if ( $b >= 0 )	{
			$ib = int($b);
		} else	{
			$ib = int($b - 1);
		}
		# save data
		# NOTE: separators are saved intentionally so they
		#  can be used for that purpose later on
		if ( $a =~ /#/ || ( $a =~ /[0-9]/ && $cellage{$ia}{$ib} >= $self->{maptime} ) )	{
			push @worldlng,$a;
			push @worldlat,$b;
		}
	}
	close COAST;

	if ( $q->param('borderlinecolor') ne "none" && $q->param('borderlinecolor') =~ /[A-Za-z]/ )	{
		if ( ! open BORDER,"<$COAST_DIR/noaa.borders.$resostem" ) {
			$self->htmlError ( "Couldn't open [$COAST_DIR/noaa.borders.$resostem]: $!" );
		}
		while (<BORDER>)	{
			s/\n//;
			($a,$b) = split /\t/,$_;
			if ( $a >= 0 )	{
				$ia = int($a);
			} else	{
				$ia = int($a - 1);
			}
			if ( $b >= 0 )	{
				$ib = int($b);
			} else	{
				$ib = int($b - 1);
			}
			if ( $a =~ /#/ || ( $a =~ /[0-9]/ && $cellage{$ia}{$ib} >= $self->{maptime} ) )	{
				push @borderlng,$a;
				push @borderlat,$b;
			}
		}
		close BORDER;
	}
	if ( $q->param('usalinecolor') ne "none" && $q->param('usalinecolor') =~ /[A-Za-z]/ )	{
		if ( ! open USA,"<$COAST_DIR/noaa.usa.$resostem" ) {
			$self->htmlError ( "Couldn't open [$COAST_DIR/noaa.usa.$resostem]: $!" );
		}
		while (<USA>)	{
			s/\n//;
			($a,$b) = split /\t/,$_;
			if ( $a >= 0 )	{
				$ia = int($a);
			} else	{
				$ia = int($a - 1);
			}
			if ( $b >= 0 )	{
				$ib = int($b);
			} else	{
				$ib = int($b - 1);
			}
			if ( $a =~ /#/ || ( $a =~ /[0-9]/ && $cellage{$ia}{$ib} >= $self->{maptime} ) )	{
				push @usalng,$a;
				push @usalat,$b;
			}
		}
		close USA;
	}
	if ( $q->param('crustcolor') ne "none" && $q->param('crustcolor') =~ /[A-Za-z]/ )	{
		if ( $q->param('crustedgecolor') ne "none" && $q->param('crustedgecolor') =~ /[A-Za-z]/ )	{
			if ( ! open EDGES,"<$COAST_DIR/platepolygons/edges.$self->{maptime}" ) {
				$self->htmlError ( "Couldn't open [$COAST_DIR/platepolygons/polygons.$self->{maptime}]: $!" );
			}
			while (<EDGES>)	{
				s/\n//;
				($a,$b) = split /\t/,$_;
				if ( $a >= 0 )	{
					$ia = int($a);
				} else	{
					$ia = int($a - 1);
				}
				if ( $b >= 0 )	{
					$ib = int($b);
				} else	{
					$ib = int($b - 1);
				}
				if ( $a =~ /#/ || $a =~ /[0-9]/ )	{
					push @crustlng,$a;
					push @crustlat,$b;
				}
			}
			close EDGES;
			push @crustlng , "edge";
			push @crustlat , "edge";
		}
		if ( ! open PLATES,"<$COAST_DIR/platepolygons/polygons.$self->{maptime}" ) {
			$self->htmlError ( "Couldn't open [$COAST_DIR/platepolygons/polygons.$self->{maptime}]: $!" );
		}
		while (<PLATES>)	{
			s/\n//;
			($a,$b) = split /\t/,$_;
			if ( $a >= 0 )	{
				$ia = int($a);
			} else	{
				$ia = int($a - 1);
			}
			if ( $b >= 0 )	{
				$ib = int($b);
			} else	{
				$ib = int($b - 1);
			}
			if ( $a =~ /#/ || $a =~ /[0-9]/ )	{
				push @crustlng,$a;
				push @crustlat,$b;
			}
		}
		close PLATES;
	}
}

# read Scotese's plate ID and rotation data files
sub mapGetRotations	{
	my $self = shift;

    if (!@ALL_ROT) {
	    if ( ! open ROT,"<$COAST_DIR/master01c.rot" ) {
		    $self->htmlError ( "Couldn't open [$COAST_DIR/master01c.rot]: $!" );
	    }
	    while (<ROT>)	{
		    s/\n//;
            push @ALL_ROT, $_;
        }
	    close ROT;
    }

	# read the rotations
	# numbers are millions of years ago; plate ID; latitude and longitude
	#  of pole of rotation; and degrees rotated
    foreach (@ALL_ROT) {
		my @temp = split /,/,$_;
	# Philippines test: pole of rotation doesn't change, so actually
	#  the plate comes into existence after the Paleozoic
		if ( $lastrotx{$temp[1]} != $temp[3] || $lastroty{$temp[1]} != $temp[2] || $lastrotdeg{$temp[1]} != $temp[4] || $temp[1] == 1 )	{
			$rotx{$temp[0]}{$temp[1]} = $temp[3];
			$roty{$temp[0]}{$temp[1]} = $temp[2];
			$rotdeg{$temp[0]}{$temp[1]} = $temp[4];
		}
		if ( $temp[3] =~ /[0-9]/ )	{
			$lastrotx{$temp[1]} = $temp[3];
			$lastroty{$temp[1]} = $temp[2];
			$lastrotdeg{$temp[1]} = $temp[4];
		}
	}
	# rotations for the Recent are all zero; poles are same as 10 Ma
	my @pids = sort { $a <=> $b } keys %{$rotx{'10'}};
	if ( $self->{maptime} > 0 && $self->{maptime} < 10 )	{
		for $p ( @pids )	{
			$rotx{0}{$p} = $rotx{10}{$p};
			$roty{0}{$p} = $roty{10}{$p};
			$rotdeg{0}{$p} = 0;
		}
	}

    # use world's dumbest linear interpolation to estimate pole of rotation and
    #  angle of rotation values if this time interval is non-standard
	if ( ! $roty{$self->{maptime}}{'1'} )	{

		my $basema = $self->{maptime};
		while ( ! $roty{$basema}{'1'} && $basema >= 0 )	{
			$basema--;
		}
		my $topma = $self->{maptime};
		while ( ! $roty{$topma}{'1'} && $topma < 1000 )	{
			$topma++;
		}

		if ( $topma < 1000 )	{
			$basewgt = ( $topma - $self->{maptime} ) / ( $topma - $basema );
			$topwgt = ( $self->{maptime} - $basema ) / ( $topma - $basema );
			my @pids = sort { $a <=> $b } keys %{$rotx{$topma}};
			for $pid ( @pids )	{
				my $x1 = $rotx{$basema}{$pid};
				my $x2 = $rotx{$topma}{$pid};
				my $y1 = $roty{$basema}{$pid};
				my $y2 = $roty{$topma}{$pid};
				my $z1 = $rotdeg{$basema}{$pid};
				my $z2 = $rotdeg{$topma}{$pid};

			# Africa/plate 701 150 Ma bug: suddenly the pole of
			#  rotation is projected to the opposite side of the
			#  planet, so the degrees of rotation have a flipped
			#  sign
			# sometimes the lat/long signs flip but the degrees
			#  of rotation don't (e.g., plate 619 410 Ma case),
			#  and therefore nothing should be done to the latter;
			#  test is whether the degrees have opposite signs
			# sometimes the pole just goes around the left or right
			#  edge of the map (e.g., Madagascar/plate 702 230 Ma),
			#  so nothing should be done; the longitudes will be
			#  off by > 270 degrees in that case

				if ( abs($x1 - $x2) > 90 && abs($x1 - $x2) < 270 && ( ( $x1 > 0 && $x2 < 0 ) || ( $x1 < 0 && $x2 > 0 ) ) ) 	{
					if ( ( $y1 > 0 && $y2 < 0 ) || ( $y1 < 0 && $y2 > 0 ) )	{
						if ( $x2 > 0 )	{
							$x2 = $x2 - 180;
						} else	{
							$x2 = $x2 + 180;
						}
						$y2 = -1 * $y2;
						if ( ( $z1 > 0 && $z2 < 0 ) || ( $z1 < 0 && $z2 > 0 ) )	{
							$z2 = -1 * $z2;
						}
					}
				}

			# sometimes the degrees of rotation suddenly flip
			#  even though the pole doesn't  (e.g., plate 616
			#  410 Ma case)
				if ( abs($z1 - $z2) > 90 && ( $z1 > 0 && $z2 < 0 || $z1 < 0 && $z2 > 0 ) )	{
					if ( abs($z1 - $z2) < 270 )	{
						$z2 = -1 * $z2;
					}
			# sometimes the degrees have just gone over 180 or
			#  under -180 (e.g., plate 611 375 Ma case)
					else	{
						if ( $z1 > 0 )	{
							$z1 = $z1 - 360;
						} else	{
							$z1 = $z1 + 360;
						}
					}
				}

			
			# averaging works better and better as you get close
			#  to the origin, and works horribly near the edges of
			#  the map, so treat the first pole as the origin,
			#  rotate the second accordingly, interpolate, and
			#  unrotate the interpolated pole
			# key test cases involve Antarctica (45, 85, 290 Ma)

				($x2,$y2) = rotatePoint($x2,$y2,$x1,$y1);
				my $interpolatedx = $topwgt * $x2;
				my $interpolatedy = $topwgt * $y2;

				($rotx{$self->{maptime}}{$pid},$roty{$self->{maptime}}{$pid})  = rotatePoint($interpolatedx,$interpolatedy,$x1,$y1,"reversed");

				$rotdeg{$self->{maptime}}{$pid} = ( $basewgt * $z1 ) + ( $topwgt * $z2 );

			# it's mathematically possible that the degrees have
			#  averaged out to over 180 or under -180 in something
			#  like the plate 611 375 Ma case
			if ( $rotdeg{$self->{maptime}}{$pid} > 180 )	{
				$rotdeg{$self->{maptime}}{$pid} = $rotdeg{$self->{maptime}}{$pid} - 360;
			} elsif ( $rotdeg{$self->{maptime}}{$pid} < - 180 )	{
				$rotdeg{$self->{maptime}}{$pid} = $rotdeg{$self->{maptime}}{$pid} + 360;
			}

			}
		}
	}

	$unrotatedmidlng = $midlng;
	$unrotatedmidlat = $midlat;
	if ( $self->{rotatemapfocus} =~ /y/i )	{
		my $a;
		my $b;
		($a,$b,$midlng,$midlat) = $self->projectPoints($midlng,$midlat);
	}

}


sub mapSetupImage {
    my $self = shift;

    # erase all files that haven't been accessed in more than a day
	opendir(DIR,"$GIF_DIR") or die "couldn't open $GIF_DIR ($!)";
	# grab only files with extensions;  not subdirs or . or ..
	my @filenames = grep { /.*?\.(\w+)/ } readdir(DIR);
	closedir(DIR);

	foreach my $file (@filenames){
		if((-M "$GIF_DIR/$file") > 1){
			unlink "$GIF_DIR/$file";
		}
	}

    if ( $q->param('mapname') !~ /[A-Za-z]/ )	{
        # get the next number for file creation.
        if ( ! open GIFCOUNT,"<$GIF_DIR/gifcount" ) {
            $self->htmlError ( "Couldn't open [$GIF_DIR/gifcount]: $!" );
        }
        $gifcount = <GIFCOUNT>;
        chomp($gifcount);
        close GIFCOUNT;

        $gifcount++;
        if ( ! open GIFCOUNT,">$GIF_DIR/gifcount" ) {
            $self->htmlError ( "Couldn't open [$GIF_DIR/gifcount]: $!" );
        }
        print GIFCOUNT "$gifcount";
        close GIFCOUNT;

        $gifcount++;
    }

    # set up the filenames
    my $mapstem = "pbdbmap";
    # change the file names if it looks like this is a linecommand, assuming
    #  that animations are being produced JA 29.4.06
    if ( $q->param('linecommand') =~ /[A-Za-z]/ )	{
        $mapstem = "anim";
        if ( $q->param('mapname') =~ /[A-Za-z]/ )	{
            $mapstem = $q->param('mapname');
            $gifcount = "";
        }
    }
    $gifname = $mapstem . $gifcount . ".gif";
    $pngname = $mapstem . $gifcount . ".png";
    $htmlname = $mapstem .$gifcount.".html";
    $ainame = $mapstem . $gifcount . ".ai";
    $jpgname = $mapstem . $gifcount . ".jpg";
    if ( ! open MAPGIF,">$GIF_DIR/$gifname" ) {
          $self->htmlError ( "Couldn't open [$GIF_DIR/$gifname]: $!" );
    }

	# Write this to a file, not stdout
	open(MAPOUT,">$GIF_DIR/$htmlname") or die "couldn't open $GIF_DIR/$htmlname ($!)";

    $hmult = 2;
    $vmult = 2;
    $hpix = 312;
    $vpix = 156;
    if ( $q->param('projection') eq "orthographic" )	{
        $hpix = 288;
        $vpix = 288;
    } elsif ( $q->param('projection') =~ /Eckert IV|Mollweide/ )	{
    # these numbers cram the map in as tightly as possible
        $hpix = 288;
        $vpix = 146;
    } elsif ( ( $cont =~ /Africa/ || $cont =~ /South America/ ) &&
              $scale > 1.5 )	{
        $hpix = 288;
        $vpix = 240;
    }
    my $x = $q->param('mapsize');
    $x =~ s/[^0-9]//g;
    # need this correction because the entire image is too large with
    #  this projection JA 27.4.06
    if ( $q->param("projection") eq "orthographic")	{
        $x = $x * 0.75;
    }
    $hmult = $hmult * $x / 100;
    $vmult = $vmult * $x / 100;
    # squash the plate caree projection horizontally to make it an
    #  equirectangular projection JA 8.5.08
    # previously, I called this the rectilinear projection and used an
    #  arbitrary and incorrect 0.8 factor; this one is 0.866
    if ( $q->param("projection") eq "equirectangular" )	{
       $hmult = $hmult * sin( 60 * $PI / 180 );
    }
    $height = int($vmult * $vpix);
    $width = int($hmult * $hpix);
    if ( $q->param('mapwidth') !~ /100/ && $q->param('mapwidth') =~ /^[0-9]/ )	{
        my $x = $q->param('mapwidth');
        $x =~ s/[^0-9]//g;
        $width = int($width * $x / 100);
    }

    # recenter the image if the GIF size is non-standard
    # have to do this using width and height because there may have been
    #  a width adjustment
    $gifoffhor = int(( 360 - ( $width / $hmult ) ) / ( $scale * 2 ));
    $gifoffver = int(( 180 - ( $height / $vmult ) ) / ( $scale * 2 ));

    if ( $width > 300 )	{
        $totalheight = $height + 16;
    } else	{
        $totalheight = $height + 26;
    }

    $ai = "";

    $sizestring = $width . "x";
    $sizestring .= $height + 12;

    my $tileID = getTileID($q);
    my $pngTileName = "$TILE_DIR/map_$tileID.png";
    my $aiTileName = "$TILE_DIR/map_$tileID.ai";
    if (-e $pngTileName) {
        $im = GD::Image->newFromPng($pngTileName,1);
        if ($im) {
            dbg("Using premade tile $tileID");
            $self->initPalette($im);
            open(AI_TILE,"<$aiTileName");
            while(<AI_TILE>) {
                $ai .=  $_;
            }
        }
    }

    if (!$im) {
        $im = new GD::Image($width,$totalheight,1);
        $self->initPalette($im);

        ($x,$y) = $self->drawBackground();

        if ( $q->param('gridposition') eq "in back" )	{
            $self->drawGrids();
        }
        
        $self->mapDrawCoasts();

        if ( $q->param('gridposition') ne "in back" )	{
            $self->drawGrids();
        }

        $self->mapFinishSetup();

        open(PNG_TILE_OUT, ">$pngTileName");
        binmode(PNG_TILE_OUT);
        print PNG_TILE_OUT $im->png;
        close PNG_TILE_OUT;

        open(AI_TILE_OUT, ">$aiTileName");
        print AI_TILE_OUT $ai;
        close AI_TILE_OUT;
    }

	print MAPOUT "<table><tr><td>\n<map name=\"PBDBmap\">\n";

    return "$GIF_DIR/$htmlname";
}

# This draws a footer and few miscellaneous items
sub mapFinishSetup {
    my $mapbgcolor = $q->param('mapbgcolor');
    if ( ! $mapbgcolor )	{
        $mapbgcolor = 'white';
    }
    # draw a box around the map if this is a equirectangular map with a white
    #  background JA 2.5.06
    if ( $mapbgcolor eq "white" && $projection eq "equirectangular" )	{
        # don't show the poles if this is a full-sized paleogeographic map
        if ( $self->{maptime} > 0 && $scale == 1 )	{
            my $poleoffset = int($height * 5 / 180);
            $im->rectangle(0,0+$poleoffset,$width-1,$height-$poleoffset,$edgecolor);
        } else	{
            $im->rectangle(0,0,$width-1,$height-1,$edgecolor);
        }
    }
    # used to draw a short white rectangle across the bottom for the caption
    #  here, but this is no longer needed
    if ( ! $q->param('linecommand') )	{
        @b = $im->stringFT($col{'unantialiased'},$FONT,10,0,5,$height+12,"plotting software 2002-2006 J. Alroy");
    }
    $ai .=  "0 To\n";
    $ai .= sprintf("1 0 0 1 %.1f %.1f 0 Tp\nTP\n",$AILEFT+5,$AITOP-$height-8);
    my $mycolor = $aicol{'black'};
    $mycolor =~ s/ XA/ Xa/;
    $ai .= sprintf("0 Tr\n0 O\n%s\n",$mycolor);
    $ai .=  "/_CenturyGothic 10 Tf\n";
    $ai .= sprintf("0 Tw\n");
    $ai .=  "(plotting software c 2002-2006 J. Alroy) Tx 1 0 Tk\nTO\n";
    $ai .=  "0 To\n";
    $ai .= sprintf("1 0 0 1 %.1f %.1f 0 Tp\nTP\n",$AILEFT+86.5,$AITOP-$height-10);
    $ai .=  "/_CenturyGothic 18 Tf\n";
    $ai .=  "(o) Tx 1 0 Tk\nTO\n";

    # print the Ma or year counter except if you are computing a small image
    #  from the line command JA 3.5.06
    # or narrow image JA 9.10.06
    if ( ( $q->param('year') > 0 || $self->{maptime} > 0 ) && ! $q->param('linecommand') && $width > 350 ) 	{
         my $counter;
         if ( $q->param('year') > 0 )	{
             my $year = $q->param('year');
             $year =~ s/^(19)|(20)//;
             my $month = $q->param('month');
             @months = ("","January","February","March","April","May","June","July","August","September","October","November","December");
             for my $m ( 0..$#months )	{
                 $month =~ s/$months[$m]/$m/;
             }
             if ( $q->param('beforeafter') =~ /before/i )	{
                 $counter = "< " . $month . "/" . $q->param('day_of_month') . "/" . $year;
             } else	{
                 $counter = "> " . $month . "/" . $q->param('day_of_month') . "/" . $year;
             }
         } else	{
             $counter = $self->{maptime} . " Ma";
         }
         # some of this might be needed for producing animations, not sure
         #if ( ! $q->param('linecommand') && $width > 300 )	{
         #    $im->string(gdTinyFont,5,$height-6,$counter,$col{'black'});
         #} elsif ( $q->param('projection') eq "orthographic" )	{
         #    $im->string(gdTinyFont,30,$height-30,$counter,$col{'black'});
         #} elsif ( $q->param('projection') eq "Eckert IV" )	{
         #    $im->string(gdTinyFont,5,$height-45,$counter,$col{'black'});
         #} elsif ( $width > 300 )	{
         #    $im->string(gdTinyFont,5,$height+1,$counter,$col{'black'});
         #} else	{
         #    $im->string(gdTinyFont,5,$height+13,$counter,$col{'black'});
         #}
          $im->stringFT($col{'unantialiased'},$FONT,11,0,int($width/2)-14,$height+12,$counter);
    }

    if ( $self->{maptime} > 0 && ! $q->param('linecommand') )	{
        if ( $width > 300 )	{
            @b = $im->stringFT($col{'unantialiased'},$FONT,10,0,$width-160,$height+12,"paleogeography 2002 C. R. Scotese");
        } else	{
            @b = $im->stringFT($col{'unantialiased'},$FONT,10,0,$width-160,$height+22,"paleogeography 2002 C. R. Scotese");
            $scoteseoffset = 12;
        }
        $ai .=  "0 To\n";
        $ai .= sprintf("1 0 0 1 %.1f %.1f 0 Tp\nTP\n",$AILEFT+$width-184,$AITOP-$height-8-$scoteseoffset);
        $ai .=  "/_CenturyGothic 10 Tf\n";
        $ai .=  "(paleogeography c 2002 C. R. Scotese) Tx 1 0 Tk\nTO\n";
        $ai .=  "0 To\n";
        $ai .= sprintf("1 0 0 1 %.1f %.1f 0 Tp\nTP\n",$AILEFT+$width-100.5,$AITOP-$height-10-$scoteseoffset);
        $ai .=  "/_CenturyGothic 18 Tf\n";
        $ai .=  "(o) Tx 1 0 Tk\nTO\n";
    }
}

sub initPalette {
    my ($self,$im,$reinit) = @_;

    # this color is needed to fool GD into NOT anti-aliasing fonts (!)
    $col{'unantialiased'} = $im->colorAllocate(-1,-1,-1);

    my %rgbs = ("white", "255,255,255",
    "borderblack", "1,1,1",
    "black", "0,0,0",
    "gray", "128,128,128",
    "light gray", "211,211,211",
    "offwhite", "254,254,254",
    "red", "255,0,0",
    "dark red", "139,0,0",
    "pink", "255,159,255",
    "deep pink", "255,20,147",
    "violet", "238,130,238",
    "orchid", "218,112,214",
    "magenta", "255,0,255",
    "dark violet", "148,0,211",
    "purple", "128,0,128",
    "slate blue", "106,90,205",
    "cyan", "0,255,255",
    "turquoise", "64,224,208",
    "steel blue", "70,130,180",
    "sky blue", "135,206,235",
    "dodger blue", "30,144,255",
    "royal blue", "65,105,225",
    "blue", "0,0,255",
    "dark blue", "0,0,139",
    "lime", "0,255,0",
    "light green", "144,238,144",
    "sea green", "46,139,87",
    "green", "0,128,0",
    "dark green", "0,100,0",
    "olive drab", "107,142,35",
    "olive", "128,128,0",
    "teal", "0,128,128",
    "orange red", "255,69,0",
    "dark orange", "255,140,0",
    "orange", "255,165,0",
    "gold", "255,215,0",
    "yellow", "255,255,0",
    "medium yellow", "255,255,160",
    "tan", "210,180,140",
    "sandy brown", "244,164,96",
    "chocolate", "210,105,30",
    "saddle brown", "139,69,19",
    "sienna", "160,82,45",
    "brown", "165,42,42");

    for my $color ( keys %rgbs )	{
        my ($r,$g,$b) = split /,/,$rgbs{$color};
        if ($reinit) {
            $col{$color} = $im->colorAllocate($r,$g,$b);
        } else {
            $col{$color} = $im->colorClosest($r,$g,$b);
        }
        $aicol{$color} = sprintf "%.2f %.2f %.2f XA",$r/255, $g/255, $b/255;
    }
	# create an interlaced GIF with a white background
	$im->interlaced('true');
	# I'm not sure what this does, it seems to have no effect one way or
	#  another and I'm not sure who put it in JA 2.5.06
#	$im->transparent(-1);
}

# draw crust, coastlines, and borders
sub mapDrawCoasts {
    my $self = shift;

    # first rescale the coordinates depending on the rotation
        if ( $q->param('crustcolor') ne "none" && $q->param('crustcolor') =~ /[A-Za-z]/ )	{
            for $c (0..$#crustlat)	{
                if ( $crustlat[$c] =~ /[0-9]/ )	{
                    ($crustlng[$c],$crustlat[$c],$crustlngraw[$c],$crustlatraw[$c],$crustplate[$c]) = $self->projectPoints($crustlng[$c],$crustlat[$c],"grid");
                }
            }
        }
        for $c (0..$#worldlat)	{
            if ( $worldlat[$c] =~ /[0-9]/ )	{
                ($worldlng[$c],$worldlat[$c],$worldlngraw[$c],$worldlatraw[$c],$worldplate[$c]) = $self->projectPoints($worldlng[$c],$worldlat[$c]);
            }
        }
        if ( $q->param('borderlinecolor') ne "none" && $q->param('borderlinecolor') =~ /[A-Za-z]/ )	{
            for $c (0..$#borderlat)	{
                if ( $borderlat[$c] =~ /[0-9]/ )	{
                    ($borderlng[$c],$borderlat[$c],$borderlngraw[$c],$borderlatraw[$c],$borderplate[$c]) = $self->projectPoints($borderlng[$c],$borderlat[$c]);
                }
            }
        }
        if ( $q->param('usalinecolor') ne "none" && $q->param('usalinecolor') =~ /[A-Za-z]/ )	{
            for $c (0..$#usalat)	{
                if ( $usalat[$c] =~ /[0-9]/ )	{
                    ($usalng[$c],$usalat[$c],$usalngraw[$c],$usalatraw[$c],$usaplate[$c]) = $self->projectPoints($usalng[$c],$usalat[$c]);
                }
            }
        }

    if ( $q->param('linethickness') eq "thick" )	{
        $thickness = 0.5;
        $aithickness = 1.5;
    } elsif ( $q->param('linethickness') eq "medium" )	{
        $thickness = 0.25;
        $aithickness = 1;
    } else	{
        $thickness = 0;
        $aithickness = 0.5;
    }

    # draw crust - this is different from coastlines or borders because the
    #  crust pieces need to be filled, which means drawing a polygon for each
    #  degree cell JA 30.4.06
    # oh yeah, and it's incredibly complicated and slow
    if ( $q->param('crustcolor') ne "none" && $q->param('crustcolor') =~ /[A-Za-z]/ )	{
        my $crustcolor = $q->param('crustcolor');
    # the rotation may have forced the polygon to straddle the edges of the map
    # if so, it has to be broken into pieces, which can be done by creating two
    #  smaller, poorly shaped ones
        my $lastsep = 1;
        my $bad = 0;
        my @newcrustlat = ();
        my @newcrustlng = ();
        my @newcrustlatraw = ();
        my @newcrustlngraw = ();
        my @templat = ();
        my @templng = ();
        my @templatraw = ();
        my @templngraw = ();
        for my $c (0..$#crustlat-1)	{
            push @templat , $crustlat[$c];
            push @templng , $crustlng[$c];
            push @templatraw , $crustlatraw[$c];
            push @templngraw , $crustlngraw[$c];
            my $d;
            if ( $crustlng[$c+1] =~ /#/ )	{
                $d = $lastsep;
            } else	{
                $d = $c + 1;
            }
            if ( $crustlng[$c] !~ /NaN/ && $crustlng[$c] =~ /[0-9]/ &&
                 abs ( $crustlng[$c] - $crustlng[$d] ) >= 45 )	{
                $bad++;
            }
            if ( $crustlng[$c+1] =~ /#/ )	{
                $lastsep = $c + 2;
            # okay, the cell is normal
                if ( $bad == 0 )	{
                  for my $t ( 0..$#templat )	{
                      push @newcrustlat , $templat[$t];
                      push @newcrustlng , $templng[$t];
                      push @newcrustlatraw , $templatraw[$t];
                      push @newcrustlngraw , $templngraw[$t];
                  }
            # no it isn't, it straddles 180 degrees longitude, so make
            #  two cells on opposite sides of the map
                } else	{
                  my @templng2 = @templng;
                  my @templat2 = @templat;
                  my @templngraw2 = @templngraw;
                  my @templatraw2 = @templatraw;
                  for my $t ( 0..$#templat )	{
                      if ( $templng[$t] > 0 )	{
                          ($templngraw[$t],$templatraw[$t]) = rotatePoint(-179.9,$templatraw[$t],$midlng,$midlat,"reversed");
                          ($templng[$t],$templat[$t],$templngraw[$t],$templatraw[$t]) = $self->projectPoints($templngraw[$t],$templatraw[$t],"grid");

                      }
                      push @newcrustlat , $templat[$t];
                      push @newcrustlng , $templng[$t];
                      push @newcrustlatraw , $templatraw[$t];
                      push @newcrustlngraw , $templngraw[$t];
                  }
                  for my $t ( 0..$#templat2 )	{
                      if ( $templng2[$t] < 0 )	{
                          ($templngraw2[$t],$templatraw2[$t]) = rotatePoint(179.9,$templatraw2[$t],$midlng,$midlat,"reversed");
                          ($templng2[$t],$templat2[$t],$templngraw2[$t],$templatraw2[$t]) = $self->projectPoints($templngraw2[$t],$templatraw2[$t],"grid");
                      }
                      push @newcrustlat , $templat2[$t];
                      push @newcrustlng , $templng2[$t];
                      push @newcrustlatraw , $templatraw2[$t];
                      push @newcrustlngraw , $templngraw2[$t];
                  }
                }
                @templat = ();
                @templng = ();
                @templatraw = ();
                @templngraw = ();
                $bad = 0;
            }
        }
        @crustlat = @newcrustlat;
        @crustlng = @newcrustlng;
        @crustlatraw = @newcrustlatraw;
        @crustlngraw = @newcrustlngraw;

    # this is the main crust cell drawing routine
        my $poly = new GD::Polygon;
        my $thickness = "0.5";
        my $strokefill = "F\n";
        if ( $q->param('crustedgecolor') ne "none" && $q->param('crustedgecolor') =~ /[A-Za-z]/ )	{
            $im->setThickness(4);
            $thickness = "3";
            $crustcolor = $q->param('crustedgecolor');
            $strokefill = "B\n";
        }
        $ai .=  "u\n";  # start the group
        my $tempcolor = $aicol{$crustcolor};
        if ( ! $q->param('crustedgecolor') )	{
            $tempcolor =~ s/ XA/ Xa/;
        }
        $ai .=  "$tempcolor\n";
        $ai .=  "$thickness w\n";
        my $lastsep = 1;
        my $bad = 0;
        my $lastx1 = "";
        my $lasty1 = "";
        my $badlastx1 = "";
        my $badlasty1 = "";
        push @crustlng , $crustlng[0];
        push @crustlngraw , $crustlng[0];
        push @crustlat , "";
        push @crustlatraw , "";
        for my $c (0..$#crustlat-1)	{
            # finish drawing the edges of the plates
            my $d;
            if ( $crustlng[$c+1] =~ /#/ )	{
                $d = $lastsep;
            } else	{
                $d = $c + 1;
            }
            if ( $crustlng[$c] !~ /NaN/ && $crustlng[$c] =~ /[0-9]/ &&
                 ( ( abs ( $crustlat[$c] - $crustlat[$d] ) < 60 &&
                 abs ( $crustlng[$c] - $crustlng[$d] ) < 60 ) ||
                 abs ( $crustlng[$c] - $crustlng[$d] ) == 359.8 ) )	{
                my $x1 = $self->getLng($crustlng[$c]);
                my $y1 = $self->getLat($crustlat[$c]);
                if ( $x1 !~ /NaN/ && $y1 !~ /NaN/ )	{
                    $poly->addPt($x1,$y1);
    # finished writing this (too lazy to do it before) 6.10.06
                    if ( ! $lastx1 && ! $lasty1 )  {
                        $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
                    } else	{
                        $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x1,$AITOP-$y1);
                    }
                    if ( ! $firstx1 )	{
                        $firstx1 = $x1;
                        $firsty1 = $y1;
                    }
                    $lastx1 = $x1;
                    $lasty1 = $y1;
                } else	{
                    $badlastx1 = $x1;
                    $badlasty1 = $y1;
                    $bad++;
                }
            } elsif ( $crustlng[$c] !~ /#/ )	{
                $bad++;
            }
    # finish up with this plate and start a new one
            if ( $crustlng[$c+1] =~ /#/ )	{
                $lastsep = $c + 2;
        # stretch the polygon up to the edge of the map if necessary
                if ( $bad > 0 && $bad < 3 )	{
                    if ( $badlastx1 =~ / L/ )	{
	                $poly->addPt(0,$lasty1);
	                $ai .= sprintf("%.1f %.1f l\n",$AILEFT,$AITOP-$lasty1);
                    } elsif ( $badlastx1 =~ / R/ )	{
	                $poly->addPt($width,$lasty1);
	                $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$width,$AITOP-$lasty1);
                    } elsif ( $badlasty1 =~ / B/ )	{
	                $poly->addPt($lastx1,0);
	                $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$lastx1,$AITOP);
                    } elsif ( $badlasty1 =~ / T/ )	{
	                $poly->addPt($lastx1,$height);
	                $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$lastx1,$AITOP-$height);
                    }
                }
                if ( $firstx1 )	{
                    $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$firstx1,$AITOP-$firsty1);
                    $ai .=  $strokefill;
                    if ( $crustcolor eq $q->param('crustcolor') )	{
                        $im->filledPolygon($poly,$col{$crustcolor});
                    } else	{
                        $im->openPolygon($poly,$col{$crustcolor});
                    }
                }
                $bad = 0;
                $firstx1 = "";
                $firsty1 = "";
                $lastx1 = "";
                $lasty1 = "";
                $badlastx1 = "";
                $badlasty1 = "";
                if ( $crustlng[$c] =~ /edge/ )	{
                    $im->setThickness(1);
                    $crustcolor = $q->param('crustcolor');
                    my $tempcolor = $aicol{$crustcolor};
                    $tempcolor =~ s/ XA/ Xa/;
                    $strokefill = "F\n";
                    $ai .=  "U\n";  # terminate the group
                    $ai .=  "u\n";  # start the group
                    $ai .=  "$tempcolor\n";
                    $ai .=  "0.5 w\n";
                }
                $poly = new GD::Polygon;
            }
        }
    # finish the last plate
        if ( $bad == 0 )	{
            $im->filledPolygon($poly,$col{$crustcolor});
            $ai .=  "U\n";  # terminate the group
        }
    }

    # draw coastlines
    # do NOT connect neighboring points that (1) are on different tectonic
    #  plates, or (2) now are widely separated because one point has rotated
    #  onto the other edge of the map
    $coastlinecolor  = $q->param('coastlinecolor');
    $ai .=  "u\n";  # start the group
    for $c (0..$#worldlat-1)	{
        if ( $worldlat[$c] !~ /NaN/ && $worldlat[$c+1] !~ /NaN/ &&
             $worldlat[$c] =~ /[0-9]/ && $worldlat[$c+1] =~ /[0-9]/ &&
             $worldplate[$c] == $worldplate[$c+1] &&
             abs ( $worldlatraw[$c] - $worldlatraw[$c+1] ) < 5 &&
             abs ( $worldlngraw[$c] - $worldlngraw[$c+1] ) < 5 )	{
            my $x1 = $self->getLng($worldlng[$c]);
            my $y1 = $self->getLat($worldlat[$c]);
            my $x2 = $self->getLng($worldlng[$c+1]);
            my $y2 = $self->getLat($worldlat[$c+1]);
            if ( $x1 !~ /NaN/ && $y1 !~ /NaN/ && $x2 !~ /NaN/ && $y2 !~ /NaN/ )	{
                $im->line( $x1, $y1, $x2, $y2, $col{$coastlinecolor} );
                $ai .=  "$aicol{$coastlinecolor}\n";
                $ai .= sprintf("%.1f w\n",$aithickness);
                $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
                $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x2,$AITOP-$y2);
                $ai .=  "S\n";
                # extra lines offset horizontally
                if ( $thickness > 0 )	{
                    $im->line( $x1-$thickness,$y1,$x2-$thickness,$y2,$col{$coastlinecolor});
                    $im->line( $x1+$thickness,$y1,$x2+$thickness,$y2,$col{$coastlinecolor});
                    # extra lines offset vertically
                    $im->line( $x1,$y1-$thickness,$x2,$y2-$thickness,$col{$coastlinecolor});
                    $im->line( $x1,$y1+$thickness,$x2,$y2+$thickness,$col{$coastlinecolor});
                }
            }
        }
    }
    $ai .=  "U\n";  # terminate the group

    # draw the international borders
    if ( $q->param('borderlinecolor') ne "none" && $q->param('borderlinecolor') =~ /[A-Za-z]/ )	{
        $borderlinecolor = $q->param('borderlinecolor');
        $ai .=  "u\n";  # start the group
        for $c (0..$#borderlat-1)	{
            if ( $borderlat[$c] !~ /NaN/ && $borderlat[$c+1] !~ /NaN/ &&
                 $borderlat[$c] =~ /[0-9]/ && $borderlat[$c+1] =~ /[0-9]/ &&
                 $borderplate[$c] == $borderplate[$c+1] &&
                 abs ( $borderlatraw[$c] - $borderlatraw[$c+1] ) < 5 &&
                 abs ( $borderlngraw[$c] - $borderlngraw[$c+1] ) < 5 )	{
                my $x1 = $self->getLng($borderlng[$c]);
                my $y1 = $self->getLat($borderlat[$c]);
                my $x2 = $self->getLng($borderlng[$c+1]);
                my $y2 = $self->getLat($borderlat[$c+1]);
                if ( $x1 !~ /NaN/ && $y1 !~ /NaN/ && $x2 !~ /NaN/ && $y2 !~ /NaN/ )	{
                  $im->line( $x1, $y1, $x2, $y2, $col{$borderlinecolor} );
                  $ai .=  "$aicol{$borderlinecolor}\n";
                  $ai .=  "0.5 w\n";
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
                  $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x2,$AITOP-$y2);
                  $ai .=  "S\n";
                }
            }
        }
        $ai .=  "U\n";  # terminate the group
    }

    # draw USA state borders
    if ( $q->param('usalinecolor') ne "none" && $q->param('usalinecolor') =~ /[A-Za-z]/ )	{
        $usalinecolor = $q->param('usalinecolor');
        $ai .=  "u\n";  # start the group
        for $c (0..$#usalat-1)	{
            if ( $usalat[$c] !~ /NaN/ && $usalat[$c+1] !~ /NaN/ &&
                 $usalat[$c] =~ /[0-9]/ && $usalat[$c+1] =~ /[0-9]/ &&
                 $usaplate[$c] == $usaplate[$c+1] &&
                 abs ( $usalatraw[$c] - $usalatraw[$c+1] ) < 5 &&
                 abs ( $usalngraw[$c] - $usalngraw[$c+1] ) < 5 )	{
                my $x1 = $self->getLng($usalng[$c]);
                my $y1 = $self->getLat($usalat[$c]);
                my $x2 = $self->getLng($usalng[$c+1]);
                my $y2 = $self->getLat($usalat[$c+1]);
                if ( $x1 !~ /NaN/ && $y1 !~ /NaN/ && $x2 !~ /NaN/ && $y2 !~ /NaN/ )	{
                    $im->line( $x1, $y1, $x2, $y2, $col{$usalinecolor} );
                    $ai .=  "$aicol{$usalinecolor}\n";
                    $ai .=  "0.5 w\n";
                    $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
                    $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x2,$AITOP-$y2);
                    $ai .=  "S\n";
                }
            }
        }
        $ai .=  "U\n";  # terminate the group
    }
}

# Draw the points for collections on the map
sub mapDrawPoints{
    my $self = shift;
    my $dataRowsRef = shift;
    my $ptset = shift;

    # find the point size JA 26.4.06
    if ($q->param("pointsize$ptset") =~ /auto/) {
        if ( $#{$dataRowsRef} > 100 )   {
            $q->param("pointsize$ptset"=>'small');
        } elsif ( $#{$dataRowsRef} > 50 )   {
            $q->param("pointsize$ptset"=>'medium');
        } elsif ( $#{$dataRowsRef} > 20 )   {
            $q->param("pointsize$ptset"=>'large');
        } else  {
            $q->param("pointsize$ptset"=>'very large');
        }   
    }

    $dotsizeterm = $q->param("pointsize$ptset") || "small";
    $dotshape = $q->param("pointshape$ptset") || "circles";
    $dotcolor = $q->param("dotcolor$ptset") || "red";
    $bordercolor = $dotcolor;

    if ($q->param("dotborder$ptset") ne "no" )	{
        if($q->param('mapbgcolor') eq "black" || $q->param("dotborder$ptset") eq "white" )	{
            $bordercolor = "white";
        } else {
            $bordercolor = "borderblack";
        }
    }

    if ($dotsizeterm eq "pixel")	{
        $dotsize = 0.3;
    } elsif ($dotsizeterm eq "tiny")	{
        $dotsize = 0.5;
    } elsif ($dotsizeterm eq "very small")	{
        $dotsize = 0.75;
    } elsif ($dotsizeterm eq "small")	{
        $dotsize = 1;
    } elsif ($dotsizeterm eq "medium")	{
        $dotsize = 1.25;
    } elsif ($dotsizeterm eq "large")	{
        $dotsize = 1.5;
    } elsif ($dotsizeterm eq "very large")	{
        $dotsize = 2;
    } elsif ($dotsizeterm eq "huge")	{
        $dotsize = 2.5;
    }
    $maxdotsize = $dotsize;
    if ($dotsizeterm eq "proportional")	{
        $maxdotsize = 3.5;
    }

    # draw collection data points
    %atCoord = ();
    %longVal = ();
    %latVal = ();
    my $matches = 0;
	foreach $collRef ( @{$dataRowsRef} ) {
 		%coll = %{$collRef};
 		if (( $coll{'latdeg'} > 0 || $coll{'latmin'} > 0 || $coll{'latdec'} > 0 ) &&
            ( $coll{'lngdeg'} > 0 || $coll{'lngmin'} > 0 || $coll{'lngdec'} > 0 )) {
            # When magnification is high, want to use minutes 
            # in addition to degrees, so the resolution is a bit higher
            if ($scale > 6)  {
                $lngoff = $coll{'lngdeg'};
                $lnghalf = ".00";
                # doubles the number of points longitudinally
                if ( $coll{'lngmin'} >= 30 || ($coll{'lngdec'} =~ /^(5|6|7|8|9)/))	{
                  $lngoff = $lngoff + 0.5;
                  $lnghalf = ".50";
                }

                # E/W modification appears unnecessary, but code is here just in case
                if ( $coll{'lngdir'} eq "East" )	{
                  $lngoff = $lngoff + 0.0;
                } elsif ( $coll{'lngdir'} eq "West" )	{
                  $lngoff = $lngoff - 0.0;
                }
                
                $latoff = $coll{'latdeg'};
                $lathalf = ".00";
                # quadruples the number of point rows latitudinally
                if ( $coll{'latmin'} >= 45 || ($coll{'latdec'} =~ /^(9|8|7(9|8|7|6|5))/))	{
                  $latoff = $latoff + 0.75;
                  $lathalf = ".75";
                } elsif ( $coll{'latmin'} >= 30 || ($coll{'latdec'} =~ /^(5|6|7)/ ))	{
                  $latoff = $latoff + 0.5;
                  $lathalf = ".50";
                } elsif ( $coll{'latmin'} >= 15 || ($coll{'latdec'} =~ /^(4|3|2(9|8|7|6|5))/ ))	{
                  $latoff = $latoff + 0.25;
                  $lathalf = ".25";
                }
                
                if ( $coll{'latdir'} eq "North" )	{
                  $latoff = $latoff + 0.25;
                } elsif ( $coll{'latdir'} eq "South" )	{
                  $latoff = $latoff - 0.25;
                }
                $coordres = 'half';
            } else {
                $lngoff = $coll{'lngdeg'};
                # E/W modification appears unnecessary, but code is here just in case
                if ( $coll{'lngdir'} eq "East" )	{
                  $lngoff = $lngoff + 0.0;
                } elsif ( $coll{'lngdir'} eq "West" )	{
                  $lngoff = $lngoff - 0.0;
                }
                $latoff = $coll{'latdeg'};
                $lathalf = ".00";
                $lnghalf = ".00";
                # doubles the number of point rows latitudinally
                if ( $coll{'latmin'} >= 30 || $coll{'latdec'} =~ /^[5-9]/ )	{
                  $latoff = $latoff + 0.5;
                  $lathalf = ".50";
                }
                if ( $coll{'latdir'} eq "North" )	{
                  $latoff = $latoff + 0.5;
                } elsif ( $coll{'latdir'} eq "South" )	{
                  $latoff = $latoff - 0.5;
                }
                $coordres = 'full';
            }
          
            ($x1,$y1,$hemi) = $self->getCoords($lngoff,$latoff);

            if ( $x1 > 0 && $y1 > 0 && $x1-$maxdotsize > 0 &&
                $x1+$maxdotsize < $width &&
                $y1-$maxdotsize > 0 &&
                $y1+$maxdotsize < $height )	{
            # the rounding guarantees that all circles will have the same
            #  shape, and adding 0.5 guarantees that all circles will be
            #  symmetrical and therefore round
                    $x1 = int($x1) + 0.5;
                    $y1 = int($y1) + 0.5;
                    push @{$atCoord{$x1}{$y1}},$coll{'collection_no'};
                    $longVal{$x1} = $coll{'lngdeg'} . $lnghalf . " " . $coll{'lngdir'};
                    $latVal{$y1} = $coll{'latdeg'} . $lathalf . " " . $coll{'latdir'};

                    #dbg("Collection ".$coll{'collection_no'}." pixels($x1,$y1) " 
                    #         . "with degrees(".$coll{'lngdeg'}." ".$coll{'lngmin'}."/".$coll{'lngdec'}.",".$coll{'latdeg'}." ".$coll{'latmin'}."/".$coll{'latdec'}.")"
                    #         . "binned to degrees(".$longVal{$x1}.",".$latVal{$y1}.")");

                    $hemiVal{$x1}{$y1} = $hemi;
                    $matches++;
            }
        }
    }
    
	# Bail if we don't have anything to draw.
	if($matches < 1 && $q->param('simple_map') =~ /YES/i){
		print "NO MATCHING COLLECTION DATA AVAILABLE<br>";
		return;
	}

    $ai .=  "u\n";  # start the group
    for $x1 (keys %longVal)	{
	    for $y1 (keys %latVal)	{
		    if (ref $atCoord{$x1}{$y1})	{
			    if ($dotsizeterm eq "proportional")	{
				    $dotsize = int(scalar(@{$atCoord{$x1}{$y1}})**0.5 / 2) + 1;
			    }
			    print MAPOUT "<area shape=\"rect\" coords=\"";
			    if ( $hemiVal{$x1}{$y1} eq "N" )	{
				    printf MAPOUT "%d,%d,%d,%d", int($x1-(1.5*$dotsize)), int($y1+0.5-(1.5*$dotsize)), int($x1+(1.5*$dotsize)), int($y1+0.5+(1.5*$dotsize));
			    } else	{
				    printf MAPOUT "%d,%d,%d,%d", int($x1-(1.5*$dotsize)), int($y1-0.5-(1.5*$dotsize)), int($x1+(1.5*$dotsize)), int($y1-0.5+(1.5*$dotsize));
			    }
			    print MAPOUT "\" href=\"$READ_URL?action=displayCollResults";
                print MAPOUT "&amp;collection_list=".join(",",@{$atCoord{$x1}{$y1}});
                print MAPOUT "\">\n";

                my $mycolor = $aicol{$dotcolor};
                $mycolor =~ s/ XA/ Xa/;
                if ( $dotshape !~ /circles/ && $dotshape !~ /crosses/ )	{
                    $ai .=  "0 O\n";
                    $ai .=  "$mycolor\n";
                    $ai .=  "0 G\n";
                    $ai .=  "4 M\n";
                } elsif ( $dotshape !~ /circles/ )	{
                    $ai .=  "$mycolor\n";
                    $ai .=  "0 G\n";
                }
                # draw a circle and fill it

                $im->setAntiAliased($col{$dotcolor});
                if ($dotshape =~ /^circles$/)	{
                  if ( $x1+($dotsize*1.5)+1 < $width && $x1-($dotsize*1.5)-1 > 0 &&
                       $y1+($dotsize*1.5)+1 < $height && $y1-($dotsize*1.5)-1 > 0 )	{
                    my $poly = new GD::Polygon;
                    $poly->addPt($x1,$y1+($dotsize*2));
                    $poly->addPt($x1+($dotsize*1.414),$y1+($dotsize*1.414));
                    $poly->addPt($x1+($dotsize*2),$y1);
                    $poly->addPt($x1+($dotsize*1.414),$y1-($dotsize*1.414));
                    $poly->addPt($x1,$y1-($dotsize*2));
                    $poly->addPt($x1-($dotsize*1.414),$y1-($dotsize*1.414));
                    $poly->addPt($x1-($dotsize*2),$y1);
                    $poly->addPt($x1-($dotsize*1.414),$y1+($dotsize*1.414));
                    $im->filledPolygon($poly,gdAntiAliased);
                my $diam = $dotsize * 3;
                my $rad = $diam / 2;
                my $aix = $AILEFT+$x1+$rad;
                my $aiy = $AITOP-$y1;
                my $obl = $diam * 0.27612;
                $ai .=  "$mycolor\n";
                $ai .=  "0 G\n";
                $ai .= sprintf("%.1f %.1f m\n",$aix,$aiy);
                $ai .= sprintf("%.1f %.1f %.1f %.1f %.1f %.1f c\n",$aix,$aiy-$obl,$aix-$rad+$obl,$aiy-$rad,$aix-$rad,$aiy-$rad);
                $ai .= sprintf("%.1f %.1f %.1f %.1f %.1f %.1f c\n",$aix-$rad-$obl,$aiy-$rad,$aix-$diam,$aiy-$obl,$aix-$diam,$aiy);
                $ai .= sprintf("%.1f %.1f %.1f %.1f %.1f %.1f c\n",$aix-$diam,$aiy+$obl,$aix-$rad-$obl,$aiy+$rad,$aix-$rad,$aiy+$rad);
                $ai .= sprintf("%.1f %.1f %.1f %.1f %.1f %.1f c\n",$aix-$rad+$obl,$aiy+$rad,$aix,$aiy+$obl,$aix,$aiy);
                if ( $bordercolor !~ "borderblack" )	{
                    $ai .=  "f\n";
                } else	{
                    $ai .=  "b\n";
                    }
                  }
                } elsif ($dotshape =~ /^crosses$/)	{
                  $im->line($x1-$dotsize,$y1-$dotsize,$x1+$dotsize,$y1+$dotsize,$col{$dotcolor});
                  $im->line($x1-$dotsize+0.50,$y1-$dotsize+0.50,$x1+$dotsize+0.50,$y1+$dotsize+0.50,$col{$dotcolor});
                  $im->line($x1-$dotsize+0.50,$y1-$dotsize-0.50,$x1+$dotsize+0.50,$y1+$dotsize-0.50,$col{$dotcolor});
                  $im->line($x1-$dotsize-0.50,$y1-$dotsize+0.50,$x1+$dotsize-0.50,$y1+$dotsize+0.50,$col{$dotcolor});
                  $im->line($x1-$dotsize-0.50,$y1-$dotsize-0.50,$x1+$dotsize-0.50,$y1+$dotsize-0.50,$col{$dotcolor});
                  $ai .= sprintf("2 w\n");
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1-$dotsize,$AITOP-$y1+$dotsize);
                  $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x1+$dotsize,$AITOP-$y1-$dotsize);
                  $ai .=  "S\n";

                  $im->line($x1+$dotsize,$y1-$dotsize,$x1-$dotsize,$y1+$dotsize,$col{$dotcolor});
                  $im->line($x1+$dotsize+0.50,$y1-$dotsize+0.50,$x1-$dotsize+0.50,$y1+$dotsize+0.50,$col{$dotcolor});
                  $im->line($x1+$dotsize+0.50,$y1-$dotsize-0.50,$x1-$dotsize+0.50,$y1+$dotsize-0.50,$col{$dotcolor});
                  $im->line($x1+$dotsize-0.50,$y1-$dotsize+0.50,$x1-$dotsize-0.50,$y1+$dotsize+0.50,$col{$dotcolor});
                  $im->line($x1+$dotsize-0.50,$y1-$dotsize-0.50,$x1-$dotsize-0.50,$y1+$dotsize-0.50,$col{$dotcolor});
                  $ai .=  "$aicol{$dotcolor}\n";
                  $ai .= sprintf("2 w\n");
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1+$dotsize,$AITOP-$y1+$dotsize);
                  $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x1-$dotsize,$AITOP-$y1-$dotsize);
                  $ai .=  "S\n";
                } elsif ($dotshape =~ /^diamonds$/)	{
                  my $poly = new GD::Polygon;
                  $poly->addPt($x1,$y1+($dotsize*2));
                  $poly->addPt($x1+($dotsize*2),$y1);
                  $poly->addPt($x1,$y1-($dotsize*2));
                  $poly->addPt($x1-($dotsize*2),$y1);
                  $im->filledPolygon($poly,$col{$dotcolor});
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1-($dotsize*2));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1+($dotsize*2),$AITOP-$y1);
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1,$AITOP-$y1+($dotsize*2));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1-($dotsize*2),$AITOP-$y1);
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1,$AITOP-$y1-($dotsize*2));
                }
                elsif ($dotshape =~ /^stars$/)	{
                  my $poly = new GD::Polygon;
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1+($dotsize*sin(9*36*$PI/180)),$AITOP-$y1+($dotsize*cos(9*36*$PI/180)));
                  for $p (0..9)	{
                    if ( $p % 2 == 1 )	{
                      $poly->addPt($x1+($dotsize*sin($p*36*$PI/180)),$y1-($dotsize*cos($p*36*$PI/180)));
                      $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1+($dotsize*sin($p*36*$PI/180)),$AITOP-$y1+($dotsize*cos($p*36*$PI/180)));
                    } else	{
                      $poly->addPt($x1+($dotsize/$C72*sin($p*36*$PI/180)),$y1-($dotsize/$C72*cos($p*36*$PI/180)));
                      $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1+($dotsize/$C72*sin($p*36*$PI/180)),$AITOP-$y1+($dotsize/$C72*cos($p*36*$PI/180)));
                    }
                  }
                  $im->filledPolygon($poly,$col{$dotcolor});
                }
            # or draw a triangle
                elsif ($dotshape =~ /^triangles$/)	{
                  my $poly = new GD::Polygon;
               # lower left vertex
                  $poly->addPt($x1+($dotsize*2),$y1+($dotsize*2*sin(60*$PI/180)));
               # top middle vertex
                  $poly->addPt($x1,$y1-($dotsize*2*sin(60*$PI/180)));
               # lower right vertex
                  $poly->addPt($x1-($dotsize*2),$y1+($dotsize*2*sin(60*$PI/180)));
                  $im->filledPolygon($poly,$col{$dotcolor});
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1+($dotsize*2),$AITOP-$y1-($dotsize*2*sin(60*$PI/180)));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1,$AITOP-$y1+($dotsize*2*sin(60*$PI/180)));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1-($dotsize*2),$AITOP-$y1-($dotsize*2*sin(60*$PI/180)));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1+($dotsize*2),$AITOP-$y1-($dotsize*2*sin(60*$PI/180)));
                }
            # or draw a square
                else	{
                  $im->filledRectangle($x1-($dotsize*1.5),$y1-($dotsize*1.5),$x1+($dotsize*1.5),$y1+($dotsize*1.5),$col{$dotcolor});
                  $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1-($dotsize*1.5),$AITOP-$y1-($dotsize*1.5));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1-($dotsize*1.5),$AITOP-$y1+($dotsize*1.5));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1+($dotsize*1.5),$AITOP-$y1+($dotsize*1.5));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1+($dotsize*1.5),$AITOP-$y1-($dotsize*1.5));
                  $ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1-($dotsize*1.5),$AITOP-$y1-($dotsize*1.5));
                }
                if ( $dotshape !~ /circles/ && $dotshape !~ /crosses/ )	{
                  if ( $bordercolor !~ "borderblack" )	{
                    $ai .=  "f\n";
                  } else	{
                    $ai .=  "b\n";
                  }
                }
            }
        }
    }
    $ai .=  "U\n";  # terminate the group

   
    $im->setAntiAliased($col{$bordercolor});
    # redraw the borders if they are not the same color as the points
      for $x1 (keys %longVal)	{
        for $y1 (keys %latVal)	{
          if (ref $atCoord{$x1}{$y1}) {
            if ($dotsizeterm eq "proportional")	{
              $dotsize = int(scalar(@{$atCoord{$x1}{$y1}})**0.5 / 2) + 1;
            }
            if ($dotshape =~ /^circles$/)	{
              # for consistency, antialiasing actually only supported for straight lines, not arcs
              my $poly = new GD::Polygon;
              $poly->addPt($x1,$y1+($dotsize*2));
              $poly->addPt($x1+($dotsize*1.414),$y1+($dotsize*1.414));
              $poly->addPt($x1+($dotsize*2),$y1);
              $poly->addPt($x1+($dotsize*1.414),$y1-($dotsize*1.414));
              $poly->addPt($x1,$y1-($dotsize*2));
              $poly->addPt($x1-($dotsize*1.414),$y1-($dotsize*1.414));
              $poly->addPt($x1-($dotsize*2),$y1);
              $poly->addPt($x1-($dotsize*1.414),$y1+($dotsize*1.414));
              $im->polygon($poly,gdAntiAliased);
            } elsif ($dotshape =~ /^crosses$/)	{ # don't do anything
            } elsif ($dotshape =~ /^diamonds$/)	{
              my $poly = new GD::Polygon;
              $poly->addPt($x1,$y1+($dotsize*2));
              $poly->addPt($x1+($dotsize*2),$y1);
              $poly->addPt($x1,$y1-($dotsize*2));
              $poly->addPt($x1-($dotsize*2),$y1);
              # straight diagonals aren't antialiased, this just here for consistency
              $im->polygon($poly,gdAntiAliased);
            } elsif ($dotshape =~ /^stars$/)	{
              my $poly = new GD::Polygon;
              for $p (0..9)	{
                if ( $p % 2 == 1 )	{
                  $poly->addPt($x1+($dotsize*sin($p*36*$PI/180)),$y1-($dotsize*cos($p*36*$PI/180)));
              } else	{
                  $poly->addPt($x1+($dotsize/$C72*sin($p*36*$PI/180)),$y1-($dotsize/$C72*cos($p*36*$PI/180)));
                }
              }
              $im->polygon($poly,gdAntiAliased);
            } elsif ($dotshape =~ /^triangles$/)	{
              my $poly = new GD::Polygon;
              $poly->addPt($x1+($dotsize*2),$y1+($dotsize*2*sin(60*$PI/180)));
              $poly->addPt($x1,$y1-($dotsize*2*sin(60*$PI/180)));
              $poly->addPt($x1-($dotsize*2),$y1+($dotsize*2*sin(60*$PI/180)));
              $im->polygon($poly,gdAntiAliased);
            } else	{
              $im->rectangle($x1-($dotsize*1.5),$y1-($dotsize*1.5),$x1+($dotsize*1.5),$y1+($dotsize*1.5),gdAntiAliased);
            }
          }
        }
      }
}

sub getCoords	{
	my $self = shift;

	my ($x,$y) = @_;
	if ($coll{'lngdir'} =~ /West/)	{
		$x = $x * -1;
	}
	if ($coll{'latdir'} =~ /South/)	{
		$y = $y * -1;
	}
	($x,$y) = $self->projectPoints($x,$y);
	# Get pixel values
	$x = $self->getLng($x);
	$y = $self->getLat($y);
	if ( $x !~ /NaN/ && $y !~ /NaN/ )	{
		if ( $y > 0 )	{
			return($x,$y,"North");
		} else	{
			return($x,$y,"South");
		}
	} else	{
		return;
	}
}

sub projectPoints	{
	my $self = shift;

	my ($x,$y,$pointclass,$no_cache) = @_;
	my $pid;
	my $rotation;
	my $oldx;
	my $oldy;

	# rotate point if a paleogeographic map is being made
	# strategy: rotate point such that the pole of rotation is the
	#  north pole; use the GCD between them to get the latitude;
	#  add the degree offset to its longitude to get the new value;
	#  re-rotate point back into the original coordinate system
	if ( $self->{maptime} > 0 && ( $midlng != $x || $midlat != $y || $self->{'rotatemapfocus'} =~ /y/i ) && $pointclass ne "grid" && ($projected{$x}{$y} eq "" || $no_cache))	{

		my $ma = $self->{maptime};
		$oldx = $x;
		$oldy = $y;


	# integer coordinates are needed to determine the plate ID
	# IMPORTANT: Scotese's plate ID data are weird in that the coordinates
	#   refer to the lower left (southwest) corner of each grid cell, so,
	#  say, cell -10 / 10 is from -10 to -9 long and 10 to 11 lat
		my $q; 
		my $r;
		if ( $x >= 0 )	{
			$q = int($x);
		} else	{
			$q = int($x-1);
		}
		if ( $y >= 0 )	{
			$r = int($y);
		} else	{
			$r = int($y-1);
		}

	    # what plate is this point on?
	    $pid = $self->{plate}{$q}{$r};

	# if there are no data, just bomb out
		if ( $pid eq "" || $rotx{$ma}{$pid} eq "" || $roty{$ma}{$pid} eq "" )	{
			return('NaN','NaN');
		}

	# how far are we going?
		$rotation = $rotdeg{$ma}{$pid};

	# if the pole of rotation is in the southern hemisphere,
	#  rotate negatively (clockwise) - WARNING: I have no idea why
	#  this works, but it does
		if ( $roty{$ma}{$pid} <= 0 )	{
			$rotation = -1 * $rotation;
		}

	# locate the old origin in the "new" system defined by the POR
	# the POR is the north pole, so the origin is 90 deg south of it
	# for a southern hemisphere POR, flip the longitude
		my $neworigx;
		my $neworigy;
		if ( $roty{$ma}{$pid} > 0 )	{
			$neworigx = $rotx{$ma}{$pid};
		} elsif ( $rotx{$ma}{$pid} > 0 )	{
			$neworigx = $rotx{$ma}{$pid} - 180;
		} else	{
			$neworigx = $rotx{$ma}{$pid} + 180;
		}
		$neworigy = abs($roty{$ma}{$pid}) - 90;

	# rotate the point into the new coordinate system
		($x,$y) = rotatePoint($x,$y,$neworigx,$neworigy);
		if ( $x =~ /NaN/ || $y =~ /NaN/ )	{
			if ( $x !~ /NaN/ )	{
				$x = "NaN";
			}
			if ( $y !~ /NaN/ )	{
				$y = "NaN";
			}
			return($x,$y);
		}

	# adjust the longitude
		$x = $x + $rotation;

		if ( $x <= -180 )	{
			$x = $x + 360;
		} elsif ( $x >= 180 )	{
			$x = $x - 360;
		}

	# put the point back in the old projection
		($x,$y) = rotatePoint($x,$y,$neworigx,$neworigy,"reversed");
		$projected{$oldx}{$oldy} = $x . ":" . $y . ":" . $pid;
		if ( $x =~ /NaN/ || $y =~ /NaN/ )	{
			if ( $x !~ /NaN/ )	{
				$x = "NaN";
			}
			if ( $y !~ /NaN/ )	{
				$y = "NaN";
			}
			return($x,$y);
		}

	}
	if ( $oldx eq "" && $oldy eq "" && $projected{$x}{$y} ne "" && $pointclass ne "grid" )	{
		($x,$y,$pid) = split /:/,$projected{$x}{$y};
	}

	# rotate point if origin is not at 0/0
	# but not if a point on a plate is the map focus and we are trying
	#  to get the new focus JA 12.5.06
	if ( ( $midlat != 0 || $midlng != 0 ) && ( $self->{'rotatemapfocus'} !~ /y/i || $unrotatedmidlng != $midlng || $unrotatedmidlat != $midlat ) )	{
		($x,$y) = rotatePoint($x,$y,$midlng,$midlat);
		if ( $x =~ /NaN/ || $y =~ /NaN/ )	{
			if ( $x !~ /NaN/ )	{
				$x = "NaN";
			}
			if ( $y !~ /NaN/ )	{
				$y = "NaN";
			}
			return($x,$y);
		}
	}

	$rawx = $x;
	$rawy = $y;

	# don't even bother drawing anything near the poles in an
	#  equirectangular projection, because the crust gets completely
	#   screwed up there JA 2.5.06
	if ( $self->{maptime} > 0 && $scale == 1 )	{
		if ( $projection eq "equirectangular" and $y > 85 )	{
			$y = 85;
		} elsif ( $projection eq "equirectangular" and $y < -85 )	{
			$y = -85;
		}
	}

	if ( $projection eq "equirectangular" && $x ne "" )	{
		$x = $x * sin( 60 * $PI / 180);
		$y = $y * sin( 60 * $PI / 180);
	} elsif ( $projection eq "orthographic" && $x ne "" )	{

		# how far is this point from the origin?
		my $dist = ($x**2 + $y**2)**0.5;
		# dark side of the Earth is invisible!
		if ( $dist > 90 )	{
			return('NaN','NaN');
		}
		# transform to radians
		$dist = $PI * $dist / 360;
		$x = $x * cos($dist) * ( 1 / cos( $PI / 4 ) ) ;
		$y = $y * cos($dist) * ( 1 / cos( $PI / 4 ) ) ;
		# fool tests for returned null data elsewhere in the script
		if ( $x == 0 )	{
			$x = 0.001;
		}
		if ( $y == 0 )	{
			$y = 0.001;
		}
	} elsif ( $projection eq "Mollweide" && $x ne "")	{
	# this is the exact Mollweide projection; previously an approximation
	#  was used JA 7.5.06
	# first convert to radians
		$x = $x * $PI / 360;
		$y = $y * $PI / 360;
		my $maxy = 90 * $PI / 360;
		my $theta = asin($y / $maxy);
		$y = 1 / 2 * sqrt(8) * sin($theta);
		if ( $y**2 >= 2 )	{
			$y = sqrt(2) - 0.00000001;
		}
		$x = 2 * 2 * $x / $PI * sqrt(2 - $y**2);
	# rescale just to fit in the image, using the maximum possible value
	#  of x
		my $imagescale = ($hpix - 2) / (4 * sqrt(2));
		$x = $x * $imagescale;
		$y = $y * $imagescale;
	} elsif ( $projection eq "Eckert IV" && $x ne "")	{
	# this is the exact Eckert IV projection; previously an approximation
	#  was used JA 7.5.06
	# in mathematical notation, longitude and latitude in radians are
	#  lambda and phi
	# first convert to radians
		$x = $x * $PI / 360;
		$y = $y * $PI / 720;
	# the Eckert IV uses a special expression for theta that some sources
	#  don't mention
	# algebraically, it might seem that the maximum ratio of X to Y would
	#  be 2, but actually the expression for theta has a maximum not of
	#  pi / 2 but of 1.336, so the maximum of sin(theta) is not 1 but
	#  0.9792, so a scaling factor is needed
		my $theta = 1 / 2 * (4 + $PI) * sin($y);
		$x = 2 * 2 * $x * (1 + cos($theta)) / sqrt($PI * (4 + $PI));
		$y = 2 * sqrt($PI) / sqrt(4 + $PI) * sin($theta);
		my $scaley = sin(1 / 2 * (4 + $PI) * sin(90 * $PI / 720));
		$y = $y / $scaley;
	# rescale just to fit in the image, using the maximum possible value
	#  of x
		my $imagescale = ($hpix - 2) / (8 * $PI / sqrt($PI * (4 + $PI)));
		$x = $x * $imagescale;
		$y = $y * $imagescale;
	}

	return($x,$y,$rawx,$rawy,$pid);
}

sub rotatePoint	{

	my ($x,$y,$origx,$origy,$direction) = @_;

	# flip the pole of rotation if you're going backwards
	if ( $direction eq "reversed" )	{
		$origx = -1 * $origx;
		$origy = -1 * $origy;
	}
	# recenter the longitude on the new origin
	else	{
		$x = $x - $origx;
		if ( $x <= -180 )	{
			$x = $x + 360;
		} elsif ( $x >= 180 )	{
			$x = $x - 360;
		}
	}

	# find the great circle distance to the new origin
	my $gcd = GCD($y,$origy,$x);

	# find the great circle distance to the point opposite the new origin
	my $oppgcd;
	if ( $x > 0 )	{
		$oppgcd = GCD($y,-1*$origy,180-$x);
	} else	{
		$oppgcd = GCD($y,-1*$origy,180+$x);
	}

	# find the great circle distance to the POR (the new north pole)
	my $porgcd;
	if ( $origy <= 0 )	{ # pole is at same longitude as origin
		$porgcd = GCD($y,90+$origy,$x);
	} elsif ( $x > 0 )	{ # pole is at 180 deg, point is east
		$porgcd = GCD($y,90-$origy,180-$x);
	} else	{ # pole is at 180 deg, point is west
		$porgcd = GCD($y,90-$origy,180+$x);
	}

	# now finally shift the point's coordinate relative to the new origin

	# find new latitude exploiting fact that great circle distance from
	#  point to the new north pole must be 90 - latitude

	$y = 90 - $porgcd;
	if ( $y > 89.9 )	{
		$y = 89.9;
	}
	if ( $x >= 179.999 )	{
		$x = 179.9;
	} elsif ( $x <= -179.999 )	{
		$x = -179.9;
	} elsif ( abs($x) < 0.005 )	{
		$x = 0.1;
	} 

	# find new longitude exploiting fact that distance from point to
	#  origin G scales to latitude Y and longitude X, so X = acos(cosGcosY)
	if ( abs($x) > 0.005 && abs($x) < 179.999 && abs($y) < 90 )	{
		if ( $gcd > 90 )	{
			if ( abs( abs($y) - abs($oppgcd) ) < 0.001 )	{
				$oppgcd = $oppgcd + 0.001;
			}
			if ( $x > 0 )	{
				$x = 180 - ( 180 / $PI * acos( cos($oppgcd * $PI / 180) / cos($y * $PI / 180) ) );
			} else	{
				$x = -180 + ( 180 / $PI * acos( cos($oppgcd * $PI / 180) / cos($y * $PI / 180) ) );
			}
		} else	{
			if ( abs( abs($y) - abs($gcd) ) < 0.001 )	{
				$gcd = $gcd + 0.001;
			}
			if ( $x > 0 )	{
				$x = 180 / $PI * acos( cos($gcd * $PI / 180) / cos($y * $PI / 180) );
			} else	{
				$x = -1 * 180 / $PI * acos( cos($gcd * $PI / 180) / cos($y * $PI / 180) );
			}

		}
	} else	{
	# toss out points with extreme values that blow up the arcos
	#  function due to rounding error (should never happen given
	#  corrections made right before calculation above)
		return('NaN','NaN');
	}

	# recenter the longitude on the old origin at the end
	#   of a paleolat calculation
	if ( $direction eq "reversed" )	{
		$x = $x - $origx;
		if ( $x <= -180 )	{
			$x = $x + 360;
		} elsif ( $x >= 180 )	{
			$x = $x - 360;
		}
	}
	return ($x,$y);

}

sub getLng	{
	my $self = shift;

	my $l = $_[0];
	if ( $l =~ /NaN/ )	{
		return($l);
	}
	# correction here and in the next three subroutines corrects for
	#  the fact that the orthographic projection squashes down the
	#  edges of the map into a globe JA 27.4.06
	if ( $q->param('projection') eq "orthographic" )	{
		$l = $l * 1.5;
	}
	$l = (180 + $l - $offlng - $gifoffhor) * $hmult * $scale;
	if ( $l < 0 )	{
		return('NaN L');
	} elsif ( $l > $width )	{
		return('NaN R');
	}
	if ( $l == 0 )	{
		$l = 0.0001;
	}
	return $l;
}

sub getLngTrunc	{
	my $self = shift;

	my $l = $_[0];
	if ( $l =~ /NaN/ )	{
		return($l);
	}
	if ( $q->param('projection') eq "orthographic" )	{
		$l = $l * 1.5;
	}
	$l = (180 + $l - $offlng - $gifoffhor) * $hmult * $scale;
	if ( $l <= 0 )	{
		return(0.0001);
	} elsif ( $l > $width )	{
		return($width);
	}
	return $l;
}

sub getLat	{
	my $self = shift;

	my $l = $_[0];
	if ( $l =~ /NaN/ )	{
		return($l);
	}
	if ( $q->param('projection') eq "orthographic" )	{
		$l = $l * 1.5;
	}
	$l = (90 - $l - $offlat - $gifoffver) * $vmult * $scale;
	if ( $l < 0 )	{
		return('NaN B');
	} elsif ( $l > $height )	{
		return('NaN T');
	}
	if ( $l == 0 )	{
		$l = 0.0001;
	}
	return $l;
}

sub getLatTrunc	{
	my $self = shift;

	my $l = $_[0];
	if ( $l =~ /NaN/ )	{
		return($l);
	}
	if ( $q->param('projection') eq "orthographic" )	{
		$l = $l * 1.5;
	}
	$l = (90 - $l - $offlat - $gifoffver) * $vmult * $scale;
	if ( $l <= 0 )	{
		return(0.0001);
	} elsif ( $l > $height )	{
		return($height);
	}
	return $l;
}

sub drawBackground	{
	my $self = shift;
	my $stage = shift;

	my ($origx,$origy) = $self->projectPoints($midlng,$midlat);
	my $mapbgcolor = $q->param('mapbgcolor');
	if (  !$mapbgcolor )	{
		$mapbgcolor = 'white';
	}
	$origx = $self->getLng($origx);
	$origy = $self->getLat($origy);
	# need this color to encircle the globe with a solid line
	$edgecolor = $col{$q->param('coastlinecolor')};
	$aiedgecolor = $aicol{$q->param('coastlinecolor')};
	my $mycolor = $aicol{$q->param('mapbgcolor')};
	$mycolor =~ s/ XA/ Xa/;
	$ai .=  "u\n";  # start the group
	# gray will have to do (previously this was offwhite; I'm not sure
	#  whose fault that was) JA 2.5.06
	if ( $q->param('coastlinecolor') eq "white" )	{
		$edgecolor = $col{'gray'};
		$aiedgecolor = $aicol{'gray'};
	}
	# this is a little tricky: draw a background rectangle in a weird
	#  color, then declare the color transparent, so nothing else
	#  will be
	my $transparent = $im->colorAllocate(11, 22, 33);
	$im->filledRectangle(0,0,$width,$totalheight,$transparent);
	$im->transparent($transparent);
	if ( $q->param('projection') eq "equirectangular" )	{
		# don't even try to draw the background around the poles
		my $poleoffset = 0;
		# don't show the poles if this is a full-sized paleogeographic
                #  map
		if ( $self->{maptime} > 0 && $scale == 1 )	{
			$poleoffset = $height * 5 / 180;
		}
		$im->filledRectangle(0,0+$poleoffset,$width,$height-$poleoffset,$col{$mapbgcolor});
  		$ai .=  "0 O\n";
            	$ai .= sprintf("%s\n",$mycolor);
		$ai .= sprintf("%.1f %.1f m\n",$AILEFT,$AITOP-$poleoffset);
		$ai .= sprintf("%.1f %.1f L\n",$AILEFT+$width,$AITOP-$poleoffset);
		$ai .= sprintf("%.1f %.1f L\n",$AILEFT+$width,$AITOP-$height);
		$ai .= sprintf("%.1f %.1f L\n",$AILEFT,$AITOP-$height);
		$ai .= sprintf("%.1f %.1f L\n",$AILEFT,$AITOP-$poleoffset);
	} else	{
	# now draw the background of the globe proper
		my $poly = new GD::Polygon;
  		$ai .=  "0 O\n";
           	$ai .= sprintf("%s\n",$mycolor);
		my $x1;
		my $y1;
		for my $hemi (0..1)	{
			for my $lat (-90..90)	{
				my $ll = $lat;
				if ( $hemi == 1 )	{
					$ll = -1 * $ll;
				}
				if ( $q->param('projection') eq "orthographic" )	{
					$x1 = 90 * cos($ll * $PI / 180);
					$y1 = 90 * sin($ll * $PI / 180);
				} elsif ( $q->param('projection') eq "Eckert IV" )	{
				# this is the exact Eckert IV equation JA 7.5.06
				# first convert to radians
					$x1 = $PI / 2;
					$y1 = $ll * $PI / 720;
					$theta = 1 / 2 * (4 + $PI) * sin($y1);
					$x1 = 2 * 2 * $x1 * (1 + cos($theta)) / sqrt($PI * (4 + $PI));
					$y1 = 2 * sqrt($PI) / sqrt(4 + $PI) * sin($theta);
					my $scaley1 = sin(1 / 2 * (4 + $PI) * sin(90 * $PI / 720));
					$y1 = $y1 / $scaley1;
				# rescale just to fit in the image
					my $imagescale = ($hpix - 2) / (8 * $PI / sqrt($PI * (4 + $PI)));
					$x1 = $x1 * $imagescale;
					$y1 = $y1 * $imagescale;
				} elsif ( $q->param('projection') eq "Mollweide" )	{
				# this is the exact Mollweide equation JA 7.5.06
				# first convert to radians
					$x1 = $PI / 2;
					$y1 = $ll * $PI / 360;
					my $maxy = 90 * $PI / 360;
					my $theta = asin($y1 / $maxy);
					$y1 = 1 / 2 * sqrt(8) * sin($theta);
					if ( $y1**2 >= 2 )	{
						if ( $y1 >= 0 )	{
							$y1 = sqrt(2) - 0.00000001;
						} else	{
							$y1 = -1 * (sqrt(2) - 0.00000001);
						}
					}
					$x1 = 2 * 2 * $x1 / $PI * sqrt(2 - $y1**2);
				# rescale just to fit in the image
					my $imagescale = ($hpix - 2) / (4 * sqrt(2));
					$x1 = $x1 * $imagescale;
					$y1 = $y1 * $imagescale;
				}
				if ( $hemi == 1 )	{
					$x1 = -1* $x1;
				}
				if ( $q->param('projection') ne "orthographic" )	{
				}
				$x1 = $self->getLngTrunc($x1);
				$y1 = $self->getLatTrunc($y1);
				$poly->addPt($x1,$y1);
				if ( $lat == -90 && $hemi == 0 )	{
					$ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
				} else	{
					$ai .= sprintf("%.1f %.1f L\n",$AILEFT+$x1,$AITOP-$y1);
				}
			}
		}
		$im->filledPolygon($poly,$col{$mapbgcolor});
	# the globe has to have a dark edge or it won't be readable, but
	#  this is only ever a problem if the background is white JA 2.5.06
	# there is a big, big assumption here that you want the coastlines
	#  and the edge of the map to be the same color
	# I'm not sure why all previous versions apparently left this out
		if ( $mapbgcolor eq "white" )	{
			$im->openPolygon($poly,$edgecolor);
		}
	}
	$ai .=  "f\n";
  	$ai .=  "U\n";  # terminate the group

	return($origx,$origy);
}

sub drawGrids	{
    my $self = shift;

  # this section used to have a very complicated routine for printing lat/long
  #  numbers along the grid lines; I removed it because the numbers looked
  #  horrible and weren't being printed due to some bug I couldn't fix
  #  JA 7.5.06
  my $grids = $q->param('gridsize');
  my $gridcolor = $q->param('gridcolor');
  $ai .=  "u\n";  # start the group
  if ($grids > 0)	{
    for my $lat ( int(-90/$grids)..int(90/$grids) )	{
      for my $deg (-180..179)	{
        my $lng1;
        my $lat1;
        my $lng2;
        my $lat2;
        ($lng1,$lat1,$rawlng1,$rawlat1) = $self->projectPoints($deg , $lat * $grids, "grid");
        ($lng2,$lat2,$rawlng2,$rawlat2) = $self->projectPoints($deg + 1 , $lat * $grids, "grid");
	# never draw anything along the map edges JA 20.1.07
	# don't know why, but somehow the values at the edges come out of
	#  projectPoints a little low
	if ( ( $rawlng1 < -178.0 && $rawlng2 < -178.0 ) ||
             ( $rawlng1 > 178.0 && $rawlng2 > 178.0 ) ||
             ( $rawlat1 < -88.5 && $rawlat2 < -88.5 ) ||
             ( $rawlat1 > 88.5 && $rawlat2 > 88.5 ) )	{
            next;
        }
        if ( $lng1 !~ /NaN/ && $lat1 !~ /NaN/ && $lng2 !~ /NaN/ && $lat2 !~ /NaN/ && abs($lng1-$lng2) < 90 )	{
          my $x1 = $self->getLng($lng1);
          my $y1 = $self->getLat($lat1);
          my $x2 = $self->getLng($lng2);
          my $y2 = $self->getLat($lat2);
          if ( $x1 !~ /NaN/ && $y1 !~ /NaN/ && $x2 !~ /NaN/ && $y2 !~ /NaN/ )	{
            $im->line( $x1, $y1, $x2, $y2, $col{$gridcolor} );
            $ai .=  "$aicol{$gridcolor}\n";
            $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
            $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x2,$AITOP-$y2);
            $ai .=  "S\n";
          }
        }
      }
    }

    for my $lng ( int(-180/$grids)..int((180 - $grids)/$grids) )	{
      for my $doubledeg (-180..178)	{
	my $deg = $doubledeg / 2;
        my $lng1;
        my $lat1;
        my $lng2;
        my $lat2;
        ($lng1,$lat1,$rawlng1,$rawlat1) = $self->projectPoints($lng * $grids, $deg, "grid");
        ($lng2,$lat2,$rawlng2,$rawlat2) = $self->projectPoints($lng * $grids, $deg + 0.5, "grid");
	# never draw anything along the map edges JA 20.1.07
	# don't know why, but somehow the values at the edges come out of
	#  projectPoints a little low
	if ( ( $rawlng1 < -178.0 && $rawlng2 < -178.0 ) ||
             ( $rawlng1 > 178.0 && $rawlng2 > 178.0 ) ||
             ( $rawlat1 < -88.5 && $rawlat2 < -88.5 ) ||
             ( $rawlat1 > 88.5 && $rawlat2 > 88.5 ) )	{
            next;
        }
	if ( $lng1 == 180 )	{
		$lng1 = 179.5;
	}
	if ( $lng2 == 180 )	{
		$lng2 = 179.5;
	}
        if ( $lng1 !~ /NaN/ && $lat1 !~ /NaN/ && $lng2 !~ /NaN/ && $lat2 !~ /NaN/ && abs($lat1-$lat2) < 45 )	{
          my $x1 = $self->getLng($lng1);
          my $y1 = $self->getLat($lat1);
          my $x2 = $self->getLng($lng2);
          my $y2 = $self->getLat($lat2);
          if ( $x1 !~ /NaN/ && $y1 !~ /NaN/ && $x2 !~ /NaN/ && $y2 !~ /NaN/ )	{
            $im->line( $x1, $y1, $x2, $y2, $col{$gridcolor} );
            $ai .=  "$aicol{$gridcolor}\n";
            $ai .= sprintf("%.1f %.1f m\n",$AILEFT+$x1,$AITOP-$y1);
            $ai .= sprintf("%.1f %.1f l\n",$AILEFT+$x2,$AITOP-$y2);
            $ai .=  "S\n";
          }
        }
      }
    }
  }
  $ai .=  "U\n";  # terminate the group
}

# This function gets the name of the tile in the tile cache to use
# This function is only necessary because os x has a limit of 255 characters on the name and
# thus we can't just store all these params in the filename, so hash them out to a md5 string,
# which should never collide
sub getTileID {
    my $q = shift;
    my @tileParams = ('projection','mapscale','mapwidth','mapsize','maptime','maplat','maplng','usalinecolor','borderlinecolor','mapbgcolor','crustcolor','crustedgecolor','gridsize','gridcolor','gridposition','linethickness','coastlinecolor');

    my $data = "";
    foreach my $p (@tileParams) {
        $data .= "$p=".$q->param($p);
        dbg("$p=".$q->param($p));
    }
    my $id = Digest::MD5::md5_hex($data);
    return $id;
}

sub acos {
    my $a;
    if ($_[0] > 1 || $_[0] < -1) {
        $a = 1;
#        carp "Map.pm warning, bad args passed to acos: $_[0] x $x y $y";
    } else {
        $a = $_[0];
    }
    atan2( sqrt(1 - $a * $a), $a )
}
sub asin { atan2($_[0], sqrt(1 - $_[0] * $_[0])) }

sub tan { sin($_[0]) / cos($_[0]) }

# returns great circle distance given two latitudes and a longitudinal offset
sub GCD { ( 180 / $PI ) * acos( ( sin($_[0]*$PI/180) * sin($_[1]*$PI/180) ) + ( cos($_[0]*$PI/180) * cos($_[1]*$PI/180) * cos($_[2]*$PI/180) ) ) }

# This is only shown for internal errors
sub htmlError {
    my $self = shift;
    my $message = shift;

    print $message;
    exit 1;
}


1;
