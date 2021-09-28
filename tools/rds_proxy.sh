#!/usr/bin/env bash

set -eu -o pipefail

function usage() {
    echo "Makes a tunnel to RDS database via a bastion host in private network, using SSH tunnel via SSM service"
    echo "By default binds local port 7432, use -r to pick a random port"
    echo ""
    echo "Usage:"
    echo "./rds_proxy [options]"
    echo ""
    echo "Options:"
    echo "-h                       Show help"
    echo "-d db-identifier         Required: Select the DB instance to which the tunnel is made"
    echo "-l port (default 7432)   Local port to use for the tunnel"
    echo "-j name                  Required: Name tag of the bastion instance to use (jump host)"
    echo "-r                       Use random local port"
}

if ! command -v session-manager-plugin >/dev/null 2>&1
then
    echo ""
    echo "Please install the session manager plugin"
    echo "See instructions at: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
    echo ""
    exit 1
fi

LOCAL_PORT=7432
DB_IDENTIFIER=""
JUMP_INSTANCE_NAME=""
USE_RANDOM_LOCAL_PORT=""

while getopts ":hd:l:j:r" opt; do
    case "$opt" in
        d)
            DB_IDENTIFIER=$OPTARG
            ;;
        l)
            LOCAL_PORT=$OPTARG
            ;;
        j)
            JUMP_INSTANCE_NAME=$OPTARG
            ;;
        r)
            USE_RANDOM_LOCAL_PORT=1
            ;;
        h|*)
            usage
            exit 1
            ;;
    esac
done

if [ "$DB_IDENTIFIER" = "" ]; then
    echo "Missing DB_IDENTIFIER, please specify with -i"
    echo ""
    usage
    exit 1
fi

if [ "$JUMP_INSTANCE_NAME" = "" ]; then
    echo "Missing JUMP_INSTANCE_NAME, please specify with -j"
    echo ""
    usage
    exit 1
fi

# Setup folder for temporary SSH keys and the control socket
KEY_FOLDER=$HOME/.ssh/aws-tools/ssm-tunnel
mkdir -p "$KEY_FOLDER"
# Base name for generated SSH keys
SSH_KEY_FILE_BASE="$KEY_FOLDER/ssm-bastion-key"

echo "Starting SSH tunnel to $DB_IDENTIFIER via $JUMP_INSTANCE_NAME"

# SSH Socket for controlling the SSH connection
CONTROL_SOCKET="$KEY_FOLDER/bastion-$DB_IDENTIFIER.sock"

if [ "$USE_RANDOM_LOCAL_PORT" != "" ]; then
    SEED=$(echo "$DB_IDENTIFIER" | sum | cut -f1 -d' ')
    RANDOM=$SEED LOCAL_PORT=$(( ((RANDOM<<15)|RANDOM) % 63001 + 2000 ))
fi

# Fetch EC2 Instance ID and Availability zone of the jump host
INSTANCE_ID_AND_AVAILABILITY_ZONE=$(aws ec2 describe-instances \
                                        --filter Name=tag:Name,Values="$JUMP_INSTANCE_NAME" Name=instance-state-name,Values=running\
                                        --query 'Reservations[0].Instances[0].[InstanceId, Placement.AvailabilityZone]' \
                                        --out text)
EC2_INSTANCE_ID=$(echo "$INSTANCE_ID_AND_AVAILABILITY_ZONE" | awk '{print $1}')
EC2_AVAILABILITY_ZONE=$(echo "$INSTANCE_ID_AND_AVAILABILITY_ZONE" | awk '{print $2}')

# Fetch database endpoint
RDS_ADDRESS_AND_PORT=$(aws rds describe-db-instances \
                           --db-instance-identifier "$DB_IDENTIFIER" \
                           --query 'DBInstances[0].Endpoint.[Address, Port]' \
                           --out text)
RDS_ADDRESS=$(echo "$RDS_ADDRESS_AND_PORT" | awk '{print $1}')
RDS_PORT=$(echo "$RDS_ADDRESS_AND_PORT" | awk '{print $2}')

# Remove old key files if present
rm -f "$SSH_KEY_FILE_BASE"
rm -f "$SSH_KEY_FILE_BASE.pub"

# Generate temporary SSH key
ssh-keygen -t rsa \
           -f "$SSH_KEY_FILE_BASE" \
           -N '' \
           -q

# Send the public key to AWS, for use via instance metadata
# The SSH key will be usable for 60 seconds after initial upload
aws ec2-instance-connect send-ssh-public-key \
    --instance-id "$EC2_INSTANCE_ID" \
    --availability-zone "$EC2_AVAILABILITY_ZONE" \
    --instance-os-user ec2-user \
    --ssh-public-key "file://$SSH_KEY_FILE_BASE.pub" > /dev/null

# Use the SSH keypair and SSM proxying for making a connection the SSHD on the instance, and create a tunnel to RDS
ssh -i "$SSH_KEY_FILE_BASE" \
    -4 \
    -f \
    -N \
    -M \
    -S "$CONTROL_SOCKET" \
    -L "$LOCAL_PORT:$RDS_ADDRESS:$RDS_PORT" \
    -o "UserKnownHostsFile=/dev/null" \
    -o "StrictHostKeyChecking=no" \
    -o "IdentitiesOnly=yes" \
    -o ProxyCommand="aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p'" \
    ec2-user@"$EC2_INSTANCE_ID"

echo "RDS tunnel started on localhost at port $LOCAL_PORT for $DB_IDENTIFIER"

# Wait for termination
read -rsn1 -p "Press any key to close session."; echo
ssh -O exit -S "$CONTROL_SOCKET" "*"
# Remove the key files
rm "$SSH_KEY_FILE_BASE"
rm "$SSH_KEY_FILE_BASE.pub"
