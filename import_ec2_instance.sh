#!/bin/bash

# Ultra Simple EC2 Import Script - No complex parsing
# Usage: ./import_ec2_instance.sh <instance-id>

set -e
export AWS_DEFAULT_REGION=ap-northeast-1

if [ $# -eq 0 ]; then
    echo "Usage: $0 <instance-id>"
    echo "Example: $0 i-0b7fc7c40f824a8b9"
    exit 1
fi

INSTANCE_ID="$1"

echo "🔧 Ultra Simple EC2 Import Script"
echo "=================================="
echo ""
echo "Importing instance: $INSTANCE_ID"
echo ""

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

# Step 1: Get instance details
echo "Step 1: Fetching instance details..."
INSTANCE_DATA=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0]' 2>/dev/null)

if [ $? -ne 0 ]; then
    echo "❌ Failed to get instance details. Please check the instance ID."
    exit 1
fi

# Extract information
NAME=$(echo $INSTANCE_DATA | jq -r '.Tags[]? | select(.Key=="Name") | .Value // "unnamed"')
AMI=$(echo $INSTANCE_DATA | jq -r '.ImageId')
INSTANCE_TYPE=$(echo $INSTANCE_DATA | jq -r '.InstanceType')
SUBNET_ID=$(echo $INSTANCE_DATA | jq -r '.SubnetId')
VPC_ID=$(echo $INSTANCE_DATA | jq -r '.VpcId')
PRIVATE_IP=$(echo $INSTANCE_DATA | jq -r '.PrivateIpAddress')
IAM_ROLE=$(echo $INSTANCE_DATA | jq -r '.IamInstanceProfile.Arn // "null"' | sed 's|.*/||')
KEY_NAME=$(echo $INSTANCE_DATA | jq -r '.KeyName // "null"')

# Security groups
SECURITY_GROUPS=$(echo $INSTANCE_DATA | jq -r '.SecurityGroups[].GroupId' | tr '\n' ' ')
SG_ARRAY="["
for sg in $SECURITY_GROUPS; do
    SG_ARRAY="$SG_ARRAY\"$sg\", "
done
SG_ARRAY=$(echo $SG_ARRAY | sed 's/, $//')"]"

# Metadata options
HTTP_ENDPOINT=$(echo $INSTANCE_DATA | jq -r '.MetadataOptions.HttpEndpoint // "enabled"')
HTTP_TOKENS=$(echo $INSTANCE_DATA | jq -r '.MetadataOptions.HttpTokens // "optional"')
HTTP_HOP_LIMIT=$(echo $INSTANCE_DATA | jq -r '.MetadataOptions.HttpPutResponseHopLimit // 1')
METADATA_TAGS=$(echo $INSTANCE_DATA | jq -r '.MetadataOptions.InstanceMetadataTags // "disabled"')

# Protection settings
TERMINATION_PROTECTION=$(aws ec2 describe-instance-attribute --instance-id $INSTANCE_ID --attribute disableApiTermination --query 'DisableApiTermination.Value' --output text)
STOP_PROTECTION=$(aws ec2 describe-instance-attribute --instance-id $INSTANCE_ID --attribute disableApiStop --query 'DisableApiStop.Value' --output text)

# Monitoring
MONITORING=$(echo $INSTANCE_DATA | jq -r '.Monitoring.State // "disabled"')
if [ "$MONITORING" = "enabled" ]; then
    MONITORING="true"
else
    MONITORING="false"
fi

# Root volume tags (preserve existing ones)
ROOT_VOLUME_TAGS=""
ROOT_VOLUME_ID=$(echo $INSTANCE_DATA | jq -r '.BlockDeviceMappings[] | select(.DeviceName == "/dev/xvda" or .DeviceName == "/dev/sda1") | .Ebs.VolumeId' | head -1)
ROOT_VOLUME_SIZE="20"
ROOT_VOLUME_TYPE="gp3"
ROOT_VOLUME_ENCRYPTED="false"

