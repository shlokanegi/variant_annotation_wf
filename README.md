# Variant annotation

Variant annotation workflow

- Variants are annotated with their predicted impact on the genes using SNPeff
- Then with public variant databases:
    - Small variants are annotated with with gnomAD's allele frequencies, conservation/CADD/MetaRNN scores, and ClinVar's clinical significance.
    - Structural variants are annotated with the frequency in SV catalogs, and their overlap with dbVar clinical SVs, or DGV.
- Structural variants can also be re-genotyped from the long reads to compute the read support and help rank/filter them by confidence.

The workflow was written in 

- WDL: see [wdl/workflow.wdl](wdl/workflow.wdl) and [WDL section](#wdl) below.
- Snakemake: see [workflow/Snakefile](workflow/Snakefile) (and `config`, `profile` folders) and [Snakemake section](#snakemake) below.

## Input

The worklow annotates a VCF file containing small variants and structural variants (SVs).
Mapped reads should also be provided to perform some QC on the SVs.

After [preparing the annotation files](#prepare-annotation-files), jump to the [WDL]() or [Snakemake]() sections to run the workflow.

## Prepare annotation files

### SnpEff

```sh
wget https://snpeff.blob.core.windows.net/databases/v5_1/snpEff_v5_1_GRCh38.105.zip
unzip snpEff_v5_1_GRCh38.105.zip
```

### gnomAD

To reduce the size of the VCF with the variants in gnomAD, keeping only the field that we want to use (AF):

```sh
for CHR in `seq 1 22` X Y
do
    curl https://storage.googleapis.com/gcp-public-data--gnomad/release/3.0/vcf/genomes/gnomad.genomes.r3.0.sites.chr${CHR}.vcf.bgz | zcat | bcftools annotate -x ^INFO/AF,ID,FILTER,QUAL -e 'FILTER~"AC0"' -Oz -o gnomad_chr.genomes.r3.0.sites.chr${CHR}.vcf.gz
done
bcftools concat gnomad_chr.genomes.r3.0.sites.chr*.vcf.gz | bcftools sort -Oz -o gnomad.genomes.r3.0.sites.small.vcf.bgz -m 3G
rm gnomad_chr.genomes.r3.0.sites.chr*.vcf.gz
```

The final bgzipped VCF is only 4.5G. 

### dbNSFP

To reduce the size of the dbNSFP database used by SNPeff:

```sh
## download dbNSFP zip from https://sites.google.com/site/jpopgen/dbNSFP
## list files in the zip
unzip -l dbNSFP4.4a.zip
## list columns in full txt file. helps finding/double-checking the column numbers we want to keep
unzip -p dbNSFP4.4a.zip dbNSFP4.4a_variant.chr1.gz | zcat | head -1 | awk 'BEGIN{RS="\t"}{N=N+1;print N" "$0}' | less
## keep only some columns. gzip to control the size of temporary files and use multi-threaded gzip (pigz) to speed up a bit
unzip -p dbNSFP4.4a.zip dbNSFP4.4a_variant.chr1.gz | zcat | head -1 | cut -f 1-4,77-79,128-130,165-167,676 | gzip > temp.txt.gz
for CHR in `seq 1 22` X Y M
do
    unzip -p dbNSFP4.4a.zip dbNSFP4.4a_variant.chr${CHR}.gz | zcat | sed 1d | cut -f 1-4,77-79,128-130,165-167,676 | pigz -c -p 4 >> temp.txt.gz
done
## bgzip instead of gzip
unpigz -c -p 4 temp.txt.gz | bgzip > dbNSFP4.4a.small.txt.gz
## index with tabix
tabix -b 2 -e 2 -s 1 dbNSFP4.4a.small.txt.gz
```

If we keep only information about GERP, CADD, MetaRNN, and ALFA, the file size decreases from 35G to about 2G.

### AnnotSV

To also use the GeneHancer database for enhancers, download manually from [the GeneHancer website](https://www.genecards.org/Guide/Datasets).
Then download the `GeneHancer-v5.9-for-AnnotSV.zip` file.

```sh
docker run -it -v `pwd`:/app -w /app -u `id -u $USER` quay.io/jmonlong/annotsv:3.4
# - # IN DOCKER CONTAINER
cp -r /build/AnnotSV .
cd AnnotSV
PREFIX=. make install-human-annotation
cd share/AnnotSV/Annotations_Human/FtIncludedInSV/RegulatoryElements
cp /app/GeneHancer-v5.9-for-AnnotSV.zip .
unzip GeneHancer-v5.9-for-AnnotSV.zip
cd ../../../../../
AnnotSV -SVinputFile tests/AnnotSV/test_06_VCFfromLumpy/input/test1.vcf -outputDir temp_out -annotationsDir share/AnnotSV
mv share/AnnotSV ../AnnotSV_annotations
cd ..
rm -fr AnnotSV
# - # OUT DOCKER CONTAINER
```

### Misc annotations in R object

`annotation_database.RData`

*Details and link soon...*

### Tandem repeat expansion in public controls

`hprc-hgsvc-tr-catalog.tsv.gz`

*Details and link soon...*

### ClinVar VCF

*Details soon...*

## Running the workflow

### WDL

The input JSON should contain a `VCF` field with the path to the VCF file to annotate.

See [test/test.inputs.bam.json](test/test.inputs.bam.json) for an example.

For instance, running the workflow locally with miniwdl:

```sh
miniwdl run --as-me -i test/test.inputs.bam.json wdl/workflow.wdl
```

Below are more details about the other input parameters.

#### Gene annotation

If `SNPEFF_DB` and `SNPEFF_DB_NAME` are provided, SNPeff will annotate variants with their impact based on the gene annotation.

#### Small variant databases

If `GNOMAD_VCF`, `GNOMAD_VCF_INDEX`, `CLINVAR_VCF`, `CLINVAR_VCF_INDEX`, `DBNSFP_DB`, and `DBNSFP_DB_INDEX` are provided, SNPeff/SNPsift will annotate small variants with:

- their frequency in gnomAD
- their presence and clinical significance in ClinVar
- the predicted impact based on conservation (GERP++), CADD, or MetaRNN.

#### Structural variant databases

If `SV_DB_RDATA` is provided, SVs are annotated with:

- the frequency of similar SVs in public SV catalogs
- their similarity with variants in DGV
- their similarity with the Clinical SV dataset from dbVar

#### Structural variant validation

If `BAM`, `BAM_INDEX`, and `REFERENCE_FASTA` are provided, SVs will be re-genotyped from the long reads using local pangenomes built with vg.
Two new INFO fields will represent the read support for the SV allele:

- `RS_PROP` with the proportion of supporting reads.
- `RS_AD` with the read support for the reference and alternate alleles (e.g. `3,5` for 3 reference-supporting reads and 5 SV-supporting reads).


### Snakemake

Assuming you're in the root of the repository, run the workflow with:

```sh
snakemake --use-singularity --configfile config.yaml -p reports --cores 4
```

The `config.yaml` file points to all the relevant files (FASTA, databases, sample information).

See [test/snakemake.config.yaml](test/snakemake.config.yaml) and [test/snakemake.sample_info.tsv](snakemake.sample_info.tsv) for examples of those two files.

The `config.yaml` parameters are:

- `clinvar`: VCF with ClinVar (prepared above)
- `dbnsfp`: dbNSFP indexed file ([prepared above](#dbnsfp))
- `gnomad`: gnomAD VCF with allele frequencies ([prepared above](#gnomad))
- `svdb`: RData file with misc annotations, mostly for SV annotatio ([prepared above](#misc-annotations-in-r-object))
- `annotsv`: folder with the AnnotSV annotations ([prepared above](#annotsv))
- `snpeff`: folder with the SnpEff databse ([prepared above](#snpeff))
- `ref`: (indexed) FASTA of the reference genome
- `tr_catalog`: Tandem repeat expansion in public controls ([prepared above](#tandem-repeat-expansion-in-public-controls))
- `sample_info`: TSV file with sample information (name, VCF, BAM)
- `sample`: sample(s) to process. If empty, all samples in `sample_info` will be processed.
- `tmp_dir`: a directory to use as temporary directory.

The `sample_info` parameter point to a TSV file with (at least) the following three columns:

- `sample`: sample name
- `bam`: path to the (indexed) BAM file
- `hvcf`: harmonized VCF with small and structural variants (e.g. from the [Napu pipeline](https://github.com/nanoporegenomics/napu_wf)).

## Test locally

See [test/README.md](test/README.md).

