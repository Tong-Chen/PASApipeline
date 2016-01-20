#!/usr/bin/env perl

use strict;
use warnings;
use Time::localtime;
use FindBin;
use lib ($FindBin::Bin);
use Pasa_init;
use Pasa_conf;
use ConfigFileReader;
use Getopt::Long qw(:config no_ignore_case bundling pass_through);
use Cwd;
use File::Basename;

$ENV{PATH} = "$FindBin::Bin/../bin:$ENV{PATH}";

my ($opt_c, $opt_C, $opt_r, $opt_R, $opt_A, $opt_g, $opt_t, $opt_f, $opt_T, $opt_u, $opt_d, $opt_h, $opt_x, $opt_s, $opt_e,
	$ALT_SPLICE, $INVALIDATE_SINGLE_EXON_ESTS, $IMPORT_CUSTOM_ALIGNMENTS_GFF3,
	$splice_graph_assembler_flag,
    $ALIGNED_IS_TRANSCRIBED_ORIENT,
	$ANNOTS_GFF3, $opt_L, $STRINGENT_ALIGNMENT_OVERLAP, $GENE_OVERLAP,
    $SIM4_CHASER, $genetic_code, $TRANSDECODER, @PRIMARY_ALIGNERS,
    );


my $MAX_INTRON_LENGTH = 500000;
my $CPU = 2;
my $NUM_TOP_ALIGNMENTS = 1;

my $TDN_file; # file containing list of Trinity (full) de novo transcriptome assemblies. (used to find 'missing' genes in genome, among other types)

my %SUPPORTED_PRIMARY_ALIGNERS = map { + $_ => 1 } qw (gmap blat);

my $PASA_PIPELINE_CMD = join(" ", $0, @ARGV);
my $CUFFLINKS_GTF;


&GetOptions ( 'c=s' => \$opt_c,
              'C' => \$opt_C,
              'r' => \$opt_r,
              'R' => \$opt_R,
              'A' => \$opt_A,
              'g=s' => \$opt_g,
              't=s' => \$opt_t,
              'f=s' => \$opt_f,
              'T' => \$opt_T,
              'u=s' => \$opt_u,
			  'd' => \$opt_d,
              'h' => \$opt_h,
              'x' => \$opt_x,
              's=i' => \$opt_s,
			  'e=i' => \$opt_e,
              'INVALIDATE_SINGLE_EXON_ESTS' => \$INVALIDATE_SINGLE_EXON_ESTS,
              'IMPORT_CUSTOM_ALIGNMENTS_GFF3=s' => \$IMPORT_CUSTOM_ALIGNMENTS_GFF3,
              'USE_SPLICE_GRAPH_ASSEMBLER' => \$splice_graph_assembler_flag,
			  'MAX_INTRON_LENGTH|I=i' => \$MAX_INTRON_LENGTH,
              'APPLY_SIM4_CHASER' => \$SIM4_CHASER,
              'TRANSDECODER' => \$TRANSDECODER,
              'CPU=i' => \$CPU,
              'TDN=s' => \$TDN_file,
              
              'N=i' => \$NUM_TOP_ALIGNMENTS,
              
              'ALIGNERS=s' => \@PRIMARY_ALIGNERS,
              
              'cufflinks_gtf=s' => \$CUFFLINKS_GTF,


			  ## RNA-Seq options
              'transcribed_is_aligned_orient' => \$ALIGNED_IS_TRANSCRIBED_ORIENT,
			  			  

              'ALT_SPLICE' => \$ALT_SPLICE,
              

			  ## Annotation compare opts
			  'L' => \$opt_L,
			  'annots_gff3=s' => \$ANNOTS_GFF3,
              'GENETIC_CODE=s' => \$genetic_code,


			  ## clustering options:
			  'stringent_alignment_overlap=f' => \$STRINGENT_ALIGNMENT_OVERLAP,
			  'gene_overlap=f' => \$GENE_OVERLAP,
			  
			  
			  );

if (@ARGV) {
    die "Error, do not recognize opts: @ARGV\n";
}


$|=1;
our $SEE = 0;

open (STDERR, "&>STDOUT");

my $usage =  <<_EOH_;

