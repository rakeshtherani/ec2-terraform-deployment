#!/bin/bash

# EC2 Management Hub
# Central script to manage all EC2 operations

set -e
export AWS_DEFAULT_REGION=ap-northeast-1

echo "🎯 EC2 Management Hub"
echo "===================="
echo ""

# Check if required tools are installed
check_dependencies() {
    local missing_deps=()

    for cmd in aws terraform jq; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "❌ Missing required dependencies: ${missing_deps[*]}"
        echo "Please install them and try again."
        exit 1
    fi
}

# Function to list current instances
list_instances() {
    echo "📋 Current EC2 Instances"
    echo "========================"
    echo ""

    if [ -f "main.tf" ]; then
        echo "Terraform-managed instances:"
        terraform state list 2>/dev/null | grep aws_instance || echo "  None found in state"
        echo ""

        echo "Configuration summary:"
        terraform output instance_summary 2>/dev/null || echo "  Run 'terraform refresh' to see summary"
    else
        echo "❌ No main.tf found. No instances are currently managed by Terraform."
    fi

    echo ""
    echo "All AWS instances in region $AWS_DEFAULT_REGION:"
    aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],InstanceType,State.Name,PrivateIpAddress]' --output table 2>/dev/null || echo "  Failed to fetch AWS instances"
}

# Function to validate current setup
validate_setup() {
    echo "🔍 Validating Setup"
    echo "=================="
    echo ""

    if [ -f "main.tf" ]; then
        echo "✅ main.tf found"
        terraform validate
        if [ $? -eq 0 ]; then
            echo "✅ Terraform configuration is valid"
        else
            echo "❌ Terraform configuration has errors"
        fi
    else
        echo "⚠️  No main.tf found"
    fi

    echo ""
    echo "🔧 Checking AWS credentials..."
    aws sts get-caller-identity > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "✅ AWS credentials are working"
    else
        echo "❌ AWS credentials not configured or invalid"
    fi
}

# Function to show terraform plan
show_plan() {
    echo "📋 Terraform Plan"
    echo "================"
    echo ""

    if [ -f "main.tf" ]; then
        terraform plan
    else
        echo "❌ No main.tf found. Nothing to plan."
    fi
}

# Function to apply changes
apply_changes() {
    echo "🚀 Applying Terraform Changes"
    echo "============================"
    echo ""

    if [ -f "main.tf" ]; then
        echo "This will apply all pending changes to your infrastructure."
        read -p "Are you sure you want to continue? (yes/no): " confirm

        if [ "$confirm" = "yes" ]; then
            terraform apply
        else
            echo "Apply cancelled."
        fi
    else
        echo "❌ No main.tf found. Nothing to apply."
    fi
}

# Function to remove an instance from Terraform management
remove_instance() {
    echo "🗑️  Remove Instance from Management"
    echo "=================================="
    echo ""

    if [ ! -f "main.tf" ]; then
        echo "❌ No main.tf found."
        return
    fi

    echo "Current managed instances:"
    terraform state list | grep aws_instance
    echo ""

    read -p "Enter the instance resource name to remove (e.g., test_rakesh): " resource_name

    if [ -z "$resource_name" ]; then
        echo "❌ No resource name provided."
        return
    fi

    resource_address="aws_instance.managed_instances[\"$resource_name\"]"

    # Check if resource exists
    if terraform state show "$resource_address" &>/dev/null; then
        echo "⚠️  This will remove the instance from Terraform management."
        echo "The actual AWS instance will NOT be destroyed."
        echo ""
        read -p "Continue? (y/n): " confirm

        if [[ $confirm =~ ^[Yy]$ ]]; then
            # Remove from state
            terraform state rm "$resource_address"
            echo "✅ Instance removed from Terraform state"

            # Also remove from main.tf configuration
            echo "🔧 Removing from main.tf configuration..."

            # Backup main.tf
            cp main.tf main.tf.backup.$(date +%Y%m%d_%H%M%S)

            # Extract existing instances excluding the one being removed
            REMAINING_INSTANCES=$(awk -v resource="$resource_name" '
            BEGIN { in_target_instance=0; brace_count=0 }

            /instances = \{/ {
                in_instances=1;
                brace_count=1;
                print $0
                next
            }
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
                    # Only print if not in target instance
                    if(in_target_instance==0) {
                        print $0
                    }
                }
            }
            in_instances==0 { print $0 }
            ' main.tf > main.tf.tmp && mv main.tf.tmp main.tf)

            echo "✅ Instance removed from main.tf configuration"
            echo "💡 Configuration updated. You may want to run 'terraform plan' to verify."
        else
            echo "Operation cancelled."
        fi
    else
        echo "❌ Resource '$resource_name' not found in Terraform state."
    fi
}

# Function to backup current state
backup_state() {
    echo "💾 Backup Current State"
    echo "======================"
    echo ""

    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="backup_$timestamp"

    mkdir -p "$backup_dir"

    # Backup main files
    for file in main.tf terraform.tfstate terraform.tfstate.backup; do
        if [ -f "$file" ]; then
            cp "$file" "$backup_dir/"
            echo "✅ Backed up $file"
        fi
    done

    echo ""
    echo "✅ Backup created in: $backup_dir"
}

# Main menu
show_menu() {
    echo "Select an operation:"
    echo ""
    echo "1. 📋 List all instances"
    echo "2. ➕ Create new instance"
    echo "3. 📥 Import existing instance"
    echo "4. 🔍 Validate setup"
    echo "5. 📋 Show terraform plan"
    echo "6. 🚀 Apply changes"
    echo "7. 🗑️  Remove instance from management"
    echo "8. 💾 Backup current state"
    echo "9. ❌ Exit"
    echo ""
}

# Check dependencies first
check_dependencies

# Main loop
while true; do
    show_menu
    read -p "Enter your choice (1-9): " choice
    echo ""

    case $choice in
        1)
            list_instances
            ;;
        2)
            if [ -f "create_ec2_instance.sh" ]; then
                ./create_ec2_instance.sh
            else
                echo "❌ create_ec2_instance.sh not found in current directory"
            fi
            ;;
        3)
            if [ -f "import_ec2_instance.sh" ]; then
                read -p "Enter instance ID to import (e.g., i-0b7fc7c40f824a8b9): " instance_id
                if [ -z "${instance_id// }" ]; then
                    echo "❌ No instance ID provided"
                else
                    ./import_ec2_instance.sh "$instance_id"
                fi
            else
                echo "❌ import_ec2_instance.sh not found in current directory"
            fi
            ;;
        4)
            validate_setup
            ;;
        5)
            show_plan
            ;;
        6)
            apply_changes
            ;;
        7)
            remove_instance
            ;;
        8)
            backup_state
            ;;
        9)
            echo "👋 Goodbye!"
            exit 0
            ;;
        *)
            echo "❌ Invalid choice. Please select 1-9."
            ;;
    esac

    echo ""
    echo "Press Enter to continue..."
    read
    echo ""
done
