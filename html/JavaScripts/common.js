//some common java script functions which are used throughout the web site.
//note, these are for use on BOTH the PUBLIC and PRIVATE page.
//created by rjp, 1/2004.


function checkBrowserVersion() {
	var match = /Microsoft/i;
	
	if (match.test(navigator.appName)) {
		document.write("<div class=\"warning\">Internet Explorer is not recommended for this web site.<BR> Read the web browsers <A HREF=\"javascript: tipsPopup('/public/tips/browser_tips.html')\">tip sheet</A> for information on which browser to download.</div>");
	}
}


//
// for validation of form input
//

// returns true if the input is in a proper format for a last name
function properLastName(input) {
	if ((!input) || input == "") { return false; }
	
	var match = /^[A-Za-z ,-.\']+$/;
	
	return match.test(input);
}

// returns true if the input is in a proper format for an initial 
function properInitial(input) {
	if ((!input) || input == "") { return false; }
	
	var match = /^[A-Za-z .]+$/;
	
	return match.test(input);
}

// returns true if it's a proper year format which begins with a 1 or 2,
// ie, 1900 and something or 2000 something.
function properYear(input) {
	if ((!input) || input == "") { return false; }
	
	var match = /^[12]\d{3}$/;
	
	return match.test(input);
}


// pass this a taxon name as a string,
// and it will look at the number of spaces to determine
// the rank.  Returns "invalid" if it's not a valid spacing..
//
// 0 spaces = higher
// 1 space  = species
// 2 spaces = subspecies
//
// it will return a string, either "higher", "species", "subspecies", or "invalid"
// ** note, we can't tell the difference between a genus and a higher taxon
// by just looking at the spacing.. so a genus name will return as "higher" as well.
//
// by rjp, 2/2004 
function taxonRank(taxon) {
	var isSpecies = /^[A-Z][a-z]+[ ][a-z]+\n?$/;
	var isSubspecies = /^[A-Z][a-z]+[ ][a-z]+[ ][a-z]+\n?$/;
	var isHigher = /^[A-Z][a-z]+\n?$/;
	
	//alert ("taxon = '" + taxon + "'");
	if (isSubspecies.test(taxon)) {
		return "subspecies";	
	}
	
	if (isSpecies.test(taxon)) {
		return "species";	
	}

	if (isHigher.test(taxon)) {
		return "higher";
	}
	
	return "invalid";
}


// pass this a specific rank such as subspecies, genus, order, family, etc. 
// and a general rank which is one of the results returned by the taxonRank() function
// subspecies, species, higher, or invalid.
//
// returns true if they match (ie, if order and higher, then it matches), or false otherwise.
function specificRankMatchesGeneralRank(specific, general) {
	var toreturn = true;
	
	if (general == "subspecies") {	
		toreturn = (specific == "subspecies");
	} else if (general == "species") {
		toreturn = (specific == "species");
	} else if (general == "invalid") {
		toreturn = false;	
	}
	
	return toreturn;
}


// Error is a JavaScript class for error reporting..  
// To use it, first create a new instance of the object, for example
// var err = new Error();  // you can optionally pass an error message in the constructor
// Then, call the add() method each time you want to add an error to it.
// err.add("my error message");
// When finished, you can print the alert by calling the showAlert method,
// or you can directly grab the string.
// err.showAlert();  //displays the alert message with the entire error
// alert(err);  // same thing

// constructor, optionally pass it the first error message.
//
// by rjp, 2/2004
function Error(msg) {
	this.starting = "\tPlease fix the following errors:\n\n";
	this.message = "";
	this.internalcount = 0;
	
	if (msg) {
		this.message = "* " + msg;	
	}	
	
	this.ending = "\n\nRefer to the tip sheet for instructions.";
}

// adds an error with a bullet point to the list of error messages
Error.prototype.add = function(msg) {
	this.message += "\n* " + msg;
	this.internalcount += 1;
}

Error.prototype.count = function() {
	return this.internalcount;
}

// displays an alert message with the error
Error.prototype.showAlert = function() {
	alert(this);
}

// converts the error object to a string.
Error.prototype.toString = function() {
	return this.starting + this.message + this.ending;
}

// pass this method another Error object, and it will append the
// new object onto the end of itself.
Error.prototype.appendErrors = function(newError) {
	this.message += newError.message;
	this.internalcount += newError.internalcount;
}

// End of error class.




//show a popup window with the passed URL.
function tipsPopup (URL) {
	window.open(URL, 'tips', 'toolbar=1,scrollbars=1,location=1,statusbar=0,menubar=0,resizable=1,width=640,height=480');
}


//if java script is turned on, then this will
//print a hidden input field so we can check from the perl
//code and see that it was turned on.
function javascriptOnCheck() {
	document.writeln("<INPUT type=\"hidden\" name=\"javascripton\" value=\"yes\"></INPUT>");	
}


//meant to fill the years in a pull down menu from 1998 to the current year.
//
// by rjp, 2/2004
function fillYears() {
	var yearField = document.forms[0].year
	var date = new Date();

	var maxYear = date.getFullYear(); 
	var year;

	for (year = maxYear; year >= 1998; year--) {
		document.writeln("<OPTION>" + year + "</OPTION>");
	}	
}


function fillMonths() {
	document.write("<option>December</option>");
	document.write("<option>November</option>");
	document.write("<option>October</option>");
	document.write("<option>September</option>");
	document.write("<option>August</option>");
	document.write("<option>July</option>");
	document.write("<option>June</option>");
	document.write("<option>May</option>");
	document.write("<option>April</option>");
	document.write("<option>March</option>");
	document.write("<option>February</option>");
	document.write("<option>January</option>");
}

function fillDays() {
	var i;
	for (i = 31; i > 0; i--) {
		document.writeln("<OPTION>" + i + "</OPTION>");
	}
}