############################# Options ###############################
# 
#   * indicates required
#
#
# -c * <filename>  configuration file
#
# // spliced alignment settings
# --ALIGNERS <string>   aligners (available options include: gmap, blat... can run both using 'gmap,blat')
# -N <int>              max number of top scoring alignments (default: 1)
# --MAX_INTRON_LENGTH|-I  <int>         (max intron length parameter passed to GMAP or BLAT)  (default: 100000)
# --IMPORT_CUSTOM_ALIGNMENTS_GFF3 <filename> :only using the alignments supplied in the corresponding GFF3 file.
# --cufflinks_gtf <filename>      :incorporate cufflinks-generated transcripts
#
#
# // actions
# -C               flag, create MYSQL database
# -r               flag, drop MYSQL database if -C is also given. This will DELETE all your data and it is irreversible.
# -R               flag, run alignment/assembly pipeline.
# -A               (see section below; can use with opts -L and --annots_gff3)  compare to annotated genes.
# --ALT_SPLICE     flag, run alternative splicing analysis

# // input files
# -g * <filename>  genome sequence FASTA file (should contain annot db asmbl_id as header accession.)
# -t * <filename>  transcript db 
# -f <filename>    file containing a list of fl-cdna accessions.
# --TDN <filename> file containing a list of accessions corresponding to Trinity (full) de novo assemblies (not genome-guided)
#
# // polyAdenylation site identification  ** highly recommended **
# -T               flag,transcript db were trimmed using the TGI seqclean tool.
#    -u <filename>   value, transcript db containing untrimmed sequences (input to seqclean)
#                  <a filename with a .cln extension should also exist, generated by seqclean.>
#
#
# // Jump-starting or prematurely terminating
# -x               flag, print cmds only, don\'t process anything. (useful to get indices for -s or -e opts below)
# -s <int>         pipeline index to start running at (avoid rerunning searches). 
# -e <int>         pipeline index where to stop running, and do not execute this entry. 
#
#
# Misc:
# --TRANSDECODER   flag, run transdecoder to identify candidate full-length coding transcripts
# --CPU <int>      multithreading (default: $CPU)
# -d               flag, Debug 
# -h               flag, print this option menu and quit
#
#########
#
# // Transcript alignment clustering options (clusters are fed into the PASA assembler):
#
#       By default, clusters together transcripts based on any overlap (even 1 base!).
#
#    Alternatives:
#
#        --stringent_alignment_overlap <float>  (suggested: 30.0)  overlapping transcripts must have this min % overlap to be clustered.
#
#        --gene_overlap <float>  (suggested: 50.0)  transcripts overlapping existing gene annotations are clustered.  Intergenic alignments are clustered by default mechanism.
#               * if --gene_overlap, must also specify --annots_gff3  with annotations in gff3 format (just examines 'gene' rows, though).
#
#
#
# --INVALIDATE_SINGLE_EXON_ESTS    :invalidates single exon ests so that none can be built into pasa assemblies.
#
#
# --transcribed_is_aligned_orient   flag for strand-specific RNA-Seq assemblies, the aligned orientation should correspond to the transcribed orientation.
#
#
################
#
#  // Annotation comparison options (used in conjunction with -A at top).
#   
#  -L   load annotations (use in conjunction with --annots_gff3)
#  --annots_gff3 <filename>  existing gene annotations in gff3 format.
#  --GENETIC_CODE (default: universal, options: Euplotes, Tetrahymena, Candida, Acetabularia)
#
###################### Process Args and Options #####################



_EOH_

    ;

# --USE_SPLICE_GRAPH_ASSEMBLER  (use at own risk! alpha-state)   // likely will cause the alt-splice analysis to break...


if ($opt_h) {die $usage;}
my $DEBUG = $opt_d;

my $full_length_cdna_listing = $opt_f || "NULL"; ## NULL filename results in graceful exit, used when nothing exists to load.
my $RUN_PIPELINE = $opt_R;
#$ALT_SPLICE = $RUN_PIPELINE;  ## always run alt-splice analysis in alignment-assembly pipeline.
my $COMPARE_TO_ANNOT = $opt_A;
my $CREATE_MYSQL_DB = $opt_C;
my $STARTING_INDEX = (defined($opt_s)) ? $opt_s : undef;
my $ENDING_INDEX = (defined($opt_e)) ? $opt_e : undef;

if ($STARTING_INDEX && $CREATE_MYSQL_DB) {
    print STDERR "WARNING, not creating mysql database since in resume mode, as per -s parameter specified.\n";
    $CREATE_MYSQL_DB = 0;
}

my $PRINT_CMDS_ONLY = $opt_x;
my $configfile = $opt_c or die $usage;

if ($splice_graph_assembler_flag) {
    $splice_graph_assembler_flag = "-X";
}
else {
    $splice_graph_assembler_flag = "";
}


