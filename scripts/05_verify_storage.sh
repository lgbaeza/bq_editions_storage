#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 05_verify_storage.sh - Verifica que todos los datasets elegibles aprobados en
#                        storage_strategy.csv operen con storageBillingModel=PHYSICAL.
# Salida               : storage_verification.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"

if [[ ! -f "$PROJECTS_CSV" || ! -f "$REGIONS_CSV" || ! -f "$STORAGE_CSV" ]]; then
  echo "[ERROR] Faltan archivos CSV requeridos. Ejecuta 00_setup.sh y 01_b_analyze_storage_strategy.sh." >&2
  exit 1
fi

VALID_PROJS=$(list_csv "$PROJECTS_CSV")
VALID_REGS=$(list_csv "$REGIONS_CSV" | tr '[:upper:]' '[:lower:]')

echo "timestamp_utc,project_id,dataset_id,location,expected_model,actual_model,status" > "$STORAGE_VERIFY_CSV"

PASS=0
FAIL=0

while IFS=',' read -r proj ds loc _ _ _ _ _ _ _ _ _ savings rec || [[ -n "${proj:-}" ]]; do
  proj=$(echo "${proj:-}" | tr -d '\r"' | xargs)
  [[ -z "$proj" || "$proj" == "project_id" ]] && continue

  ds=$(echo "$ds" | tr -d '\r"' | xargs)
  loc=$(echo "$loc" | tr -d '\r"' | xargs)
  loc_lc=$(echo "$loc" | tr '[:upper:]' '[:lower:]')
  savings=$(echo "${savings:-0}" | tr -d '\r"' | xargs)
  rec=$(echo "${rec:-false}" | tr -d '\r"' | tr '[:upper:]' '[:lower:]' | xargs)

  printf '%s\n' "$VALID_PROJS" | grep -qx "$proj"   || continue
  printf '%s\n' "$VALID_REGS"  | grep -qx "$loc_lc" || continue

  ELIGIBLE=$(awk -v s="$savings" -v m="$MIN_MONTHLY_SAVINGS" -v r="$rec" 'BEGIN { print (r=="true" && s+0 > m+0) ? 1 : 0 }')
  [[ "$ELIGIBLE" != "1" ]] && continue

  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  ACTUAL=$(bq show --format=json "${proj}:${ds}" 2>/dev/null | jq -r '.storageBillingModel // "LOGICAL"' | tr '[:lower:]' '[:upper:]' || echo "ERROR")
  if [[ "$ACTUAL" == "PHYSICAL" ]]; then
    STATUS="PASS"; PASS=$((PASS + 1))
  else
    STATUS="FAIL"; FAIL=$((FAIL + 1))
  fi
  echo "${TS},${proj},${ds},${loc},PHYSICAL,${ACTUAL},${STATUS}" >> "$STORAGE_VERIFY_CSV"
done < <(awk 'NR>1 {print}' "$STORAGE_CSV")

echo "[INFO] Verificación de almacenamiento completada: ${PASS} PASS, ${FAIL} FAIL -> ${STORAGE_VERIFY_CSV}"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
