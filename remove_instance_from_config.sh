#!/bin/bash

# Remove Instance from Configuration Script
# Usage: ./remove_instance_from_config.sh <resource_name>

set -e

if [ $# -eq 0 ]; then
    echo "Usage: $0 <resource_name>"
    echo "Example: $0 rakesh_test_1"
    echo ""
    echo "Current instances in main.tf:"
    if [ -f "main.tf" ]; then
        grep -E '^\s*[a-zA-Z0-9_]+ = \{' main.tf 2>/dev/null | sed 's/[[:space:]]*= {.*//' | sed 's/^[[:space:]]*/  • /' || echo "  None found"
    else
        echo "  No main.tf found"
    fi
    exit 1
fi

RESOURCE_NAME="$1"

echo "🗑️  Remove Instance from Configuration"
echo "====================================="
echo ""
echo "Target: $RESOURCE_NAME"
echo ""

# Check if main.tf exists
if [ ! -f "main.tf" ]; then
    echo "❌ No main.tf found"
    exit 1
fi

# Check if instance exists in configuration
if ! grep -q "^[[:space:]]*${RESOURCE_NAME}[[:space:]]*=" main.tf; then
    echo "❌ Instance '$RESOURCE_NAME' not found in main.tf"
    echo ""
    echo "Available instances:"
    grep -E '^\s*[a-zA-Z0-9_]+ = \{' main.tf 2>/dev/null | sed 's/[[:space:]]*= {.*//' | sed 's/^[[:space:]]*/  • /' || echo "  None found"
    exit 1
fi

# Backup main.tf
cp main.tf main.tf.backup.$(date +%Y%m%d_%H%M%S)
echo "✅ Backed up main.tf"

# Remove the instance block from main.tf
echo "🔧 Removing '$RESOURCE_NAME' from main.tf..."

# Use AWK to remove the specific instance block
awk -v resource="$RESOURCE_NAME" '
BEGIN {
    in_instances=0
    in_target_instance=0
    brace_count=0
    skip_line=0
}

# Track when we enter the instances block
/instances = \{/ {
    in_instances=1
    brace_count=1
    print $0
    next
}

# If we are in the instances block
in_instances==1 {
    # Check if this line starts the target instance
    if($0 ~ "^[[:space:]]*" resource "[[:space:]]*=") {
        in_target_instance=1
        brace_count++
        next
    }

    # If we are in the target instance, count braces to find its end
    if(in_target_instance==1) {
        for(i=1; i<=length($0); i++) {
            char = substr($0, i, 1)
            if(char == "{") brace_count++
            if(char == "}") brace_count--
        }

        if(brace_count == 1) {
            in_target_instance=0
        }
        next
    }

    # Count braces for the instances block
    for(i=1; i<=length($0); i++) {
        char = substr($0, i, 1)
        if(char == "{") brace_count++
        if(char == "}") brace_count--
    }

    if(brace_count == 0) {
        in_instances=0
        print $0
        next
    } else {
        # Print lines that are not part of the target instance
        if(in_target_instance==0) {
            print $0
        }
    }
}

# Print lines outside the instances block
in_instances==0 {
    print $0
}
' main.tf > main.tf.tmp

# Replace the original file
mv main.tf.tmp main.tf

echo "✅ Removed '$RESOURCE_NAME' from main.tf"

# Validate the configuration
echo ""
echo "🔍 Validating updated configuration..."
if terraform validate; then
    echo "✅ Configuration is valid"
else
    echo "❌ Configuration validation failed"
    echo "Restoring backup..."
    cp main.tf.backup.$(date +%Y%m%d_%H%M%S | head -1) main.tf 2>/dev/null || echo "Could not restore backup"
    exit 1
fi

# Show remaining instances
echo ""
echo "📋 Remaining instances in configuration:"
grep -E '^\s*[a-zA-Z0-9_]+ = \{' main.tf 2>/dev/null | sed 's/[[:space:]]*= {.*//' | sed 's/^[[:space:]]*/  • /' || echo "  None"

echo ""
echo "🎯 Next steps:"
echo "1. Review the updated main.tf"
echo "2. Run: terraform plan (should show 1 to destroy)"
echo "3. Run: terraform apply (will destroy the instance)"
echo ""
echo "💡 Note: The AWS instance is still running until you apply the changes"


# Option 2: Remove from state + config + manual cleanup
#terraform state rm 'aws_instance.managed_instances["rakesh_test_1"]'
#./remove_instance_from_config.sh rakesh_test_1
#aws ec2 terminate-instances --instance-ids i-07368e66fbc7eac87

