# EKS for someone coming from kubeadm

You've run a self-managed cluster with kubeadm before — you've SSH'd into a control plane node, looked at static pod manifests in `/etc/kubernetes/manifests`, maybe debugged etcd at 2 AM. This doc is for you. It skips the "what is a pod" stuff and just calls out what's actually different when AWS runs the control plane instead of you.

## Index

0. [Why EKS — what do you actually get for the money](#0-why-eks--what-do-you-actually-get-for-the-money)
1. [The control plane is a black box now](#1-the-control-plane-is-a-black-box-now)
2. [How worker nodes join the cluster](#2-how-worker-nodes-join-the-cluster)
3. [How a LoadBalancer actually gets you a load balancer](#3-how-a-loadbalancer-actually-gets-you-a-load-balancer)
4. [Making it secure — private subnets, NAT, and the LB](#4-making-it-secure--private-subnets-nat-and-the-lb)
5. [Want to go further — production practices](#5-want-to-go-further--production-practices)
6. [Just want to try it — jump to the quickstart](#6-just-want-to-try-it--jump-to-the-quickstart)

---

## 0. Why EKS — what do you actually get for the money

With kubeadm, you own everything: you provisioned the control plane VMs, you run etcd, you patch it, you upgrade it, you're the one paged when the API server falls over at 3 AM. That's fine for learning or for a cluster where you want full control, but it's real ongoing work.

EKS takes the control plane off your plate. AWS runs etcd, the API server, the scheduler, and the controller-manager for you — across multiple AZs, patched, backed up, upgraded on a version you choose. You still fully own the worker nodes and everything running inside the cluster (that part doesn't change). 

The other big thing you get for free is AWS-native integration: IAM for cluster auth, security groups instead of hand-rolled firewall rules, the VPC CNI giving pods real VPC IP addresses, and load balancers that provision themselves when you create a `Service`. None of that is impossible with kubeadm-on-EC2, you'd just be wiring it all up yourself.

## 1. The control plane is a black box now

This is the biggest mental shift. In kubeadm, `kubectl get pods -n kube-system` shows you `kube-apiserver-<node>`, `etcd-<node>`, `kube-scheduler-<node>` as real static pods you could `kubectl logs` or `kubectl exec` into. In EKS, **those don't exist as pods you can see** — AWS runs them in its own account, on its own infrastructure, completely outside your cluster's visibility. Run `kubectl get pods -n kube-system` on EKS and you'll only see the stuff AWS lets ride alongside your workloads: CoreDNS, the VPC CNI, kube-proxy, and anything else you've installed (like the Load Balancer Controller in this repo's `addons.tf`).

If you want control plane logs (audit, api, scheduler, etc.), you don't `journalctl` or read a static pod's logs — you enable them as CloudWatch Log Groups. This repo turns that on via `cluster_enabled_log_types` in [main.tf](../terraform/main.tf).

You also lose the ability to tune control plane flags directly (no editing `kube-apiserver` manifest to add an admission controller). What EKS exposes instead is a curated set of options — things like the API endpoint's public/private access (`cluster_endpoint_public_access` in [variables.tf](../terraform/variables.tf)) and the KMS key used to encrypt secrets at rest ([kms.tf](../terraform/kms.tf)). If you need something outside that surface, it's genuinely not available — that's the tradeoff for not managing it yourself.

## 2. How worker nodes join the cluster

With kubeadm, joining a node is a manual (or scripted) `kubeadm join` with a bootstrap token, run on a machine you provisioned and configured yourself — kubelet installed, container runtime installed, the works.

EKS has "managed node groups," which are really just an EC2 Auto Scaling Group where AWS also handles the join for you. You give it instance types, sizes, and an AMI type; AWS launches EC2 instances using an EKS-optimized AMI (bootstrap script, kubelet, and container runtime already baked in) and the node registers itself with the cluster automatically — no token to generate or copy around. That's what `eks_managed_node_groups` in [main.tf](../terraform/main.tf) is doing, fed by the `node_groups` variable you set per environment in `envs/test.tfvars` / `envs/prod.tfvars`.

Quick note on the AMI: it comes pre-installed with kubelet, containerd, and the CNI — nothing to set up by hand like on kubeadm. The only choice you make is `ami_type`, picked to match your instance type's CPU architecture (x86_64 vs Graviton/arm64) — which is why `t4g.*` instances in `envs/*.tfvars` are paired with `ami_type = "AL2023_ARM_64_STANDARD"`.

Scaling is just changing `min_size`/`max_size`/`desired_size` on that ASG — same idea as adding kubeadm nodes, except AWS launches and joins the instance for you instead of you SSH-ing in and running a join command.

## 3. How a LoadBalancer actually gets you a load balancer

On kubeadm (especially on-prem or bare EC2 without help), creating a `Service` of `type: LoadBalancer` just... doesn't do anything, because there's no cloud controller listening for it. That confuses a lot of people coming from kubeadm — the field exists in the API, it's just inert without a controller behind it. You either use `NodePort` + your own reverse proxy, or bolt on something like MetalLB.

On EKS, that field means something once you install the **AWS Load Balancer Controller** — a pod running in your cluster that watches for `Service`/`Ingress` objects and calls the AWS API to actually create a real NLB or ALB for each one, then keeps its target group in sync with your pods. This repo installs it via Helm in [addons.tf](../terraform/addons.tf), gated behind `enable_aws_load_balancer_controller`.

Once that controller is running, `kubectl apply` on a `Service` like [k8s-manifests/nginx-test.yaml](../k8s-manifests/nginx-test.yaml) is enough — no separate AWS console click, no manually creating a target group. The controller does it, and tears it down again when you delete the `Service` (which is why you always delete the app before `terraform destroy` — see the quickstart).

## 4. Making it secure — private subnets, NAT, and the LB

The pattern this repo uses (and that you'll see in most production EKS setups) is: **nothing that runs your workloads has a public IP**.

- **Worker nodes sit in private subnets** ([main.tf](../terraform/main.tf) sets `subnet_ids = module.vpc.private_subnets`) — no route to the internet gateway, so nothing can reach a node directly from outside the VPC, no matter what port is open on it.
- **NAT Gateway** sits in the public subnet and gives those private nodes a way to reach *out* (pulling container images, calling AWS APIs, etc.) without allowing anything to connect *in*. It's one-directional by nature — that's the whole point of a NAT Gateway vs. just giving nodes a public IP.
- **The load balancer is the only thing that's actually internet-facing**, and it lives in the public subnets ([vpc.tf](../terraform/vpc.tf) tags them `kubernetes.io/role/elb` so the LB controller knows to put internet-facing LBs there). Traffic flow is internet → LB (public subnet) → pod (private subnet), never internet → node directly.

On top of that, this repo also locks down the EKS API server itself the same way you'd think about SSH access on kubeadm boxes: `cluster_endpoint_public_access_cidrs` restricts who can even reach the Kubernetes API from the internet (test env), and prod goes further with `cluster_endpoint_public_access = false` — private-only, reachable only from inside the VPC (VPN/bastion/CI runner). Same instinct as "don't expose your kubeadm control plane node's port 6443 to the world," just enforced at the AWS level instead of with `iptables`.

## 5. Want to go further — production practices

Everything above is the minimum to get a working, reasonably secure cluster. If you want the fuller picture — HA node groups, IAM/RBAC, storage, observability, autoscaling with Karpenter, disaster recovery, GitOps — that's all laid out section-by-section in [production-eks-checklist.md](production-eks-checklist.md), including what's actually built in this repo vs. still planned.

## 6. Just want to try it — jump to the quickstart

If you'd rather see it running than keep reading, skip straight to the [aws-eks quickstart](../README.md#quickstart--test-workspace) — it walks through spinning up the test cluster and deploying nginx behind a real internet-facing load balancer.
