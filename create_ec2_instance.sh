#!/bin/bash

# Ultra Simple EC2 Instance Creator - No complex parsing
# Usage: ./create_ec2_instance.sh

set -e
export AWS_DEFAULT_REGION=ap-northeast-1

echo "🚀 Ultra Simple EC2 Instance Creator"
echo "===================================="
echo ""

# Function to get latest AMI
get_latest_ami() {
    local pattern=$1
    local owner=${2:-amazon}

    echo "Finding latest AMI..." >&2
    local ami_id=$(aws ec2 describe-images \
        --owners $owner \
        --filters "Name=name,Values=$pattern" "Name=state,Values=available" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>/dev/null)

    if [ "$ami_id" != "None" ] && [ -n "$ami_id" ]; then
        echo "Found: $ami_id" >&2
        echo $ami_id
    else
        echo "No AMI found" >&2
        return 1
    fi
}

# Function to extract existing instances from main.tf
extract_existing_instances() {
    if [ ! -f "main.tf" ]; then
        echo ""
        return
    fi

    # Extract the instances block content between "instances = {" and the matching "}"
    awk '
    /instances = \{/ {
        in_instances=1;
        brace_count=1;
        next
    }
    in_instances==1 {
        # Count braces to find the matching closing brace
        for(i=1; i<=length($0); i++) {
            char = substr($0, i, 1)
            if(char == "{") brace_count++
            if(char == "}") brace_count--
        }

        if(brace_count == 0) {
            in_instances=0
            next
        } else {
            print $0
        }
    }
    ' main.tf
}

# Simple function to check if main.tf exists and what instances are in it
check_existing_instances() {
    if [ ! -f "main.tf" ]; then
        echo "📋 No existing main.tf found - will create new one"
        return
    fi

    echo "📋 Current main.tf exists - will add to existing instances"

    # Simple check - just look for instance names
    echo "Current instances:"
    grep -E '^\s*[a-zA-Z0-9_]+ = \{' main.tf 2>/dev/null | sed 's/[[:space:]]*= {.*//' | sed 's/^[[:space:]]*/  • /' || echo "  None found"
}

# Collect all information first
echo "=== Instance Configuration ==="
echo ""

# Instance name
read -p "Enter instance name: " INSTANCE_NAME
RESOURCE_NAME=$(echo $INSTANCE_NAME | sed 's/[^a-zA-Z0-9_]/_/g' | sed 's/__*/_/g')

# Check current main.tf state
echo ""
check_existing_instances
echo ""

# Check if instance already exists by name
if [ -f "main.tf" ] && grep -q "^[[:space:]]*${RESOURCE_NAME}[[:space:]]*=" main.tf; then
    echo "❌ Instance '$RESOURCE_NAME' already exists in main.tf"
    echo "Please choose a different name or remove the existing one first."
    exit 1
fi

# Instance type
echo ""
echo "Common instance types:"
echo "  t3.micro, t3.small, t3.medium, t3.large"
echo "  c5.large, c5.xlarge, c5.2xlarge, c5.4xlarge"
echo "  m5.large, m5.xlarge, m5.2xlarge, m5.4xlarge"
read -p "Enter instance type: " INSTANCE_TYPE

# VPC selection
echo ""
echo "Available VPCs:"
aws ec2 describe-vpcs --query 'Vpcs[].{VpcId:VpcId,Name:Tags[?Key==`Name`].Value|[0],CIDR:CidrBlock}' --output table
read -p "Enter VPC ID: " VPC_ID

# Subnet selection
echo ""
echo "Available subnets in VPC $VPC_ID:"
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[].{SubnetId:SubnetId,Name:Tags[?Key==`Name`].Value|[0],CIDR:CidrBlock,AZ:AvailabilityZone}' --output table
read -p "Enter Subnet ID: " SUBNET_ID

# Security Groups
echo ""
echo "Available security groups in VPC $VPC_ID:"
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[].{GroupId:GroupId,GroupName:GroupName,Description:Description}' --output table
echo ""
echo "💡 Enter Security Group IDs (sg-xxxxx), not names!"
read -p "Enter security group IDs (space-separated): " -a SECURITY_GROUPS

# Validate security group IDs
for sg in "${SECURITY_GROUPS[@]}"; do
    if [[ ! $sg =~ ^sg-[0-9a-f]+$ ]]; then
        echo "❌ Invalid security group format: $sg"
        echo "Please use IDs like: sg-08b61d2c25fc4fe3f"
        exit 1
    fi
done

# AMI selection
echo ""
echo "AMI Options:"
echo "1. Latest Amazon Linux 2023"
echo "2. Latest Ubuntu 22.04 LTS"
echo "3. Latest Ubuntu 20.04 LTS"
echo "4. Custom AMI ID"
read -p "Choose AMI option (1-4): " AMI_CHOICE

case $AMI_CHOICE in
    1)
        AMI_ID=$(get_latest_ami "al2023-ami-*-x86_64" "amazon")
        ;;
    2)
        AMI_ID=$(get_latest_ami "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "099720109477")
        ;;
    3)
        AMI_ID=$(get_latest_ami "ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*" "099720109477")
        ;;
    4)
        read -p "Enter custom AMI ID: " AMI_ID
        ;;
    *)
        echo "Invalid choice. Exiting."
        exit 1
        ;;
