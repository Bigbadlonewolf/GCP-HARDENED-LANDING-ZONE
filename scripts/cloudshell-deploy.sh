#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# cloudshell-deploy.sh — GCP Hardened Landing Zone
#
# Run entirely inside GCP Cloud Shell (no local tooling needed):
#   https://shell.cloud.google.com
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Bigbadlonewolf/GCP-HARDENED-LANDING-ZONE/master/scripts/cloudshell-deploy.sh | bash
#
#   — OR — open Cloud Shell, then:
#   git clone https://github.com/Bigbadlonewolf/GCP-HARDENED-LANDING-ZONE.git
#   bash GCP-HARDENED-LANDING-ZONE/scripts/cloudshell-deploy.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
PROJECT_ID="mythical-cider-496423-h6"
REGION="us-central1"
STATE_BUCKET="${PROJECT_ID}-tf-state"
REGISTRY="${REGION}-docker.pkg.dev/${PROJECT_ID}/landing-zone"
REPO_URL="https://github.com/Bigbadlonewolf/GCP-HARDENED-LANDING-ZONE.git"
WORK_DIR="${HOME}/gcp-hardened-landing-zone"
REQUIRED_TF_MINOR=6   # need >= 1.6
INSTALL_TF_VERSION="1.8.5"

# ── Colour helpers ────────────────────────────────────────────────────────────
BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC}  $*"; }
die()  { echo -e "${RED}✗ ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}══ $* ══${NC}"; }

# ── Banner ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     GCP Hardened Landing Zone — Cloud Shell Deploy       ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}║  Project : ${PROJECT_ID}         ║${NC}"
echo -e "${BOLD}║  Region  : ${REGION}                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Verify we're authenticated ────────────────────────────────────────────────
step "Checking authentication"
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
[ -n "$ACTIVE_ACCOUNT" ] || die "No active gcloud account found. Run: gcloud auth login"
ok "Authenticated as: $ACTIVE_ACCOUNT"

gcloud config set project "$PROJECT_ID" --quiet
ok "Active project set to $PROJECT_ID"

# Set ADC quota project so Terraform can call GCP APIs
gcloud auth application-default set-quota-project "$PROJECT_ID" --quiet 2>/dev/null || true

# ── Install Terraform ≥ 1.6 if needed ────────────────────────────────────────
step "Checking Terraform"
TF_BIN="terraform"

