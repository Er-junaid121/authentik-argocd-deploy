# Data sources
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

# VPC
module "vpc" {
  source = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for k, v in slice(data.aws_availability_zones.available.names, 0, 3) : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in slice(data.aws_availability_zones.available.names, 0, 3) : cidrsubnet(var.vpc_cidr, 4, k + 4)]
  database_subnets = [for k, v in slice(data.aws_availability_zones.available.names, 0, 3) : cidrsubnet(var.vpc_cidr, 4, k + 8)]

  enable_nat_gateway     = true
  single_nat_gateway     = true
  enable_dns_hostnames   = true
  enable_dns_support     = true
  create_database_subnet_group = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = {
    Environment = var.environment
    Project     = "authentik-argocd"
  }
}

# EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Cluster access entry
  enable_cluster_creator_admin_permissions = true
  
  cluster_addons = {
    coredns                = {}
    eks-pod-identity-agent = {}
    kube-proxy            = {}
    vpc-cni               = {}
    aws-ebs-csi-driver    = {}
  }

  # EKS Managed Node Groups
  eks_managed_node_groups = {
    main = {
      min_size     = 1
      max_size     = 3
      desired_size = 2

      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"

      update_config = {
        max_unavailable_percentage = 25
      }
    }
  }

  tags = {
    Environment = var.environment
    Project     = "authentik-argocd"
  }
}

# RDS PostgreSQL for Authentik
resource "aws_db_subnet_group" "authentik" {
  name       = "${var.cluster_name}-db-subnet-group"
  subnet_ids = module.vpc.database_subnets

  tags = {
    Name        = "${var.cluster_name}-db-subnet-group"
    Environment = var.environment
  }
}

resource "aws_security_group" "rds" {
  name_prefix = "${var.cluster_name}-rds-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.cluster_name}-rds-sg"
    Environment = var.environment
  }
}

resource "aws_db_instance" "authentik" {
  identifier             = "${var.cluster_name}-authentik-db"
  engine                 = "postgres"
  engine_version         = "15.7"
  instance_class         = var.db_instance_class
  allocated_storage      = 20
  max_allocated_storage  = 100
  
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
  
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.authentik.name
  
  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "Sun:04:00-Sun:05:00"
  
  skip_final_snapshot = true
  deletion_protection = false

  tags = {
    Name        = "${var.cluster_name}-authentik-db"
    Environment = var.environment
  }
}

# Redis for Authentik caching
resource "aws_elasticache_subnet_group" "authentik" {
  name       = "${var.cluster_name}-redis-subnet-group"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "redis" {
  name_prefix = "${var.cluster_name}-redis-"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  tags = {
    Name        = "${var.cluster_name}-redis-sg"
    Environment = var.environment
  }
}

resource "aws_elasticache_replication_group" "authentik" {
  replication_group_id         = "${var.cluster_name}-authentik-redis"
  description                  = "Redis cluster for Authentik"
  
  port                         = 6379
  parameter_group_name         = "default.redis7"
  node_type                    = "cache.t3.micro"
  num_cache_clusters           = 1
  
  subnet_group_name            = aws_elasticache_subnet_group.authentik.name
  security_group_ids           = [aws_security_group.redis.id]
  
  at_rest_encryption_enabled   = true
  transit_encryption_enabled   = false  # Simplified for demo
  
  tags = {
    Name        = "${var.cluster_name}-authentik-redis"
    Environment = var.environment
  }
}

# Kubernetes namespaces
resource "kubernetes_namespace" "argocd" {
  depends_on = [module.eks]
  
  metadata {
    name = "argocd"
  }
}

resource "kubernetes_namespace" "authentik" {
  depends_on = [module.eks]
  
  metadata {
    name = "authentik"
  }
}

# Secrets for Authentik
resource "kubernetes_secret" "authentik_db" {
  depends_on = [kubernetes_namespace.authentik]
  
  metadata {
    name      = "authentik-db-secret"
    namespace = "authentik"
  }

  data = {
    AUTHENTIK_POSTGRESQL__HOST     = aws_db_instance.authentik.address
    AUTHENTIK_POSTGRESQL__NAME     = aws_db_instance.authentik.db_name
    AUTHENTIK_POSTGRESQL__USER     = aws_db_instance.authentik.username
    AUTHENTIK_POSTGRESQL__PASSWORD = aws_db_instance.authentik.password
  }

  type = "Opaque"
}

resource "kubernetes_secret" "authentik_redis" {
  depends_on = [kubernetes_namespace.authentik]
  
  metadata {
    name      = "authentik-redis-secret"
    namespace = "authentik"
  }

  data = {
    AUTHENTIK_REDIS__HOST = aws_elasticache_replication_group.authentik.primary_endpoint_address
  }

  type = "Opaque"
}

resource "kubernetes_secret" "authentik_secret_key" {
  depends_on = [kubernetes_namespace.authentik]
  
  metadata {
    name      = "authentik-secret-key"
    namespace = "authentik"
  }

  data = {
    AUTHENTIK_SECRET_KEY = var.authentik_secret_key
  }

  type = "Opaque"
}

# ArgoCD Installation
resource "helm_release" "argocd" {
  depends_on = [kubernetes_namespace.argocd]
  
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.6.12"
  namespace  = "argocd"

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }

  set {
    name  = "configs.params.server\\.insecure"
    value = "true"
  }
}