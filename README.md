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
