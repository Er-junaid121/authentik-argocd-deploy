# Authentik + ArgoCD on AWS EKS

This project deploys Authentik (identity provider) via ArgoCD (GitOps) on AWS EKS cluster with infrastructure as code using Terraform.

## Architecture

- **EKS Cluster**: Kubernetes cluster with managed node groups
- **PostgreSQL**: Amazon RDS for Authentik database
- **Redis**: Amazon ElastiCache for Authentik caching
- **ArgoCD**: GitOps deployment and management (ClusterIP + port-forward)
- **Authentik**: Identity and access management (via NGINX ingress)
- **NGINX Ingress**: Single LoadBalancer for cost optimization

## Prerequisites

- AWS CLI configured with appropriate permissions
- Terraform >= 1.0
- kubectl
- Git

### Required AWS Permissions

Your AWS user/role needs permissions for:
- EC2 (VPC, Security Groups, Subnets)
- EKS (Cluster creation and management)
- RDS (Database instances)
- ElastiCache (Redis)
- IAM (Roles and policies for EKS)

## Quick Start

### 1. Clone and Setup

```bash
git clone https://github.com/YOUR_USERNAME/authentik-argocd-aws.git
cd authentik-argocd-aws
```

### 2. Configure Variables

```bash
# Copy and edit the variables file
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` with your values:

```hcl
aws_region = "ap-south-1"
cluster_name = "authentik-cluster"
environment = "dev"

# Database Configuration
db_password = "your-secure-database-password"

# Authentik Configuration  
authentik_secret_key = "your-authentik-secret-key-min-32-chars"
```

### 3. Update Repository URL

Edit `argocd/applications/authentik.yaml` and update the repository URL:

```yaml
source:
  repoURL: https://github.com/YOUR_USERNAME/authentik-argocd-aws
```

### 4. Deploy

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

### 5. Deploy Authentik and Ingress

After the infrastructure is ready:

```bash
# Deploy Authentik via ArgoCD
kubectl apply -f argocd/applications/authentik.yaml

# Apply ingress resources
kubectl apply -f k8s-manifests/ingress-resources.yaml
```

## Access

### ArgoCD (Port-Forward Access)
- Port-forward: `kubectl port-forward svc/argocd-server -n argocd 8080:80`
- URL: `http://localhost:8080`
- Username: `admin`
- Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

### Authentik (Ingress Access)
- Get the NGINX LoadBalancer URL: `kubectl get svc ingress-nginx-controller -n ingress-nginx`
- Access Authentik via the LoadBalancer URL
- Follow Authentik's setup wizard on first access

## Project Structure

```
authentik-argocd-aws/
├── terraform/              # Infrastructure as Code
│   ├── main.tf             # Main Terraform configuration
│   ├── variables.tf        # Variable definitions
│   ├── outputs.tf          # Output values
│   ├── providers.tf        # Provider configurations
│   └── terraform.tfvars.example
├── argocd/                 # ArgoCD configurations
│   ├── applications/       # ArgoCD applications
│   └── charts/authentik/   # Authentik Helm chart
├── k8s-manifests/          # Kubernetes manifests
│   ├── ingress-resources.yaml  # Ingress configurations
│   └── nginx-ingress.yaml      # NGINX ingress setup
├── scripts/                # Deployment scripts
│   ├── deploy.sh          # Main deployment script
│   └── cleanup.sh         # Cleanup script
└── README.md
```

## Customization

### Database Configuration

To change database settings, modify variables in `terraform/variables.tf`:

```hcl
variable "db_instance_class" {
  default = "db.t3.small"  # Increase for production
}
```

### Authentik Configuration

Modify `argocd/charts/authentik/values.yaml` to customize Authentik:

```yaml
server:
  replicas: 2  # Increase for HA
  
resources:
  server:
    requests:
      memory: "512Mi"  # Increase for production
```

### Network Configuration

VPC and subnets can be customized in `terraform/main.tf`:

```hcl
variable "vpc_cidr" {
  default = "10.0.0.0/16"  # Change as needed
}
```

## Security Considerations

1. **Database Security**
   - Encrypted RDS with security groups
   - Database credentials stored as Kubernetes secrets

2. **Network Security**
   - Private subnets for EKS nodes
   - Security groups with minimal access
   - Single LoadBalancer reduces attack surface

3. **Production Recommendations**
   - Enable SSL/TLS certificates for ingress
   - Use AWS Secrets Manager
   - Enable audit logging
   - Set up monitoring
   - Configure proper DNS for ingress

## Monitoring

Monitor your deployment:

```bash
# Check EKS cluster status
kubectl get nodes

# Check ArgoCD applications
kubectl get applications -n argocd

# Check Authentik pods
kubectl get pods -n authentik

# Check NGINX ingress controller
kubectl get pods -n ingress-nginx

# View ArgoCD dashboard
kubectl port-forward svc/argocd-server -n argocd 8080:80

# Get Authentik URL
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

## Troubleshooting

### Common Issues

1. **Terraform fails to apply**
   - Check AWS credentials: `aws sts get-caller-identity`
   - Verify permissions
   - Check if resources already exist

2. **ArgoCD can't access Git repository**
   - Ensure repository URL is correct in `authentik.yaml`
   - Check if repository is public or configure credentials

3. **Authentik fails to start**
   - Check database connectivity
   - Verify secrets are created: `kubectl get secrets -n authentik`
   - Check pod logs: `kubectl logs -n authentik deployment/authentik-server`

### Getting Logs

```bash
# ArgoCD logs
kubectl logs -n argocd deployment/argocd-server

# Authentik logs
kubectl logs -n authentik deployment/authentik-server
kubectl logs -n authentik deployment/authentik-worker

# Database connectivity test
kubectl run -it --rm debug --image=postgres:15 --restart=Never -- psql -h <RDS_ENDPOINT> -U authentik -d authentik
```

## Cleanup

To destroy all resources:

```bash
chmod +x scripts/cleanup.sh
./scripts/cleanup.sh
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test the deployment
5. Submit a pull request

## License

This project is licensed under the MIT License.

## Support

For issues and questions:
1. Check the troubleshooting section
2. Review AWS EKS and ArgoCD documentation
3. Open an issue in this repository