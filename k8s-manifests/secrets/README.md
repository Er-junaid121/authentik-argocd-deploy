# Secrets Management (DEPRECATED)

⚠️ **This directory is deprecated.** Secrets are now generated dynamically.

## New Approach: Dynamic Secret Generation

Secrets are now generated automatically during deployment:
- **Random generation**: `scripts/generate-secrets.sh`
- **Secure**: 50-character random strings using OpenSSL
- **Unique**: Different secrets for each deployment
- **No Git storage**: Never stored in version control

## Security Benefits:

✅ **No hardcoded secrets** in repository  
✅ **Random generation** for maximum security  
✅ **Terraform integration** updates infrastructure  
✅ **Kubernetes-only storage** - secrets stay in cluster  

## Usage:

**Generate secrets** (automatic during deployment):
```bash
./scripts/deploy.sh
```

**View secrets** (when needed):
```bash
./scripts/show-secrets.sh
```

**Manual secret retrieval**:
```bash
# Get specific secret
kubectl get secret authentik-secrets -n authentik -o jsonpath='{.data.AUTHENTIK_SECRET_KEY}' | base64 -d

# Get all secrets in YAML format
kubectl get secret authentik-secrets -n authentik -o yaml
```

## For Production:
- Use **AWS Secrets Manager** with External Secrets Operator
- Use **Sealed Secrets** for GitOps workflows
- Use **Vault** for enterprise secret management