# 
# CoreFunction.pm
# 
# Basic database and utility routines.


package CoreFunction;

use strict;

use DBI;
use YAML;
use Term::ReadKey;
use Carp qw(carp croak);

use ConsoleLog qw(logMessage);

use base qw(Exporter);

our (@EXPORT_OK) = qw(connectDB loadConfig configData loadSQLFile activateTables);



# Store configuration information until needed.

my ($CONFIG);



# connect ( config_filename, db_name )
# 
# Create a new database handle, reading the connection attributes from the
# specified configuration file.  If $db_name is given, it overrides the database
# name from the configuration file.

sub connectDB {

    # If not specified the name of the configuration file defaults to
    # 'config.yml'.  If the database name is not specified, then it defaults
    # to the value given in the configuration file.
    
    my ($config_filename, $db_name) = @_;
    
    # If we haven't read the configuration file yet, do so.
    
    unless ( $CONFIG )
    {
	loadConfig($config_filename);
    }
    
    # Extract the relevant configuration parameters.  Ask for a password unless
    # one was specified in the configuration file.
    
    my $dbconf = configData('Database');
    
    my $DB_DRIVER = $dbconf->{driver};
    my $DB_NAME = $db_name || $dbconf->{database};
    my $DB_HOST = $dbconf->{host};
    my $DB_PORT = $dbconf->{port};
    my $DB_USER = $dbconf->{username};
    my $DB_PASSWD = $dbconf->{password};
    my $DBI_PARAMS = $dbconf->{dbi_params};
    
    croak "You must specify the database driver as 'driver' in config.yml" unless $DB_DRIVER;
    croak "You must specify the database name as 'database' in config.yml or on the command line" unless $DB_NAME;
    croak "You must specify the database host as 'host' in config.yml" unless $DB_HOST;
    
    unless ( $DB_PASSWD )
    {
	ReadMode('noecho');
	print "Password: ";
	$DB_PASSWD = <STDIN>;
	chomp $DB_PASSWD;
	ReadMode('restore');
    }
    
    # Connect to the database.
    
    my $dsn = "DBI:$DB_DRIVER:database=$DB_NAME";
    
    if ( $DB_HOST )
    {
	$dsn .= ";host=$DB_HOST";
    }
    
    if ( $DB_PORT )
    {
	$dsn .= ";port=$DB_PORT";
    }
    
    $dsn .= ";mysql_client_found_rows=0";
    
    my $dbh = DBI->connect($dsn, $DB_USER, $DB_PASSWD, $DBI_PARAMS);
    
    croak "Could not connect to database: $DBI::errstr" unless $dbh;
    
    return $dbh;
}


# loadConfig ( filename )
# 
# Read configuration data from the specified filename.  Look in both the
# current directory and the parent directory.  If the filename is not given,
# it defaults to 'config.yml'.

sub loadConfig {

    my ($filename) = @_;
    
    $filename ||= 'config.yml';
    
    $CONFIG = YAML::LoadFile($filename);
    
    unless ( $CONFIG )
    {
	$CONFIG = YAML::LoadFile("../$filename");
    }
    
    carp "Could not read $filename: $!" unless $CONFIG;
}


# configData ( key )
# 
# Returns the configuration data corresponding to the specified key.  If not
# found, tries the specified key as a subkey of 'plugins' and 'engines' in turn.

sub configData {
    
    my ($key) = @_;
    
    # Throw an error if we haven't yet loaded the configuration information.
    
    croak "You must call loadConfig() before configData()." unless $CONFIG;
    
    # First try the key directly.
    
    return $CONFIG->{$key} if exists $CONFIG->{$key};
    
    # Then try it as a subkey of the following keys:
    
    my @keys = ('plugins', 'engines');
    
    foreach my $upper (@keys)
    {
	next unless exists $CONFIG->{$upper}{$key};
	return $CONFIG->{$upper}{$key};
    }
    
    return;
}


# loadSQLFile ( dbh, filename )
# 
# Load SQL data from the specified file, which should be generated by the
# mysqldump utility.

sub loadSQLFile {

    my ($dbh, $filename) = @_;
    
    # First try to open the file.  If not successful, prepend "../" to the
    # name and try again.
    
    my $result = open(my $interval_fh, "<", $filename);
    
    unless ( $result )
    {
	carp "Could not open file $filename: $!";
	$result = open($interval_fh, "<", "../$filename");
    }
    
    croak "Could not open file ../$filename: $!"
	unless $result;
    
    # Read the contents of the file.
    
    my @contents = <$interval_fh>;
    
    close $interval_fh;
    
    croak "The file '$filename' was empty or could not be read." unless @contents;
    
    # Put the content lines together into SQL statements, skipping blank lines
    # and comments.  Execute each statement in turn.
    
    my $statement = '';
    
    foreach my $line (@contents)
    {
	# Skip blank lines and comments
	
	next if $line =~ qr{ ^ -- | ^ /\* }xs;
	next unless $line =~ qr{ \w }xs;
	
	# Everything else gets appended to the current statement.
	
	$statement .= $line;
	
	# If the line ends in a semicolon, execute the statement.
	
	if ( $line =~ qr{ ;$ }xs )
	{
	    $result = $dbh->do($statement);
	    $statement = '';
	}
    }
    
    return 1;
}


# activate_tables ( dbh, table_list )
# 
# The table list should be a list with alternating work table name and active
# table name.  Each work table is safely substituted for the corresponding
# active table.

sub activateTables {
    
    my ($dbh, @table_list) = @_;
    
    my @work_tables;
    my @active_tables;
    my %active_table;
    my %backup_table;
    
    my ($sql, $result);
    
    while ( @table_list )
    {
	my $work_table = shift @table_list;
	my $active_table = shift @table_list;
	
	push @work_tables, $work_table;
	push @active_tables, $active_table;
	$active_table{$work_table} = $active_table;
	$backup_table{$work_table} = "${active_table}_bak";
    }
    
    my $activate_string = join("', '", @active_tables);
    
    logMessage(2, "activating tables '$activate_string'");
    
    # Delete any old backup tables that might have been left around.  Create
    # empty active tables if any of them don't exist, so that the atomic table
    # swap won't throw an error.
    
    foreach my $t (@work_tables)
    {
	$result = $dbh->do("DROP TABLE IF EXISTS $backup_table{$t}");
	$result = $dbh->do("CREATE TABLE IF NOT EXISTS $active_table{$t} LIKE $t");
    }
    
    # Now construct an SQL statement that will swap in all of the tables at
    # the same time.
    
    my $rename_lines = '';
    
    foreach my $t (@work_tables)
    {
	$rename_lines .= ",\n" if $rename_lines;
	$rename_lines .= "	$active_table{$t} to $backup_table{$t},\n";
	$rename_lines .= "	$t to $active_table{$t}";
    }
    
    $sql = "RENAME TABLE\n$rename_lines";
    
    $result = $dbh->do($sql);
    
    # Then delete the backup tables.
    
    foreach my $t (@work_tables)
    {
	$result = $dbh->do("DROP TABLE IF EXISTS $backup_table{$t}");
    }
    
    my $a = 1;		# We can stop here when debugging
}


1;
