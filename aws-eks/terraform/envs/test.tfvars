# Test/sandbox environment — optimized to minimize hourly AWS spend while still
# exercising the real module code path. Use with envs/test.backend.hcl:
#
#   terraform init -backend-config=envs/test.backend.hcl
#   terraform plan  -var-file=envs/test.tfvars
#   terraform apply -var-file=envs/test.tfvars
#
# Cost deltas vs. prod, and why:
#   - single_nat_gateway = true     → 1 NAT Gateway instead of 3 (~$0.045/hr x 2 saved)
#   - enable_vpc_endpoints = false  → skip 5 interface endpoints (~$0.01/hr each x 5)
#   - enable_flow_logs = false      → skip CloudWatch Logs ingestion/storage cost
#   - availability_zones: 2 not 3   → fewer subnets/route tables to reason about
#   - short log/KMS retention       → faster cleanup, nothing to keep long-term
# None of this is HA-safe — that's the point, this environment is disposable.

cluster_name = "eks-test"
aws_region   = "us-east-1"
environment  = "test"

vpc_cidr           = "10.1.0.0/16" # distinct /16 from prod's 10.0.0.0/16
availability_zones = ["us-east-1a", "us-east-1b"]

single_nat_gateway = true # 1 shared NAT Gateway — cheapest option, cross-AZ SPOF (fine for test)

enable_vpc_endpoints    = false # save the interface-endpoint hourly cost; ECR/STS/etc. traffic goes via NAT instead
enable_flow_logs        = false # save CloudWatch ingestion/storage cost
flow_log_retention_days = 7

kubernetes_version              = "1.36"
cluster_endpoint_private_access = true
cluster_endpoint_public_access  = true # convenience — reach the API from your laptop without a bastion/VPN
# Required since cluster_endpoint_public_access = true — your own IP as a /32 (never 0.0.0.0/0).
# Filled in via `curl ifconfig.me` on 2026-09-10 — re-run that and update this if your
# IP changes (most home/office connections are dynamic) or you're on a different network.
cluster_endpoint_public_access_cidrs = ["103.220.81.210/32"]

cluster_log_retention_days               = 7
kms_key_deletion_window_in_days          = 7
enable_cluster_creator_admin_permissions = true

# One small On-Demand node group — no Spot interruption risk. Graviton (ARM) for
# lower cost than the equivalent x86 size. No taints, so everything (including system
# pods) schedules here; fine for a disposable sandbox.
node_groups = {
  general = {
    ami_type       = "AL2023_ARM_64_STANDARD"
    instance_types = ["t4g.small"] # 2 vCPU, 2 GiB RAM
    capacity_type  = "ON_DEMAND"
    min_size       = 1
    max_size       = 2
    desired_size   = 1
    disk_size      = 20
    labels         = { role = "general" }
  }
}

# Needed so a Service/Ingress can provision a real internet-facing NLB/ALB — see
# ../../k8s-manifests/nginx-test.yaml for a working example once this is applied.
enable_aws_load_balancer_controller = true
