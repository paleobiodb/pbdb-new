# some global functions which can be used by any other module.

package Globals;

use strict;


# who is the "god" user (ie, full access to everything?)
# This is an inline function, so it should be fast.
sub god () {
	return 'J. Alroy';	
}




# pass this a warning message and it will print it directly
# to the web page.  Note, you still need to add the standard page 
# header and footer before and after this.
sub printWarning {
	my $warning = shift;

	print "<CENTER><H3><FONT COLOR='red'>Warning:</FONT> $warning</H3></CENTER>\n";
}


# pass this a full month name such as "December" and it will return the month number, ie, 12.
sub monthNameToNumber {
	my $name = shift;
	
	my %month2num = (  "January" => "01", "February" => "02", "March" => "03",
                         "April" => "04", "May" => "05", "June" => "06",
                         "July" => "07", "August" => "08", "September" => "09",
                         "October" => "10", "November" => "11",
                         "December" => "12");
	
	my $month = $month2num{$name};  # needs semicolon because it's a hash.. weird.
	
	return $month;
}





1;