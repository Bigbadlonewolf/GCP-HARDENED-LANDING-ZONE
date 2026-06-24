# CLAUDE.md — GCP Hardened Landing Zone

GCP project: `mythical-cider-496423-h6` | Region: `us-central1`

## What This Is

A production-deployed hardened landing zone for a single GCP project. Demonstrates
the "security by default" pattern financial institutions use when provisioning
new teams: every workspace gets encryption, audit logging, network isolation, and
policy enforcement without manual intervention.

## Stack

- **IaC**: Terraform >= 1.6, `hashicorp/google` v5.x
- **Policy gate**: OPA/Conftest (reuses `projects/compliance-as-code` policies)
- **CI/CD**: Cloud Build (`cloudbuild/cloudbuild.yaml`)
- **Image registry**: Artifact Registry (`us-central1-docker.pkg.dev/mythical-cider-496423-h6/landing-zone`)
- **State**: GCS backend (`mythical-cider-496423-h6-tf-state`)

## Deployment layers

Each layer has its own Terraform root and GCS backend prefix. Apply in order.

| Layer | Directory | What it creates |
|---|---|---|
| 0-bootstrap | `terraform/0-bootstrap/` | State bucket, CI SA, Artifact Registry, APIs |
| 1-security | `terraform/1-security/` | KMS keys, audit log sinks, monitoring alerts |
| 2-network | `terraform/2-network/` | VPC, private subnet, firewall rules |
| 3-workload | `terraform/3-workload/` | Cloud Run demo service |

## Commands

```bash
# Full first-time deployment
bash scripts/deploy.sh

# Apply a single layer
cd terraform/1-security && terraform init && terraform apply

# Check what changed without applying
cd terraform/2-network && terraform plan

# Build and push demo image manually
docker build -t us-central1-docker.pkg.dev/mythical-cider-496423-h6/landing-zone/demo:latest app/
docker push us-central1-docker.pkg.dev/mythical-cider-496423-h6/landing-zone/demo:latest

# View Cloud Run service URL
cd terraform/3-workload && terraform output service_url

# Tail audit logs in BigQuery
bq query --use_legacy_sql=false \
  'SELECT timestamp, protoPayload.methodName, protoPayload.authenticationInfo.principalEmail
   FROM audit_logs.cloudaudit_googleapis_com_activity
   ORDER BY timestamp DESC LIMIT 20'
```

## Security controls

| Control | Mechanism | Standard |
|---|---|---|
| Encryption at rest | Cloud KMS CMEK, 90-day rotation | PCI DSS 6.3.5, NIST SC-28 |
| Audit logging | Log sinks → GCS (7yr) + BigQuery | PCI DSS 10.2.1, NIST AU-2 |
| No primitive roles | Monitoring alert fires on grant | PCI DSS 7.2.5, NIST AC-6 |
| No public members | Monitoring alert fires on grant | PCI DSS 7.2.6, SOC2 CC6.1 |
| Network isolation | Deny-all VPC, IAP-only SSH | PCI DSS 1.3.2, NIST AC-17 |
| Policy enforcement | OPA gate in Cloud Build CI | PCI DSS 6.5.3, SOC2 CC8.1 |
| Least-privilege SA | Dedicated per-workload SA | NIST AC-6, SOC2 CC6.3 |

## Module: hardened-project

`modules/hardened-project/` is the reusable blueprint a new team calls:

```hcl
module "payments_team" {
  source               = "../../modules/hardened-project"
  project_id           = "payments-team-proj"
  team_name            = "payments"
  owner_email          = "lead@example.com"
  central_audit_bucket = "mythical-cider-496423-h6-audit-logs"
}
```

This provisions: APIs, KMS key ring, audit log sink to central bucket,
workload SA, and mandatory labels — all in one call.

## Estimated monthly cost

| Resource | Cost |
|---|---|
| Cloud KMS (3 keys) | ~$0.18 |
| GCS state + audit buckets | ~$0.05 |
| Cloud Run (scale-to-zero) | Free tier |
| BigQuery (log dataset) | Free tier |
| Cloud Build | Free (120 min/day) |
| VPC + firewall | Free |
| Monitoring alerts | Free |
| **Total** | **~$0.25–2/month** |

## Conventions

- All resources carry labels: `managed-by=terraform`, `environment=prod`, `project=landing-zone`
- No secrets or credentials in Terraform state — use Secret Manager
- `prevent_destroy = true` on KMS keys to prevent accidental key deletion
- Cloud Run scales to 0 — no idle cost
