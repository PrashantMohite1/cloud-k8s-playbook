# HCL Cheatsheet

Quick-reference examples only — see [hcl-basics.md](hcl-basics.md) for explanations.
Paste any of these into `terraform console` to try them.

## Variables

```hcl
variable "environment" {
  type    = string
  default = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "additional_access_entries" {
  type = map(object({
    principal_arn     = string
    policy_arn        = string
    access_scope_type = optional(string, "cluster")
  }))
  default = {}
}

var.environment
```

## Locals

```hcl
locals {
  common_tags = {
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

local.common_tags
```

## Outputs

```hcl
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}
```

## String interpolation

```hcl
name = "${var.cluster_name}-vpc"
name = var.cluster_name   # braces optional for a bare reference
```

## Ternary

```hcl
condition ? value_if_true : value_if_false

4 > 2 ? "greater" : "lower"
var.single_nat_gateway ? "single-nat" : "per-az-nat"
version == "" ? { most_recent = true } : { addon_version = version }
```

## `for` expressions

```hcl
[for n in [1, 2, 3] : n * 10]                       # => [10, 20, 30]
[for n in [1, 2, 3, 4, 5, 6] : n if n % 2 == 0]      # => [2, 4, 6]
{for k, v in { a = 1, b = 2 } : k => v * 100}        # => { a = 100, b = 200 }
{for k, v in { a = 1, b = 2 } : upper(k) => v}       # => { A = 1, B = 2 }

{
  for name, version in local.addon_defaults : name => merge(
    { before_compute = contains(["vpc-cni", "eks-pod-identity-agent"], name) },
    version == "" ? { most_recent = true } : { addon_version = version },
    name == "aws-ebs-csi-driver" ? {
      pod_identity_association = [{
        role_arn        = module.ebs_csi_pod_identity.iam_role_arn
        service_account = "ebs-csi-controller-sa"
      }]
    } : {}
  )
}
```

## `count`

```hcl
module "karpenter" {
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  count  = var.enable_karpenter ? 1 : 0
}

module.karpenter[0].iam_role_arn
```

## `for_each`

```hcl
resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = var.iam_role_additional_policies
  role       = aws_iam_role.node.name
  policy_arn = each.value
}
```

## `depends_on`

```hcl
module "karpenter" {
  source       = "terraform-aws-modules/eks/aws//modules/karpenter"
  cluster_name = module.eks.cluster_name
  depends_on   = [module.eks]
}
```

## `dynamic` blocks

```hcl
dynamic "ingress" {
  for_each = var.allowed_ports
  content {
    from_port = ingress.value
    to_port   = ingress.value
    protocol  = "tcp"
  }
}
```

## Functions

```hcl
merge({ a = 1 }, { b = 2 }, { a = 99 })          # => { a = 99, b = 2 }
contains(["a", "b"], "a")                        # => true
lookup(var.tags, "Owner", "unknown")
try(var.optional.field, null)
coalesce(var.override, var.default)
concat([1, 2], [3])                              # => [1, 2, 3]
join(",", ["a", "b"])                            # => "a,b"
split(",", "a,b")                                # => ["a", "b"]
length(["a", "b"])                               # => 2
slice(data.aws_availability_zones.available.names, 0, 3)
cidrsubnet(var.vpc_cidr, 4, 0)
jsonencode({ Version = "2012-10-17" })
jsondecode(file("policy.json"))
templatefile("user-data.sh.tpl", { name = var.cluster_name })
```

## Data sources

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data.aws_availability_zones.available.names
data.aws_caller_identity.current.arn
```
