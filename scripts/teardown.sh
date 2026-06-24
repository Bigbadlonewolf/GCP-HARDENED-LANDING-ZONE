#!/usr/bin/env bash
# teardown.sh — Destroy all landing zone resources
# Run in Cloud Shell when done with the demo.
# Deletes everything Terraform created to stop any ongoing costs.

set -euo pipefail

PROJECT_ID="mythical-cider-496423-h6"
WORK_DIR="${HOME}/gcp-hardened-landing-zone"
TF_BIN=$(command -v terraform || echo "${HOME}/.local/bin/terraform")

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

echo -e "${RED}"
echo "  WARNING: This will destroy all landing zone resources."
echo "  KMS keys with prevent_destroy=true will require manual deletion."
echo -e "${NC}"
read -r -p "Type 'destroy' to confirm: " CONFIRM
[ "$CONFIRM" = "destroy" ] || { echo "Aborted."; exit 0; }

gcloud config set project "$PROJECT_ID" --quiet

# Destroy in reverse order
for layer in 3-workload 2-network 1-security; do
  echo -e "\n${YELLOW}Destroying $layer...${NC}"
  cd "${WORK_DIR}/terraform/${layer}"
  $TF_BIN init -input=false -no-color
  $TF_BIN destroy -auto-approve -input=false -no-color || true
done

echo -e "\n${YELLOW}Destroying bootstrap...${NC}"
cd "${WORK_DIR}/terraform/0-bootstrap"
$TF_BIN init -input=false -no-color
# Remove prevent_destroy override for KMS before destroy
$TF_BIN destroy -auto-approve -input=false -no-color || true

echo ""
echo -e "${GREEN}Teardown complete.${NC}"
echo ""
echo "Note: KMS keys with prevent_destroy=true must be deleted manually:"
echo "  gcloud kms keys versions destroy 1 \\"
echo "    --key terraform-state-key --keyring landing-zone-kr \\"
echo "    --location us-central1 --project $PROJECT_ID"
echo ""
echo "State bucket (if not destroyed by Terraform):"
echo "  gcloud storage rm -r gs://${PROJECT_ID}-tf-state"
echo "  gcloud storage rm -r gs://${PROJECT_ID}-audit-logs"
