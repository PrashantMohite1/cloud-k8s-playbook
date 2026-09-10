locals {
  common_tags = {
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  # /20 per AZ (4094 usable IPs) — headroom for pod IP density via the VPC CNI.
  private_subnets = [for i in range(length(var.availability_zones)) : cidrsubnet(var.vpc_cidr, 4, i)]

  # /24 per AZ, offset by 48 netnums so this range never overlaps the /20 private
  # blocks above (which occupy netnums 0-15 in /20 terms, i.e. up to .47.x in /24 terms).
  public_subnets = [for i in range(length(var.availability_zones)) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
}
