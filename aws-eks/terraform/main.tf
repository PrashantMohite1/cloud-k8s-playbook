# EKS Control Plane (Section 2) + Node Groups / Compute (Section 3).

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_private_access      = var.cluster_endpoint_private_access
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  # We manage the KMS key ourselves in kms.tf (custom alias, rotation, deletion window)
  # instead of letting the module create its own.
  create_kms_key = false
  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  enable_cluster_creator_admin_permissions = var.enable_cluster_creator_admin_permissions

  # var.node_groups covers only the fields each environment actually varies (size, instance
  # types, taints...); these apply to every node group regardless of environment:
  #   - skip the module's custom launch template so the native `disk_size` argument applies
  #     directly (simpler than hand-building block_device_mappings for now)
  #   - SSM Session Manager access instead of SSH keys/bastion
  eks_managed_node_groups = {
    for name, ng in var.node_groups : name => merge(ng, {
      use_custom_launch_template = false
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    })
  }

  tags = local.common_tags
}
