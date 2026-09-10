# HCL Basics for Production Terraform

This is a practical tour of the HCL (HashiCorp Configuration Language) syntax you'll
actually run into reading or writing the Terraform in this repo — not the full
language reference, just the pieces that show up constantly in production configs.

Every example below can be pasted straight into `terraform console` — a REPL that
evaluates HCL expressions without touching any cloud provider:

```bash
cd aws-eks/terraform   # or any directory with a terraform config
terraform console
```

Type an expression, hit Enter, see the result. `Ctrl+D` (or `Ctrl+Z` then Enter on
Windows) to exit.

---

## 1. Variables

Inputs to a module, declared once and supplied at `plan`/`apply` time (CLI flag,
`.tfvars` file, environment variable, or a default).

```hcl
variable "environment" {
  description = "Deployment environment"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}
```

- `type` catches mistakes at plan time (string, number, bool, list(...), map(...), object({...})).
- `validation` blocks enforce business rules beyond just type — the `environment`
  variable above rejects anything outside three known values. See
  [aws-eks/terraform/variables.tf](../../aws-eks/terraform/variables.tf) for real
  ones: `cluster_name` checked against a regex, `vpc_cidr` checked with `cidrhost()`,
  and `availability_zones` restricted to a list of length 2 or 3.
- Reference a variable anywhere with `var.<name>`.

## 2. Locals

Named expressions, computed once, reused by reference — think "a `let` binding for
your config." Unlike variables, locals aren't set from outside; they're derived from
other values.

```hcl
locals {
  common_tags = {
    Project     = var.cluster_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

Reference with `local.<name>`. Real example:
[aws-eks/terraform/locals.tf](../../aws-eks/terraform/locals.tf) computes subnet
CIDRs once as `local.private_subnets` / `local.public_subnets` and reuses them in
the `module "vpc"` block in [vpc.tf](../../aws-eks/terraform/vpc.tf) instead of
repeating the `cidrsubnet(...)` calls.

## 3. Outputs

Values a module exposes to whoever calls it (a human running `terraform output`, or
a parent module).

```hcl
output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value     = module.eks.cluster_certificate_authority_data
  sensitive = true
}
```

`sensitive = true` stops the value from being printed in plan/apply logs — use it for
anything secret-shaped.

## 4. String interpolation

`"${...}"` embeds an expression's result inside a string. Modern HCL lets you drop
the braces when the whole string is just one reference, but you still need them
when mixing literal text with a value:

```hcl
name = "${var.cluster_name}-vpc"

# just a reference, braces optional:
name = var.cluster_name
```

Real example: [aws-eks/terraform/vpc.tf](../../aws-eks/terraform/vpc.tf) builds the
VPC name as `"${var.cluster_name}-vpc"` and the endpoints security group name as
`"${var.cluster_name}-vpc-endpoints"`.

## 5. Conditionals — the ternary operator

HCL has no `if` statement, only an `if` *expression*:

```
condition ? value_if_true : value_if_false
```

```hcl
var.single_nat_gateway ? "cheap-single-nat" : "resilient-per-az-nat"
```

Read it as: "evaluate the condition; the whole expression collapses to whichever
branch matches." It's used constantly to make one field conditional without a
separate resource block — for example, choosing an EKS addon's version pin:

```hcl
version == "" ? { most_recent = true } : { addon_version = version }
```

If no version was pinned (`""`), use `most_recent = true`; otherwise pin the addon
to that exact version. (This will land in `main.tf` once the EKS control plane
module is added — see
[production-eks-checklist.md](../../aws-eks/docs/production-eks-checklist.md#2-eks-control-plane).)

## 6. `for` expressions

Not a loop that runs statements — an expression that **transforms one collection
into another**. Two shapes:

```hcl
# list -> list
[for x in var.list : upper(x)]

