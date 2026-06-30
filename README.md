# GCP Hardened Landing Zone

A production-deployed security baseline for GCP financial workloads —
provisioned end-to-end with Terraform, enforced with OPA policy gates,
and mapped to PCI DSS v4.0, NIST 800-53, and SOC 2 controls.

This is not a proof-of-concept. It runs. Every control in the table below
is active in project `mythical-cider-496423-h6`.

---

## The Problem It Solves

Most GCP deployments start permissive and harden reactively. Financial
institutions can't afford that posture. When a new team provisions a
workspace, they need encryption, audit logging, network isolation, and
policy enforcement in place before the first workload deploys — not after
the first audit finding.

This landing zone implements "security by default": a reusable Terraform
module that gives every new team a hardened baseline in a single call,
with no security assumptions left to the individual engineer.

---

## Security Controls

| Control | Mechanism | Regulatory Mapping |
|---|---|---|
| Encryption at rest | Cloud KMS CMEK, 90-day key rotation | PCI DSS 6.3.5 · NIST SC-28 |
| Audit logging | Log sinks → GCS (7-year retention) + BigQuery | PCI DSS 10.2.1 · NIST AU-2 |
| No primitive roles | Monitoring alert fires on any `roles/owner` grant | PCI DSS 7.2.5 · NIST AC-6 |
| No public members | Monitoring alert fires on `allUsers` / `allAuthenticatedUsers` | PCI DSS 7.2.6 · SOC 2 CC6.1 |
| Network isolation | Deny-all VPC, private subnets, IAP-only SSH | PCI DSS 1.3.2 · NIST AC-17 |
| Policy enforcement | OPA/Conftest gate in Cloud Build CI — plan fails if policy violated | PCI DSS 6.5.3 · SOC 2 CC8.1 |
| Least-privilege | Dedicated per-workload service account | NIST AC-6 · SOC 2 CC6.3 |

OPA policies are shared with the
[COMPLIANCE_AS_CODE](https://github.com/Bigbadlonewolf/COMPLIANCE_AS_CODE)
repository, which runs 50 passing unit tests across PCI DSS, SOC 2, and
NIST policy sets.

---

## Architecture

The zone deploys in four ordered layers. Each layer has its own Terraform
root and isolated GCS backend prefix.

```
Layer 0: Bootstrap
├── GCS bucket for Terraform state
├── Service account for CI/CD
└── IAM bindings for automation

Layer 1: Security
├── Cloud KMS (CMEK, 90-day rotation)
├── VPC Service Controls
├── Security Command Center configuration
└── Organization policies (constraints)

Layer 2: Network
├── Deny-all VPC
├── Private subnets (RFC 1918)
├── Cloud IAP for SSH access
├── Cloud NAT for egress
└── Firewall rules (default deny, explicit allow)

Layer 3: Workload
├── GKE cluster (private, shielded nodes)
├── Cloud SQL (private IP, SSL enforced)
├── Dedicated service accounts per workload
└── Workload Identity Federation
```

### Layer Dependencies

```
Layer 0 (Bootstrap)
       │
       ▼
Layer 1 (Security)
       │
       ▼
Layer 2 (Network)
       │
       ▼
Layer 3 (Workload)
```

Each layer's outputs feed into the next layer's inputs via Terraform remote state.

### Zero Trust Layers

| Layer | Technology | Trust Model |
|---|---|---|
| Ingress | Cloud IAP | Identity-aware proxy — no VPN required |
| Service-to-service | Istio mTLS | Automatic mutual TLS between pods |
| Policy enforcement | OPA default-deny | Every request must be explicitly allowed |
| Infrastructure | Terraform IaC | Immutable, version-controlled infrastructure |

---

## Quick Start

### Prerequisites

- GCP organization with billing
- `roles/resourcemanager.organizationAdmin`
- Terraform 1.7+
- `gcloud` CLI authenticated

### Deploy

```bash
# 1. Clone and configure
git clone https://github.com/Bigbadlonewolf/GCP-HARDENED-LANDING-ZONE.git
cd GCP-HARDENED-LANDING-ZONE

# 2. Set your organization and project IDs
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars

# 3. Deploy layer by layer
cd terraform/0-bootstrap && terraform init && terraform apply
cd ../1-security  && terraform init && terraform apply
cd ../2-network   && terraform init && terraform apply
cd ../3-workload  && terraform init && terraform apply

# 4. Validate with OPA
./scripts/validate-policies.sh
```

---

## Repository Layout

```
GCP-HARDENED-LANDING-ZONE/
├── README.md
├── terraform/
│   ├── 0-bootstrap/        # State backend, CI/CD service account
│   ├── 1-security/         # KMS, VPC SC, org policies
│   ├── 2-network/          # VPC, subnets, IAP, NAT, firewalls
│   └── 3-workload/         # GKE, Cloud SQL, service accounts
├── policies/               # OPA/Conftest policies (symlink to COMPLIANCE_AS_CODE)
├── modules/                # Reusable Terraform modules
├── scripts/
│   ├── validate-policies.sh
│   └── apply-layer.sh
├── cloudbuild/
│   └── terraform-apply.yaml
├── docs/
│   ├── architecture.md     # Full ADR
│   ├── controls-mapping.md # Requirement → control mapping
│   └── runbook.md          # Operational procedures
└── app/                    # Sample workload manifests
```

---

## CI/CD

| Pipeline | Trigger | Purpose |
|---|---|---|
| `terraform-plan` | PR to master | OPA policy check + Terraform plan review |
| `terraform-apply` | Merge to master | Automated layer deployment |
| `security-scan` | Daily | Trivy vulnerability scan of container images |

---

## Cost Estimate

| Component | Monthly Cost |
|---|---|
| Cloud KMS | ~$3 |
| VPC + NAT | ~$35 |
| GCS (state + logs) | ~$5 |
| Monitoring | ~$10 |
| **Total** | **~$53/month** |

---

## Related Projects

- [COMPLIANCE_AS_CODE](https://github.com/Bigbadlonewolf/COMPLIANCE_AS_CODE) — OPA/Rego policies used by this landing zone
- [SecureVault](https://github.com/Bigbadlonewolf/SecureVault) — Real-time security findings alerting
- [JIT-ACCESS-BROKER](https://github.com/Bigbadlonewolf/JIT-ACCESS-BROKER) — Just-in-time privileged access

## License

MIT