esac

if [ -z "$AMI_ID" ]; then
    echo "❌ Could not determine AMI ID. Exiting."
    exit 1
fi

# IAM Instance Profile
echo ""
echo "Available IAM instance profiles:"
aws iam list-instance-profiles --query 'InstanceProfiles[].InstanceProfileName' --output table
read -p "Enter IAM instance profile name (or press Enter for none): " IAM_PROFILE

# Key Pair
echo ""
echo "Available key pairs:"
aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName' --output table
read -p "Enter key pair name (or press Enter for none): " KEY_NAME

# Network settings
read -p "Specify private IP address (or press Enter for auto-assign): " PRIVATE_IP

# Monitoring
read -p "Enable detailed monitoring? (y/n) [n]: " MONITORING
MONITORING=${MONITORING:-n}
if [[ $MONITORING =~ ^[Yy]$ ]]; then
    MONITORING="true"
else
    MONITORING="false"
fi

# Storage configuration
echo ""
echo "=== Storage Configuration ==="
read -p "Root volume size in GB [20]: " ROOT_VOLUME_SIZE
ROOT_VOLUME_SIZE=${ROOT_VOLUME_SIZE:-20}

read -p "Root volume type (gp3/gp2/io1/io2) [gp3]: " ROOT_VOLUME_TYPE
ROOT_VOLUME_TYPE=${ROOT_VOLUME_TYPE:-gp3}

read -p "Encrypt root volume? (y/n) [y]: " ENCRYPT_ROOT
ENCRYPT_ROOT=${ENCRYPT_ROOT:-y}
if [[ $ENCRYPT_ROOT =~ ^[Yy]$ ]]; then
    ROOT_VOLUME_ENCRYPTED="true"
else
    ROOT_VOLUME_ENCRYPTED="false"
fi

# Additional volumes
echo ""
read -p "Add additional EBS volumes? (y/n) [n]: " ADD_VOLUMES
EBS_VOLUMES_ARRAY=""

if [[ $ADD_VOLUMES =~ ^[Yy]$ ]]; then
    VOLUME_COUNT=1
    EBS_VOLUMES_LIST=""

    while true; do
        echo ""
        echo "--- Additional Volume $VOLUME_COUNT ---"

        read -p "Device name [/dev/sd$(echo $VOLUME_COUNT | tr '123456789' 'fghijklmn')]: " DEVICE_NAME
        DEVICE_NAME=${DEVICE_NAME:-/dev/sd$(echo $VOLUME_COUNT | tr '123456789' 'fghijklmn')}

        read -p "Volume size in GB [100]: " VOLUME_SIZE
        VOLUME_SIZE=${VOLUME_SIZE:-100}

        read -p "Volume type [gp3]: " VOLUME_TYPE
        VOLUME_TYPE=${VOLUME_TYPE:-gp3}

        read -p "Encrypt volume? (y/n) [y]: " ENCRYPT_VOLUME
        ENCRYPT_VOLUME=${ENCRYPT_VOLUME:-y}
        if [[ $ENCRYPT_VOLUME =~ ^[Yy]$ ]]; then
            VOLUME_ENCRYPTED="true"
        else
            VOLUME_ENCRYPTED="false"
        fi

        read -p "Delete on termination? (y/n) [n]: " DELETE_ON_TERM
        DELETE_ON_TERM=${DELETE_ON_TERM:-n}
        if [[ $DELETE_ON_TERM =~ ^[Yy]$ ]]; then
            DELETE_ON_TERMINATION="true"
        else
            DELETE_ON_TERMINATION="false"
        fi

        # Add to volumes list
        if [ -n "$EBS_VOLUMES_LIST" ]; then
            EBS_VOLUMES_LIST="$EBS_VOLUMES_LIST, "
        fi

        EBS_VOLUMES_LIST="$EBS_VOLUMES_LIST{
          device_name = \"$DEVICE_NAME\"
          volume_size = $VOLUME_SIZE
          volume_type = \"$VOLUME_TYPE\"
          encrypted = $VOLUME_ENCRYPTED
          delete_on_termination = $DELETE_ON_TERMINATION
          name = \"volume-$VOLUME_COUNT\"
        }"

        echo "✓ Volume $VOLUME_COUNT configured"

        read -p "Add another volume? (y/n) [n]: " ADD_ANOTHER
        if [[ ! $ADD_ANOTHER =~ ^[Yy]$ ]]; then
            break
        fi
        ((VOLUME_COUNT++))
    done

    EBS_VOLUMES_ARRAY="[$EBS_VOLUMES_LIST]"
