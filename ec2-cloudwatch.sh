#!/bin/bash

# List of AWS regions to target
REGIONS=(
    "ap-east-1"
    "ap-northeast-1"
    "ap-northeast-2"
    "ap-northeast-3"
    "ap-south-1"
    "ap-southeast-1"
    "ap-southeast-2"
    "ca-central-1"
    "us-east-1"
    "us-east-2"
    "us-west-1"
    "us-west-2"
    "eu-central-1"
    "eu-north-1"
    "eu-west-1"
    "eu-west-2"
    "eu-west-3"
    "sa-east-1"
)

# Function to get timestamp in UTC
get_timestamp() {
    local offset=$1
    if [ -z "$offset" ]; then
        python3 -c 'from datetime import datetime; print(datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))'
    else
        # Extract number of days from the offset (removes the 'd' suffix)
        days=${offset%d}
        python3 -c "from datetime import datetime, timedelta; print((datetime.utcnow() + timedelta(days=$days)).strftime('%Y-%m-%dT%H:%M:%SZ'))"
    fi
}


# Function to find snapshots from unused EBS volumes
find_snapshots_from_unused_ebs() {
    local region=$1
    
    # Get list of available (unused) volumes
    echo "Finding unused volumes in $region..."
    unused_volumes=$(aws ec2 describe-volumes \
        --region "$region" \
        --filters "Name=status,Values=available" \
        --query 'Volumes[*].VolumeId' \
        --output text)
    
    if [ -n "$unused_volumes" ]; then
        echo "Finding snapshots for unused volumes..."
        for volume in $unused_volumes; do
            aws ec2 describe-snapshots \
                --region "$region" \
                --filters "Name=volume-id,Values=$volume" \
                --query 'Snapshots[*].[SnapshotId,VolumeId,StartTime,Description]' \
                --output text | \
                while IFS=$'\t' read -r snapshot_id volume_id start_time description; do
                    echo "$region,$snapshot_id,$volume_id,$start_time,$description" >> unused_ebs_snapshots.csv
                done
        done
    fi
}

# Function to get EBS volume metrics
get_ebs_metrics() {
    local region=$1
    local start_time=$2
    local end_time=$3
    local period=$4
    local volume_id=$5
    local state=$6
    local attachment_time=$7
    local instance_id=$8
    
    # Get read operations
    aws cloudwatch get-metric-statistics \
        --region "$region" \
        --namespace AWS/EBS \
        --metric-name VolumeReadOps \
        --dimensions Name=VolumeId,Value="$volume_id" \
        --period "$period" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --statistics Maximum \
        --output json | \
        jq -r --arg region "$region" \
            --arg volume_id "$volume_id" \
            --arg state "$state" \
            --arg attachment_time "$attachment_time" \
            --arg instance_id "$instance_id" \
            '.Datapoints[] | [$region, $volume_id, $state, $attachment_time, $instance_id, .Timestamp, .Maximum, null] | @csv' >> ebs_volume_metrics.csv
    
    # Get write operations
    aws cloudwatch get-metric-statistics \
        --region "$region" \
        --namespace AWS/EBS \
        --metric-name VolumeWriteOps \
        --dimensions Name=VolumeId,Value="$volume_id" \
        --period "$period" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --statistics Maximum \
        --output json | \
        jq -r --arg region "$region" \
            --arg volume_id "$volume_id" \
            --arg state "$state" \
            --arg attachment_time "$attachment_time" \
            --arg instance_id "$instance_id" \
            '.Datapoints[] | [$region, $volume_id, $state, $attachment_time, $instance_id, .Timestamp, null, .Maximum] | @csv' >> ebs_volume_metrics.csv
}

# Function to get EC2 CPU metrics
get_ec2_cpu_metrics() {
    local region=$1
    local start_time=$2
    local end_time=$3
    local period=$4
    local instance_id=$5
    local instance_type=$6
    local platform=$7
    local platform_details=$8
    
    aws cloudwatch get-metric-statistics \
        --region "$region" \
        --namespace AWS/EC2 \
        --metric-name CPUUtilization \
        --dimensions Name=InstanceId,Value="$instance_id" \
        --period "$period" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --statistics Average \
        --output json | \
        jq -r --arg region "$region" \
            --arg instance_id "$instance_id" \
            --arg type "$instance_type" \
            --arg platform "$platform" \
            --arg platform_details "$platform_details" \
            '.Datapoints[] | [$region, $instance_id, $type, $platform, $platform_details, .Timestamp, .Average] | @csv' >> ec2_cpu_metrics.csv
}

# Function to find unused Elastic IPs
find_unused_eips() {
    local region=$1
    
    echo "Finding unused Elastic IPs in $region..."
    aws ec2 describe-addresses \
        --region "$region" \
        --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
        --output text | \
        while IFS=$'\t' read -r public_ip allocation_id; do
            echo "$region,$public_ip,$allocation_id" >> unused_eips.csv
        done
}

# Calculate timestamps
END_TIME=$(get_timestamp)
START_90D=$(get_timestamp "-90d")
PERIOD=2592000

echo "END_TIME: $END_TIME"
echo "START_90D: $START_90D"

# Create CSV headers
echo "region,volume_id,state,attachment_time,instance_id,timestamp,read_ops,write_ops" > ebs_volume_metrics.csv
echo "region,instance_id,instance_type,platform,platform_details,timestamp,average_pct" > ec2_cpu_metrics.csv
echo "region,snapshot_id,volume_id,start_time,description" > unused_ebs_snapshots.csv
echo "region,public_ip,allocation_id" > unused_eips.csv

# Loop through each region
for region in "${REGIONS[@]}"; do
    echo "Processing region: $region"
    
    # Get instance IDs and types
    aws ec2 describe-instances \
        --region "$region" \
        --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,Platform,PlatformDetails]' \
        --output text > "instances_${region}.tmp"
    
    # Process EC2 instances
    while IFS=$'\t' read -r instance_id instance_type platform platform_details; do
        echo "Processing instance: $instance_id ($instance_type) in region: $region"
        get_ec2_cpu_metrics "$region" "$START_90D" "$END_TIME" "$PERIOD" "$instance_id" "$instance_type" "$platform" "$platform_details"
    done < "instances_${region}.tmp"

    # Process EBS volumes
    aws ec2 describe-volumes \
        --region "$region" \
        --query 'Volumes[].[VolumeId,State,Attachments[0].State,Attachments[0].AttachTime,Attachments[0].InstanceId,Attachments[0].Device]' \
        --output text | while IFS=$'\t' read -r volume_id state attachment_state attachment_time instance_id device; do
        
        echo "Processing volume: $volume_id"
        get_ebs_metrics "$region" "$START_90D" "$END_TIME" "$PERIOD" "$volume_id" "$state" "$attachment_time" "$instance_id"
    done

    # Find snapshots from unused EBS volumes
    find_snapshots_from_unused_ebs "$region"
    
    # Find unused Elastic IPs
    find_unused_eips "$region"
done
