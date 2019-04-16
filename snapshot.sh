#!/bin/bash
# This script will create a snapshot of volume(s) attached to an Instance and also delete older snapshots in aws environment. 
# This script depends on installed aws-cli and jq
ACTION="$1"
TAG_VALUE="$2"
AWS_PROFILE="$3"
DAYS="$4"
BACKUP='backup'
DELETE='delete'
MODES=("$BACKUP" "$DELETE")
DATE=''
SCRIPT=$(basename "$0")
TAG_KEY='snapshot_key'

if [[ "$OSTYPE" == "darwin"* ]]; then
  DATE="/usr/local/bin/gdate"
elif [[ "$OSTYPE" == "linux-gnu" ]]; then
  DATE="/bin/date"
else
  echo "$OSTYPE not supported"
  echo " Linux, Mac is supported"
  exit 1
fi

# create a timestamp for the logging function
function timestamp () {
  echo "$($DATE -u '+%FT%T%.6N%:z')"
}

# generate a log statement
function logger () {
  echo "$(timestamp) - [$SCRIPT] - $*"
}

# print usage
function usage() {
  echo "Usage: "
  echo "$SCRIPT <ACTION=backup> <TAG_VALUE> <AWS_PROFILE>" 
  echo "$SCRIPT <ACTION=delete> <TAG_VALUE> <AWS_PROFILE> <DAYS>" 
}

# pass in an array and a string, return true if it is in the array
array_contains () {
  local array="$1[@]"
  local seeking=$2
  local in=1
  for element in "${!array}"; do
    if [[ $element == "$seeking" ]]; then
      in=0
      break
    fi
  done
  return $in
}

# pass in an AWS profile, return true if it exists
function verify_creds() {
  local PROFILE=$1
  aws configure --profile "$PROFILE" list > /dev/null
  EXIT_CODE=$?
  if ! [[ $EXIT_CODE == 0 ]]; then
    usage
    exit 1
  fi
  return 0
}