## Read configuration file.
my %config = &readConfig($configfile);

my $mysql_db = $config{MYSQLDB} or die "Error, couldn't extract mysql_db name from config file " . cwd() . "/$configfile\n";
my $mysql_server = &Pasa_conf::getParam("MYSQLSERVER");
my $user = &Pasa_conf::getParam("MYSQL_RW_USER");
my $password = &Pasa_conf::getParam("MYSQL_RW_PASSWORD");

my $MYSQLstring = $mysql_db; #"$mysql_db:$mysql_server";

my %advanced_prog_opts = &parse_advanced_prog_opts();

## Add a few env variables:

my $UTILDIR = "$ENV{PASAHOME}/scripts"; 
my $PLUGINS_DIR = "$ENV{PASAHOME}/pasa-plugins";


unless ($RUN_PIPELINE || $COMPARE_TO_ANNOT || $ALT_SPLICE || $CREATE_MYSQL_DB) {
    print STDERR "Sorry, nothing to do here.\n";
    exit(1);
}

if ($CREATE_MYSQL_DB) {
    
    if (&Pasa_conf::getParam("USE_PASA_DB_SETUP_HOOK") =~ /true/i) {
        &execute_custom_PASA_DB_setup_hook();
    }
    else {
        ## going the old fashioned way
	my $params = "-c $opt_c -S $ENV{PASAHOME}/schema/cdna_alignment_mysqlschema";
	$params .= ' -r' if $opt_r;
        &process_cmd(
                     {
                         prog => "$UTILDIR/create_mysql_cdnaassembly_db.dbi",
                         params => $params,
                         input => undef,
                         output => undef
                         }
                     );
        
    }
}



## directory to store voluminous logging info from pasa processes
my $PASA_LOG_DIR = "pasa_run.log.dir";
if (! -d $PASA_LOG_DIR) {
    mkdir ($PASA_LOG_DIR) or die "Error, cannot mkdir $PASA_LOG_DIR"; 
}

## Analyze pipeline run options.

my $genome_db = $opt_g or die "Must specify genome_db.\n\n$usage\n";
unless (-s $genome_db) {
    die "Can't find $genome_db\n\n";
}
my $transcript_db = $opt_t or die "Must specify transcript_db.\n\n$usage\n";
unless (-s $transcript_db) {
    die "Can't find $transcript_db\n";
}


my $POLYA_IDENTIFICATION = $opt_T;
my $untrimmed_transcript_db = $opt_u;
if ($POLYA_IDENTIFICATION) {
    unless (-s $untrimmed_transcript_db) {
        die "ERROR, cannot find untrimmed transcript database ($untrimmed_transcript_db)\n";
    }
    
    if ($transcript_db eq $untrimmed_transcript_db) {
        die "ERROR, your transcript db and untrimmed-transcript db are named identically.\n";
    }
    
    unless ($transcript_db =~ /$untrimmed_transcript_db/) {
        print STDERR "WARNING: The transcript database ($transcript_db) name appears unrelated to the untrimmed transcript database ($untrimmed_transcript_db)\n";
        print STDERR "press cntrl-c to stop the job and rerun using different parameters.\n";
        sleep(10);
    }
    unless ($transcript_db =~ /\.clean/) {
        print STDERR "WARNING: The transcript database ($transcript_db) lacks the .clean extension generated by seqclean.  Are you certain you are using a set of trimmed transcript sequences?\n";
        print STDERR "press cntrl-c to stop the job and rerun using different parameters.\n";
        sleep(10);
    }
    
    unless (-s "$untrimmed_transcript_db.cln") {
        die "ERROR: I cannot locate the .cln file generated by seqclean, expecting $untrimmed_transcript_db.cln\n\n";
    }
}



