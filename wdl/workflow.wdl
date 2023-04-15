version 1.0

workflow annotate_variants {

    meta {
	    author: "Jean Monlong"
        email: "jmonlong@ucsc.edu"
        description: "Annotate a VCF with SNPeff, frequencies in gnomAD, and ClinVar"
    }

    parameter_meta {
        VCF: {help: "Input VCF. Can be gzipped/bgzipped."},
        SNPEFF_DB: {help: "SNPeff annotation bundle (zip file)"},
        SNPEFF_DB_NAME: {help: "Name of SNPeff annotation bundle. E.g. GRCh38.105"},
        GNOMAD_VCF: {help: "VCF with all variants in gnomAD and their allele frequency (AF INFO field). Must be sorted, bgzipped, and indexed."},
        GNOMAD_VCF_INDEX: {help: "Index for GNOMAD_VCF (.tbi file)."},
        CLINVAR_VCF: {help: "VCF with all variants in ClinVar and their clinical significance (CLNSIG INFO field). Must be sorted, bgzipped, and indexed."},
        CLINVAR_VCF_INDEX: {help: "Index for CLINVAR_VCF (.tbi file)."},
        SV_DB_RDATA: {help: "RData file with the databases used for SV annotation (e.g. SV catalogs, dbVar clinical SVs, DGV)."},
        SPLIT_MULTIAL: {help: "Should multiallelic variants be split into biallelic records?", default: "true"},
        SORT_INDEX_VCF: {help: "Should the output VCF be sorted, bgzipped, and indexed?", default: "true"}
    }
    
    input {
        File VCF
        File? SNPEFF_DB
        String? SNPEFF_DB_NAME
        File? GNOMAD_VCF
        File? GNOMAD_VCF_INDEX
        File? CLINVAR_VCF
        File? CLINVAR_VCF_INDEX
        File? SV_DB_RDATA
        Boolean SPLIT_MULTIAL = true
        Boolean SORT_INDEX_VCF = true
    }

    # split multi-allelic variants
    if (SPLIT_MULTIAL){
        call split_multiallelic_vcf {
            input:
            input_vcf=VCF
        }
    }

    # annotate variants with predicted effect based on gene annotation
    File current_vcf = select_first([split_multiallelic_vcf.vcf, VCF])

    if(defined(SNPEFF_DB) && defined(SNPEFF_DB)){
        call annotate_with_snpeff {
            input:
            input_vcf=current_vcf,
            snpeff_db=select_first([SNPEFF_DB]),
            db_name=select_first([SNPEFF_DB_NAME])
        }
    }

    File annotated_vcf = select_first([annotate_with_snpeff.vcf, current_vcf])

    # annotate SNVs/indels with frequency in gnomAD and presence in ClinVar
    # note: first filter variants to keep those with high/moderate impact or with predicted loss of function (speeds up DB matching a lot)
    if (defined(GNOMAD_VCF) && defined(GNOMAD_VCF_INDEX) && defined(CLINVAR_VCF) && defined(CLINVAR_VCF_INDEX)){
        call subset_annotate_smallvars_with_db {
            input:
            input_vcf=annotated_vcf,
            gnomad_vcf=select_first([GNOMAD_VCF]),
            gnomad_vcf_index=select_first([GNOMAD_VCF_INDEX]),
            clinvar_vcf=select_first([CLINVAR_VCF]),
            clinvar_vcf_index=select_first([CLINVAR_VCF_INDEX])
        }
    }
    
    File small_annotated_vcf = select_first([subset_annotate_smallvars_with_db.vcf, annotated_vcf])
    
    # annotate SVs with frequency in SV databases and presence in dbVar Clinical SVs
    if (defined(SV_DB_RDATA)){
        call annotate_sv_with_db {
            input:
            input_vcf=small_annotated_vcf,
            sv_db_rdata=select_first([SV_DB_RDATA])
        }
    }
    
    File sv_annotated_vcf = select_first([annotate_sv_with_db.vcf, small_annotated_vcf])

    # sort annotated VCF
    if (SORT_INDEX_VCF){
        call sort_vcf {
            input:
            input_vcf=sv_annotated_vcf
        }
    }
    
    File final_vcf = select_first([sort_vcf.vcf, sv_annotated_vcf])
    
    output {
        File vcf = final_vcf
        File? vcf_index = sort_vcf.vcf_index
    }
}

task split_multiallelic_vcf {
    input {
        File input_vcf
        Int memSizeGB = 4
        Int threadCount = 1
        Int diskSizeGB = 5*round(size(input_vcf, "GB")) + 20
    }

    String basen = sub(sub(basename(input_vcf), ".vcf.bgz$", ""), ".vcf.gz$", "")
    
    command <<<
    set -eux -o pipefail
    
    bcftools norm -m -both --threads ~{threadCount} -Oz -o ~{basen}.norm.vcf.gz ~{input_vcf}
    >>>
    
    output {
        File vcf = "~{basen}.norm.vcf.gz"
    }
    
    runtime {
        memory: memSizeGB + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSizeGB + " SSD"
        docker: "quay.io/biocontainers/bcftools:1.16--hfe4b78e_1"
        preemptible: 1
    }
}