if [ "$ROOT_VOLUME_ID" != "null" ] && [ -n "$ROOT_VOLUME_ID" ]; then
    VOLUME_INFO=$(aws ec2 describe-volumes --volume-ids $ROOT_VOLUME_ID --query 'Volumes[0]' 2>/dev/null)
    if [ $? -eq 0 ]; then
        ROOT_VOLUME_SIZE=$(echo $VOLUME_INFO | jq -r '.Size')
        ROOT_VOLUME_TYPE=$(echo $VOLUME_INFO | jq -r '.VolumeType')
        ROOT_VOLUME_ENCRYPTED=$(echo $VOLUME_INFO | jq -r '.Encrypted')

        # Extract existing root volume tags
        ROOT_VOLUME_TAGS_JSON=$(echo $VOLUME_INFO | jq -r '.Tags // []')
        while IFS= read -r tag; do
            KEY=$(echo $tag | jq -r '.Key')
            VALUE=$(echo $tag | jq -r '.Value')
            VALUE=$(echo "$VALUE" | sed 's/"/\\"/g')
            if [[ $KEY =~ [^a-zA-Z0-9_] ]]; then
                ROOT_VOLUME_TAGS="$ROOT_VOLUME_TAGS        \"$KEY\" = \"$VALUE\"\n"
            else
                ROOT_VOLUME_TAGS="$ROOT_VOLUME_TAGS        $KEY = \"$VALUE\"\n"
            fi
        done < <(echo $ROOT_VOLUME_TAGS_JSON | jq -c '.[]')
    fi
fi

# Tags (escaped for main.tf)
TAGS_FORMATTED=""
TAGS_JSON=$(echo $INSTANCE_DATA | jq -r '.Tags // []')
while IFS= read -r tag; do
    KEY=$(echo $tag | jq -r '.Key')
    VALUE=$(echo $tag | jq -r '.Value')
    VALUE=$(echo "$VALUE" | sed 's/"/\\"/g')
    if [[ $KEY =~ [^a-zA-Z0-9_] ]]; then
        TAGS_FORMATTED="$TAGS_FORMATTED        \"$KEY\" = \"$VALUE\"\n"
    else
        TAGS_FORMATTED="$TAGS_FORMATTED        $KEY = \"$VALUE\"\n"
    fi
done < <(echo $TAGS_JSON | jq -c '.[]')

RESOURCE_NAME=$(echo $NAME | sed 's/[^a-zA-Z0-9_]/_/g' | sed 's/__*/_/g')

echo "✅ Instance details:"
echo "  Name: $NAME"
echo "  Resource: $RESOURCE_NAME"
echo "  Type: $INSTANCE_TYPE"
echo "  Root Volume: ${ROOT_VOLUME_SIZE}GB $ROOT_VOLUME_TYPE"
echo ""

# Simple check: if main.tf exists, we'll add to it, otherwise create new
if [ -f "main.tf" ]; then
    echo "📋 Found existing main.tf - will add this instance to it"

    # Check if this instance already exists in main.tf
    if grep -q "$RESOURCE_NAME" main.tf; then
        read -p "⚠️  Instance '$RESOURCE_NAME' already exists in main.tf. Overwrite? (y/n): " OVERWRITE
        if [[ ! $OVERWRITE =~ ^[Yy]$ ]]; then
            echo "Import cancelled."
            exit 0
        fi
    fi
else
    echo "📋 No main.tf found - will create new one"
fi

# Step 2: Adding instance to configuration
echo ""
echo "Step 2: Adding instance to configuration..."

# Backup existing main.tf if it exists
if [ -f "main.tf" ]; then
    cp main.tf main.tf.backup.$(date +%Y%m%d_%H%M%S)
    echo "✅ Backed up existing main.tf"
fi

