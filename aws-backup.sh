#!/bin/bash

help=""
bucket=$AWS_BACKUP_BUCKET
input_dev=$AWS_BACKUP_INPUT_DEV
empty_options=1
#alias aws=_fake_aws
n=4
size=100
host=$(hostname)
host='mainsrv'
dev_name=/dev/sda

function _timestamp {
  date '+%Y-%m-%d %T.%3N'
}

function _log_err {
  echo $(_timestamp) Error: $@ >&2
}

function _log_warn {
  echo $(_timestamp) Warn: $@
}

function _log_info {
  echo $(_timestamp) Info: $@
}

function _parse_args {
    opts=$(getopt --options h,b:,s:,t:,i:,m: --longoptions help,bucket:,size:,tmp:,input-dev:,mail: --name aws-backup -- "$@")

    eval set -- $opts
  
    while true;
    do
        case "$1" in
            -b | --bucket)
                bucket="$2"
                empty_options=0
                shift 2
            ;;
            -s | --size) 
                size="$2"
                empty_options=0
                shift 2
            ;;
            -t | --tmp-dir) 
                tmp_dir="$2"
                empty_options=0
                shift 2
            ;;
            -i | --input-dev)
                input_dev="$2"
                echo $input_dev
                empty_options=0
                shift 2
            ;;
            -m | --mail)
                mail="$2"
                empty_options=0
                shift 2
            ;;
            -h | --help)
                help="display"
                shift
            ;;
            *)
                echo $1
                break
            ;;
        esac
    done
}

function _usage { 
    cat <<EOF
    Usage:
        aws-backup [-h | -b bucket -t TMP_DIR -s SIZE -i INPUT_DEV -m MAIL_GPG ]

    Options:
        -h | --help Display this message and exit
        -b | --bucket S3 bucket name
        -t | --tmp-dir Directory for store the temporary copies of input device before upload
        -s | --size Size in MiB (1MiB = 1024 * 1024 B) for reading from input device, 
                    does not guarantee the output file size due to compression and encyption
        -i | --input-device Block devece for read from
        -m | --mail Mail address associaated with the GPG key that will be used for encryption
EOF
    exit 0
}

function _fake_aws {
    echo "aws command called with args: $@"
    echo size: $(du -sh $5)
}

function _show_results {
    _log_info "Uploaded $1 chunks of $size MiB to $bucket"
    exit 0
}

function _main {

    

    _parse_args $@

    if [ -n "$help" -o $empty_options -eq 1 ] 
    then 
        _usage
    fi
    
    count=893
    offset=0
    while true
    do
        offset=$(( count * size ))
        # echo count: $count, offset: $offset

        # try to read 1 byte from next chunk
        can_continue=$(dd bs=1 skip=$(( offset * 1024 * 1024 )) count=1 if=$input_dev of=/dev/null 2>&1 | tail -n 1 | cut -d ' ' -f 1)
        #echo $offset $input_dev

        device=$(echo $dev_name | tr / . | cut -d . -f 2-)
        name_template="${host}.${device}.%08x.img.gpg.zst"
        output_file=$(printf $name_template $count)

        # copy size MB from disk to stdout
        # encrypt using pub key associated with email
        # compress output
        _log_info "Creating file ${output_file}"
        dd status=none bs=1M skip=$offset count=$size if=$input_dev | \
        gpg --encrypt --recipient $mail --output - | \
        zstd -T6 -16 --no-progress - -o "${tmp_dir}/${output_file}" 
        
        if [ $(( count % n )) -eq $(( n - 1)) -o $can_continue -eq 0 ]
        then
            _log_info "Uploading $n files"
            for i in $(seq $n)
            do
                source_file=$(printf $name_template $(( count - n + i )) )
                destination="s3://${bucket}/${source_file}"
                _log_info "Uploading file to bucket: [${source_file}] ==> [${destination}]"
                _fake_aws s3 cp --storage-class DEEP_ARCHIVE $source_file $destination
                #aws s3 cp --storage-class DEEP_ARCHIVE $source_file $destination
                #rm $source_file
            done
        fi

        if [ $can_continue -eq 0 ]
        then
            _show_results $count

        fi

        (( count++ ))
    done
}

_main $@

# unalias -a aws