task sort_vcf {
    input {
        File input_vcf
        Int memSizeGB = 4
        Int diskSizeGB = 5*round(size(input_vcf, "GB")) + 20
    }

    String basen = sub(sub(basename(input_vcf), ".vcf.bgz$", ""), ".vcf.gz$", "")
    
    command <<<
    set -eux -o pipefail

    bcftools sort -Oz -o ~{basen}.formatted.vcf.gz ~{input_vcf}
    bcftools index -t -o ~{basen}.formatted.vcf.gz.tbi ~{basen}.formatted.vcf.gz
    >>>
    
    output {
        File vcf = "~{basen}.formatted.vcf.gz"
        File? vcf_index = "~{basen}.formatted.vcf.gz.tbi"
    }
    
    runtime {
        memory: memSizeGB + " GB"
        cpu: 1
        disks: "local-disk " + diskSizeGB + " SSD"
        docker: "quay.io/biocontainers/bcftools:1.16--hfe4b78e_1"
        preemptible: 1
    }
}

task annotate_with_snpeff {
    input {
        File input_vcf
        File snpeff_db
        String db_name
        Int memSizeGB = 16
        Int threadCount = 2
        Int diskSizeGB = 5*round(size(input_vcf, "GB") + size(snpeff_db, 'GB')) + 20
    }

    Int snpeffMem = if memSizeGB < 6 then 2 else memSizeGB - 4
    String basen = sub(sub(basename(input_vcf), ".vcf.bgz$", ""), ".vcf.gz$", "")
    
	command <<<
        set -eux -o pipefail

        unzip ~{snpeff_db}
        
        snpEff -Xmx~{snpeffMem}g -nodownload -no-intergenic \
               -dataDir "${PWD}/data" ~{db_name} \
               ~{input_vcf} | gzip > ~{basen}.snpeff.vcf.gz
	>>>

	output {
		File vcf = "~{basen}.snpeff.vcf.gz"
	}

    runtime {
        memory: memSizeGB + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSizeGB + " SSD"
        docker: "quay.io/biocontainers/snpeff:5.1d--hdfd78af_0"
        preemptible: 1
    }
}

task subset_annotate_smallvars_with_db {
    input {
        File input_vcf
        File gnomad_vcf
        File gnomad_vcf_index
        File clinvar_vcf
        File clinvar_vcf_index
        Int memSizeGB = 16
        Int threadCount = 2
        Int diskSizeGB = 5*round(size(input_vcf, "GB") + size(gnomad_vcf, 'GB') + size(clinvar_vcf, 'GB')) + 30
    }

    Int snpsiftMem = if memSizeGB < 6 then 2 else memSizeGB - 4
    String basen = sub(sub(basename(input_vcf), ".vcf.bgz$", ""), ".vcf.gz$", "")
    
	command <<<
        set -eux -o pipefail

        ## link the database VCF to make sure their indexes can be found
        ln -s ~{gnomad_vcf} gnomad.vcf.bgz
        ln -s ~{gnomad_vcf_index} gnomad.vcf.bgz.tbi
        ln -s ~{clinvar_vcf} clinvar.vcf.bgz
        ln -s ~{clinvar_vcf_index} clinvar.vcf.bgz.tbi

        ## filter variants to keep those with high/moderate impact or with predicted loss of function
        ## then annotate with their frequency in gnomAD
        SnpSift -Xmx1g filter "(ANN[*].IMPACT has 'HIGH') | (ANN[*].IMPACT has 'MODERATE') | ((exists LOF[*].PERC) & (LOF[*].PERC > 0.9))" ~{input_vcf} | \
            SnpSift -Xmx~{snpsiftMem}g annotate -noId -v gnomad.vcf.bgz | gzip > ~{basen}.gnomad.vcf.gz

        ## annotate IDs with clinvar IDs and add the CLNSIG INFO field
        SnpSift -Xmx~{snpsiftMem}g annotate -info CLNSIG -v clinvar.vcf.bgz ~{basen}.gnomad.vcf.gz | gzip > ~{basen}.gnomad.clinvar.vcf.gz
	>>>

	output {
		File vcf = "~{basen}.gnomad.clinvar.vcf.gz"
	}

    runtime {
        memory: memSizeGB + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSizeGB + " SSD"
        docker: "quay.io/biocontainers/snpsift:5.1d--hdfd78af_0"
        preemptible: 1
    }
}

task annotate_sv_with_db {
    input {
        File input_vcf
        File sv_db_rdata
        Int memSizeGB = 8
        Int threadCount = 2
        Int diskSizeGB = 5*round(size(input_vcf, "GB") + size(sv_db_rdata, 'GB')) + 30
    }

    String basen = sub(sub(basename(input_vcf), ".vcf.bgz$", ""), ".vcf.gz$", "")
    
	command <<<
        set -eux -o pipefail

        # extract SVs and small variants
        bcftools view -i "STRLEN(REF)>=30 | MAX(STRLEN(ALT))>=30" -Oz -o svs.vcf.gz ~{input_vcf}
        bcftools view -i "STRLEN(REF)<30 & MAX(STRLEN(ALT))<30" ~{input_vcf} | bcftools sort -Oz -o smallvars.vcf.gz

        # annotate SVs
        Rscript /opt/scripts/annotate_svs.R svs.vcf.gz ~{sv_db_rdata} svs.annotated.vcf
        
        # merge back SVs
        bcftools sort -Oz -o svs.annotated.vcf.gz svs.annotated.vcf
        bcftools index -t svs.annotated.vcf.gz
        bcftools index -t smallvars.vcf.gz
        bcftools concat -a -Oz -o ~{basen}.svannotated.vcf.gz smallvars.vcf.gz svs.annotated.vcf.gz
    >>>

	output {
		File vcf = "~{basen}.svannotated.vcf.gz"
	}

    runtime {
        memory: memSizeGB + " GB"
        cpu: threadCount
        disks: "local-disk " + diskSizeGB + " SSD"
        docker: "quay.io/jmonlong/svannotate_sveval:0.1"
        preemptible: 1
    }
}
