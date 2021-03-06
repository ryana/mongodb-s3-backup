#!/bin/bash
#
# Argument = -u user -p password -k key -s secret -b bucket
#
# To Do - Add logging of output.
# To Do - Abstract bucket region to options

set -e

export PATH="$PATH:/usr/local/bin"

usage()
{
cat << EOF
usage: $0 options

This script dumps the current mongo database, tars it, then sends it to an Amazon S3 bucket.

OPTIONS:
   -h      Show this message
   -a      Address to connect to
   -u      Mongodb user
   -p      Mongodb password
   -k      AWS Access Key
   -s      AWS Secret Key
   -r      Amazon S3 region
   -b      Amazon S3 bucket name
   -o      Only run on secondary
   -f      Skip auth
EOF
}

MONGODB_ADDR=
MONGODB_USER=
MONGODB_PASSWORD=
AWS_ACCESS_KEY=
AWS_SECRET_KEY=
S3_REGION=
S3_BUCKET=
SECONDARY_ONLY=
SKIP_AUTH=

while getopts “htof:u:p:k:s:r:b:a:” OPTION
do
  case $OPTION in
    h)
      usage
      exit 1
      ;;
    a)
      MONGODB_ADDR=$OPTARG
      ;;
    u)
      MONGODB_USER=$OPTARG
      ;;
    p)
      MONGODB_PASSWORD=$OPTARG
      ;;
    k)
      AWS_ACCESS_KEY=$OPTARG
      ;;
    s)
      AWS_SECRET_KEY=$OPTARG
      ;;
    r)
      S3_REGION=$OPTARG
      ;;
    b)
      S3_BUCKET=$OPTARG
      ;;
    o)
      SECONDARY_ONLY=true
      ;;
    f)
      SKIP_AUTH=true
      ;;
    ?)
      usage
      exit
    ;;
  esac
done

if [[ -z $AWS_ACCESS_KEY ]] || [[ -z $AWS_SECRET_KEY ]] || [[ -z $S3_REGION ]] || [[ -z $S3_BUCKET ]]
then
  usage
  exit 1
fi

if [[ "$SKIP_AUTH" != "true" ]]
then
  if [[ -z $MONGODB_USER ]] || [[ -z $MONGODB_PASSWORD ]]
  then
    echo "SKIP_AUTH set to false but user & password missing..."
    usage
    exit 1
  else
    MONGO_AUTH=" -username $MONGODB_USER -password $MONGODB_PASSWORD "
    MONGO_CMD="mongo $MONGODB_ADDR $MONGO_AUTH "
  fi
else
  MONGO_AUTH=""
  MONGO_CMD="mongo $MONGODB_ADDR"
fi

if [[ "$SECONDARY_ONLY" == "true" ]] && [[ `$MONGO_CMD --quiet --eval "printjson(rs.isMaster()['ismaster'])"` == "true" ]]
then
  echo "Not running on master..."
  exit 0
fi

# Get the directory the script is being run from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
echo $DIR
# Store the current date in YYYY-mm-DD-HHMMSS
DATE=$(date -u "+%F-%H%M%S")
FILE_NAME="backup-$DATE"
ARCHIVE_NAME="$FILE_NAME.tar.gz"
BACKUP_DIR=$DIR/backup
mkdir -p $BACKUP_DIR

# Lock the database
# Note there is a bug in mongo 2.2.0 where you must touch all the databases before you run mongodump
echo $MONGODB_ADDR
echo $MONGO_AUTH
echo "Locking..."
mongo $MONGODB_ADDR $MONGO_AUTH --eval "printjson(db.fsyncLock())"
echo "Locked..."
echo "Dumping to $BACKUP_DIR/$FILE_NAME"

# Dump the database
mongodump -h $MONGODB_ADDR $MONGO_AUTH --out $BACKUP_DIR/$FILE_NAME

echo "Dumped..."

# Unlock the database
mongo $MONGODB_ADDR $MONGO_AUTH --eval "printjson(db.fsyncUnlock())"

# Tar Gzip the file
tar -C $BACKUP_DIR/ -zcvf $BACKUP_DIR/$ARCHIVE_NAME $FILE_NAME/

# Remove the backup directory
rm -r $BACKUP_DIR/$FILE_NAME

# Send the file to the backup drive or S3

HEADER_DATE=$(date -u "+%a, %d %b %Y %T %z")
CONTENT_MD5=$(openssl dgst -md5 -binary $BACKUP_DIR/$ARCHIVE_NAME | openssl enc -base64)
CONTENT_TYPE="application/x-download"
STRING_TO_SIGN="PUT\n$CONTENT_MD5\n$CONTENT_TYPE\n$HEADER_DATE\n/$S3_BUCKET/$ARCHIVE_NAME"
SIGNATURE=$(echo -e -n $STRING_TO_SIGN | openssl dgst -sha1 -binary -hmac $AWS_SECRET_KEY | openssl enc -base64)

curl -X PUT \
--header "Host: $S3_BUCKET.s3-$S3_REGION.amazonaws.com" \
--header "Date: $HEADER_DATE" \
--header "content-type: $CONTENT_TYPE" \
--header "Content-MD5: $CONTENT_MD5" \
--header "Authorization: AWS $AWS_ACCESS_KEY:$SIGNATURE" \
--upload-file $BACKUP_DIR/$ARCHIVE_NAME \
https://$S3_BUCKET.s3-$S3_REGION.amazonaws.com/$ARCHIVE_NAME
