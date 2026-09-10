output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC"
  value       = module.vpc.vpc_cidr_block
}

output "availability_zones" {
  description = "AZs the VPC's subnets are spread across"
  value       = var.availability_zones
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (worker nodes/pods)"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (NAT Gateways, internet-facing load balancers)"
  value       = module.vpc.public_subnets
}

output "nat_gateway_ids" {
  description = "IDs of the NAT Gateway(s)"
  value       = module.vpc.natgw_ids
}

output "private_route_table_ids" {
  description = "IDs of the private route tables"
  value       = module.vpc.private_route_table_ids
}

output "public_route_table_ids" {
  description = "IDs of the public route tables"
  value       = module.vpc.public_route_table_ids
}

# --- EKS Control Plane ---

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate data for the cluster's CA, needed to configure kubeconfig"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_version" {
  description = "Running Kubernetes version of the control plane"
  value       = module.eks.cluster_version
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS control plane's ENIs"
  value       = module.eks.cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's OIDC provider — used by IRSA role trust policies"
  value       = module.eks.oidc_provider_arn
}

output "eks_kms_key_arn" {
  description = "ARN of the KMS key used for EKS secrets envelope encryption"
  value       = aws_kms_key.eks.arn
}

# --- Node Groups / Compute ---

output "node_security_group_id" {
  description = "Security group ID shared by all worker nodes"
  value       = module.eks.node_security_group_id
}

output "node_group_autoscaling_group_names" {
  description = "Auto Scaling Group names backing each EKS managed node group"
  value       = module.eks.eks_managed_node_groups_autoscaling_group_names
}
