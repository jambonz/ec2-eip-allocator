#!/bin/bash
set -x

# Configure AWS CLI to use system CA bundle and disable strict validation
export AWS_CA_BUNDLE="/etc/pki/tls/certs/ca-bundle.crt"  # Point to system CA bundle
export AWS_VERIFY_SSL=false  # Disable strict verification
export AWS_SDK_LOAD_CONFIG=1
export AWS_MAX_ATTEMPTS=10
export AWS_RETRY_MODE=standard

# Default values
TAG_KEY=${AWS_EIP_NODE_GROUP_ROLE_KEY:-"role"}
TAG_VALUE=${AWS_EIP_NODE_GROUP_ROLE:-"default-role"}
TIMEOUT=60
PAUSE=5

# Add --no-verify-ssl to AWS CLI commands
aws_cmd() {
  aws --no-verify-ssl "$@"
}

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

aws_get_primary_network_interface() {
    # Try AWS CLI with SSL verification disabled
    network_interface_id=$(aws_cmd ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=${instance_id}" "Name=attachment.device-index,Values=0" --region ${instance_region} --query "NetworkInterfaces[0].NetworkInterfaceId" --output text)
    
    # If that fails, try metadata
    if [ -z "$network_interface_id" ] || [ "$network_interface_id" == "None" ]; then
        echo "AWS CLI method failed, trying metadata method..."
        mac=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | head -1)
        if [ -n "$mac" ]; then
            network_interface_id=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}interface-id)
            echo "Retrieved interface ID from metadata: $network_interface_id"
        fi
    fi
    
    if [ -n "$network_interface_id" ]; then 
        echo "Primary network interface: $network_interface_id"
        return 0
    else 
        echo "Failed to get network interface ID"
        return 1
    fi
}

aws_get_unassigned_eips() {
    echo "Looking for EIPs with tag '$TAG_KEY=$TAG_VALUE'..."
    local describe_addresses_response=$(aws_cmd ec2 describe-addresses --region $instance_region --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" --query "Addresses[?AssociationId==null].AllocationId" --output text)
    eips=(${describe_addresses_response})
    if [ -n "$describe_addresses_response" ] && [ ${#eips[@]} -gt 0 ]; then
        echo "Found ${#eips[@]} unassigned EIPs with tag '$TAG_KEY=$TAG_VALUE'"
        return 0
    else
        # Check if this instance already has an EIP
        local instance_ip=$(aws_cmd ec2 describe-addresses --region $instance_region --filters "Name=instance-id,Values=$instance_id" --query "Addresses[0].PublicIp" --output text)
        if [ -n "$instance_ip" ] && [ "$instance_ip" != "None" ]; then
            echo "Instance already has EIP: $instance_ip"
            exit 0  # Exit with success if EIP already assigned
        fi
        
        echo "No unassigned EIPs found with tag '$TAG_KEY=$TAG_VALUE'"
        return 1
    fi
}

aws_get_details() {
    if aws_get_instance_id; then
        echo "Instance ID: ${instance_id}"
        if aws_get_instance_region; then
            echo "Instance Region: ${instance_region}"
            if aws_get_primary_network_interface; then
                echo "Looking for EIPs with tag key: $TAG_KEY and value: $TAG_VALUE"
                return 0
            else
                echo "Failed to get primary network interface"
                return 1
            fi
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
    echo "Attempting to assign EIP $1 to network interface $network_interface_id..."
    result=$( (aws_cmd ec2 associate-address --region $instance_region --network-interface-id $network_interface_id --allocation-id $1 --no-allow-reassociation) 2>&1 )
    exit_code=$?
    if [ "$exit_code" -ne 0 ]; then
        echo "Failed to assign Elastic IP [$1] to network interface [$network_interface_id]. ERROR: $result"
    else
        echo "Successfully assigned EIP $1 to network interface $network_interface_id"
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
        exit 0  # Exit with success to allow pod to continue
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
    
    echo "Failed to assign Elastic IP after $TIMEOUT seconds."
    # Exit with success anyway to allow pod to continue
    exit 0
}

declare instance_id
declare instance_region
declare network_interface_id
declare eips

main "$@"