if ($RUN_PIPELINE) {

	## Build Pipeline Command List

    @PRIMARY_ALIGNERS = split(/,/,join(',',@PRIMARY_ALIGNERS)); # unpack list of aligners in case commas are used.
    
    unless (@PRIMARY_ALIGNERS || $IMPORT_CUSTOM_ALIGNMENTS_GFF3) {
        die "Error, must specify at least one primary aligner via --ALIGNER or imported via --IMPORT...";
    }
    foreach my $aligner (@PRIMARY_ALIGNERS) {
        unless ($SUPPORTED_PRIMARY_ALIGNERS{$aligner}){
            die "Error, do not recognize aligner: [$aligner] ";
        }
    }
    

	
    my $TDN_param = "";
    if ($TDN_file) {
        $TDN_param = "-T $TDN_file";
    }
    
	my @cmds = ( { prog => "$UTILDIR/upload_transcript_data.dbi",
				   params => "-M $mysql_db -t $transcript_db $TDN_param -f $full_length_cdna_listing ",
				   input => undef,
				   output => undef,
                 }
        );
	
    if (@PRIMARY_ALIGNERS) {
        push (@cmds, { prog => "$UTILDIR/run_spliced_aligners.pl",
                       params => "--aligners " . join(",", @PRIMARY_ALIGNERS) . " --genome $genome_db"
                           . " --transcripts $transcript_db -I $MAX_INTRON_LENGTH -N $NUM_TOP_ALIGNMENTS --CPU $CPU",
                           input => undef,
                           output => undef,
              } );
        
        foreach my $aligner (@PRIMARY_ALIGNERS) {
            
            push (@cmds, { prog => "$UTILDIR/import_spliced_alignments.dbi",
                           params => "-M $mysql_db  -A $aligner -g $aligner.spliced_alignments.gff3",
                           input => undef,
                           output => undef,
                  },
                );    
        }
    }
    
    if ($IMPORT_CUSTOM_ALIGNMENTS_GFF3) {
		
        push (@cmds, { prog => "$UTILDIR/import_spliced_alignments.dbi",
                       params => "-M $mysql_db -A custom -g $IMPORT_CUSTOM_ALIGNMENTS_GFF3",
                       input => undef,
                       output => undef,
              },
            );    
        
        push (@PRIMARY_ALIGNERS, "custom");
        
	}

    if ($CUFFLINKS_GTF) {

        push (@cmds, 
              
              # first convert it to gff3-alignment format
              
              { prog => "$UTILDIR/../misc_utilities/cufflinks_gtf_to_alignment_gff3.pl",
                params => "$CUFFLINKS_GTF",
                input => undef,
                output => "$CUFFLINKS_GTF.gff3",
            },
              
              # convert to fasta format:
              { 
                  prog => "$UTILDIR/../misc_utilities/cufflinks_gtf_genome_to_cdna_fasta.pl",
                  params => "$CUFFLINKS_GTF $genome_db",
                  input => undef,
                  output => "$CUFFLINKS_GTF.fasta",
              },
              
              # upload fasta entries into mysqldb
              {
                  prog => "$UTILDIR/upload_transcript_data.dbi",
                  params => "-M $mysql_db -t $CUFFLINKS_GTF.fasta",
                  input => undef,
                  output => undef,
              },

              # upload the cufflinks transcript structures
              {
                  prog => "$UTILDIR/import_spliced_alignments.dbi",
                  params => "-M $mysql_db -A cufflinks -g $CUFFLINKS_GTF.gff3",
                  input => undef,
                  output => undef,
              },
              
              # combine the cufflinks transcripts with the other transcripts for use in validation and other downstream studies
              {
                  prog => "cat",
                  params => "$transcript_db $CUFFLINKS_GTF.fasta",
                  input => undef,
                  output => "__all_transcripts.fasta",
              }



              );

        ## reset the transcript db to the combined database
        $transcript_db = "__all_transcripts.fasta";
        
    }
    
    
	##############################
	## done aligning transcripts.
	##############################
    
    if ($TRANSDECODER) {
        
        ## Identify likely full-length transcripts via TransDecoder plug-in
        
        my $td_params = "-t $transcript_db ";
        if ($genetic_code) {
            $td_params .= " -G $genetic_code";
        }
        if ($ALIGNED_IS_TRANSCRIBED_ORIENT) {
            $td_params .= " -S ";
        }
        
        push (@cmds, { prog => "$PLUGINS_DIR/transdecoder/transcripts_to_best_scoring_ORFs.pl",
                       params => $td_params,
                       input => undef,
                       output => undef,
              },
            );
        
        
        ## get the full-length entries
        
        my $transdecoder_gff3_file = basename("$transcript_db.transdecoder.gff3");        
        my $td_full_length_file = "$transdecoder_gff3_file.fl_accs";
       
        
        push (@cmds, { prog => "$UTILDIR/extract_FL_transdecoder_entries.pl",
                       params => $transdecoder_gff3_file, 
                       input => undef,
                       output => $td_full_length_file,
              },


              ## update the full-length status
              { prog => "$UTILDIR/update_fli_status.dbi",
                params => "-M $mysql_db -f $td_full_length_file",
                input => undef,
                output => undef,
              },

            );
        
    }
    
	
	push (@cmds, 
		  
		  
		  # validate the alignment data:
		  {
			  prog => "$UTILDIR/validate_alignments_in_db.dbi",
			  params => "-M $mysql_db -g $genome_db -t $transcript_db --MAX_INTRON_LENGTH $MAX_INTRON_LENGTH --CPU $CPU ", # creates output file: $mysql_db.${map_program}_validations that is read in below.
			  input => undef,
			  output => "alignment.validations.output",
		  },
		  
		  # update the alignment validation results.
		  {
			  prog => "$UTILDIR/update_alignment_status.dbi",
			  params => "-M $mysql_db",
			  input => "alignment.validations.output",
			  output => "$PASA_LOG_DIR/alignment.validation_loading.output",
		  },
        );


    foreach my $map_program (@PRIMARY_ALIGNERS) {
        
        push (@cmds, 
              
              # write the gff3 file describing the valid alignments:
              { 
                  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
                  params => "-M $mysql_db -v -A -P ${map_program}",
                  input => undef,
                  output => "$mysql_db.valid_${map_program}_alignments.gff3"
              },
              
              # do again, but write in BED format
              { 
                  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
                  params => "-M $mysql_db -v -A -P ${map_program} -B ",
                  input => undef,
                  output => "$mysql_db.valid_${map_program}_alignments.bed"
              },

              # do again, but write in GTF format
              { 
                  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
                  params => "-M $mysql_db -v -A -P ${map_program} -T ",
                  input => undef,
                  output => "$mysql_db.valid_${map_program}_alignments.gtf"
              },
              
              
              # write the gff3 file describing the failures:
              { 
                  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
                  params => "-M $mysql_db -f -A -P ${map_program}",
                  input => undef,
                  output => "$mysql_db.failed_${map_program}_alignments.gff3"
              },
              
              # do again, but write in BED format
              { 
                  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
                  params => "-M $mysql_db -f -A -P ${map_program} -B ",
                  input => undef,
                  output => "$mysql_db.failed_${map_program}_alignments.bed"
              },
              
              # do again, but write in BED format
              { 
                  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
                  params => "-M $mysql_db -f -A -P ${map_program} -T ",
                  input => undef,
                  output => "$mysql_db.failed_${map_program}_alignments.gtf"
              },
              
              
            );
        
    }
    

	if ($INVALIDATE_SINGLE_EXON_ESTS) {
		push (@cmds, 
			  {
				  prog => "$UTILDIR/invalidate_single_exon_ESTs.dbi",
				  params => "-M $mysql_db",
				  input => undef,
				  output => "$PASA_LOG_DIR/invalidating_single_exon_alignments.output",
				  },
			);
	}
	

	## PolyA-site analysis, help assign transcribed orientations to intron-less alignments.
	if ($POLYA_IDENTIFICATION) {
		push (@cmds, (
					  ## Analyze polyA site-inferring transcripts
					  {
						  prog => "$UTILDIR/polyA_site_transcript_mapper.dbi",
						  params => "-M $mysql_db -c $untrimmed_transcript_db.cln "
							  . "-g $genome_db -t $untrimmed_transcript_db",
							  
							  input => undef,
							  output => "$PASA_LOG_DIR/polyAsite_analysis.out"
						  },
					  
					  ## Summarize PolyA site findings:
					  { 
						  prog => "$UTILDIR/polyA_site_summarizer.dbi",
						  params => "-M $mysql_db -g $genome_db ",
						  input => undef,
						  output => "$mysql_db.polyAsites.fasta",
					  },
					  
					  )
			  );
	}

	
    if ($ALIGNED_IS_TRANSCRIBED_ORIENT) {
        
        push (@cmds, 
              
              {
                  prog => "$UTILDIR/set_spliced_orient_transcribed_orient.dbi",
                  params => "-M $mysql_db",
                  input => undef,
                  output => "$PASA_LOG_DIR/setting_aligned_as_transcribed_orientation.output",
              },
              
              );
    }
    
		
	#####################################
	## Cluster the transcript alignments.
	#####################################

	if ($STRINGENT_ALIGNMENT_OVERLAP) {
		
		## require substantial overlap between neighboring transcript alignments for clustering.

		push (@cmds, 
			  
			  { 
				  prog => "$UTILDIR/assign_clusters_by_stringent_alignment_overlap.dbi",
				  params => "-M $mysql_db -L $STRINGENT_ALIGNMENT_OVERLAP", # require all alignments are valid here.
				  input => undef,
				  output => "$PASA_LOG_DIR/cluster_reassignment_by_stringent_overlap.out"
				  },
			  );
		
	}
	elsif ($GENE_OVERLAP) {
		
		# define transcript overlap clusters based on mapping to overlapping annotated gene models (annotation-informed).
		## transcripts in intergenic regions are clustered using the default method.
	
		unless ($ANNOTS_GFF3) {
			die "Error, need --annots_gff3 specified for clustering genes based on gene overlaps.    ";
		}
		
	
		push (@cmds, 
			  { 
				  prog => "$UTILDIR/assign_clusters_by_gene_intergene_overlap.dbi",
				  params => "-M $mysql_db -G $ANNOTS_GFF3 -L $GENE_OVERLAP", # require all alignments are valid here.
				  input => undef,
				  output => "$PASA_LOG_DIR/alignment_cluster_reassignment.out"
				  },
			  );
	}
	else {
		## Default transcript clustring based on overlap piles (any overlap with same transcribed orientation)
		
		push (@cmds,
			  
			  { 
				  prog => "$UTILDIR/reassign_clusters_via_valid_align_coords.dbi",
				  params => "-M $mysql_db ", 
				  input => undef,
				  output => "$PASA_LOG_DIR/cluster_reassignment_by_valid_alignment_coords.default.out"
				  },
			  );
	}


    if ($NUM_TOP_ALIGNMENTS > 1 || scalar(@PRIMARY_ALIGNERS) == 0) {

        ## ensure only one valid alignment per cdna per cluster
        # (doesn't make sense to assemble a blat and gsnap alignment for the same cDNA.
        # Instead, just keep the highest scoring alignment of that cdna at that locus )
        
        push (@cmds, 
              { 
                  prog => "$UTILDIR/ensure_single_valid_alignment_per_cdna_per_cluster.pl",
                  params => "-M $mysql_db",
                  input => undef,
                  output => "$PASA_LOG_DIR/ensuring_single_valid_alignment_per_cdna_per_cluster.log",
              },
              );
    }
    
    
	####################################################
	## PASA assembly of clustered transcript alignments
	####################################################

	push (@cmds, 
				  
	  
		  # build the assemblies:
		  {
			  prog => "$UTILDIR/assemble_clusters.dbi",
			  params => "-G $genome_db  -M $mysql_db $splice_graph_assembler_flag -T $CPU ",
			  input => undef,
			  output => "$mysql_db.pasa_alignment_assembly_building.ascii_illustrations.out"
		  },
		  
		  
		  # load the assemblies:
		  {
			  prog => "$UTILDIR/assembly_db_loader.dbi",
			  params => "-M $mysql_db",
			  input => undef,
			  output => "$PASA_LOG_DIR/alignment_assembly_loading.out"
		  },
		  
		  
		  # build the subclusters:
		  {
			  prog => "$UTILDIR/subcluster_builder.dbi",
			  params => "-G $genome_db -M $mysql_db ",
			  input => undef,
			  output => "$PASA_LOG_DIR/alignment_assembly_subclustering.out"
		  },
		  
		  
		  # populate the alignment field for assemblies:
		  {
			  prog => "$UTILDIR/populate_mysql_assembly_alignment_field.dbi",
			  params => "-M $mysql_db -G $genome_db",
			  input => undef,
			  output => undef
			  },
		  
		  # populate pasa assembly sequences:
		  {
			  prog => "$UTILDIR/populate_mysql_assembly_sequence_field.dbi",
			  params => "-M $mysql_db -G $genome_db",
			  input => undef,
			  output => undef
			  },
		  
		  
		  # load the subclusters:
		  
		  {
			  prog => "$UTILDIR/subcluster_loader.dbi",
			  params => "-M $mysql_db ",
			  input => "$PASA_LOG_DIR/alignment_assembly_subclustering.out",
			  output => undef
			  },
		  
		  # create gene models based on pasa assembies and long orfs (note, this is only used in web displays!, see documentation for more robust de novo annotation based on transcripts.)
		  
		  { 
			  prog => "$UTILDIR/alignment_assembly_to_gene_models.dbi",
			  params => "-M $mysql_db -G $genome_db",
			  input => undef,
			  output => undef,
		  },
		  

		  ############################################################
		  # write summary GFF3 files for PASA assemblies:
		  # and other summary reports
		  ############################################################
		  

          { # gff3 format
			  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
			  params => "-M $mysql_db -a ",
			  input => undef,
			  output => "$mysql_db.pasa_assemblies.gff3"
			  },
          
          { # bed format
			  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
			  params => "-M $mysql_db -a -B ",
			  input => undef,
			  output => "$mysql_db.pasa_assemblies.bed"
			  },
          
          { # gtf format
			  prog => "$UTILDIR/PASA_transcripts_and_assemblies_to_GFF3.dbi",
			  params => "-M $mysql_db -a -T ",
			  input => undef,
			  output => "$mysql_db.pasa_assemblies.gtf"
			  },
		  
          

		  # describe assemblies in the pasa alignment format, which can be used with accessory scripts.
		  { 
			  prog => "$UTILDIR/describe_alignment_assemblies_cgi_convert.dbi",
			  params => "-M $mysql_db ",
			  input => undef,
			  output => "$mysql_db.pasa_assemblies_described.txt",
			  
		  },
		  		  		  
		  );
	

	###############################
	#  Pipeline command execution:
	###############################

    ## write them all to a log file for safe keeping:
    {
        open (my $ofh, ">$mysql_db.run.$$.cmds") or die $!;
        print $ofh "PASA Pipeline CMD:\t$PASA_PIPELINE_CMD\n\n";

        my $counter = 0;
        foreach my $cmd (@cmds) {
            $counter++;
            print $ofh "CMD[$counter]:\t" . &reconstruct_cmd_line($cmd) . "\n\n";
        }
        close $ofh;
    }
    
    
    my $i = 1;
    if ($STARTING_INDEX) {
        while ($i < $STARTING_INDEX) {
            shift @cmds;
            $i++;
        }
    }
    
    my $total_cmds = scalar(@cmds);
    foreach my $cmd (@cmds) {
        if (defined($ENDING_INDEX) && $i >= $ENDING_INDEX) {
            print STDERR "ENDING_INDEX($ENDING_INDEX) reached. Stopping here. Resume with -s ($i).\n\n";
            exit(0);
        }
        
        &process_cmd($cmd, "$i/$total_cmds");
        $i++;
    }
}


