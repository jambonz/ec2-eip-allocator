#!/bin/bash
set -xe

AWS_EIP_NODE_GROUP_ROLE_KEY=${AWS_EIP_NODE_GROUP_ROLE_KEY:-"role"}

# Obtain temp auth token
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
# Get instance attributes
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PUBLIC_IP_TO_DISASSOCIATE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" --silent http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r .region)
NODEGROUP_NAME_FROM_TAGS=$(aws ec2 describe-tags --filters "Name=resource-id,Values=$INSTANCE_ID" --region=$REGION | jq '.Tags[] | select(.Key == "aws:autoscaling:groupName") | {Value}' | jq -r '.Value')
NETWORK_INTERFACE_ID=$(aws ec2 describe-network-interfaces --filters Name=addresses.association.public-ip,Values=$PUBLIC_IP_TO_DISASSOCIATE --region=$REGION | jq '.NetworkInterfaces[] | {NetworkInterfaceId}' | jq -r '.NetworkInterfaceId')
# Get the list of EIPs from $AWS_EIP_NODE_GROUP_ROLE EIP pool
ALLOCATION_EIP_POOL=$(aws ec2 describe-addresses --filters "Name=tag:$AWS_EIP_NODE_GROUP_ROLE_KEY,Values=$AWS_EIP_NODE_GROUP_ROLE" --region=$REGION | jq '.Addresses | .[] ' | jq '{PublicIp}'| jq -r '.PublicIp')
# Get next free EIP from $AWS_EIP_NODE_GROUP_ROLE EIP pool
ALLOCATION_ID=$(aws ec2 describe-addresses --filters "Name=tag:$AWS_EIP_NODE_GROUP_ROLE_KEY,Values=$AWS_EIP_NODE_GROUP_ROLE" --region=$REGION | jq '.Addresses | .[] | select(.AssociationId == null)' | jq '{AllocationId}'| jq -r '.AllocationId')
ALLOCATION_ID=$(echo $ALLOCATION_ID | cut -d ' ' -f1)

# Check if the EIP from the pool is already assigned
for EIP in $ALLOCATION_EIP_POOL
do
  if [[ $PUBLIC_IP_TO_DISASSOCIATE == $EIP ]]
    then
    echo "$EIP from the pool is already assigned, exiting"
    exit 0
  fi
done

# Check if a free EIP is available in the pool
if [[ $ALLOCATION_ID == "" ]]
  then
    echo "No free EIPs available in the $AWS_EIP_NODE_GROUP_ROLE EIP group. Restarting..."
    exit 1
fi

echo "Attempt to associate $ALLOCATION_ID EIP. Check logs for errors"
aws ec2 associate-address --allocation-id "$ALLOCATION_ID" --network-interface-id "$NETWORK_INTERFACE_ID" --region=$REGION --no-allow-reassociation
