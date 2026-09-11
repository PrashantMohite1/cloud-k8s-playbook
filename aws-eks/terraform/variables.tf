variable "aws_region" {
  description = "AWS region to deploy the VPC and cluster into"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name prefix used for the VPC and every related resource (also the future EKS cluster name)"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,38}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric/hyphens, 3-40 chars, and not start/end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, staging, prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (needs to be large enough for private /20 subnets + public /24 subnets per AZ)"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "AZs to spread subnets across — must be real AZ names for aws_region"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.availability_zones) == 2 || length(var.availability_zones) == 3
    error_message = "availability_zones must contain 2 or 3 AZs — production clusters should use 3 for full HA."
  }
}

variable "single_nat_gateway" {
  description = "Use one shared NAT Gateway instead of one per AZ. Cheaper but a cross-AZ SPOF — leave false in prod."
  type        = bool
  default     = false
}

variable "enable_vpc_endpoints" {
  description = "Create VPC endpoints (S3 gateway + ECR/EC2/STS/CloudWatch Logs interface endpoints) to keep AWS API traffic off the public internet and reduce NAT cost"
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs"
  type        = number
  default     = 90
}

# --- EKS Control Plane — see production-eks-checklist.md Section 2. ---

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane — pin explicitly, never leave blank/\"latest\""
  type        = string
  default     = "1.36"
}

variable "cluster_endpoint_private_access" {
  description = "Enable the API server's private endpoint (reachable from inside the VPC)"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable the API server's public endpoint. Prefer false (private-only) in prod; if true, restrict cluster_endpoint_public_access_cidrs"
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to reach the public API endpoint. Only applies when cluster_endpoint_public_access = true"
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "cluster_endpoint_public_access_cidrs must not include 0.0.0.0/0 — restrict to known CIDRs (office/VPN), even with the public endpoint enabled."
  }
}

variable "cluster_log_retention_days" {
  description = "CloudWatch Logs retention for EKS control plane logs (api, audit, authenticator, controllerManager, scheduler)"
  type        = number
  default     = 90
}

variable "kms_key_deletion_window_in_days" {
  description = "Waiting period before the EKS secrets KMS key is actually deleted, if ever scheduled for deletion"
  type        = number
  default     = 30
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Grant the IAM principal running Terraform cluster-admin via an EKS access entry"
  type        = bool
  default     = true
}

# --- Node Groups / Compute — see production-eks-checklist.md Section 3. ---

variable "node_groups" {
  description = "EKS managed node group definitions, keyed by node group name"
  type = map(object({
    ami_type            = optional(string, "AL2023_x86_64_STANDARD") # or BOTTLEROCKET_x86_64
    ami_release_version = optional(string, null)                     # pin an exact AMI release; null = latest at creation time
    instance_types      = list(string)                               # list several when capacity_type = SPOT, for pool diversity
    capacity_type       = optional(string, "ON_DEMAND")              # ON_DEMAND | SPOT
    min_size            = number
    max_size            = number
    desired_size        = number
    disk_size           = optional(number, 20) # GiB, gp3
    labels              = optional(map(string), {})
    taints = optional(map(object({
      key    = string
      value  = optional(string)
      effect = string # NO_SCHEDULE | NO_EXECUTE | PREFER_NO_SCHEDULE
    })), {})
  }))

  default = {
    general = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
    }
  }
}

# --- Kubernetes Add-ons — see production-eks-checklist.md Section 4. ---
# Only the AWS Load Balancer Controller so far, needed to expose Services/Ingresses
# to the internet via NLB/ALB (nodes have no public IP of their own).

variable "enable_aws_load_balancer_controller" {
  description = "Install the AWS Load Balancer Controller via Helm, so Services/Ingresses can provision real NLBs/ALBs"
  type        = bool
  default     = false
}
