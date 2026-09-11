# terraform-deployer-policy.json

Customer-managed IAM policy for the human/CI IAM user that runs `terraform
plan`/`apply`/`destroy` against `aws-eks/terraform/` — not a resource this
Terraform config creates, not an IRSA/in-cluster policy (those are Section 6).

## What it covers

Everything the current `.tf` files actually provision: the S3 state backend
(`envs/*.backend.hcl` buckets), VPC + VPC endpoints + flow logs, the EKS
cluster/nodegroups/access entries, the EKS/node/IRSA IAM roles (scoped to
`eks-*`, since `cluster_name` is always `eks-test`/`eks-prod`), the KMS key in
`kms.tf`, CloudWatch Logs for control-plane/flow logs, and the load balancer
controller's IRSA role in `addons.tf`. It intentionally leaves out Fargate
profiles, EKS addons, and Spot service-linked roles — nothing in this repo
uses them yet; add the relevant statements back if that changes.

It does **not** cover: creating the state bucket itself (bootstrap, one-time,
do it out-of-band), or the AWS Load Balancer Controller's own runtime
permissions (that's a separate policy the module generates and attaches to
its IRSA role — this policy only needs `iam:CreatePolicy` to create it, not
the underlying `elasticloadbalancing:*` actions themselves).

## Applying it

```bash
aws iam create-policy \
  --policy-name eks-terraform-deployer \
  --policy-document file://terraform-deployer-policy.json

aws iam attach-user-policy \
  --user-name <your-iam-user> \
  --policy-arn arn:aws:iam::<account-id>:policy/eks-terraform-deployer
```

## Known constraints

- Sits at ~5.8k of AWS's 6,144-character customer-managed-policy limit
  (measured with whitespace stripped) — there's headroom for small additions,
  but a large one (e.g. re-adding Fargate/addons) may need a second policy
  attached alongside this one rather than growing this file further.
- The `TerraformStateBackend`/`TerraformStateObjects` statements are scoped to
  the single `aws-tfstate-bucket-0` bucket that both `envs/test.backend.hcl`
  and `envs/prod.backend.hcl` point at (different keys, same bucket). Update
  this file if the bucket name ever changes.
- IAM role/policy/instance-profile scoping assumes every `cluster_name`
  starts with `eks-` (true for `eks-test`/`eks-prod` today). Widen the
  `eks-*` ARN patterns if that convention ever changes.
- This is a deploy-time policy, not least-privilege-for-production-security —
  several statements (EC2, EKS, Auto Scaling, KMS, CloudWatch Logs) use
  `Resource: "*"` because these AWS APIs don't support meaningful ARN scoping
  for the actions Terraform needs at create-time. `iam:PassRole` and
  `iam:CreateServiceLinkedRole` are condition-scoped to specific AWS services
  as the one place that matters most (an unscoped `PassRole` is the classic
  privilege-escalation footgun).
