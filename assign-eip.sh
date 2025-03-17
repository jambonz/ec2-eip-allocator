#!/bin/bash
set -x

# AWS SDK Configuration
export AWS_SDK_LOAD_CONFIG=1
export AWS_MAX_ATTEMPTS=10
export AWS_RETRY_MODE=standard

# Default values
TAG_KEY=${AWS_EIP_NODE_GROUP_ROLE_KEY:-"role"}
TAG_VALUE=${AWS_EIP_NODE_GROUP_ROLE:-"default-role"}
TIMEOUT=120  # Increased timeout
PAUSE=5

# Enhanced logging
log() {
  echo "$@"
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") - $@" >> /tmp/eip-allocator.log
}

# Test network connectivity
test_connectivity() {
  log "Testing network connectivity..."
  curl -v https://ec2.us-east-2.amazonaws.com/ || log "WARNING: Cannot connect to EC2 endpoint directly"
  aws sts get-caller-identity || log "WARNING: Cannot authenticate with AWS"
}

# AWS CLI with timeout
aws_with_timeout() {
  timeout 15 aws "$@" --cli-connect-timeout 10
}

aws_get_instance_id() {
  instance_id=$(curl -s --retry 3 --retry-delay 2 http://169.254.169.254/latest/meta-data/instance-id)
  if [ -n "$instance_id" ]; then
    log "Retrieved instance ID: $instance_id"
    return 0
  else
    log "Failed to retrieve instance ID"
    return 1
  fi
}

aws_get_instance_region() {
  instance_region=$(curl -s --retry 3 --retry-delay 2 http://169.254.169.254/latest/meta-data/placement/availability-zone)
  # region here needs the last character removed to work
  instance_region=${instance_region::-1}
  if [ -n "$instance_region" ]; then
    log "Retrieved instance region: $instance_region"
    return 0
  else
    log "Failed to retrieve instance region"
    return 1
  fi
}

aws_get_primary_network_interface() {
  log "Attempting to get primary network interface..."
  
  # Try AWS CLI method first
  network_interface_id=$(aws_with_timeout ec2 describe-network-interfaces --filters "Name=attachment.instance-id,Values=${instance_id}" "Name=attachment.device-index,Values=0" --region ${instance_region} --query "NetworkInterfaces[0].NetworkInterfaceId" --output text)
  
  # If that fails, try metadata method
  if [ -z "$network_interface_id" ] || [ "$network_interface_id" == "None" ]; then
    log "AWS CLI method failed, trying metadata method..."
    mac=$(curl -s --retry 3 --retry-delay 2 http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | head -1)
    if [ -n "$mac" ]; then
      network_interface_id=$(curl -s --retry 3 --retry-delay 2 http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac}interface-id)
      log "Retrieved interface ID from metadata: $network_interface_id"
    fi
  fi
  
  if [ -n "$network_interface_id" ] && [ "$network_interface_id" != "None" ]; then
    log "Primary network interface: $network_interface_id"
    return 0
  else
    log "Failed to get primary network interface"
    return 1
  fi
}

check_existing_eip() {
  log "Checking if instance already has an EIP assigned..."
  local ip=$(curl -s --retry 3 --retry-delay 2 http://169.254.169.254/latest/meta-data/public-ipv4)
  
  if [ -n "$ip" ]; then
    log "Instance has public IP: $ip"
    local is_elastic=$(aws_with_timeout ec2 describe-addresses --region $instance_region --filters "Name=public-ip,Values=$ip" --query "Addresses[0].AllocationId" --output text)
    
    if [ "$is_elastic" != "None" ] && [ -n "$is_elastic" ]; then
      log "Instance already has EIP assigned: $ip (AllocationId: $is_elastic)"
      return 0
    fi
  fi
  
  log "Instance does not have an EIP assigned"
  return 1
}

aws_get_unassigned_eips() {
  log "Looking for EIPs with tag '$TAG_KEY=$TAG_VALUE'..."
  local describe_addresses_response=$(aws_with_timeout ec2 describe-addresses --region $instance_region --filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" --query "Addresses[?AssociationId==null].AllocationId" --output text)
  eips=(${describe_addresses_response})
  if [ -n "$describe_addresses_response" ] && [ ${#eips[@]} -gt 0 ]; then
    log "Found ${#eips[@]} unassigned EIPs with tag '$TAG_KEY=$TAG_VALUE'"
    return 0
  else
    log "No unassigned EIPs found with tag '$TAG_KEY=$TAG_VALUE'"
    return 1
  fi
}

aws_get_details() {
  if aws_get_instance_id; then
    log "Instance ID: ${instance_id}"
    if aws_get_instance_region; then
      log "Instance Region: ${instance_region}"
      if aws_get_primary_network_interface; then
        log "Looking for EIPs with tag key: $TAG_KEY and value: $TAG_VALUE"
        return 0
      else
        log "Failed to get primary network interface"
        return 1
      fi
    else
      log "Failed to get Instance Region"
      return 1
    fi
  else
    log "Failed to get Instance ID"
    return 1
  fi
}

attempt_to_assign_eip() {
  local result
  local exit_code
  log "Attempting to assign EIP $1 to network interface $network_interface_id..."
  result=$( (aws_with_timeout ec2 associate-address --region $instance_region --network-interface-id $network_interface_id --allocation-id $1 --no-allow-reassociation) 2>&1 )
  exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    log "Failed to assign Elastic IP [$1] to network interface [$network_interface_id]. ERROR: $result"
  else
    log "Successfully assigned EIP $1 to network interface $network_interface_id"
  fi
  return $exit_code
}

try_to_assign() {
  for eip_id in "${eips[@]}"; do
    if attempt_to_assign_eip $eip_id; then
      log "Elastic IP successfully assigned to instance"
      return 0
    fi
  done
  return 1
}

main() {
  log "Starting EIP association process..."
  log "Tag Key: $TAG_KEY, Tag Value: $TAG_VALUE"
  
  # Test connectivity first
  test_connectivity
  
  local end_time=$((SECONDS+TIMEOUT))
  
  # Check if instance already has an EIP
  if check_existing_eip; then
    log "Instance already has an EIP assigned. No action needed."
    exit 0
  fi
  
  if ! aws_get_details; then
    log "Failed to get instance details. Exiting."
    exit 1
  fi
  
  while [ $SECONDS -lt $end_time ]; do
    if aws_get_unassigned_eips && try_to_assign "${eips[@]}"; then
      log "Successfully assigned EIP to instance $instance_id. New public IP should now be active."
      # Print the new public IP
      sleep 5
      NEW_IP=$(curl -s --retry 3 --retry-delay 2 http://169.254.169.254/latest/meta-data/public-ipv4)
      log "New public IP: $NEW_IP"
      exit 0
    fi
    log "Failed to assign EIP. Pausing for $PAUSE seconds before retrying..."
    sleep $PAUSE
  done
  
  log "Failed to assign Elastic IP after $TIMEOUT seconds."
  # Return success anyway to allow pod to continue
  log "Allowing pod to continue despite EIP allocation failure."
  exit 0
}

declare instance_id
declare instance_region
declare network_interface_id
declare eips

# Write header to log file
echo "===== EIP Allocator Starting $(date -u) =====" > /tmp/eip-allocator.log

# Run main function
main "$@"