else
    EBS_VOLUMES_ARRAY="[]"
fi

# User data
echo ""
read -p "Enter user data script path (or press Enter for none): " USER_DATA_PATH

# Protection settings
read -p "Enable termination protection? (y/n) [n]: " TERM_PROTECTION
TERM_PROTECTION=${TERM_PROTECTION:-n}
if [[ $TERM_PROTECTION =~ ^[Yy]$ ]]; then
    TERM_PROTECTION="true"
else
    TERM_PROTECTION="false"
fi

read -p "Enable stop protection? (y/n) [n]: " STOP_PROTECTION
STOP_PROTECTION=${STOP_PROTECTION:-n}
if [[ $STOP_PROTECTION =~ ^[Yy]$ ]]; then
    STOP_PROTECTION="true"
else
    STOP_PROTECTION="false"
fi

# Tags
echo ""
echo "Configure additional tags (default tags will be added automatically):"
echo "Note: Name, Terraform, and Environment tags are added by default"
CUSTOM_TAGS=""
while true; do
    read -p "Tag key (or Enter to finish): " TAG_KEY
    if [ -z "$TAG_KEY" ]; then
        break
    fi

    # Skip default tags to avoid duplicates
    if [ "$TAG_KEY" = "Name" ] || [ "$TAG_KEY" = "Terraform" ] || [ "$TAG_KEY" = "Environment" ]; then
        echo "⚠️  Skipping '$TAG_KEY' - this is a default tag"
        continue
    fi

    read -p "Tag value for '$TAG_KEY': " TAG_VALUE

    if [[ $TAG_KEY =~ [^a-zA-Z0-9_] ]]; then
        CUSTOM_TAGS="$CUSTOM_TAGS        \"$TAG_KEY\" = \"$TAG_VALUE\"\n"
    else
        CUSTOM_TAGS="$CUSTOM_TAGS        $TAG_KEY = \"$TAG_VALUE\"\n"
    fi
done

# Build security groups array
SG_ARRAY="["
for sg in "${SECURITY_GROUPS[@]}"; do
    SG_ARRAY="$SG_ARRAY\"$sg\", "
done
SG_ARRAY=$(echo $SG_ARRAY | sed 's/, $//')"]"

# Summary
echo ""
echo "=== Configuration Summary ==="
echo "Instance Name: $INSTANCE_NAME"
echo "Resource Name: $RESOURCE_NAME"
echo "Instance Type: $INSTANCE_TYPE"
echo "AMI ID: $AMI_ID"
echo "VPC: $VPC_ID"
echo "Subnet: $SUBNET_ID"
echo "Security Groups: ${SECURITY_GROUPS[*]}"
echo "Root Volume: ${ROOT_VOLUME_SIZE}GB $ROOT_VOLUME_TYPE (encrypted: $ROOT_VOLUME_ENCRYPTED)"
if [ "$EBS_VOLUMES_ARRAY" != "[]" ]; then
    echo "Additional Volumes: Yes"
fi
echo ""

read -p "Add this instance to main.tf? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Adding instance to main.tf..."

# Backup existing main.tf if it exists
if [ -f "main.tf" ]; then
    cp main.tf main.tf.backup.$(date +%Y%m%d_%H%M%S)
    echo "✅ Backed up existing main.tf"
fi

