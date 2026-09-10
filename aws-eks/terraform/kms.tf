# KMS CMK for EKS secrets envelope encryption — see production-eks-checklist.md Section 2.
# Encrypts Kubernetes Secrets at rest in etcd, on top of EKS's own storage encryption.

resource "aws_kms_key" "eks" {
  description             = "EKS secrets envelope encryption for ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_in_days
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${var.cluster_name}-eks"
  target_key_id = aws_kms_key.eks.key_id
}
