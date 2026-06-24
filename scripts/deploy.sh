#!/usr/bin/env bash
# deploy.sh — Full landing zone deployment sequence
# Run once to bootstrap the project and deploy all layers.
#
# Prerequisites:
#   gcloud auth login
#   gcloud config set project mythical-cider-496423-h6
#   terraform >= 1.6 installed
#   docker installed (for local image build)

set -euo pipefail

PROJECT_ID="mythical-cider-496423-h6"
REGION="us-central1"
STATE_BUCKET="${PROJECT_ID}-tf-state"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/landing-zone"

echo "=== GCP Hardened Landing Zone Deployment ==="
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo ""

# ── Step 0: Authenticate ──────────────────────────────────────────────────────
echo "[0] Verifying authentication..."
gcloud config set project "$PROJECT_ID"
gcloud auth application-default login --no-launch-browser 2>/dev/null || true

# ── Step 1: Bootstrap ─────────────────────────────────────────────────────────
echo ""
echo "[1] Applying bootstrap (state bucket, APIs, Artifact Registry)..."
cd terraform/0-bootstrap
terraform init
terraform apply -auto-approve
cd ../..

echo "[1] Waiting 60s for APIs to propagate..."
sleep 60

# ── Step 2: Migrate bootstrap state to GCS ────────────────────────────────────
echo ""
echo "[2] Migrating bootstrap state to GCS bucket..."
cd terraform/0-bootstrap
cat > backend.tf << EOF
terraform {
  backend "gcs" {
    bucket = "${STATE_BUCKET}"
    prefix = "landing-zone/bootstrap"
  }
}
EOF
terraform init -migrate-state -force-copy
cd ../..

# ── Step 3: Authenticate Docker for Artifact Registry ─────────────────────────
echo ""
echo "[3] Configuring Docker for Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

# ── Step 4: Build and push demo image ────────────────────────────────────────
echo ""
echo "[4] Building and pushing demo Docker image..."
docker build -t "${REGISTRY}/demo:latest" app/
docker push "${REGISTRY}/demo:latest"

# ── Step 5: Security layer ────────────────────────────────────────────────────
echo ""
echo "[5] Applying security layer (KMS, audit logging, monitoring)..."
cd terraform/1-security
terraform init
terraform apply -auto-approve
cd ../..

# ── Step 6: Network layer ─────────────────────────────────────────────────────
echo ""
echo "[6] Applying network layer (VPC, subnets, firewall rules)..."
cd terraform/2-network
terraform init
terraform apply -auto-approve
cd ../..

# ── Step 7: Workload layer ────────────────────────────────────────────────────
echo ""
echo "[7] Deploying demo Cloud Run service..."
cd terraform/3-workload
terraform init
terraform apply -auto-approve
SERVICE_URL=$(terraform output -raw service_url)
cd ../..

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "=============================="
echo "Deployment complete!"
echo "=============================="
echo ""
echo "Demo endpoint: ${SERVICE_URL}"
echo ""
echo "Resources deployed:"
echo "  - GCS state bucket:      ${STATE_BUCKET}"
echo "  - KMS key ring:          landing-zone-kr (us-central1)"
echo "  - KMS keys:              terraform-state-key, audit-logs-key, app-key (90-day rotation)"
echo "  - Audit log bucket:      ${PROJECT_ID}-audit-logs (7-year retention)"
echo "  - BigQuery dataset:      audit_logs"
echo "  - VPC:                   landing-zone-vpc"
echo "  - Subnet:                private-us-central1 (10.0.1.0/24)"
echo "  - Firewall:              deny-all-ingress, allow-iap-ssh, allow-internal"
echo "  - Cloud Run:             landing-zone-demo"
echo "  - Artifact Registry:     ${REGISTRY}"
echo ""
echo "Next steps:"
echo "  1. Add notification channels to monitoring alerts in GCP Console"
echo "  2. Connect Cloud Build to your GitHub repo for CI/CD"
echo "  3. Run: gcloud projects get-ancestors $PROJECT_ID"
echo "     to verify project labels"