# Generate the new instance block
NEW_INSTANCE="    $RESOURCE_NAME = {
      ami                    = \"$AMI\"
      instance_type         = \"$INSTANCE_TYPE\"
      subnet_id            = \"$SUBNET_ID\"
      vpc_id               = \"$VPC_ID\"
      security_group_ids   = $SG_ARRAY
      iam_instance_profile = $(if [ "$IAM_ROLE" != "null" ]; then echo "\"$IAM_ROLE\""; else echo "null"; fi)
      key_name             = $(if [ "$KEY_NAME" != "null" ]; then echo "\"$KEY_NAME\""; else echo "null"; fi)
      private_ip           = \"$PRIVATE_IP\"
      monitoring           = $MONITORING
      root_volume_size     = $ROOT_VOLUME_SIZE
      root_volume_type     = \"$ROOT_VOLUME_TYPE\"
      root_volume_encrypted = $ROOT_VOLUME_ENCRYPTED
      root_volume_tags     = {
$(echo -e "$ROOT_VOLUME_TAGS")      }
      ebs_volumes          = []
      user_data_path       = null
      http_endpoint        = \"$HTTP_ENDPOINT\"
      http_tokens          = \"$HTTP_TOKENS\"
      http_hop_limit       = $HTTP_HOP_LIMIT
      metadata_tags        = \"$METADATA_TAGS\"
      termination_protection = $(echo $TERMINATION_PROTECTION | tr '[:upper:]' '[:lower:]')
      stop_protection       = $(echo $STOP_PROTECTION | tr '[:upper:]' '[:lower:]')
      tags = {
$(echo -e "$TAGS_FORMATTED")      }
    }"

# Extract existing instances to preserve them (exclude the one we're replacing if it exists)
EXISTING_INSTANCES=$(extract_existing_instances)
if [ -n "$EXISTING_INSTANCES" ]; then
    # Remove this instance from existing instances if it exists
    EXISTING_INSTANCES=$(echo "$EXISTING_INSTANCES" | awk -v resource="$RESOURCE_NAME" '
    BEGIN { in_target_instance=0; brace_count=0 }

    # Check if this line starts the target instance
    $0 ~ "^[[:space:]]*" resource "[[:space:]]*=" {
        in_target_instance=1
        brace_count=1
        next
    }

    # If we are in the target instance, count braces to find its end
    in_target_instance==1 {
        for(i=1; i<=length($0); i++) {
            char = substr($0, i, 1)
            if(char == "{") brace_count++
            if(char == "}") brace_count--
        }

        if(brace_count == 0) {
            in_target_instance=0
        }
        next
    }

    # Print lines that are not part of the target instance
    in_target_instance==0 { print $0 }
    ')
fi

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
    delete_on_termination = false  # Preserve existing setting for imported instances
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
if [ -n "$EXISTING_INSTANCES" ]; then
    echo "✅ Existing instances preserved in configuration"
fi

# Step 3: Validate
echo ""
echo "Step 3: Validating configuration..."
terraform validate

if [ $? -ne 0 ]; then
    echo "❌ Validation failed"
    exit 1
fi

echo "✅ Configuration valid"

# Step 3.5: Check if instance already exists in state and remove if needed
echo ""
echo "Step 3.5: Checking if instance already exists in Terraform state..."
RESOURCE_ADDRESS="aws_instance.managed_instances[\"$RESOURCE_NAME\"]"

# Check if the resource exists in state
if terraform state show "$RESOURCE_ADDRESS" &>/dev/null; then
    echo "⚠️  Instance already managed by Terraform. Removing from state for re-import..."
    terraform state rm "$RESOURCE_ADDRESS"

    if [ $? -eq 0 ]; then
        echo "✅ Successfully removed from Terraform state"
    else
        echo "❌ Failed to remove from state"
        exit 1
    fi
else
    echo "✅ Instance not currently in Terraform state"
fi

# Step 4: Import
echo ""
echo "Step 4: Importing instance..."
terraform import "$RESOURCE_ADDRESS" "$INSTANCE_ID"

if [ $? -ne 0 ]; then
    echo "❌ Import failed"
    exit 1
fi

echo "✅ Import successful"

# Step 5: Final verification
echo ""
echo "Step 5: Final verification..."
terraform plan

echo ""
echo "🎉 Import Complete!"
echo "=================="
echo ""
echo "✅ Instance successfully imported:"
echo "  • $NAME ($INSTANCE_ID)"
echo "  • Resource: $RESOURCE_NAME"
echo "  • Type: $INSTANCE_TYPE"
echo ""
echo "📊 All managed instances:"
terraform state list | grep aws_instance
echo ""
echo "💡 To add more instances:"
echo "  • Create new: ./create_ec2_instance.sh"
echo "  • Import existing: ./import_ec2_instance.sh <instance-id>"
echo ""
echo "🎯 The instance is now managed by Terraform!"
