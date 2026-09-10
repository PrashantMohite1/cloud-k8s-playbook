# Production environment — full HA, private-only API, everything the
# production-eks-checklist.md Section 1/2 items call for. Use with the "prod"
# Terraform workspace:
#
#   terraform workspace new prod   (first time only)
#   terraform workspace select prod
#   terraform plan  -var-file=envs/prod.tfvars
#   terraform apply -var-file=envs/prod.tfvars
#
# This costs meaningfully more than envs/test.tfvars (3 NAT Gateways + 5 interface
# endpoints x 3 AZs + flow logs) — that's the cost of the HA/security posture below.

cluster_name = "eks-prod"
aws_region   = "us-east-1"
environment  = "prod"

vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

single_nat_gateway = false # one NAT Gateway per AZ — no cross-AZ single point of failure

enable_vpc_endpoints    = true
enable_flow_logs        = true
flow_log_retention_days = 90

kubernetes_version              = "1.31"
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = false # private-only — reach the API via VPN/bastion/Direct Connect, not the internet
# Not used while cluster_endpoint_public_access = false. If you ever do need temporary
# public access, restrict this to a specific known CIDR — never 0.0.0.0/0.
cluster_endpoint_public_access_cidrs = []

cluster_log_retention_days               = 90
kms_key_deletion_window_in_days          = 30
enable_cluster_creator_admin_permissions = true

# Two node groups: a small On-Demand "system" pool (tainted so only pods that
# tolerate CriticalAddonsOnly land there — cluster-critical controllers, autoscaler,
# CoreDNS, CNI, etc.) and a larger Spot "general" pool for regular workloads. This is
# the On-Demand/Spot mix the checklist calls for — Spot for fault-tolerant workloads,
# On-Demand for anything the cluster itself depends on.
node_groups = {
  system = {
    instance_types = ["m5.large"]
    capacity_type  = "ON_DEMAND"
    min_size       = 2
    max_size       = 3
    desired_size   = 2
    disk_size      = 30
    labels         = { role = "system" }
    taints = {
      critical-addons = {
        key    = "CriticalAddonsOnly"
        value  = "true"
        effect = "NO_SCHEDULE"
      }
    }
  }
  general = {
    instance_types = ["m5.large", "m5a.large", "m5n.large"] # 3 types spread across Spot capacity pools
    capacity_type  = "SPOT"
    min_size       = 2
    max_size       = 6
    desired_size   = 3
    disk_size      = 50
    labels         = { role = "general" }
  }
}

# Needed so a Service/Ingress can provision a real internet-facing NLB/ALB.
# IMPORTANT: since cluster_endpoint_public_access = false above, `terraform apply`
# itself needs network access to the private API endpoint to install this Helm
# release — run it from a CI/CD runner, bastion, or VPN that's inside the VPC, not
# from an arbitrary laptop on the public internet.
enable_aws_load_balancer_controller = true