######################################
##  Annotation Comparison
######################################


if ($COMPARE_TO_ANNOT) {

	if ($opt_L) {

		unless ($ANNOTS_GFF3) {
			die "Error, must set --annots_gff3 for auto-loading of gene annotations";
		}

		my $cmd = { 
			prog => "$UTILDIR/Load_Current_Gene_Annotations.dbi",
			params => "-c $configfile -g $genome_db -P $ANNOTS_GFF3 ",
			input => undef,
			output => "$PASA_LOG_DIR/output.annot_loading.$$.out",
		};
		
		&process_cmd($cmd);
	}
	
    ## compare to annotation:
    my $genetic_code_opt = ($genetic_code) ? "--GENETIC_CODE $genetic_code" : "";
    my $cmd = {
        prog => "$UTILDIR/cDNA_annotation_comparer.dbi",
        params => "-G $genome_db --CPU $CPU -M $MYSQLstring $genetic_code_opt",
        input => undef,
        output => "$PASA_LOG_DIR/$mysql_db.annotation_compare.$$.out"  ## TODO: use compare_id and annot_version values for file naming. Ditto for below and other relevant places.
        };
    
    &process_cmd($cmd);
	
	$cmd = { 
        prog => "$UTILDIR/dump_valid_annot_updates.dbi",
        params => "-M $MYSQLstring -V -R -g $genome_db",
        input => undef,
        output => "$mysql_db.gene_structures_post_PASA_updates.$$.gff3",
    };
    
    &process_cmd($cmd);

	## write it in BED format:
	$cmd = {
		prog => "$UTILDIR/../misc_utilities/gff3_file_to_bed.pl",
		params => "$mysql_db.gene_structures_post_PASA_updates.$$.gff3",
		input => undef,
		output => "$mysql_db.gene_structures_post_PASA_updates.$$.bed",
	};
	
	&process_cmd($cmd);
    
    
}

