# Production EKS Cluster — Terraform Checklist

Scope of everything to account for when building a production-grade Amazon EKS cluster with Terraform. Use this as the planning doc before writing `.tf` files; check items off as modules are implemented.

## Summary Table

| # | Category | Key Terraform/Config Items | Priority |
|---|----------|------------------------------|----------|
| 1 | [Networking & VPC](#1-networking--vpc) | Multi-AZ subnets, NAT per AZ, subnet tags, VPC endpoints, flow logs | Critical |
| 2 | [EKS Control Plane](#2-eks-control-plane) | Pinned version, private endpoint, control plane logging, KMS secrets encryption, OIDC/IRSA | Critical |
| 3 | [Node Groups / Compute](#3-node-groups--compute) | Managed node groups (or hand-off to Karpenter), multi-AZ, On-Demand + Spot mix, taints/labels | Critical |
| 4 | [Kubernetes Add-ons](#4-kubernetes-add-ons) | VPC CNI, CoreDNS, kube-proxy, EBS/EFS CSI, LB Controller, ExternalDNS, Cert-Manager, Metrics Server | Critical |
| 5 | [Karpenter (Node Autoscaling)](#5-karpenter-node-autoscaling) | Controller + node IRSA roles, SQS/EventBridge for Spot interruption, subnet/SG discovery tags, `NodePool`/`EC2NodeClass` CRDs | High (if chosen over Cluster Autoscaler) |
| 6 | [IAM & Access Control](#6-iam--access-control) | IRSA per service account, `aws-auth`/access entries, least-privilege roles, no static creds | Critical |
| 7 | [Storage](#7-storage) | Encrypted gp3 default StorageClass, PV backup strategy, EFS if needed | High |
| 8 | [Security & Compliance](#8-security--compliance) | Endpoint restriction, network policies, secrets manager integration, image scanning, CIS benchmark | Critical |
| 9 | [Observability](#9-observability) | Container Insights/Prometheus, centralized logging, alerting, audit log analysis | High |
| 10 | [High Availability & DR](#10-high-availability--dr) | Multi-AZ, PDBs, backup/restore tested, DR strategy | High |
| 11 | [Cost Management](#11-cost-management) | Spot mix, autoscaler right-sizing, cost tags, Savings Plans | Medium |
| 12 | [Terraform Project Structure & State](#12-terraform-project-structure--state) | Remote S3+DynamoDB backend, per-env state, module choice, CI/CD gate, version pinning | Critical |
| 13 | [GitOps / Deployment Workflow](#13-gitops--deployment-workflow) | ArgoCD/Flux or CI/CD app deployment, Terraform vs. app-layer separation | High |

Jump to: [Module Layout](#actual-terraform-layout-as-built) · [Recommended Starting Point](#recommended-starting-point)

---

## 1. Networking & VPC

- Dedicated VPC (not shared with unrelated workloads), sized for future node/pod growth
- Public + private subnets across **3 Availability Zones** (HA requirement for control plane + nodes)
- Private subnets for worker nodes/pods; public subnets only for NAT Gateways / public-facing ALBs
- NAT Gateway per AZ (avoid single NAT as a cross-AZ bottleneck/SPOF) or NAT instance for cost-sensitive envs
- Correct subnet tags for EKS/ALB controller auto-discovery (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`, `kubernetes.io/cluster/<cluster-name>=shared`)
- VPC CNI IP planning — enough IPs per subnet for pod density (consider custom networking / prefix delegation for large clusters)
- Secondary CIDR for pods if using large pod counts (VPC CNI custom networking)
- Security groups: cluster SG, node SG, additional SGs for shared services
- Network ACLs (optional, defense-in-depth)
- VPC endpoints (S3, ECR API/DKR, STS, EC2, CloudWatch Logs, etc.) to keep traffic off public internet and reduce NAT cost
- VPC Flow Logs enabled for auditing/network troubleshooting

## 2. EKS Control Plane

- EKS cluster version pinned explicitly (not `latest`) with an upgrade strategy
- Private + public API endpoint access configured deliberately (prefer private endpoint + restricted public CIDRs, or fully private with VPN/Direct Connect/bastion)
- Control plane logging to CloudWatch: `api`, `audit`, `authenticator`, `controllerManager`, `scheduler`
- Cluster encryption config — KMS CMK for secrets envelope encryption (`encryption_config`)
- IRSA (IAM Roles for Service Accounts) OIDC provider enabled
- Cluster security group rules reviewed (control-plane-to-node communication)

## 3. Node Groups / Compute

- Managed Node Groups (EKS-managed) or self-managed ASGs, **or hand off dynamic provisioning to Karpenter** (see [Section 5](#5-karpenter-node-autoscaling)) — pick one strategy and justify it
- Separate node groups by workload type (system/critical, general, spot, GPU, high-memory, etc.) — still needed for a small "system" node group even when Karpenter handles the rest
- Mix of On-Demand (critical/system workloads) + Spot (fault-tolerant workloads) for cost optimization
- Launch templates with pinned AMI (EKS-optimized AMI, or Bottlerocket for hardened nodes)
- Node instance IAM role — least privilege (no unnecessary AWS-managed admin policies)
- Taints/labels per node group to control scheduling (e.g., `dedicated=system:NoSchedule`)
- Cluster Autoscaler configured with proper scale-down policies (only if not using Karpenter)
- Node disk size/type (gp3 recommended) sized for workload + container image cache
- Multi-AZ spread for node groups (avoid single-AZ node pools for HA workloads)
- Max pods per node tuned (ENI/IP limits vs. `max-pods` setting)
- Bottlerocket/AMI patching strategy (automated AMI rotation via launch template versions)

## 4. Kubernetes Add-ons

- **VPC CNI** (Amazon EKS add-on, version pinned)
- **CoreDNS** (add-on, sized/autoscaled — consider `cluster-proportional-autoscaler` or NodeLocal DNSCache for large clusters)
- **kube-proxy** (add-on)
- **EBS CSI Driver** (for PersistentVolumes) + IRSA role
- **EFS CSI Driver** if shared storage needed
- **AWS Load Balancer Controller** (ALB/NLB ingress) + IRSA role — the piece that lets a `Service`/`Ingress` provision a real internet-facing load balancer for pods sitting in private subnets; see [addons.tf](../terraform/addons.tf)
- **External DNS** for automated Route53 record management
- **Cert-Manager** for TLS certificate automation
- **Metrics Server** (required for HPA)
- **Cluster Autoscaler** or **Karpenter** controller (see [Section 5](#5-karpenter-node-autoscaling))
- Prefer managed EKS Add-ons over self-managed Helm where available, for easier version/security patching

## 5. Karpenter (Node Autoscaling)

Karpenter is an open-source, Kubernetes-native node autoscaler (originally built by AWS, now a CNCF project) that provisions EC2 instances directly and just-in-time, rather than scaling pre-defined Auto Scaling Groups. It's the recommended default for new production clusters over Cluster Autoscaler + static Managed Node Groups, but is called out as its own category because it introduces its own set of Terraform-managed resources beyond a normal node group.

**Why it's used in production:**
- Provisions the right instance type/size/AZ per pending pod automatically, instead of you pre-defining fixed instance types in a node group
- Faster scale-up (calls EC2 `RunInstances` directly — often seconds, vs. waiting on ASG scaling activities)
- Better bin-packing — consolidates workloads and replaces underutilized nodes to cut waste
- Native, low-effort Spot + On-Demand mixing with automatic fallback/replacement on Spot interruption
- Fewer node groups to hand-maintain as workload shapes change

**What Terraform needs to provision for it:**
- IAM role for the Karpenter **controller** (IRSA — scoped to `ec2:RunInstances`, `ec2:TerminateInstances`, `ec2:CreateLaunchTemplate`, `iam:PassRole`, pricing/spot APIs, etc.)
- IAM role + **instance profile** for the **nodes** Karpenter launches (equivalent to a node group's node role: CNI, ECR pull, SSM policies)
- SQS queue + EventBridge rules for Spot interruption / instance rebalance notifications (Karpenter's interruption handling)
- Cluster tagging (`karpenter.sh/discovery=<cluster-name>`) on subnets and security groups so Karpenter can auto-discover where to launch nodes
- Karpenter controller deployed via Helm (`helm_release` in Terraform, or handed off to GitOps) — the controller itself runs on the small "system" node group, not on nodes it manages
- `NodePool` and `EC2NodeClass` Kubernetes CRDs (applied via `kubectl_manifest`/Helm/GitOps, not raw Terraform resources) defining allowed instance types, AZs, capacity type (Spot/On-Demand), taints, and disk config

**Trade-offs vs. Managed Node Groups + Cluster Autoscaler:**
- More moving pieces to provision and reason about (IAM x2, SQS/EventBridge, CRDs) vs. a single `eks_managed_node_groups` block
- CRDs live outside pure Terraform state (usually applied post-cluster-bootstrap), so ordering/dependency needs care
- Newer tool — smaller operational track record than Cluster Autoscaler for teams new to it

**Terraform module:** the community module [`terraform-aws-modules/eks/aws`](https://github.com/terraform-aws-modules/terraform-aws-eks) has a companion Karpenter sub-module (`terraform-aws-modules/eks/aws//modules/karpenter`) that provisions the controller IAM role, node IAM role/instance profile, and SQS/EventBridge wiring in one block — preferred over hand-rolling these resources.

## 6. IAM & Access Control

- IRSA roles per service account (least-privilege, scoped to specific K8s namespaces/SAs) instead of broad node IAM roles
- `aws-auth` ConfigMap / EKS Access Entries mapping IAM principals to K8s RBAC groups
- Separate IAM roles for humans (SSO/Assume-Role) vs. CI/CD pipelines vs. controllers
- No long-lived static credentials in-cluster
- Cluster admin access restricted to a small, audited group
- Terraform-managed IAM boundary/permissions boundary if org requires it

## 7. Storage

- Default `StorageClass` set explicitly (gp3, encrypted by default)
- EBS volumes encrypted with KMS CMK
- Backup strategy for PVs (Velero, AWS Backup for EBS snapshots)
- EFS for RWX (ReadWriteMany) workloads if required

## 8. Security & Compliance

- Private endpoint access; restrict public endpoint CIDR allow-list
- Security groups following least privilege (no 0.0.0.0/0 except where required, e.g. public ALB)
- Pod Security Standards / Pod Security Admission (restricted profile) instead of deprecated PSPs
- Network Policies (Calico, or VPC CNI network policy support) for pod-to-pod traffic segmentation
- Secrets management — AWS Secrets Manager / Parameter Store via External Secrets Operator, not plain K8s Secrets
- KMS encryption for: EKS secrets envelope, EBS volumes, S3 (state, logs, backups)
- Image scanning (ECR scan-on-push) and admission control (e.g., OPA/Gatekeeper, Kyverno) for policy enforcement
- Private ECR repos with least-privilege repo policies
- Guardduty EKS Protection / Security Hub integration
- CIS EKS Benchmark compliance check (kube-bench)
- Regular patching cadence for cluster version, node AMIs, and add-ons

## 9. Observability

- Container Insights (CloudWatch) or Prometheus/Grafana stack (self-managed or AMP/AMG — Amazon Managed Prometheus/Grafana)
- Centralized logging: Fluent Bit → CloudWatch Logs / OpenSearch / S3
- Alerting (CloudWatch Alarms, Alertmanager) on node health, pod crashloops, control plane errors, capacity thresholds
- Distributed tracing if applicable (X-Ray, OpenTelemetry)
- Audit log analysis (control plane `audit` logs → SIEM)

## 10. High Availability & DR

- Multi-AZ control plane (default with EKS) and multi-AZ node groups
- PodDisruptionBudgets for critical workloads
- Multi-region DR strategy if RTO/RPO requires it (separate cluster + Velero/backup replication, or GitOps re-deploy)
- etcd/control plane is AWS-managed — no direct backup needed, but document RPO expectations
- Backup of persistent data (Velero + S3, EBS snapshots) with tested restore procedure

## 11. Cost Management

- Spot instances for interruption-tolerant workloads
- Right-sizing via Cluster Autoscaler/Karpenter + VPA recommendations
- Cost allocation tags on all resources (team, environment, cost-center)
- Savings Plans / Reserved Instances for steady-state baseline capacity
- Separate node groups to isolate and track cost by workload
- See [networking-cost-analysis](prd-networking-cost-analysis.md) for a full NAT Gateway / VPC endpoint pricing breakdown and ranked cost-cutting recommendations

## 12. Terraform Project Structure & State

- Remote state backend (S3 + DynamoDB lock table, or Terraform Cloud) — encrypted, versioned S3 bucket
- State isolated per environment (dev/staging/prod) — separate state files/workspaces
- Modules: reuse community module (`terraform-aws-modules/eks/aws`) or build internal module — decide and document
- Environment-specific `tfvars` (no hardcoded prod values in shared modules)
- CI/CD pipeline for `plan`/`apply` with mandatory review/approval gate for prod
- `terraform plan` output reviewed and drift detection scheduled
- Provider version pinning (`required_providers` with version constraints)
- Sensitive outputs marked `sensitive = true` (kubeconfig, tokens)
- Tagging strategy applied consistently via `default_tags` on the AWS provider

## 13. GitOps / Deployment Workflow

- GitOps tool (ArgoCD/Flux) or CI/CD pipeline for application deployments post-cluster-creation
- Separation of concerns: Terraform provisions infra + add-ons, GitOps/Helm manages app workloads — see [k8s-manifests/](../k8s-manifests/) for a plain-`kubectl` example kept deliberately outside Terraform state
- Cluster bootstrap automation (Helm/Terraform `helm_release` or a bootstrap ArgoCD app-of-apps)

---

## Actual Terraform Layout (as built)

A single root module (not split into `modules/` yet — that's a fine next step once
the config grows unwieldy), with per-environment values in `envs/*.tfvars` and a
matching per-environment S3 backend key in `envs/*.backend.hcl` — no Terraform
workspaces; the backend key is what isolates state per environment:

```
aws-eks/
├── docs/
│   ├── production-eks-checklist.md      # this file
│   ├── prd-networking-cost-analysis.md  # NAT Gateway / VPC endpoint pricing (Section 1, 11)
│   └── terraform-configs-explaination.md
├── k8s-manifests/
│   └── nginx-test.yaml                  # test workload, applied via kubectl — not Terraform (Section 13)
└── terraform/
    ├── versions.tf                      # terraform + backend "s3" (partial) + aws/kubernetes/helm provider blocks
    ├── variables.tf                     # every input, with validation blocks
    ├── locals.tf                        # common_tags, subnet CIDR math
    ├── vpc.tf                           # module "vpc" + VPC endpoints (Section 1)
    ├── main.tf                          # module "eks" — control plane (Section 2) + node groups (Section 3)
    ├── kms.tf                           # EKS secrets encryption key (Section 2)
    ├── addons.tf                        # AWS Load Balancer Controller IRSA + Helm release (Section 4)
    ├── outputs.tf
    ├── terraform.tfvars.example         # quick-start template (gitignored terraform.tfvars, single env)
    ├── iam/
    │   ├── terraform-deployer-policy.json   # IAM policy for the human/CI user running plan/apply/destroy (Section 6)
    │   └── README.md                        # what it covers, how to attach it, known constraints
    └── envs/
        ├── test.tfvars                  # cost-minimized sandbox
        ├── test.backend.hcl             # S3 backend for test — key "test/eks.tfstate" (Section 12)
        ├── prod.tfvars                  # full HA/security posture
        └── prod.backend.hcl             # S3 backend for prod — key "prod/eks.tfstate" (Section 12)
```

Usage:

```bash
terraform init -backend-config=envs/test.backend.hcl
terraform plan  -var-file=envs/test.tfvars
terraform apply -var-file=envs/test.tfvars
```

To switch environments, re-run init against the other backend config (Terraform will
offer to migrate/copy state — decline, since each env's state lives at its own key):

```bash
terraform init -backend-config=envs/prod.backend.hcl -reconfigure
terraform plan  -var-file=envs/prod.tfvars
```

Original larger-scale sketch, for when this outgrows a single root module (extract
`vpc.tf`/`main.tf` into `modules/vpc`, `modules/eks-cluster`, etc., with each `envs/<name>/`
becoming its own root module + backend config):

```
aws-eks/terraform/
├── modules/
│   ├── vpc/
│   ├── eks-cluster/
│   ├── node-groups/
│   ├── karpenter/
│   ├── irsa/
│   └── addons/
└── envs/
    ├── dev/
    ├── staging/
    └── prod/
        ├── main.tf
        ├── variables.tf
        ├── backend.tf
        └── terraform.tfvars
```

## Recommended Starting Point

Use the community module [`terraform-aws-modules/eks/aws`](https://github.com/terraform-aws-modules/terraform-aws-eks) (and its companion `terraform-aws-modules/vpc/aws`) as the base rather than hand-rolling the control plane/node group resources — it already encodes most of the items above (IRSA, encryption, managed node groups, Karpenter integration) and is widely used in production.