# must have between 3 and 4 parameters
if [ $# -gt 4 ] || [ $# -lt 3 ]; then
  logger "[ERROR] : Illegal number of arguments"
  usage
  exit 1
fi

# ensure ACTION is either 'backup' or 'delete'
if ! array_contains MODES "$ACTION"
then
  logger "[ERROR] : Invalid MODE"
  usage
  exit 1
fi 

# ensure 'backup' mode only has 3 parameters passed in 
if [ "$ACTION" == "$BACKUP" ] && [ $# -ne 3 ]; then
  logger "[ERROR] : Illegal number of arguments"
  usage
  exit 1
fi

# ensure 'delete' mode only has 4 parameters passed in
if [ "$ACTION" == "$DELETE" ] && [ $# -ne 4 ]; then
  logger "[ERROR] :  Illegal number of arguments"
  usage
  exit 1
fi

# ensure DAYS is an int >= 0
if [ "$ACTION" == "$DELETE" ] && ! [[ $DAYS =~ ^[0-9]+$ ]]; then
  logger "[ERROR] :  DAYS must be integer >= 0"
  usage
  exit 1
fi

# ensure no whitespaces in TAG_VALUE and AWS profile
whitespace=" |'"
if [[ "$AWS_PROFILE" =~ $whitespace ]]; then
  logger "[ERROR] :  AWS_PROFILE cannot contain spaces"
  usage
  exit 1
fi

if [[ "$TAG_VALUE" =~ $whitespace ]]; then
  logger "[ERROR] :  TAG_VALUE cannot contain spaces"
  usage
  exit 1
fi

# ensure AWS profile is valid
verify_creds "$AWS_PROFILE"

if [ "$ACTION" == "$BACKUP" ]; then
  logger "[INFO] : user=$USER action=$ACTION AWS_PROFILE=$AWS_PROFILE tag_value=$TAG_VALUE"
fi

if [ "$ACTION" == "$DELETE" ]; then
  logger "[INFO] : user=$USER action=$ACTION AWS_PROFILE=$AWS_PROFILE tag_value=$TAG_VALUE days=$DAYS"
fi

# creates a snapshot given an AWS profile and a tag
function snapshot_ebs () {
  local AWS_PROFILE="$1"
  local TAG_VALUE="$2"
  instances=($(aws ec2 describe-instances --filters "Name=tag-value,Values=$TAG_VALUE" --profile "$AWS_PROFILE" | jq -r ".Reservations[].Instances[].InstanceId"))

  if [[ ${#instances[@]} -lt 1 ]]; then
    logger "[ERROR] : No instances found for tag_value=$TAG_VALUE"
    exit 1
  fi
  logger "[INFO] : Found ${#instances[@]} instance(s) for tag_value=$TAG_VALUE"

  for instance in "${instances[@]}"
  do  
    volumes=($(aws ec2 describe-volumes --filter Name=attachment.instance-id,Values=$instance --profile "$AWS_PROFILE" | jq .Volumes[].VolumeId | sed 's/\"//g'))

    if [[ ${#volumes[@]} -lt 1 ]]; then
      logger "[ERROR] : No volumes found for instance=$instance tag_value=$TAG_VALUE"
      exit 1
    fi

    logger "[INFO] : Found ${#volumes[@]} volume(s) for instance=$instance tag_value=$TAG_VALUE"
    for volume in "${volumes[@]}"
    do
      logger "[INFO] : Creating snapshot for $volume"
      echo $(aws ec2 create-snapshot --volume-id $volume --description "$TAG_VALUE"  --tag-specifications "ResourceType=snapshot,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE}]" --profile "$AWS_PROFILE" )
    done
  done
}

function delete_snapshots () {
  local AWS_PROFILE="$1"
  local TAG_VALUE="$2"
  local DAYS="$3"

  snapshots=($(aws ec2 describe-snapshots --filters Name=tag:$TAG_KEY,Values=$TAG_VALUE --profile "$AWS_PROFILE" | jq .Snapshots[].SnapshotId | sed 's/\"//g'))
  if [[ ${#snapshots[@]} -lt 1 ]]; then
    logger "[ERROR] : No snapshots found with tag_value=$TAG_VALUE"
    exit 1
  fi

  logger "[INFO] : Found ${#snapshots[@]} snapshot(s) for tag_value=$TAG_VALUE"

  NUM_SNAPSHOTS_DELETED=0
  for snapshot in "${snapshots[@]}"
  do
    SNAPSHOTDATE=$(aws ec2 describe-snapshots --filters Name=snapshot-id,Values="$snapshot" --profile "$AWS_PROFILE" | jq .Snapshots[].StartTime | cut -d T -f1 | sed 's/\"//g')
    STARTDATE=$($DATE +%s)
    ENDDATE=$($DATE -d "$SNAPSHOTDATE" +%s)
    DURATION=$(echo "$STARTDATE-$ENDDATE" | bc)
    SEC_TO_DAYS=$(echo "60*60*24" | bc)
    INTERVAL=$(echo "$DURATION/$SEC_TO_DAYS" | bc)

    if (( $INTERVAL >= $DAYS ));
    then
      logger "[INFO] : Deleting snapshot --> $snapshot for tag_value=$TAG_VALUE"
      aws ec2 delete-snapshot --snapshot-id "$snapshot" --profile "$AWS_PROFILE"
      (( NUM_SNAPSHOTS_DELETED++ ))
    fi
  done
  logger "[INFO] : Deleted $NUM_SNAPSHOTS_DELETED snapshot(s) for days=$DAYS"
}

case $ACTION in
  $BACKUP)
    snapshot_ebs "$AWS_PROFILE" "$TAG_VALUE"
  ;;

  $DELETE)
    delete_snapshots "$AWS_PROFILE" "$TAG_VALUE" "$DAYS"
  ;;

esac
