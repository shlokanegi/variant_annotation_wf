import argparse
from subprocess import run
from cyvcf2 import VCF, Writer
import os
import sys
import hashlib


# function to write a VCF for one SV
# that VCF file is later used to build a pangenome
def write_single_sv_vcf(sv_info, vcf_path):
    outf = open(vcf_path, 'wt')
    outf.write("##fileformat=VCFv4.2\n")
    outf.write("#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\n")
    outf.write("{seqn}\t{pos}\t.\t{ref}\t{alt}\t.\t.\t.\n".format(seqn=sv_info['seqn'],
                                                                  pos=sv_info['start'],
                                                                  ref=sv_info['ref'],
                                                                  alt=sv_info['alt']))
    outf.close()
    bgzip_args = ["bgzip", "-c", vcf_path]
    vcf_path_gz = vcf_path + '.gz'
    with open(vcf_path_gz, 'w') as file:
        run(bgzip_args, check=True, stdout=file, stderr=sys.stderr, universal_newlines=True)
    tabix_args = ["tabix", vcf_path_gz]
    run(tabix_args, check=True, stdout=sys.stdout, stderr=sys.stderr, universal_newlines=True)
    return(vcf_path_gz)

# function to evaluate a SV
# sv_info is a dict with a 'svid', position and ref/alt sequences information
def evaluate_sv(sv_info, ref_fa_path, bam_path, output_dir, debug_mode=False, nb_cores=2):
    dump = open('/dev/null', 'w')
    # make VCF with just the one SV
    vcf_path = os.path.join(output_dir, sv_info['svid'] + ".vcf")
    vcf_path_gz = write_single_sv_vcf(sv_info, vcf_path)
    # decide on the region to consider (SV + flanks?)
    flank_size_vg = 50000
    region_coord_vg = '{}:{}-{}'.format(sv_info['seqn'],
                                        sv_info['start'] - flank_size_vg,
                                        sv_info['end'] + flank_size_vg)
    flank_size = 10000
    region_coord = '{}:{}-{}'.format(sv_info['seqn'],
                                     sv_info['start'] - flank_size,
                                     sv_info['end'] + flank_size)
    # make graph with SV
    construct_args = ["vg", "construct", "-a", "-m", "1024", "-S",
                      "-r", ref_fa_path, "-v", vcf_path_gz, "-R", region_coord_vg]
    vg_output_path = os.path.join(output_dir, sv_info['svid'] + ".vg")
    with open(vg_output_path, 'w') as file:
        run(construct_args, check=True, stdout=file, stderr=sys.stderr, universal_newlines=True)
    # extract reads
    extract_args = ["samtools", "view", "-h", bam_path, region_coord]
    sam_output_path = os.path.join(output_dir, sv_info['svid'] + ".sam")
    with open(sam_output_path, 'w') as file:
        run(extract_args, check=True, stdout=file, stderr=sys.stderr, universal_newlines=True)
    extract_args = ["samtools", "fasta", sam_output_path]
    fa_output_path = os.path.join(output_dir, sv_info['svid'] + ".fasta")
    with open(fa_output_path, 'w') as file:
        run(extract_args, check=True, stdout=file, stderr=dump, universal_newlines=True)
    # align reads to pangenome
    convert_args = ["vg", "convert", "-f", vg_output_path]
    gfa_output_path = os.path.join(output_dir, sv_info['svid'] + ".gfa")
    with open(gfa_output_path, 'w') as file:
        run(convert_args, check=True, stdout=file, stderr=sys.stderr, universal_newlines=True)    
    map_args = ["minigraph", "-t", str(nb_cores), "-c", gfa_output_path, fa_output_path]
    gaf_output_path = os.path.join(output_dir, sv_info['svid'] + ".gaf")
    with open(gaf_output_path, 'w') as file:
        run(map_args, check=True, stdout=file, stderr=dump, universal_newlines=True)    
    # genotype SV
    pack_output_path = os.path.join(output_dir, sv_info['svid'] + ".pack")
    pack_args = ["vg", "pack", "-t", str(nb_cores), "-e",
                 "-x", vg_output_path, "-o", pack_output_path, '-a', gaf_output_path]
    run(pack_args, check=True, stdout=sys.stdout, stderr=sys.stderr, universal_newlines=True)    
    call_args = ["vg", "call", "-t", str(nb_cores),
                 "-k", pack_output_path, '-v', vcf_path, vg_output_path]
    call_output_path = os.path.join(output_dir, sv_info['svid'] + ".called.vcf")
    with open(call_output_path, 'w') as file:
        run(call_args, check=True, stdout=file, stderr=sys.stderr, universal_newlines=True)    
    # update SV information or return a score
    score = -1
    for variant in VCF(call_output_path):
        ad = variant.format('AD')[0]
        score = float(ad[1]) / (ad[0] + ad[1])
    # remove intermediate files
    if not debug_mode:
        for ff in [sam_output_path, vg_output_path, fa_output_path, gfa_output_path,
                   gaf_output_path, pack_output_path, call_output_path,
                   vcf_path, vcf_path_gz, vcf_path_gz + '.tbi']:
            os.remove(ff)
    dump.close()
    return(score)

parser = argparse.ArgumentParser()
parser.add_argument('-b', help='BAM file (indexed)', required=True)
parser.add_argument('-f', help='reference FASTA file (indexed)', required=True)
parser.add_argument('-v', help='variants in VCF (can be bgzipped)', required=True)
parser.add_argument('-d', help='output directory', default='temp_valsv')
parser.add_argument('-o', help='output (annotated) VCF (will be bgzipped if ending in .gz)', default='out.vcf')
parser.add_argument('-t', help='number of threads used by the tools (vg and minigraph))', default=2)
args = parser.parse_args()

DEBUG_MODE = True

vcf = VCF(args.v)
vcf.add_info_to_header({'ID': 'VAL', 'Description': 'Validation score from vg genotyping',
    'Type':'Float', 'Number': '1'})
vcf_o = Writer(args.o, vcf)

# Read VCF and evaluate each SV
for variant in vcf:
    if len(variant.REF) > 30 or len(variant.ALT[0]) > 30:
        svinfo = {}
        svinfo['ref'] = variant.REF
        svinfo['alt'] = variant.ALT[0]
        svinfo['seqn'] = variant.CHROM
        svinfo['start'] = variant.start + 1
        svinfo['end'] = variant.end + 1
        seq = '{}_{}'.format(variant.REF, variant.ALT[0])
        seq = hashlib.sha1(seq.encode())
        svinfo['svid'] = '{}_{}_{}'.format(variant.CHROM,
                                              variant.start,
                                              seq.hexdigest())
        variant.INFO["VAL"] = evaluate_sv(svinfo, args.f, args.b, args.d, DEBUG_MODE, nb_cores=args.t)
    vcf_o.write_record(variant)

vcf_o.close()
vcf.close()