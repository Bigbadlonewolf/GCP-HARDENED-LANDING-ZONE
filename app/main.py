import datetime
import json
import os

from flask import Flask, make_response

app = Flask(__name__)

PROJECT_ID = os.environ.get("PROJECT_ID", "unknown")
REGION = os.environ.get("REGION", "us-central1")
REVISION = os.environ.get("K_REVISION", "local")


@app.route("/")
def index():
    payload = {
        "service": "GCP Hardened Landing Zone",
        "status": "operational",
        "project_id": PROJECT_ID,
        "region": REGION,
        "revision": REVISION,
        "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
        "security_controls": {
            "encryption_at_rest": {
                "status": "enforced",
                "mechanism": "Cloud KMS CMEK — 90-day rotation",
                "scope": ["GCS state bucket", "GCS audit log bucket"],
            },
            "encryption_in_transit": {
                "status": "enforced",
                "mechanism": "TLS 1.3 (Cloud Run managed)",
            },
            "audit_logging": {
                "status": "active",
                "destinations": [
                    "Cloud Storage — 7-year retention (PCI DSS 10.7)",
                    "BigQuery — queryable audit trail",
                ],
                "events": ["ADMIN_READ", "DATA_READ", "DATA_WRITE", "SYSTEM_EVENT"],
            },
            "iam": {
                "status": "hardened",
                "controls": [
                    "No primitive roles (owner/editor/viewer) — monitored by alert policy",
                    "No public IAM members (allUsers/allAuthenticatedUsers) — alert on grant",
                    "Dedicated least-privilege service account per workload",
                ],
            },
            "network": {
                "status": "isolated",
                "controls": [
                    "Custom VPC — default network deleted",
                    "Private subnets only — Private Google Access enabled",
                    "Deny-all ingress by default",
                    "IAP-only SSH access",
                ],
            },
            "policy_enforcement": {
                "status": "active",
                "mechanism": "OPA/Conftest gate in Cloud Build",
                "frameworks": ["PCI DSS v4.0", "SOC2 TSC 2017", "NIST SP 800-53 Rev 5"],
                "detail": "All Terraform plans are validated against compliance policies before apply",
            },
        },
        "infrastructure": {
            "iac": "Terraform >= 1.6",
            "provider": "hashicorp/google v5.x",
            "ci_cd": "Cloud Build",
            "image_registry": "Artifact Registry",
            "state": "GCS (versioned, CMEK-encrypted)",
        },
    }
    return make_response(
        json.dumps(payload, indent=2),
        200,
        {"Content-Type": "application/json"},
    )


@app.route("/health")
def health():
    return make_response(
        json.dumps({"status": "ok", "timestamp": datetime.datetime.utcnow().isoformat() + "Z"}),
        200,
        {"Content-Type": "application/json"},
    )


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port, debug=False)
