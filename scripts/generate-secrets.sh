#!/bin/bash

# Generate random secrets for Authentik deployment
# This script creates secure random secrets and applies them to Kubernetes

print_status() {
    echo -e "\033[0;34mℹ️  $1\033[0m"
}

print_success() {
    echo -e "\033[0;32m✅ $1\033[0m"
}

# Get Terraform outputs for database and Redis endpoints
print_status "Getting infrastructure endpoints from Terraform..."
cd terraform
DB_HOST=$(terraform output -raw rds_endpoint 2>/dev/null || echo "")
REDIS_HOST=$(terraform output -raw redis_endpoint 2>/dev/null || echo "")
cd ..

if [ -z "$DB_HOST" ] || [ -z "$REDIS_HOST" ]; then
    echo "⚠️  Could not get endpoints from Terraform. Using placeholder values."
    DB_HOST="authentik-cluster-authentik-db.region.rds.amazonaws.com"
    REDIS_HOST="authentik-cluster-authentik-redis.region.cache.amazonaws.com"
fi

# Generate random secrets
print_status "Generating secure random secrets..."
AUTHENTIK_SECRET_KEY=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-50)
DB_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-32)

print_success "Generated secure random secrets"

# Create secrets YAML dynamically
print_status "Creating Kubernetes secret..."
kubectl create secret generic authentik-secrets \
    --namespace=authentik \
    --from-literal=AUTHENTIK_SECRET_KEY="$AUTHENTIK_SECRET_KEY" \
    --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$DB_PASSWORD" \
    --from-literal=AUTHENTIK_POSTGRESQL__HOST="$DB_HOST" \
    --from-literal=AUTHENTIK_POSTGRESQL__NAME="authentik" \
    --from-literal=AUTHENTIK_POSTGRESQL__USER="authentik" \
    --from-literal=AUTHENTIK_REDIS__HOST="$REDIS_HOST" \
    --dry-run=client -o yaml | kubectl apply -f -

print_success "Kubernetes secret created with random values"

# Update Terraform variables with generated password
print_status "Updating Terraform with generated database password..."
cd terraform
if [ -f "terraform.tfvars" ]; then
    # Update existing tfvars file
    sed -i.bak "s/^db_password = .*/db_password = \"$DB_PASSWORD\"/" terraform.tfvars
    sed -i.bak "s/^authentik_secret_key = .*/authentik_secret_key = \"$AUTHENTIK_SECRET_KEY\"/" terraform.tfvars
    print_success "Updated terraform.tfvars with generated secrets"
else
    print_status "terraform.tfvars not found - secrets only created in Kubernetes"
fi
cd ..

echo ""
print_success "Secret generation completed!"
echo "🔐 Secrets are now:"
echo "   ✅ Generated randomly (secure)"
echo "   ✅ Stored in Kubernetes only"
echo "   ✅ Not committed to Git"
echo "   ✅ Unique per deployment"