#!/bin/bash

ACTION=$1
AGE=$2
AWS_PROFILE=$3

function usage() {
  echo "Usage: "
  echo "./snapshot <ACTION> <AGE (use 0 for today)> <AWS_PROFILE>" 
}

if [ -z $ACTION ];
then
    echo "Usage $1: Define ACTION of backup or delete"
    usage
    exit 1
fi

if [ "$ACTION" == "delete" ] && [ -z $AGE ];
then
    echo "Please enter the age of backups you would like to delete"
    usage
    exit 1
fi

if [ -z $AWS_PROFILE ];
then
    echo "Usage $3: Define AWS PROFILE"
    usage
    exit 1
fi
 

function backup_ebs () {
    echo $AWS_PROFILE
    prod_instances=`aws ec2 describe-instances --filters "Name=tag-value,Values=ayodeji-test-machine*" --profile $AWS_PROFILE | jq -r ".Reservations[].Instances[].InstanceId"`


    for instance in $prod_instances
    do  

        volumes=`aws ec2 describe-volumes --filter Name=attachment.instance-id,Values=$instance --profile $AWS_PROFILE | jq .Volumes[].VolumeId | sed 's/\"//g'`
        
        for volume in $volumes
        do
            #echo Creating snapshot for $volume
            echo Creating snapshot for $volume $(aws ec2 create-snapshot --volume-id $volume --description "ayodeji-machine-snapshot"  --tag-specifications 'ResourceType=snapshot,Tags=[{Key=environs,Value=ayodeji-test-machine}]' --profile $AWS_PROFILE )
        done

    done
}


function delete_snapshots () {
    
    for snapshot in $(aws ec2 describe-snapshots --filters Name=description,Values=ayodeji-machine-snapshot --profile $AWS_PROFILE | jq .Snapshots[].SnapshotId | sed 's/\"//g')
    do
        #echo $snapshot
        SNAPSHOTDATE=$(aws ec2 describe-snapshots --filters Name=snapshot-id,Values=$snapshot --profile $AWS_PROFILE | jq .Snapshots[].StartTime | cut -d T -f1 | sed 's/\"//g')
        STARTDATE=$(date +%s)
        ENDDATE=$(date -d $SNAPSHOTDATE +%s)
        INTERVAL=$[ (STARTDATE - ENDDATE) / (60*60*24) ]

        if (( $INTERVAL >= $AGE ));
        then
            echo "Deleting snapshot --> $snapshot"
            aws ec2 delete-snapshot --snapshot-id $snapshot --profile $AWS_PROFILE
        fi

    done
}

case $ACTION in
    
    "backup")
            backup_ebs
    ;;

    "delete")
            delete_snapshots
    ;;

esac