if command -v terraform &>/dev/null; then
  TF_INSTALLED=$(terraform version -json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" \
    2>/dev/null \
    || terraform version | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)
  TF_MINOR=$(echo "$TF_INSTALLED" | cut -d. -f2)
  if [ "$TF_MINOR" -ge "$REQUIRED_TF_MINOR" ]; then
    ok "Terraform $TF_INSTALLED already installed"
  else
    warn "Terraform $TF_INSTALLED too old (need >= 1.$REQUIRED_TF_MINOR) — upgrading"
    _need_install=true
  fi
else
  warn "Terraform not found — installing $INSTALL_TF_VERSION"
  _need_install=true
fi

if [ "${_need_install:-false}" = "true" ]; then
  mkdir -p "${HOME}/.local/bin"
  log "Downloading Terraform $INSTALL_TF_VERSION..."
  curl -fsSL \
    "https://releases.hashicorp.com/terraform/${INSTALL_TF_VERSION}/terraform_${INSTALL_TF_VERSION}_linux_amd64.zip" \
    -o /tmp/tf.zip
  unzip -q /tmp/tf.zip -d /tmp/tf-bin
  mv /tmp/tf-bin/terraform "${HOME}/.local/bin/terraform"
  chmod +x "${HOME}/.local/bin/terraform"
  rm -rf /tmp/tf.zip /tmp/tf-bin
  export PATH="${HOME}/.local/bin:${PATH}"
  TF_BIN="${HOME}/.local/bin/terraform"
  ok "Terraform $INSTALL_TF_VERSION installed"
fi

# ── Clone or update the repo ──────────────────────────────────────────────────
step "Repository"
if [ -d "${WORK_DIR}/.git" ]; then
  log "Repo exists — pulling latest..."
  git -C "$WORK_DIR" pull --ff-only --quiet
  ok "Pulled latest from origin"
else
  log "Cloning ${REPO_URL}..."
  git clone --quiet "$REPO_URL" "$WORK_DIR"
  ok "Cloned to $WORK_DIR"
fi

cd "$WORK_DIR"
GIT_SHA=$(git rev-parse --short HEAD)
log "At commit: $GIT_SHA"

# ── Layer 0: Bootstrap ────────────────────────────────────────────────────────
step "Layer 0: Bootstrap (APIs, state bucket, Artifact Registry)"
cd "${WORK_DIR}/terraform/0-bootstrap"

BACKEND_TF="${WORK_DIR}/terraform/0-bootstrap/backend.tf"

if gcloud storage buckets describe "gs://${STATE_BUCKET}" --quiet &>/dev/null 2>&1; then
  ok "State bucket ${STATE_BUCKET} already exists"

  # Write backend.tf so Terraform uses GCS
  cat > "$BACKEND_TF" << EOF
terraform {
  backend "gcs" {
    bucket = "${STATE_BUCKET}"
    prefix = "landing-zone/bootstrap"
  }
}
EOF
  $TF_BIN init -reconfigure -input=false -no-color
  $TF_BIN apply -auto-approve -input=false -no-color
else
  log "First-time bootstrap — using local state until bucket is created"
  $TF_BIN init -input=false -no-color
  $TF_BIN apply -auto-approve -input=false -no-color

  ok "State bucket created — migrating bootstrap state to GCS"
  cat > "$BACKEND_TF" << EOF
terraform {
  backend "gcs" {
    bucket = "${STATE_BUCKET}"
    prefix = "landing-zone/bootstrap"
  }
}
EOF
  $TF_BIN init -migrate-state -force-copy -input=false -no-color
  ok "Bootstrap state migrated to gs://${STATE_BUCKET}/landing-zone/bootstrap"
fi

ok "Layer 0 complete"

# ── Wait for APIs to activate ─────────────────────────────────────────────────
log "Waiting 90s for newly enabled APIs to propagate across GCP..."
for i in $(seq 1 9); do
  sleep 10
  echo -n "."
done
echo ""
ok "APIs should be ready"

# ── Build and push Docker image ───────────────────────────────────────────────
step "Docker: build and push demo image"
cd "$WORK_DIR"

log "Configuring Docker for Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

log "Building image..."
docker build \
  --tag "${REGISTRY}/demo:latest" \
  --tag "${REGISTRY}/demo:${GIT_SHA}" \
  --quiet \
  app/

log "Pushing to Artifact Registry..."
docker push "${REGISTRY}/demo:latest" --quiet
docker push "${REGISTRY}/demo:${GIT_SHA}" --quiet
ok "Image pushed → ${REGISTRY}/demo:${GIT_SHA}"

# ── Layer 1: Security ─────────────────────────────────────────────────────────
step "Layer 1: Security (KMS, audit logging, monitoring alerts)"
cd "${WORK_DIR}/terraform/1-security"
$TF_BIN init -input=false -no-color
$TF_BIN apply -auto-approve -input=false -no-color
ok "Layer 1 complete"

# ── Layer 2: Network ──────────────────────────────────────────────────────────
step "Layer 2: Network (VPC, private subnet, firewall)"
cd "${WORK_DIR}/terraform/2-network"
$TF_BIN init -input=false -no-color
$TF_BIN apply -auto-approve -input=false -no-color
ok "Layer 2 complete"

# ── Layer 3: Workload ─────────────────────────────────────────────────────────
step "Layer 3: Workload (Cloud Run demo service)"
cd "${WORK_DIR}/terraform/3-workload"
$TF_BIN init -input=false -no-color
$TF_BIN apply -auto-approve -input=false -no-color
SERVICE_URL=$($TF_BIN output -raw service_url)
ok "Layer 3 complete"

# ── Verify deployment ─────────────────────────────────────────────────────────
step "Verifying live endpoint"
log "Waiting 15s for Cloud Run cold start..."
sleep 15

HTTP_STATUS=$(curl -s -o /tmp/demo-response.json -w "%{http_code}" "$SERVICE_URL" || echo "000")

if [ "$HTTP_STATUS" = "200" ]; then
  ok "Endpoint responding — HTTP $HTTP_STATUS"
  echo ""
  python3 -m json.tool /tmp/demo-response.json
else
  warn "Got HTTP $HTTP_STATUS — service may still be starting. Try manually:"
  warn "  curl -s $SERVICE_URL | python3 -m json.tool"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║              Deployment Complete!                        ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Demo URL:${NC}     $SERVICE_URL"
echo -e "  ${BOLD}Git SHA:${NC}      $GIT_SHA"
echo ""
echo -e "  ${BOLD}Resources deployed:${NC}"
echo "    KMS key ring     landing-zone-kr (${REGION})"
echo "    KMS keys         terraform-state-key, audit-logs-key, app-key"
echo "    KMS rotation     90 days (PCI DSS 6.3.5)"
echo "    Audit logs GCS   gs://${PROJECT_ID}-audit-logs  (7-year retention)"
echo "    Audit logs BQ    project.audit_logs  (partitioned, queryable)"
echo "    VPC              landing-zone-vpc"
echo "    Subnet           private-us-central1  10.0.1.0/24"
echo "    Firewall         deny-all-ingress, allow-iap-ssh, deny-all-egress"
echo "    Cloud Run        landing-zone-demo  (scale 0→3)"
echo "    State bucket     gs://${STATE_BUCKET}"
echo "    Artifact Reg     ${REGISTRY}"
echo ""
echo -e "  ${BOLD}Monitoring alerts active:${NC}"
echo "    [CRITICAL] Primitive IAM role granted"
echo "    [CRITICAL] Public IAM member added"
echo "    [WARNING]  Firewall rule modified out-of-band"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    # Hit the live endpoint:"
echo "    curl -s $SERVICE_URL | python3 -m json.tool"
echo ""
echo "    # Query audit logs in BigQuery:"
echo "    bq query --use_legacy_sql=false \\"
echo "      'SELECT timestamp, protopayload_auditlog.methodName, protopayload_auditlog.authenticationInfo.principalEmail"
echo "       FROM audit_logs.cloudaudit_googleapis_com_activity"
echo "       ORDER BY timestamp DESC LIMIT 20'"
echo ""
echo "    # Check monitoring alerts:"
echo "    gcloud monitoring policies list --project=$PROJECT_ID"
echo ""
echo "    # Tear down everything:"
echo "    bash ${WORK_DIR}/scripts/teardown.sh"
