# EKS Networking — Cost Analysis & Cost-Cutting Guide

Pricing breakdown for every networking piece in [../terraform/vpc.tf](../terraform/vpc.tf) (NAT Gateway, VPC endpoints), where those charges actually show up in a running cluster, and ranked recommendations for cutting cost in production without giving up the security/HA posture from [production-eks-checklist.md](production-eks-checklist.md). Pricing below is `us-east-1`, current as of writing — always check the [AWS Pricing page](https://aws.amazon.com/vpc/pricing/) for current rates before budgeting.

| # | Section |
|---|---|
| 1 | [NAT Gateway pricing](#1-nat-gateway-pricing) |
| 2 | [VPC endpoint pricing](#2-vpc-endpoint-pricing) |
| 3 | [What "data processed" actually means](#3-what-data-processed-actually-means) |
| 4 | [Where NAT charges show up in a real cluster](#4-where-nat-charges-show-up-in-a-real-cluster) |
| 5 | [NAT vs. Interface Endpoint — which is cheaper?](#5-nat-vs-interface-endpoint--which-is-cheaper) |
| 6 | [Fixed monthly cost: test vs. prod](#6-fixed-monthly-cost-test-vs-prod) |
| 7 | [Cost-cutting recommendations, ranked](#7-cost-cutting-recommendations-ranked) |
| 8 | [Best practices to keep regardless of cost](#8-best-practices-to-keep-regardless-of-cost) |

---

## 1. NAT Gateway pricing

| Charge | Rate | Notes |
|---|---|---|
| Gateway-hour | $0.045/hr | Billed from creation to deletion; partial hours round up |
| Data processed | $0.045/GB | Every GB through the gateway, both directions |
| Public IPv4 address (EIP) | $0.005/hr | Every NAT Gateway requires an Elastic IP; AWS bills all public IPv4 addresses since Feb 2024, attached or not |
| Cross-AZ data transfer (only if traffic crosses AZs to reach the NAT) | ~$0.01/GB each direction (~$0.02/GB round-trip) | What `single_nat_gateway = true` exposes you to |

**Fixed cost per NAT Gateway, no traffic at all:**
```
(0.045 + 0.005) × 730 hrs ≈ $36.50/month
```

## 2. VPC endpoint pricing

| Type | Which of ours | Hourly | Per-GB processed |
|---|---|---|---|
| **Gateway** (S3, DynamoDB only) | `s3` | **$0** | **$0** |
| **Interface** (PrivateLink, everything else) | `ecr_api`, `ecr_dkr`, `ec2`, `sts`, `logs` | $0.01/hr **per AZ, per endpoint** | $0.01/GB |

Gateway endpoints are genuinely free — no hourly charge, ever. Interface endpoints are not free, but are **~4.5x cheaper per GB** than NAT. Each interface endpoint only connects to the one specific AWS service (or third-party service, if that vendor has published a PrivateLink endpoint service) it was created for — it is not a general proxy to the internet. See [terraform-configs-explaination.md](terraform-configs-explaination.md) for how the VPC itself is laid out around these.

## 3. What "data processed" actually means

Not CPU/compute — it's a metered toll on every byte that flows through the gateway/endpoint, in either direction. A NAT Gateway does real packet-level work (source-NAT translating the pod's private IP to the NAT's public IP outbound, and reversing that on the way back) — that packet rewriting is the "processing" being billed. Downloading a 500MB image and getting a tiny request back still bills ≈0.5GB, since the charge is dominated by whichever direction carries the bulk of the data.

## 4. Where NAT charges show up in a real cluster

| Scenario | Why it hits NAT | Typical size |
|---|---|---|
| Pulling images from Docker Hub, GHCR, quay.io — or ECR **if VPC endpoints are off** | Registry is outside the VPC | 100MB-1GB+ per image; multiplied by every restart/deploy/node scale-up that re-pulls |
| App calls to third-party APIs/SaaS (Stripe, Twilio, external DBs, webhooks) | Destination isn't in the VPC | App-dependent |
| Shipping logs/metrics to external SaaS (Datadog, New Relic, Splunk Cloud) instead of CloudWatch | No PrivateLink/endpoint for it | Often constant and large |
| OS-level calls on nodes (`apt`/`yum`, anything not covered by an endpoint) | Public internet | Usually small, adds up at scale |
| Calling your own other services via their public ALB/API Gateway URL instead of internal DNS | Common accidental gotcha — traffic leaves the VPC and re-enters via a public LB instead of staying internal | Can be large if frequent |

In [envs/prod.tfvars](../terraform/envs/prod.tfvars) (`enable_vpc_endpoints = true`), ECR pulls, STS (IRSA) calls, and CloudWatch Logs shipping never touch the NAT Gateway at all — they route through the interface endpoints instead, at $0.01/GB instead of $0.045/GB. In [envs/test.tfvars](../terraform/envs/test.tfvars) (`enable_vpc_endpoints = false`), those same calls do go through the single NAT Gateway, at the higher rate — an accepted tradeoff for a low-volume, disposable environment.

## 5. NAT vs. Interface Endpoint — which is cheaper?

| Path | Per-GB cost |
|---|---|
| Via NAT Gateway | $0.045/GB |
| Via Interface Endpoint | $0.01/GB |

Interface endpoints are cheaper per GB, but carry their own **fixed** hourly cost NAT doesn't add on top of itself. The crossover point (endpoints save money) roughly requires:

```
fixed hourly cost of the endpoints ÷ (0.045 − 0.01) = break-even GB/month
```

For prod's 5 endpoints × 3 AZs (`5 × 3 × $0.01/hr × 730 ≈ $109.50/month` fixed), that's about **~3,130 GB (~3TB)/month** through those specific services combined before the endpoints pay for themselves. Below that volume, routing through the NAT you're already paying for anyway is cheaper overall — which is exactly why a low-traffic environment like test skips the endpoints.

## 6. Fixed monthly cost: test vs. prod

| | NAT count | NAT fixed/mo | Endpoint fixed/mo | Total fixed/mo (before any data processed) |
|---|---|---|---|---|
| [envs/test.tfvars](../terraform/envs/test.tfvars) | 1 | ~$36.50 | $0 (endpoints off) | **~$36.50** |
| [envs/prod.tfvars](../terraform/envs/prod.tfvars) | 3 (one per AZ) | ~$109.50 | ~$109.50 (5 endpoints × 3 AZs) | **~$219** |

Both scale further with actual data processed on top of these fixed numbers.

## 7. Cost-cutting recommendations, ranked

1. **Keep VPC endpoints, but be selective.** The five here (`ecr_api`, `ecr_dkr`, `sts`, `logs`, `s3`-gateway) are the right high-volume picks. Keep `ec2` only if something in-cluster calls the EC2 API constantly — Karpenter, Cluster Autoscaler, or the EBS CSI driver all do; if none of those are running, it's fixed cost with no real traffic behind it. Revisit once Karpenter (checklist Section 5) is decided.
2. **Don't collapse to a single shared NAT in prod to save money.** One-per-AZ costs ~3x a single shared NAT, but a single NAT reintroduces the single-AZ-outage-kills-everyone's-egress risk. This is not the place to cut prod cost.
3. **Route VPC Flow Logs to S3 instead of CloudWatch Logs** if you don't need to query them interactively — S3 storage is meaningfully cheaper than CloudWatch Logs ingestion+storage at volume. Worth changing in [vpc.tf](../terraform/vpc.tf) if long flow-log retention starts costing real money.
4. **Skip NAT instances (self-managed EC2-as-NAT) as a cost move.** Cheaper on paper, but you take on patching/HA/scaling yourself — not worth the operational risk for what it saves in production.
5. **Reserved/Savings Plans for the steady-state compute**, adjacent to networking: the `system` node group ([envs/prod.tfvars](../terraform/envs/prod.tfvars)) is On-Demand and predictable by design — a good Savings Plan candidate once the shape is stable.

## 8. Best practices to keep regardless of cost

- **Private-only API endpoint in prod** — no public attack surface on the control plane ([variables.tf](../terraform/variables.tf) `cluster_endpoint_public_access = false`)
- **SSM Session Manager on node IAM roles** instead of SSH/bastion ([main.tf](../terraform/main.tf)) — both a cost win (no bastion host) and a security win (no open port 22, no key management)
- **VPC endpoints for the highest-volume AWS calls** — reduces cost *and* security surface (nodes don't need general internet reachability for these specific calls)
- **NAT Gateway stays the only path to genuinely arbitrary internet destinations** — correct by design. Eliminating it entirely means allowlisting every external dependency (e.g. via AWS Network Firewall) — a real option for regulated environments, but added cost/complexity, not a default.
