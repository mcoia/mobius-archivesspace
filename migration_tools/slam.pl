#!/usr/bin/perl


use lib qw(./);
use Loghandler;
use Data::Dumper;
use File::Path qw(make_path remove_tree);
use Encode;
use Cwd;
use Mobiusutil;
use XML::Simple;
use Text::CSV (csv);

# use sigtrap qw(handler cleanup normal-signals);


our $bulkImportSpreadsheetCSVFile = "/mnt/evergreen/tmp/aspace_migration/bulk_import_template.csv";
our %bulkColMap = ();

our $outfolder = "/mnt/evergreen/tmp/aspace_migration/out";
our $infolder = "/mnt/evergreen/tmp/aspace_migration/in";

my @files = @{dirtrav(\@files, $infolder)};

# we need a way to "map" the destination columns. And the best way is to use some kind of labeling system
# turns out, the "bulk_import" spreadsheet has a row with unique labels. Let's just use those!
# in order to use those, we need to have our perl script open that file and read that row.

readBulkImportSpreadsheet();

our %inputMap = (
    'ead'                   => {'in_col' => 0, 'data_manip' => '$data'},
    'indicator_1'           => {'in_col' => 1, 'data_manip' => '$data'},
    'title'                 => {'in_col' => 5, 'data_manip' => 'getTitle($data)'},
    'begin'                 => {'in_col' => 6, 'data_manip' => 'getDate($data)'},
    'end'                   => {'in_col' => 6, 'data_manip' => 'getDate($data, 1)'},
    'indicator_2'           => {'in_col' => 5, 'data_manip' => 'getChildIndicator($data)'},
    'people_agent_header_1' => {'in_col' => 5, 'data_manip' => 'getAgent($data)'},
    'type_1'                => {'in_col' => 1, 'data_manip' => '$data'},
    'type_2'                => {'in_col' => 1, 'data_manip' => '$data'},
    'level'                 => {'in_col' => 1, 'data_manip' => '$data'},

    # This stuff isn't in the data, but we have to define it
);

our @finalOutput = ();

for my $b (0 .. $#files) {
    my $thisfilename = $files[$b];
    $thisfilename =~ s/$infolder//g;
    $thisfilename =~ s/^\///g;
    my $outputFile = new Loghandler($outfolder . "/" . $thisfilename);
    my $in_csv = csv(in => $files[$b]);

    my %lastRowValues = ();
    foreach ($in_csv) {

        my $row_count = 0;

        foreach my $row (@{$_}) {

            ## skip the first 2 header rows, we could delete them from the file but I left it untouched 
            if ($row_count >= 2) {

                # check to see if we're moving into a new box
                if (trim($row->[1]) ne '') {
                    %lastRowValues = %{updateLastRowHash(\%lastRowValues, $row)};
                    # override some stuff, with some hardcoded missing values
                    $lastRowValues{'hierarchy'} = '1';
                    $lastRowValues{'title'} = $row->[4];
                    $lastRowValues{'level'} = 'Series';
                    $lastRowValues{'publish'} = 'no';
                    $lastRowValues{'cont_instance_type'} = 'Audio';
                    $lastRowValues{'type_1'} = 'Box';
                    $lastRowValues{'type_2'} = undef;
                    $lastRowValues{'indicator_2'} = undef;
                    pushNewRow(\%lastRowValues, 1);
                }
                %lastRowValues = %{updateLastRowHash(\%lastRowValues, $row)};
                $lastRowValues{'hierarchy'} = '2';
                $lastRowValues{'type_1'} = 'Box';
                $lastRowValues{'type_2'} = 'Reel';
                $lastRowValues{'level'} = 'File';
                pushNewRow(\%lastRowValues);
            }

            $row_count++;

        }

    }

}

buildFinalCSVFile();

sub buildFinalCSVFile {

    my @rows = ();
    foreach (@finalOutput) {
        my %thisDataMap = %{$_};
        my %thisOutRow = ();
        my $maxColNumber = 0;
        while ((my $outColNum, my $labelKey) = each(%bulkColMap)) {
            $maxColNumber = $outColNum if ($outColNum > $maxColNumber);
            if ($thisDataMap{$labelKey}) {
                $thisOutRow{$outColNum} = $thisDataMap{$labelKey};
            }
        }

        my @thisRow = ();
        for my $i (0 .. $maxColNumber) {
            push(@thisRow, $thisOutRow{$i});
        }

        push @rows, \@thisRow;
    }


    # and write as CSV
    print "\nExporting final csv file ==> ./new.csv\n";
    open $fh, ">:encoding(utf8)", "new.csv" or die "new.csv: $!";
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 1 });
    $csv->say($fh, $_) for @rows;
    close $fh or die "new.csv: $!";

}

    
sub updateLastRowHash {
    my $has = shift;
    my $row = shift;
    my %hash = %{$has};
    while ((my $label, my $props) = each(%inputMap)) {
        # print Dumper(%{$props}) . "\n";
        my $data = $row->[$props->{'in_col'}];
        if (trim($data) ne '') {
            my $ev = '$data = ' . $inputMap{$label}->{'data_manip'} . ';';
            # print Dumper($inputMap{$label}) . "\n";
            eval($ev);
            $hash{$label} = $data;
        }
    }
    if ($hash{'end'} && trim($hash{'end'}) ne '') {
        $hash{'date_type'} = 'bulk';
    }
    else {
        $hash{'date_type'} = 'single';
    }

    return \%hash;
}

