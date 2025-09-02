#!/bin/bash

# Show secrets for Authentik deployment
# This script retrieves and displays secrets from Kubernetes cluster

print_status() {
    echo -e "\033[0;34mℹ️  $1\033[0m"
}

print_success() {
    echo -e "\033[0;32m✅ $1\033[0m"
}

print_warning() {
    echo -e "\033[1;33m⚠️  $1\033[0m"
}

print_error() {
    echo -e "\033[0;31m❌ $1\033[0m"
}

echo "🔐 Authentik Secrets Retrieval"
echo "================================"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    print_error "kubectl is not installed or not in PATH"
    exit 1
fi

# Check if authentik namespace exists
if ! kubectl get namespace authentik &> /dev/null; then
    print_error "authentik namespace not found. Deploy the application first."
    exit 1
fi

# Check if secret exists
if ! kubectl get secret authentik-secrets -n authentik &> /dev/null; then
    print_error "authentik-secrets not found. Run deployment script first."
    exit 1
fi

print_status "Retrieving secrets from Kubernetes cluster..."

echo ""
echo "📋 Authentik Configuration Secrets:"
echo "===================================="

# Get and decode secrets
AUTHENTIK_SECRET_KEY=$(kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_SECRET_KEY}' | base64 -d)
DB_PASSWORD=$(kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__PASSWORD}' | base64 -d)
DB_HOST=$(kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__HOST}' | base64 -d)
DB_NAME=$(kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__NAME}' | base64 -d)
DB_USER=$(kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_POSTGRESQL__USER}' | base64 -d)
REDIS_HOST=$(kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_REDIS__HOST}' | base64 -d)

echo "🔑 AUTHENTIK_SECRET_KEY: $AUTHENTIK_SECRET_KEY"
echo "🗄️  DATABASE_PASSWORD:   $DB_PASSWORD"
echo "🗄️  DATABASE_HOST:       $DB_HOST"
echo "🗄️  DATABASE_NAME:       $DB_NAME"
echo "🗄️  DATABASE_USER:       $DB_USER"
echo "🔴 REDIS_HOST:           $REDIS_HOST"

echo ""
echo "📋 Additional Information:"
echo "=========================="

# Get ArgoCD admin password
if kubectl get secret argocd-initial-admin-secret -n argocd &> /dev/null; then
    ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d)
    echo "🔐 ArgoCD Admin Password: $ARGOCD_PASSWORD"
else
    print_warning "ArgoCD admin secret not found"
fi

# Get LoadBalancer URL
if kubectl get svc ingress-nginx-controller -n ingress-nginx &> /dev/null; then
    NGINX_URL=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    if [ ! -z "$NGINX_URL" ]; then
        echo "🌐 Authentik URL: http://$NGINX_URL"
    else
        print_warning "LoadBalancer URL not ready yet"
    fi
fi

echo ""
print_success "Secrets retrieved successfully!"
echo ""
print_warning "⚠️  Keep these secrets secure and do not share them!"
echo "💡 Tip: Use 'kubectl get secret authentik-secrets -n authentik -o yaml' for raw YAML output"