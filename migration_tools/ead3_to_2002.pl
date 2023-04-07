#!/usr/bin/perl


use lib qw(./); 
use Loghandler;
use Data::Dumper;
use File::Path qw(make_path remove_tree);
use Encode;
use Cwd;
use Mobiusutil;
use XML::Simple;

# use sigtrap qw(handler cleanup normal-signals);


our $outfolder = "/mnt/evergreen/tmp/aspace_migration/out";
our $infolder = "/mnt/evergreen/tmp/aspace_migration/in";

our $allTogetherBefore = "/mnt/evergreen/tmp/aspace_migration/out/allbefore.txt";
our $allTogetherAfter = "/mnt/evergreen/tmp/aspace_migration/out/allafter.txt";

our $afterWriter = new Loghandler($allTogetherAfter);
our $beforeWriter = new Loghandler($allTogetherBefore);

$afterWriter->truncFile("");
$beforeWriter->truncFile("");

my @files = @{getEADXMLFromFolder()};

my $beforeText = "";
my $afterText = "";
for my $b(0..$#files)
{
    my $thisfilename = $files[$b];
    $thisfilename =~ s/$infolder//g;
    $thisfilename =~ s/^\///g;
    my $outputFile = new Loghandler($outfolder."/".$thisfilename);

    my $orgfilename = $thisfilename;
    $thisfilename = lc($thisfilename);
    if( $thisfilename =~ m/\.xml/ )
    {
        # if($thisfilename =~ /msa4/)
        if(1)
        {
        $outputFile->truncFile('');
        my $before = '';

        print "********\nReading ". $files[$b] ."\n********\n";
        my $logreader = new Loghandler($files[$b]);
        my $output = '';
        my @lines = @{$logreader->readFile};
        $before .= $_ foreach(@lines);
        $beforeText .= "*************\n";
        $beforeText .= "$thisfilename\n";
        $beforeText .= "*************\n";
        $beforeText .= "$before\n";
        $afterText .= "*************\n";
        $afterText .= "$thisfilename\n";
        $afterText .= "*************\n";


        @lines = @{removeXMLBlock(\@lines, 'control', 1)};
        @lines = @{removeXMLBlock(\@lines, 'physdescset', 1)};
        @lines = @{replaceXMLBlock(\@lines, 'repository','
        <repository>
                <corpname>test</corpname>
            </repository>')};
        @lines = @{replaceXMLTagName(\@lines, 'physdescstructured', 'physdesc')};
        @lines = @{replaceRegex(\@lines, 'localtype', 'type')};
        @lines = @{replaceRegex(\@lines, '<p\/>', '')};
        @lines = @{appendExtentXMLInBlock(\@lines, 'physdesc', '<extent>1 box</extent>')};
        @lines = @{removeXMLChildTagInBlock(\@lines, 'corpname', 'part')};
        @lines = @{removeXMLChildTagInBlock(\@lines, 'persname', 'part')};
        @lines = @{removeXMLChildTagInBlock(\@lines, 'subject', 'part')};
        @lines = @{removeXMLChildTagInBlock(\@lines, 'geogname', 'part')};
        @lines = @{fixUndefinedCLevel(\@lines)};

        # debug only
        # @lines = @{findBadDateRanges(\@lines)};


        $output .= "$_\n" foreach(@lines);
        $outputFile->addLineRaw($output);
        $afterText .= "$output\n";
        }
        # exit;
    }

}

$beforeWriter->addLineRaw($beforeText);
$afterWriter->addLineRaw($afterText);



sub escapeRegexChars
{
    my $txt = shift;
    $txt =~ s/\\/\\\\/g;
    $txt =~ s/\//\\\//g;
    $txt =~ s/\(/\\(/g;
    $txt =~ s/\)/\\)/g;
    $txt =~ s/\?/\\?/g;
    $txt =~ s/\+/\\+/g;
    $txt =~ s/\[/\\[/g;
    $txt =~ s/\]/\\]/g;
    $txt =~ s/\-/\\-/g;
    return $txt;
}

sub findBadDateRanges
{
    my $lineRef = shift;
    my $together = convertUTFStuff($lineRef);
    my @dateChecks = split(/normal/, $together);
    shift @dateChecks;
    foreach(@dateChecks)
    {
        my @s = split(/"/, $_);
        foreach(@s)
        {
            my @dates = ();
            if($_ =~ /\d{4}[\-\/]\d{2}[\-\/]\d{2}\/\d{4}[\-\/]\d{2}[\-\/]\d{2}/)
            {
                @dates = ($_ =~ /(\d{4}[\-\/]\d{2}[\-\/]\d{2})\/(\d{4}[\-\/]\d{2}[\-\/]\d{2})/);
            }
            elsif($_ =~ /\d{4}[\-\/]\d{2}\/\d{4}[\-\/]\d{2}/)
            {
                @dates = ($_ =~ /(\d{4}[\-\/]\d{2})\/(\d{4}[\-\/]\d{2})/);
            }
            elsif($_ =~ /\d{4}\/\d{4}/)
            {
                @dates = ($_ =~ /(\d{4})\/(\d{4})/);
            }
            if($#dates > 0)
            {
                @dates[0] =~ s/[\-\/\\]//g;
                @dates[1] =~ s/[\-\/\\]//g;
                if(@dates[0] > @dates[1])
                {
                    print "Found: $_\n";
                }
            }
        }
    }
}

sub fixUndefinedCLevel
{
    my $lineRef = shift;
    print "fixUndefinedCLevel\n";

    my $together = convertUTFStuff($lineRef);
    my %fixes = ();
    for my $i (0..9)
    {
        my $thisCode = "c0$i";
        print $thisCode."\n";
        my $fixThisCode = 0;
        my @s = split(/<$thisCode/ , $together);
        shift @s;
        foreach(@s)
        {
            if(!($_ =~ /^\s*level/))
            {
                $fixThisCode = 1;
                $fixes{$thisCode} = 1;
            }
        }
    }
    while (my ($key, $value) = each(%fixes))
    {
        print "fixing: $key\n";
        $together = _fixCcodeLevel($together, $key);
    }

    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub _fixCcodeLevel
{
    my $together = shift;
    my $cCode = shift;
    my %votes = ();
    my @s = split(/<$cCode/ , $together);
    shift @s;
    foreach(@s)
    {
        my $t = $_;
        if(!($t =~ /^\s*>/))
        {
            # print "check-- \n $t\n";
            $t =~ s/^([^>]*)>.*/$1/;
        
            if($t =~ /level/)
            {
                $t =~ s/.*?level.*=.*"([^"]*)".*/$1/;
                # print "found: $t\n";
                $votes{$t} = 0 if !$votes{$t};
                $votes{$t}++;
            }
        }
    }
    print Dumper(\%votes);
    my $high = 0;
    my $choice = '';
    while (my ($key, $value) = each(%votes))
    {
        if($value+0 > $high+0)
        {
            $choice = $key;
            $high = $value;
        }
    }
    $choice = 'file' if $choice eq ''; # there may not be any examples, default to "file"
    print "Choice: $choice\n";
    $together =~ s/<\s*$cCode\s*>/<$cCode level="$choice">/g;

    return $together;
}

sub removeXMLChildTagInBlock
{
    my $lineRef = shift;
    my $block = shift;
    my $childTag = shift;
    print "removeXMLChildTagInBlock '$block'\n";
    
    my $together = convertUTFStuff($lineRef);
    my $stop = 0;
    my $loopmax = 0;
    while( ($together =~ /<$block[\s]?[^>]*>.*?$childTag.*?<\/$block\s*>/) && !$stop)
    {
        my $before = $together;
        my $blockFrag = $together;
        $blockFrag = getChildBlock($blockFrag, $block, $childTag);
        if($blockFrag ne $together)
        {
            $newBlockFrag = $blockFrag;
            $newBlockFrag =~ s/<$childTag[\s]?[^>]*>(.*?)<\/$childTag\s*>/$1/g;
            $blockFrag = escapeRegexChars($blockFrag);
            
            # print "newblock = $newBlockFrag\n";
            $together =~ s/$blockFrag/$newBlockFrag/g;
            if($together eq $before)
            {
                print "removeXMLChildTagInBlock '$block' '$childTag' affected no change\n";
                $stop = 1;
            }
        }
        $loopmax++;
        $stop = 1 if $loopmax > 20;
    }
    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub appendExtentXMLInBlock
{
    my $lineRef = shift;
    my $block = shift;
    my $addIfNoMeasurements = shift || '';
    print "appendExtentXMLInBlock '$block'\n";
    
    my @placeholder = ();
    my @blocks = ();
    my $together = convertUTFStuff($lineRef);
    my $before = $together;
    
    my $blockFrag = getChildBlock($together, $block);
    my $i = 0;
    my $loopmax = 0;
    my $stop = 0;
    while($blockFrag ne $together && !$stop)
    {
        my $thisPlaceHolder = "!!$i!!";
        push @blocks, $blockFrag;
        push @placeholder, $thisPlaceHolder;
        $blockFrag = escapeRegexChars($blockFrag);
        $together =~ s/$blockFrag/$thisPlaceHolder/g;
        $blockFrag = getChildBlock($together, $block);
        $i++;
        $loopmax++;
        $stop = 1 if $loopmax > 20;
    }
    for my $b(0..$#placeholder)
    {
        my $final = doExtentAdd(@blocks[$b], $block, $addIfNoMeasurements);
        $together =~ s/@placeholder[$b]/$final/g;
    }
    if($together eq $before)
    {
        print "appendExtentXMLInBlock '$block' '$addIfNoMeasurements' affected no change\n";
    }
    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub doExtentAdd
{
    my $physXMLBlock = shift;
    my $tag = shift;
    my $addIfNoMeasurements = shift;
    my $xmlfeeder = $physXMLBlock;
    $xmlfeeder =~ s/!!!!!!!!!!!//g;
    my $xmlin = XMLin($xmlfeeder);
    my $quantity = $xmlin->{'quantity'};
    my $unittype = $xmlin->{'unittype'};
    if($quantity && $unittype)
    {
        $addIfNoMeasurements = "<extent>$quantity $unittype</extent>";
        print "unittype and/or quantity not found here\n";
    }
    $physXMLBlock =~ s/(<$tag[\s]?[^>]*>)(.*?)(<\/$tag\s*>)/$1 $2 $addIfNoMeasurements $3/g;
    return $physXMLBlock;
}

sub replaceRegex
{
    my $lineRef = shift;
    my $block = shift;
    my $replace = shift;
    print "replaceRegex '$block'\n";
    
    my $together = convertUTFStuff($lineRef);
    my $before = $together;

    $together =~ s/$block/$replace/g;
    if($together eq $before)
    {
        print "replaceRegex '$block' '$replace' affected no change\n";
    }
    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub replaceXMLTagName
{
    my $lineRef = shift;
    my $block = shift;
    my $replace = shift;
    print "replaceXMLTagName '$block'\n";
    
    my $together = convertUTFStuff($lineRef);
    my $before = $together;

    $together =~ s/<$block/<$replace/g;
    $together =~ s/<\/$block/<\/$replace/g;
    if($together eq $before)
    {
        print "replaceXMLTagName '$block' '$replace' affected no change\n";
        
    }
    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub replaceXMLBlock
{
    my $lineRef = shift;
    my $block = shift;
    my $replace = shift;
    print "replaceXMLBlock '$block'\n";
    
    my $together = convertUTFStuff($lineRef);
    my $before = $together;

    $together =~ s/<$block[\s]?[^>]*>.*?<\/$block\s*>/$replace/g;
    if($together eq $before)
    {
        print "replaceXMLBlock '$block' '$replace' affected no change\n";
        
    }
    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub removeXMLBlock
{
    my $lineRef = shift;
    my $block = shift;
    my $raiseLevel = shift || 0;
    print "removeXMLBlock '$block'\n";
    
    my $together = convertUTFStuff($lineRef);
    my $before = $together;
    if($raiseLevel) # just removing the opening and closing tags, not the stuff between
    {
        $together =~ s/<\s*$block\s*>//g;
        if($together eq $before)
        {
            $together =~ s/<\s*$block\s+[^>]*>//g;
        }
        $together =~ s/<\/\s*$block\s*>//g;
    }
    else
    {
        $together =~ s/<$block[\s]?[^>]*>.*?<\/$block\s*>//g;
        if($together eq $before)
        {
            print "must not have a closing tag\n";
            $together =~ s/<$block[\s]?[^>]*>//g;
        }
    }
    my @lines = split(/!!!!!!!!!!!/, $together);
    return \@lines;
}

sub getChildBlock
{
    my $blockFrag = shift;
    my $childTag = shift;
    my $mustContain = shift || '';
    my $org = $blockFrag;
    if($mustContain ne '')
    {
        my @splits = split(/<\/$childTag/, $blockFrag);
        foreach(@splits)
        {
            
            my $frag = $_;
            if($frag =~ /.*?<$childTag[\s]?[^>]*>.*?$mustContain/)
            {
                $blockFrag = $frag . '</'.$childTag.'>';
                # print "$blockFrag\n";
                # print "looping\n";
                # exit;
                last;
            }
        }
        $mustContain .= '.*?';
    }
    
    # print "blockfrag: $blockFrag\n";
    # print "childTag: $childTag\n";
    # print "mustContain: $mustContain\n";
    $blockFrag =~ s/.*?(<$childTag[\s]?[^>]*>.*?$mustContain<\/$childTag\s*>).*/$1/ ;
    # print "Responding with: $blockFrag\n";
    # $blockFrag = $org if($#howmany > 1); ## the regular expression went to far and included more blocks
    return $blockFrag;
}

sub convertUTFStuff
{
    my $lineRef = shift;
    my @lines = @{$lineRef};
    for my $b(0..$#lines)
    {
        @lines[$b] =~ s/[\x00-\x1f]//go;
        @lines[$b] =~ s/\n\r//g;
    }
    my $ret = join('!!!!!!!!!!!',@lines);
    return $ret;
}

sub getEADXMLFromFolder
{
    my @files;
    #Get all files in the directory path
    @files = @{dirtrav(\@files,$infolder)};

    return \@files;
}

sub dirtrav
{
    my @files = @{@_[0]};
    my $pwd = @_[1];
    opendir(DIR,"$pwd") or die "Cannot open $pwd\n";
    my @thisdir = readdir(DIR);
    closedir(DIR);
    foreach my $file (@thisdir)
    {
        if(($file ne ".") and ($file ne ".."))
        {
            if (-d "$pwd/$file")
            {
                push(@files, "$pwd/$file");
                @files = @{dirtrav(\@files,"$pwd/$file")};
            }
            elsif (-f "$pwd/$file")
            {
                push(@files, "$pwd/$file");
            }
        }
    }
    return \@files;
}


sub DESTROY
{
    print "I'm dying, deleting PID file $pidFile\n";
    closeBrowser();
    unlink $pidFile;
}

exit;