sub pushNewRow {
    # this is needed so that our final array gets new variables, and not a reference to the same one over and over
    my $valsRef = shift;
    my $newBox = shift;
    my %vals = %{$valsRef};
    my %final = ();
    while ((my $key, my $val) = each(%vals)) {
        $final{$key} = $val;
    }
    push(@finalOutput, \%final);
}

sub getTitle {

    my $data = shift;
    my $ret = "";
    my @slashSplit = split(/\//, trim($data));
    my @spaceSplit = split(/[\r\n]+/, @slashSplit[0]);
    shift @spaceSplit;
    $ret = join(' ', @spaceSplit);
    return $ret;
}

sub getDate {
    my $data = shift;
    my $endingDate = shift;
    # print "before: $data\n";
    my $ret = '';
    $data = lc $data;

    # If we're looking for the ending date, and the data doesn't have a dash, return nothing
    return '' if ($endingDate && !($data =~ /\-/));

    my @monthWords = qw/january february march april may june july august september october november december/;
    my $matchingMonth = 0;
    my $pos = 1;
    my %datePieces = ();
    foreach (@monthWords) {
        $matchingMonth = $pos if ($data =~ /$_/);
        $pos++;
    }
    if ($matchingMonth) {
        # print "matching: $matchingMonth\n";
        # print "whole: $data\n";
        my @splits = split(/\-/, $data);
        if ($endingDate) {
            # print "******************\n";
            $data = @splits[1];
        }
        else {
            $data = @splits[0];
        }
        # print "passing: $data\n";
        # this needs to be redone, because it's possible for the logic to return the first/second matching month
        # and now, we know which one we want
        $pos = 1;
        foreach (@monthWords) {
            $matchingMonth = $pos if ($data =~ /$_/);
            $pos++;
        }
        $datePieces{'month'} = $matchingMonth;
        my $temp = @monthWords[$pos - 1]; #convert back to zero based
        $data =~ s/$temp//g;              #remove the month word from the data, we should have two groups of digits left
        $datePieces{'year'} = $data;
        $datePieces{'year'} =~ s/.*(\d{4}).*/\1/g;
        $temp = $datePieces{'year'};
        $data =~ s/$temp//g;
        $datePieces{'day'} = $data;
        $datePieces{'day'} =~ s/.*(\d{2}).*/\1/g;
        #sometimes it's a single digit day
        if (!($datePieces{'day'} =~ /\d{2}/)) {
            $datePieces{'day'} = $data;
            $datePieces{'day'} =~ s/.*(\d).*/\1/g;
        }
        $ret = $datePieces{'month'} . '/' . $datePieces{'day'} . '/' . $datePieces{'year'};
    }
    else {
        ## Handle date(s) expressed in numeric
    }
    # print "after: $ret\n";

    return $ret;
}

sub getAgent {
    my $data = shift;

    # split the text between the / text-here / 
    my @agentSplit = split /\//, $data;
    my $agentName = @agentSplit[0];

    # Grab the first 2 words of the string
    my @words = split /\s/, $agentName;
    my $firstWord, $secondWord;

    # make sure we have more than 2 words in our array then assign the agent name 
    if (@words >= 2) {
        $firstWord = @words[0];
        $secondWord = @words[1];
        $agentName = "$firstWord $secondWord";
    }

    # trim whitespace 
    $agentName =~ s/^\s+|\s+$//g;

    # Check for stray characters that indicate we're not a name
    # ex: numbers, parentheses ect...
    if ($agentName =~ /[\d|;|(|)|:|.]/ || length($firstWord) <= 3 || length($secondWord) <= 3) {
        $agentName = '';
    }

    return $agentName;

}

sub grabFirst2Words {

}

sub grabLast2Words {

}

sub getChildIndicator {
    my $data = shift;
    my $ret = trim($data);
    my @s = split(/[\s\n\r]+/, $ret);
    $ret = @s[0];
    return $ret;
}

sub dirtrav {
    my @files = @{@_[0]};
    my $pwd = @_[1];
    opendir(DIR, "$pwd") or die "Cannot open $pwd\n";
    my @thisdir = readdir(DIR);
    closedir(DIR);
    foreach my $file (@thisdir) {
        if (($file ne ".") and ($file ne "..")) {
            if (-d "$pwd/$file") {
                push(@files, "$pwd/$file");
                @files = @{dirtrav(\@files, "$pwd/$file")};
            }
            elsif (-f "$pwd/$file") {
                push(@files, "$pwd/$file");
            }
        }
    }
    return \@files;
}

sub trim {
    my $string = shift;
    $string =~ s/^[\s\n\r]+//;
    $string =~ s/[\s\n\r]+$//;
    return $string;
}

sub readBulkImportSpreadsheet {
    print "\nreading: $bulkImportSpreadsheetCSVFile\n";
    my $in_csv = csv(in => $bulkImportSpreadsheetCSVFile);
    # The bulk spreadsheet has the column labels on row 4

    my $colnum = 0;
    foreach (@{$in_csv->[3]}) {
        if ($_ ne '') {
            $bulkColMap{$colnum} = $_;
        }
        $colnum++;
    }
}

exit;