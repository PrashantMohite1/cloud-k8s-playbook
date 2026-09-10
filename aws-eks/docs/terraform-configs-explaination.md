# CIDR & `cidrsubnet()` — how `locals.tf` carves up the VPC

Companion to [locals.tf](../terraform/locals.tf). Explains the CIDR math behind:

```hcl
private_subnets = [for i in range(length(var.availability_zones)) : cidrsubnet(var.vpc_cidr, 4, i)]
public_subnets  = [for i in range(length(var.availability_zones)) : cidrsubnet(var.vpc_cidr, 8, i + 48)]
```

---

## 1. CIDR notation, from scratch

An IPv4 address is a 32-bit number, written as 4 bytes ("octets") of 0-255 each, e.g. `10.0.0.0`.

`CIDR` notation (`10.0.0.0/16`) adds a `/N` suffix saying **how many of the leading bits are fixed** (the network part) vs. free to vary (the host part, i.e. the actual usable addresses):

```
10.0.0.0/16
└──┬──┘ └┬┘
 fixed   free — 16 bits free = 2^16 = 65,536 addresses
```

Since each octet is 8 bits, `/16` conveniently means "the first 2 octets are locked, the last 2 can be anything" — so `10.0.0.0/16` covers every address from `10.0.0.0` through `10.0.255.255`.

**Bigger `/N` = smaller range** (counter-intuitive at first): more fixed bits leaves fewer free bits.

| CIDR | Fixed bits | Free bits | Addresses |
|---|---|---|---|
| `/16` | 16 | 16 | 65,536 |
| `/20` | 20 | 12 | 4,096 |
| `/24` | 24 | 8 | 256 |

`vpc_cidr = "10.0.0.0/16"` in this repo ([variables.tf](../terraform/variables.tf)) is the big block everything else gets carved from.

## 2. `cidrsubnet(prefix, newbits, netnum)`

Terraform's built-in for carving a smaller block out of a bigger one:

- **`prefix`** — the CIDR you're slicing (`var.vpc_cidr`)
- **`newbits`** — how many *additional* bits to fix, added to the prefix's own `/N`. Determines the size of each resulting slice.
- **`netnum`** — 0-indexed, which of the possible slices to return

```
new prefix length = prefix's /N + newbits
number of possible slices = 2^newbits
```

## 3. Private subnets — `cidrsubnet(var.vpc_cidr, 4, i)`

`newbits = 4` → new prefix = `/16 + 4 = /20` (4,096 addresses per subnet — private subnets hold worker nodes + pods, so they need room). `2^4 = 16` possible `/20` slices exist inside the `/16`, numbered `netnum = 0..15`:

| `netnum` | Result |
|---|---|
| 0 | `10.0.0.0/20` (`10.0.0.0` – `10.0.15.255`) |
| 1 | `10.0.16.0/20` (`10.0.16.0` – `10.0.31.255`) |
| 2 | `10.0.32.0/20` (`10.0.32.0` – `10.0.47.255`) |
| 3 | `10.0.48.0/20` |
| ... | ... |
| 15 | `10.0.240.0/20` (`10.0.240.0` – `10.0.255.255`) |

With `availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]` (3 AZs), the `for` loop runs `i = 0, 1, 2`, using only the first 3 of the 16 possible slices:

```hcl
local.private_subnets = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
```

## 4. Public subnets — `cidrsubnet(var.vpc_cidr, 8, i + 48)`

`newbits = 8` → new prefix = `/16 + 8 = /24` (256 addresses — plenty for NAT Gateways and load balancers, which don't need pod-scale IP counts). `2^8 = 256` possible `/24` slices exist, numbered `netnum = 0..255`.

**Why `netnum = i + 48` instead of starting at 0:** the two loops use *different* slice sizes (`/20` vs `/24`) over the *same* underlying `/16`, so their `netnum` values aren't directly comparable — slice `2` in `/20`-terms covers different address space than slice `2` in `/24`-terms. To avoid the public loop landing on addresses the private loop already claimed, the offset must clear whatever the private loop's highest address was.

The private loop's last used block (`netnum=2` at `/20`) ends at `10.0.47.255`. In `/24` numbering, `10.0.47.255` falls inside slice `47`. So the public loop starts at `netnum = 48` — one past where private stopped — guaranteeing no overlap regardless of the `/20` vs `/24` granularity mismatch:

```
Private (/20, netnum 0-2):  10.0.0.0 ──────────────────── 10.0.47.255
Public  (/24, netnum 48+):                                 10.0.48.0 ─── 10.0.50.255
                                                             ↑ starts right after private ends
```

With `i = 0, 1, 2` and the `+48` offset:

```hcl
local.public_subnets = ["10.0.48.0/24", "10.0.49.0/24", "10.0.50.0/24"]
```

## 5. The `for` loop wrapping it

```hcl
[for i in range(length(var.availability_zones)) : cidrsubnet(var.vpc_cidr, 4, i)]
```

Read left to right: *"for each `i` in `range(3)` (i.e. `[0, 1, 2]`), compute `cidrsubnet(...)`, collect results into a list."* `range(N)` just generates index numbers `0..N-1`; `length(var.availability_zones)` keeps that count in sync with however many AZs you actually list, so adding/removing an AZ automatically resizes both subnet lists without touching this line.

Fully expanded, it's equivalent to:

```hcl
private_subnets = [
  cidrsubnet("10.0.0.0/16", 4, 0), # "10.0.0.0/20"
  cidrsubnet("10.0.0.0/16", 4, 1), # "10.0.16.0/20"
  cidrsubnet("10.0.0.0/16", 4, 2), # "10.0.32.0/20"
]
```

## 6. End-to-end summary

| Local | Formula | `netnum` range used | Result (3 AZs) |
|---|---|---|---|
| `local.private_subnets` | `cidrsubnet(vpc_cidr, 4, i)` | 0-2 (of 16 possible) | `10.0.0.0/20`, `10.0.16.0/20`, `10.0.32.0/20` |
| `local.public_subnets` | `cidrsubnet(vpc_cidr, 8, i + 48)` | 48-50 (of 256 possible) | `10.0.48.0/24`, `10.0.49.0/24`, `10.0.50.0/24` |

These two lists feed `private_subnets` / `public_subnets` into `module "vpc"` in [vpc.tf](../terraform/vpc.tf), which creates one real `aws_subnet` per list entry — one private + one public subnet per AZ.
