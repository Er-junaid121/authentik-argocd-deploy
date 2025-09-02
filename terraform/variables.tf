variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "authentik-cluster"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "authentik-db"
}

variable "db_username" {
  description = "Database username"  
  type        = string
  default     = "authentik"
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
}

variable "authentik_secret_key" {
  description = "Authentik secret key (must be at least 32 characters)"
  type        = string
  sensitive   = true
}