######################################
## Alternative Splicing Analysis
######################################


if ($ALT_SPLICE && !$COMPARE_TO_ANNOT) { #this has bitten me before. do alt-splice analysis separately from annot comparison. plus, only do it once.
    
    my $cmd = { 
        prog => "$UTILDIR/classify_alt_splice_isoforms.dbi",
        params => "-M $MYSQLstring -G $genome_db -T $CPU ",
        input => undef,
        output => "$PASA_LOG_DIR/alt_splicing_analysis.out",
    };
    
    &process_cmd($cmd);
    
    $cmd = {
        prog => "$UTILDIR/find_alternate_internal_exons.dbi",
        params => "-M $MYSQLstring -G $genome_db",
        input => undef,
        output => "$PASA_LOG_DIR/alt_internal_exon_finding.out",
    };
    
    &process_cmd($cmd);

    $cmd = { 
        prog => "$UTILDIR/classify_alt_splice_as_UTR_or_protein.dbi",
        params => "-M $MYSQLstring -G $genome_db",
        input => undef,
        output => "$PASA_LOG_DIR/alt_splice_FL_FL_compare",
    };

    &process_cmd($cmd);


    $cmd = {
        prog => "$UTILDIR/report_alt_splicing_findings.dbi",
        params => "-M $MYSQLstring ", 
        input => undef,
        output => undef,  ## actually writes the files:  indiv_splice_labels_and_coords.dat and alt_splice_label_combinations.dat
    };

    &process_cmd($cmd);


    $cmd = {
        prog => "$UTILDIR/splicing_variation_to_splicing_event.dbi",
        params => "-M $MYSQLstring ",
        input => undef,
        output => "$mysql_db.alt_splicing_events_described.txt",
    };

    &process_cmd($cmd);
    
	
	$cmd = {
		prog => "$UTILDIR/comprehensive_alt_splice_report.dbi",
		params => "-M $MYSQLstring ",
		input => undef,
		output => "$mysql_db.alt_splicing_supporting_evidence.txt",
	};
	
	&process_cmd($cmd);
	
	
}