# Generate the new instance block
NEW_INSTANCE="    $RESOURCE_NAME = {
      ami                    = \"$AMI_ID\"
      instance_type         = \"$INSTANCE_TYPE\"
      subnet_id            = \"$SUBNET_ID\"
      vpc_id               = \"$VPC_ID\"
      security_group_ids   = $SG_ARRAY
      iam_instance_profile = $(if [ -n "$IAM_PROFILE" ]; then echo "\"$IAM_PROFILE\""; else echo "null"; fi)
      key_name             = $(if [ -n "$KEY_NAME" ]; then echo "\"$KEY_NAME\""; else echo "null"; fi)
      private_ip           = $(if [ -n "$PRIVATE_IP" ]; then echo "\"$PRIVATE_IP\""; else echo "null"; fi)
      monitoring           = $MONITORING
      root_volume_size     = $ROOT_VOLUME_SIZE
      root_volume_type     = \"$ROOT_VOLUME_TYPE\"
      root_volume_encrypted = $ROOT_VOLUME_ENCRYPTED
      root_volume_tags     = {}
      ebs_volumes          = $EBS_VOLUMES_ARRAY
      user_data_path       = $(if [ -n "$USER_DATA_PATH" ]; then echo "\"$USER_DATA_PATH\""; else echo "null"; fi)
      http_endpoint        = \"enabled\"
      http_tokens          = \"required\"
      http_hop_limit       = 2
      metadata_tags        = \"enabled\"
      termination_protection = $TERM_PROTECTION
      stop_protection       = $STOP_PROTECTION
      tags = {
        Name = \"$INSTANCE_NAME\"
        Terraform = \"true\"
        Environment = \"staging\"
$(echo -e "$CUSTOM_TAGS")      }
    }"

# Extract existing instances to preserve them
EXISTING_INSTANCES=$(extract_existing_instances)

# Create or update main.tf
cat > main.tf << EOF
# Terraform configuration for EC2 instances
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

# Define the instances we want to manage
locals {
  instances = {
$(if [ -n "$EXISTING_INSTANCES" ]; then echo "$EXISTING_INSTANCES"; fi)
$NEW_INSTANCE
  }
}

# Create all instances using for_each
resource "aws_instance" "managed_instances" {
  for_each = local.instances

  ami                     = each.value.ami
  instance_type          = each.value.instance_type
  subnet_id              = each.value.subnet_id
  vpc_security_group_ids = each.value.security_group_ids
  iam_instance_profile   = each.value.iam_instance_profile
  key_name               = each.value.key_name
  private_ip             = each.value.private_ip
  monitoring             = each.value.monitoring

  # Root block device configuration
  root_block_device {
    volume_size = each.value.root_volume_size
    volume_type = each.value.root_volume_type
    encrypted   = each.value.root_volume_encrypted
    tags = merge(
      lookup(each.value, "root_volume_tags", {}),
      {
        Name = "\${each.value.tags.Name}-root"
      }
    )
  }

  # Dynamic EBS volumes
  dynamic "ebs_block_device" {
    for_each = lookup(each.value, "ebs_volumes", [])
    content {
      device_name = ebs_block_device.value.device_name
      volume_size = ebs_block_device.value.volume_size
      volume_type = ebs_block_device.value.volume_type
      encrypted = ebs_block_device.value.encrypted
      delete_on_termination = ebs_block_device.value.delete_on_termination
      tags = {
        Name = "\${each.value.tags.Name}-\${ebs_block_device.value.name}"
      }
    }
  }

  # User data script (if specified)
  user_data = each.value.user_data_path != null ? file(each.value.user_data_path) : null

  metadata_options {
    http_endpoint               = each.value.http_endpoint
    http_tokens                = each.value.http_tokens
    http_put_response_hop_limit = each.value.http_hop_limit
    instance_metadata_tags      = each.value.metadata_tags
  }

  disable_api_termination = each.value.termination_protection
  disable_api_stop        = each.value.stop_protection

  tags = each.value.tags

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      ami,
      user_data,
    ]
  }
}

# Outputs
output "managed_instances" {
  description = "Details of all managed instances"
  value = {
    for name, instance in aws_instance.managed_instances : name => {
      id         = instance.id
      private_ip = instance.private_ip
      public_ip  = instance.public_ip
      state      = instance.instance_state
    }
  }
}

output "instance_summary" {
  description = "Summary table of managed instances"
  value = {
    for name, config in local.instances : name => {
      instance_type = config.instance_type
      subnet_id    = config.subnet_id
      name_tag     = config.tags.Name
    }
  }
}
EOF

echo "✅ Added instance to existing main.tf configuration!"
echo ""
echo "Generated configuration for:"
echo "  • Instance: $INSTANCE_NAME"
echo "  • Type: $INSTANCE_TYPE"
echo "  • AMI: $AMI_ID"
echo "  • Storage: ${ROOT_VOLUME_SIZE}GB root volume"
if [ "$EBS_VOLUMES_ARRAY" != "[]" ]; then
    echo "  • Additional volumes: Yes"
fi
echo ""
if [ -n "$EXISTING_INSTANCES" ]; then
    echo "✅ Existing instances preserved in configuration"
    echo ""
fi
echo "Next steps:"
echo "1. Review main.tf"
echo "2. Run: terraform validate"
echo "3. Run: terraform plan"
echo "4. Run: terraform apply"
echo ""
echo "🎯 Instance ready to be created!"
