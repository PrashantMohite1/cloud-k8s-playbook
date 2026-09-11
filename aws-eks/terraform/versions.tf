terraform {
  required_version = ">= 1.7.0"

  # Remote state — see production-eks-checklist.md Section 12.
  # Partial config: bucket/key/region can't come from variables (the backend is resolved
  # before the rest of the config is evaluated), so they're supplied at `terraform init`
  # time via -backend-config=envs/<env>.backend.hcl — one file per environment (same
  # bucket, key prefixed by env name: test/eks.tfstate, prod/eks.tfstate). This key
  # prefix is what isolates state per environment, so the default workspace is used
  # throughout — no `terraform workspace select`, which would otherwise double-nest
  # state under `env:/<workspace>/<key>` on top of the already-env-scoped key.
  backend "s3" {
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.14"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Auth for the kubernetes/helm providers — a short-lived token fetched fresh on every
# plan/apply via the AWS provider's own credentials (same ones running Terraform).
# Simpler than the `aws eks get-token` exec plugin (no local AWS CLI dependency), at
# the cost of the token being stored in state — acceptable here since it's short-lived
# (~15 min) and state access is already trusted/gitignored.
data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
