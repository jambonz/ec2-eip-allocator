#!/bin/bash

# Default values
TAG_KEY=${AWS_EIP_NODE_GROUP_ROLE_KEY:-"role"}
TAG_VALUE=${AWS_EIP_NODE_GROUP_ROLE:-"default-role"}
TIMEOUT=60
PAUSE=5

aws_get_instance_id() {
    instance_id=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
    if [ -n "$instance_id" ]; then return 0; else return 1; fi
}

aws_get_instance_region() {
    instance_region=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
    # region here needs the last character removed to work
    instance_region=${instance_region::-1}
    if [ -n "$instance_region" ]; then return 0; else return 1; fi
}

aws_get_unassigned_eips() {
    echo "Looking for EIPs with tag '$TAG_KEY=$TAG_VALUE'..."
    local describe_addresses_response=$(aws ec2 describe-addresses --region $instance_region --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" --query "Addresses[?AssociationId==null].AllocationId" --output text)
    eips=(${describe_addresses_response})
    if [ -n "$describe_addresses_response" ] && [ ${#eips[@]} -gt 0 ]; then
        echo "Found ${#eips[@]} unassigned EIPs with tag '$TAG_KEY=$TAG_VALUE'"
        return 0
    else
        echo "No unassigned EIPs found with tag '$TAG_KEY=$TAG_VALUE'"
        return 1
    fi
}

aws_get_details() {
    if aws_get_instance_id; then
        echo "Instance ID: ${instance_id}"
        if aws_get_instance_region; then
            echo "Instance Region: ${instance_region}"
            echo "Looking for EIPs with tag key: $TAG_KEY and value: $TAG_VALUE"
            return 0
        else
            echo "Failed to get Instance Region"
            return 1
        fi
    else
        echo "Failed to get Instance ID"
        return 1
    fi
}

attempt_to_assign_eip() {
    local result
    local exit_code
    echo "Attempting to assign EIP $1 to instance $instance_id..."
    result=$( (aws ec2 associate-address --region $instance_region --instance-id $instance_id --allocation-id $1 --no-allow-reassociation) 2>&1 )
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "Failed to assign Elastic IP [$1] to Instance [$instance_id]. ERROR: $result"
    else
        echo "Successfully assigned EIP $1 to instance $instance_id"
    fi
    return $exit_code
}

try_to_assign() {
    for eip_id in "${eips[@]}"; do
        if attempt_to_assign_eip $eip_id; then
            echo "Elastic IP successfully assigned to instance"
            return 0
        fi
    done
    return 1
}

main() {
    echo "Starting EIP association process..."
    echo "Tag Key: $TAG_KEY, Tag Value: $TAG_VALUE"
    
    local end_time=$((SECONDS+TIMEOUT))
    
    if ! aws_get_details; then
        echo "Failed to get instance details. Exiting."
        exit 1
    fi
    
    while [ $SECONDS -lt $end_time ]; do
        if aws_get_unassigned_eips && try_to_assign "${eips[@]}"; then
            echo "Successfully assigned EIP to instance $instance_id. New public IP should now be active."
            # Print the new public IP
            sleep 5
            NEW_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
            echo "New public IP: $NEW_IP"
            exit 0
        fi
        echo "Failed to assign EIP. Pausing for $PAUSE seconds before retrying..."
        sleep $PAUSE
    done
    
    echo "Failed to assign Elastic IP after $TIMEOUT seconds. Exiting."
    exit 1
}

declare instance_id
declare instance_region
declare eips

main "$@"