# map -> map (two loop variables: key, value)
{for k, v in var.map : k => upper(v)}
```

Add `if` to filter elements out:

```hcl
[for n in [1, 2, 3, 4, 5, 6] : n if n % 2 == 0]   # => [2, 4, 6]
```

Once the EKS control plane module is added, `main.tf` will build the `addons` map
for the EKS module this way — transforming a simpler map of addon-name →
pinned-version into full config objects, combining a `for` expression, a ternary,
and `merge()` in one line (see
[production-eks-checklist.md](../../aws-eks/docs/production-eks-checklist.md#4-kubernetes-add-ons)):

```hcl
addons = {
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

## 7. `count` vs `for_each` — creating multiple resources

Both are **meta-arguments** you can attach to any `resource` or `module` block to
create more than one instance from a single block.

**`count`** — a number; instances are indexed `0, 1, 2, ...`:

```hcl
resource "aws_security_group" "vpc_endpoints_sg" {
  count = var.enable_vpc_endpoints ? 1 : 0
  ...
}
```

This is the classic "conditionally create a resource" trick: `count = 0` means "don't
create this at all." Reference the result with an index:
`aws_security_group.vpc_endpoints_sg[0].id`. Real example:
[aws-eks/terraform/vpc.tf](../../aws-eks/terraform/vpc.tf) — both the security group
and the `module "vpc_endpoints"` block use this to skip creating VPC endpoints
entirely when `enable_vpc_endpoints = false`. The same
`count = var.enable_karpenter ? 1 : 0` pattern will apply once a Karpenter module is
added — see
[production-eks-checklist.md](../../aws-eks/docs/production-eks-checklist.md#5-karpenter-node-autoscaling).

**`for_each`** — a map or a set of strings; instances are keyed by whatever you
iterate over, which is more stable than `count` when the collection can change
(adding an item in the middle doesn't reshuffle every other instance's index):

```hcl
resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = var.iam_role_additional_policies
  role       = aws_iam_role.node.name
  policy_arn = each.value
}
```

Inside a `for_each` block, use `each.key` / `each.value` instead of an index.

Rule of thumb: prefer `for_each` for anything keyed by name (so removing one item
doesn't force-recreate unrelated ones); reach for `count` mainly for the
"0 or 1 of this" on/off pattern.

## 8. `depends_on`

Terraform normally infers ordering automatically from references (if block A uses
`module.b.output`, Terraform creates B first). `depends_on` forces an explicit
ordering when there's *no* such reference but one still exists in reality — usually
because a module takes a plain string, not a computed attribute.

```hcl
module "karpenter" {
  source       = "terraform-aws-modules/eks/aws//modules/karpenter"
  cluster_name = module.eks.cluster_name   # implicit dependency, this alone would be enough
  depends_on   = [module.eks]              # explicit, belt-and-suspenders
}
```

Use it sparingly — an explicit `depends_on` on both sides of two modules that also
reference each other's outputs creates a dependency **cycle**, which Terraform will
refuse to plan. No `irsa.tf` exists yet in this repo, so there's no live example to
point at — but it'll matter once IRSA roles are added, see
[production-eks-checklist.md](../../aws-eks/docs/production-eks-checklist.md#6-iam--access-control).

## 9. `dynamic` blocks

Most arguments are plain values, but some are nested *blocks* (no `=`), and you
can't loop over a block with a `for` expression. `dynamic` fills that gap:

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

This generates one `ingress { ... }` block per entry in `var.allowed_ports`. You
won't see this in the current EKS config (the modules here already expose
map/object-typed variables instead), but you'll hit it once you write raw
`aws_security_group` rules or similar.

## 10. Functions you'll use constantly

HCL ships a large stdlib of built-in functions (no user-defined functions in HCL
itself). The ones that show up everywhere in production code:

| Function | What it does | Example |
|---|---|---|
| `merge(a, b, ...)` | Combine maps; later args win on key clashes | `merge({a=1}, {a=2})` → `{a=2}` |
| `contains(list, val)` | Is `val` in `list`? | `contains(["a","b"], "a")` → `true` |
| `lookup(map, key, default)` | Safe map access with a fallback | `lookup(var.tags, "Owner", "unknown")` |
| `try(expr, default)` | Fall back if `expr` would error | `try(var.optional.field, null)` |
| `coalesce(a, b, ...)` | First non-null argument | `coalesce(var.override, var.default)` |
| `concat(list1, list2)` | Join lists | `concat([1,2], [3])` → `[1,2,3]` |
| `join(sep, list)` / `split(sep, str)` | List ↔ string | `join(",", ["a","b"])` → `"a,b"` |
| `length(x)` | Size of a list/map/string | `length(["a","b"])` → `2` |
| `slice(list, start, end)` | Sub-list | `slice(["a","b","c","d"], 0, 2)` → `["a","b"]` |
| `cidrsubnet(prefix, newbits, netnum)` | Carve a subnet out of a CIDR block | see `locals.tf` |
| `jsonencode(x)` / `jsondecode(str)` | Structured data ↔ JSON string | IAM policy documents |
| `templatefile(path, vars)` | Render a file as a template | user-data scripts |

Real example in
[aws-eks/terraform/locals.tf](../../aws-eks/terraform/locals.tf):

```hcl
locals {
  private_subnets = [for i in range(length(var.availability_zones)) : cidrsubnet(var.vpc_cidr, 4, i)]
}
```

## 11. Data sources

Read-only lookups against existing infrastructure — they don't create anything.

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}
```

Reference with `data.<type>.<name>.<attribute>`, e.g.
`data.aws_availability_zones.available.names`. This repo doesn't use a data source
for AZs — [aws-eks/terraform/variables.tf](../../aws-eks/terraform/variables.tf)
takes `availability_zones` as an explicit list variable instead, trading the
auto-discovery convenience for predictable, reviewable `plan` output (no surprise
AZ additions/removals between runs).

## 12. Object/map types in variables

Production variables are often typed as `object({...})` or `map(object({...}))` so
Terraform validates the *shape* of complex inputs, not just that they're "a map":

```hcl
variable "additional_access_entries" {
  type = map(object({
    principal_arn     = string
    policy_arn        = string
    access_scope_type = optional(string, "cluster")
  }))
  default = {}
}
```

`optional(type, default)` inside an object type marks a field as not required,
with a fallback if the caller omits it. This variable doesn't exist in
`variables.tf` yet — it'll land alongside EKS access-entry support, see
[production-eks-checklist.md](../../aws-eks/docs/production-eks-checklist.md#6-iam--access-control).

---

## Practice checklist

Open `terraform console` (in any directory with `.tf` files, or an empty scratch
folder for the pure-expression exercises) and work through these in order:

1. `[for n in [1,2,3] : n * 10]`
2. `{for k, v in {a=1, b=2} : k => v * 100}`
3. `[for n in [1,2,3,4,5,6] : n if n % 2 == 0]`
4. `contains(["x","y"], "x")`
5. `5 > 3 ? "yes" : "no"`
6. `merge({a=1}, {b=2}, {a=99})`
7. Rebuild the `addons` expression from Section 6 above inline, swapping in a
   placeholder string for `module.ebs_csi_pod_identity.iam_role_arn` — that module
   doesn't exist in this repo yet either, so a placeholder is all you have either way.
