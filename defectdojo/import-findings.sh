#!/usr/bin/env bash
# Import scanner reports into DefectDojo — the single memory of the program.
# Usage: DD_URL=https://dojo.example.com DD_TOKEN=xxx ./import-findings.sh <reports-dir>
#
# API: POST /api/v2/import-scan/ (multipart form, Token auth,
# auto_create_context creates product/engagement on the fly).
# scan_type must match a DefectDojo parser name exactly — list yours with:
#   curl -H "Authorization: Token $DD_TOKEN" "$DD_URL/api/v2/test_types/?name=Trivy"
set -euo pipefail

REPORTS_DIR="${1:?usage: import-findings.sh <reports-dir>}"
: "${DD_URL:?set DD_URL (e.g. https://dojo.example.com)}"
: "${DD_TOKEN:?set DD_TOKEN (DefectDojo API v2 key)}"

PRODUCT="payments-demo"
ENGAGEMENT="ci-pipeline"

import() {
  local file="$1" scan_type="$2"
  if [ ! -f "$REPORTS_DIR/$file" ]; then
    echo "[skip] $file not found (stage may not have run)"
    return 0
  fi
  echo "[import] $file as '$scan_type'"
  curl -sf -X POST "$DD_URL/api/v2/import-scan/" \
    -H "Authorization: Token $DD_TOKEN" \
    -F "product_type_name=Demo" \
    -F "product_name=$PRODUCT" \
    -F "engagement_name=$ENGAGEMENT" \
    -F "auto_create_context=true" \
    -F "scan_type=$scan_type" \
    -F "active=true" \
    -F "minimum_severity=Low" \
    -F "close_old_findings=true" \
    -F "file=@$REPORTS_DIR/$file" \
    >/dev/null && echo "[ok] $file" || echo "[warn] import of $file failed"
}

import gitleaks.json    "Gitleaks Scan"
import semgrep.json     "Semgrep JSON Report"
import trivy-fs.json    "Trivy Scan"
import trivy-image.json "Trivy Scan"
