# cloud-k8s-playbook
A community-driven repository containing cloud-managed Kubernetes setup guides, Terraform examples, and production-focused DevOps notes.

## Quickstart — AWS EKS test cluster

Spins up a small, cost-minimized EKS cluster (~$0.15-0.20/hr while running) to try things out end-to-end: real VPC, real control plane, one Spot-priced node, and enough wired up to deploy a workload and reach it from the internet.

**What this actually creates** — see [aws-eks/terraform/envs/test.tfvars](aws-eks/terraform/envs/test.tfvars) for the full, real config:

| | |
|---|---|
| Cluster name | `eks-test`, Kubernetes `1.31`, region `us-east-1` |
| Networking | VPC `10.1.0.0/16`, 2 AZs, 1 shared NAT Gateway, no VPC endpoints/flow logs (cost-trimmed — see [aws-eks/docs/prd-networking-cost-analysis.md](aws-eks/docs/prd-networking-cost-analysis.md)) |
| Compute | 1 node group, Spot (`t3.small`/`t3a.small`), 1-2 nodes, no taints |
| Add-ons | AWS Load Balancer Controller (so a `Service`/`Ingress` can provision a real internet-facing NLB/ALB) |

**Prerequisites:** Terraform `>= 1.7`, AWS CLI configured with credentials that can create VPC/EKS/IAM resources, `kubectl`.

```bash
cd aws-eks/terraform
terraform init

# One-time: create the isolated workspace this environment's state lives in
terraform workspace new test
terraform workspace select test

# Your own IP as a /32 — the test cluster's API endpoint is public but IP-restricted
curl ifconfig.me
# then edit cluster_endpoint_public_access_cidrs in envs/test.tfvars to ["<that-ip>/32"]

terraform plan  -var-file=envs/test.tfvars   # review — real, billable AWS resources
terraform apply -var-file=envs/test.tfvars

# Point kubectl at the new cluster
aws eks update-kubeconfig --name eks-test --region us-east-1

# Deploy nginx behind a real internet-facing load balancer
kubectl apply -f ../k8s-manifests/nginx-test.yaml
kubectl get svc nginx-test -w        # wait for EXTERNAL-IP / hostname to populate
curl http://<that hostname>          # NLB DNS takes a few minutes to become reachable
```

**Tear down** (delete the app before the infra, so the controller that owns the NLB is still running to actually deprovision it):

```bash
kubectl delete -f ../k8s-manifests/nginx-test.yaml
terraform destroy -var-file=envs/test.tfvars
```

Full checklist behind these choices, and the production (`envs/prod.tfvars`) equivalent — 3 AZs, one NAT per AZ, VPC endpoints, private-only API — lives in [aws-eks/docs/production-eks-checklist.md](aws-eks/docs/production-eks-checklist.md).

#### Structure of repo 

```
cloud-k8s-playbook/
│
├── README.md
│
├── aws-eks/              # implemented — see Quickstart above
│   ├── terraform/        # VPC, EKS control plane, node groups, add-ons
│   │   └── envs/         # test.tfvars, prod.tfvars — real per-environment configs
│   ├── k8s-manifests/    # example app manifests, applied via kubectl (not Terraform)
│   ├── docs/             # checklist, cost analysis, config walkthroughs
│   └── scripts/
│
├── azure-aks/            # planned
│   ├── terraform/
│   ├── scripts/
│   └── docs/
│
├── gcp-gke/              # planned
│   ├── terraform/
│   ├── scripts/
│   └── docs/
│
└── common/
    ├── terraform/
    │   ├── hcl-basics.md
    │   └── hcl-cheatsheet.md
    ├── kubernetes/
    ├── helm/
    ├── argocd/
    └── istio/
```