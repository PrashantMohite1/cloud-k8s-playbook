# aws-eks

Terraform + docs for a production-style EKS cluster on AWS. Start here if you're new to this directory.

## Layout

```
aws-eks/
├── README.md                        # you are here
├── docs/
│   ├── production-eks-checklist.md      # master plan — 13 sections, what's built vs. not
│   ├── prd-networking-cost-analysis.md  # NAT Gateway / VPC endpoint cost breakdown
│   ├── terraform-configs-explaination.md# walkthrough of the subnet CIDR math in locals.tf
│   └── eks-for-kubeadm-users.md         # what's different if you're coming from a kubeadm cluster
├── terraform/
│   ├── versions.tf                  # provider requirements + aws/kubernetes/helm provider blocks
│   ├── variables.tf                 # every input variable, with validation rules
│   ├── locals.tf                    # common tags + subnet CIDR math
│   ├── vpc.tf                       # VPC, subnets, VPC endpoints
│   ├── main.tf                      # EKS cluster + managed node groups
│   ├── kms.tf                       # KMS key for EKS secrets encryption
│   ├── addons.tf                    # AWS Load Balancer Controller (IRSA role + Helm release)
│   ├── outputs.tf                   # exported values (cluster endpoint, VPC id, etc.)
│   └── envs/
│       ├── test.tfvars                  # cheap sandbox config — workspace "test"
│       └── prod.tfvars                  # full HA/security config — workspace "prod"
└── k8s-manifests/
    └── nginx-test.yaml              # sample app to prove internet → NLB → pod works
```

## How it fits together

- **`terraform/`** is one flat root module (no `modules/` subdir yet — fine at this size).
- **`envs/*.tfvars`** + Terraform workspaces (`test`, `prod`) give two isolated environments from the same config — see `production-eks-checklist.md` for what each one turns on/off.
- **`k8s-manifests/`** is applied with `kubectl`, not Terraform — Terraform's job stops at the cluster + add-ons; application workloads are separate on purpose.

## Getting started

Read `docs/production-eks-checklist.md` first — it tracks what's actually built.

## Quickstart — test workspace

```bash
cd terraform
terraform init
terraform workspace new test      # first time only; use "select" after that
terraform plan  -var-file=envs/test.tfvars
terraform apply -var-file=envs/test.tfvars
```

## Try it — deploy nginx and hit it from the internet

```bash
aws eks update-kubeconfig --name eks-test --region us-east-1

kubectl apply -f k8s-manifests/nginx-test.yaml
kubectl get svc nginx-test -w        # wait for EXTERNAL-IP / hostname to populate

curl http://<EXTERNAL-IP-from-above>

# cleanup, in order:
kubectl delete -f k8s-manifests/nginx-test.yaml
cd terraform && terraform destroy -var-file=envs/test.tfvars
```