print "\n\n\n";
print "##########################################################################\n";
print "Finished.  Please visit the Assembly and Annotation Comparison results at:\n" 
    . &Pasa_conf::getParam("BASE_PASA_URL") . "/status_report.cgi?db=$config{MYSQLDB}\n";
print "##########################################################################\n\n\n";



exit(0);

####
sub process_cmd {
    my $cmd = shift;
    my $note = shift;
    
	unless (defined $note) {
		$note = "";
	}
    
    print "\n\n## Processing CMD: $note\n"; 
    
    my $construct_cmd = &reconstruct_cmd_line($cmd);
    
    
    print &mytime."CMD: $construct_cmd\n";
    
    #print STDERR "====\nPATH SETTING CURRENTLY: " . $ENV{PATH} . "\n====\n";
    
    unless ($PRINT_CMDS_ONLY) {
        
        my $retvalue = system $construct_cmd;
        if ($retvalue) {
            my ($index, $total) = split(m|/|, $note);
            die "\n\nERROR: The following command died with exit code ($retvalue):\n$construct_cmd\n\nMust re-run pipeline starting at index [$index] via running Launch_PASA_pipeline with parameter \'-s $index\' (exclude param \'-C\' since db already created)\n\n";
        }
    }
}


sub reconstruct_cmd_line {
    my ($cmd) = @_;

    my ($prog, $params, $input, $output) = ($cmd->{prog}, $cmd->{params}, $cmd->{input}, $cmd->{output});
    
    ## examine cmd for advanced option settings:
    my $progname = $prog;
    $progname =~ s/^.*\/(\S+)$/$1/;
    #print "ProgName: $progname\n";
    if (my $adv_opts = $advanced_prog_opts{$progname}) {
        $params .= " $adv_opts";
    }
    
    ## Construct the command from its parts.
    my $construct_cmd = "$prog $params";
    if (defined($input)) {
        $construct_cmd .= " < $input ";
    }
    if (defined($output)) {
        $construct_cmd .= " > $output";
    }

    return($construct_cmd);
}




####
sub parse_advanced_prog_opts {
    my %opts;
    foreach my $key (keys %config) {
        if ($key =~ /:/) {
            my ($prog, $opt) = split (/:/, $key);
            my $value = $config{$key};
            if ($value =~ /\<__/) { next; } #template parameter unchanged.
            $opts{$prog} .= " $opt $value";
        }
    }
    return (%opts);
}


####
sub execute_custom_PASA_DB_setup_hook {
    
    &Pasa_conf::call_hook("HOOK_PASA_DB_SETUP", $mysql_db);
    
    return;
}

sub mytime() {
    my $hour =
        localtime->hour() < 10 ? '0' . localtime->hour() : localtime->hour();
    my $min = localtime->min() < 10 ? '0' . localtime->min() : localtime->min();
    my $sec = localtime->sec() < 10 ? '0' . localtime->sec() : localtime->sec();
    return "$hour:$min:$sec\t";
}

