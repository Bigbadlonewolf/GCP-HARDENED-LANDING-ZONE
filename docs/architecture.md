# Architecture

## The problem this solves

Financial institutions slow down product teams because every new workspace needs a
manual security review before the team can ship anything. Without a standardized
starting point, teams make inconsistent decisions — one team enables public bucket
access, another grants `roles/owner` to a contractor. Each gap needs its own audit
finding and remediation. At scale, that's expensive and slow.

The landing zone solves this by encoding the security baseline as Terraform. A new
team gets a compliant workspace in minutes, not weeks. The controls are not optional —
they're enforced before the first line of application code deploys.

## Deployment architecture

```
mythical-cider-496423-h6 (GCP project)
│
├── Artifact Registry
│   └── landing-zone/demo:latest  (Docker image)
│
├── Cloud KMS — us-central1
│   └── key ring: landing-zone-kr
│       ├── terraform-state-key   (90-day rotation, prevent_destroy)
│       ├── audit-logs-key        (90-day rotation, prevent_destroy)
│       └── app-key               (90-day rotation)
│
├── Cloud Storage
│   ├── mythical-cider-496423-h6-tf-state   (Terraform state, versioned, CMEK)
│   └── mythical-cider-496423-h6-audit-logs (Audit logs, CMEK, 7-year retention)
│
├── BigQuery
│   └── dataset: audit_logs       (partitioned, 7-year retention)
│
├── Cloud Logging
│   ├── sink: audit-to-gcs        (→ audit-logs bucket)
│   ├── sink: audit-to-bigquery   (→ audit_logs dataset)
│   └── audit config: allServices (ADMIN_READ, DATA_READ, DATA_WRITE)
│
├── Cloud Monitoring
│   ├── metric: primitive-iam-role-granted
│   ├── metric: public-iam-member-granted
│   ├── metric: firewall-rule-changed
│   ├── alert: [CRITICAL] Primitive IAM role granted
│   ├── alert: [CRITICAL] Public IAM member added
│   └── alert: [WARNING]  Firewall rule modified
│
├── VPC — landing-zone-vpc
│   ├── subnet: private-us-central1 (10.0.1.0/24)
│   │   └── Private Google Access: enabled
│   │   └── VPC Flow Logs: enabled (0.5 sampling)
│   └── firewall rules
│       ├── deny-all-ingress     (priority 65534, all sources)
│       ├── allow-iap-ssh        (priority 1000, 35.235.240.0/20 → tag:iap-ssh, port 22)
│       ├── allow-internal       (priority 1000, 10.0.1.0/24 → same subnet)
│       ├── allow-health-checks  (priority 1000, GCP LB ranges → tag:load-balanced)
│       ├── deny-all-egress      (priority 65534, all destinations)
│       └── allow-egress-google-apis (priority 1000, → 199.36.153.4/30, 199.36.153.8/30)
│
└── Cloud Run — landing-zone-demo
    ├── image: us-central1-docker.pkg.dev/.../demo:latest
    ├── SA:    landing-zone-demo@...iam.gserviceaccount.com
    ├── roles: cloudtrace.agent, monitoring.metricWriter (no primitive roles)
    ├── scaling: 0–3 instances (scale to zero)
    └── public endpoint: yes (portfolio demo)
```

## Why each control exists

**Cloud KMS with 90-day rotation**
Key rotation is required by PCI DSS 6.3.5 for keys protecting cardholder data. 90-day
rotation is stricter than the annual requirement — it limits the blast radius if a key
is compromised. The `prevent_destroy` lifecycle block prevents Terraform from accidentally
deleting a key that's still protecting live data.

**Audit log sinks to both GCS and BigQuery**
GCS gives cheap long-term storage (Coldline after 1 year, 7-year total retention).
BigQuery gives fast queryable access for incident response — instead of downloading
raw log files, a security team can run SQL against the last 90 days of activity in
seconds. PCI DSS 10.7 requires audit log retention for at least 12 months, with the
last 3 months available for immediate analysis.

**Data Access audit logs (ADMIN_READ, DATA_READ, DATA_WRITE)**
GCP only enables Admin Activity and System Event logs by default. Data Access logs
(who read which file, who called which API) require explicit enablement and are billed
against log volume. For a financial workload, the billing cost is worth it — without
Data Access logs you can tell someone accessed the system but not what they read.

**Monitoring alerts on IAM changes**
The alert policies fire within 60 seconds of a primitive role being granted or a public
member being added. Without monitoring, you might not notice these changes until an
external audit. The log-based metric captures the specific IAM delta (which role, which
member) from the Cloud Audit log so the alert carries enough context to act on.

**Deny-all VPC firewall**
GCP's default network has permissive rules (allow-ssh-from-everywhere, allow-rdp-from-everywhere).
Creating a custom VPC without auto-created subnets starts clean, then the deny-all
ingress rule at priority 65534 makes the deny visible in Security Command Center. 
Cloud IAP SSH is allowed from `35.235.240.0/20` — this is Google's IAP proxy range,
meaning SSH goes through Google's identity verification layer before reaching any VM.

**Dedicated workload service account**
Cloud Run's default behavior is to use the compute default service account, which
inherits the project editor role. The `landing-zone-demo` SA has only two roles:
`cloudtrace.agent` and `monitoring.metricWriter`. If the container is compromised,
the attacker can't use the SA to read IAM policies, list buckets, or call the KMS API.

## What this doesn't cover

This is a project-scoped baseline, not a full organization landing zone. Without a
GCP Organization:

- **No organization policies** — constraints like `compute.skipDefaultNetworkCreation`
  and `iam.disableServiceAccountKeyCreation` require org-level policy. These would apply
  automatically to every new project in an org-based setup.
- **No folder hierarchy** — dev/staging/prod separation via folders isn't possible
  without an org. Projects sit at the root level.
- **No VPC Service Controls** — perimeter-based access control (preventing data
  exfiltration to external projects) requires an org.

The `modules/hardened-project/` module shows what a team-workspace provisioning call
would look like with an org in place. The controls are the same; the scope changes from
a single project to any project the module is called against.

## Cost

Scale-to-zero Cloud Run means there is no idle compute cost. The KMS keys and storage
buckets account for most of the bill.

| Line item | Monthly estimate |
|---|---|
| 3 KMS keys × $0.06/key | $0.18 |
| GCS state + audit buckets (minimal data) | ~$0.05 |
| Cloud Run (free tier: 2M requests, 360K GB-seconds) | $0 |
| BigQuery (free tier: 10GB storage, 1TB queries) | $0 |
| Cloud Build (free tier: 120 min/day) | $0 |
| VPC, firewall, monitoring, logging | $0 |
| **Total** | **~$0.25–2/month** |
