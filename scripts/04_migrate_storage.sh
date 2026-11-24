#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 04_migrate_storage.sh - Migra a facturación PHYSICAL los datasets aprobados
#                         en storage_strategy.csv (acotados a projects.csv y regions.csv).
# Salida                : storage_migration_results.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

if [[ ! -f "$PROJECTS_CSV" || ! -f "$REGIONS_CSV" || ! -f "$STORAGE_CSV" ]]; then
  echo "[ERROR] Faltan archivos CSV requeridos. Ejecuta 00_setup.sh y 01_b_analyze_storage_strategy.sh." >&2
  exit 1
fi

VALID_PROJS=$(list_csv "$PROJECTS_CSV")
VALID_REGS=$(list_csv "$REGIONS_CSV" | tr '[:upper:]' '[:lower:]')

echo "timestamp_utc,project_id,dataset_id,location,monthly_savings_usd,status" > "$STORAGE_RESULTS_CSV"

FAILED=0
MIGRATED=0

while IFS=',' read -r proj ds loc model _ _ _ _ _ _ _ _ savings rec || [[ -n "${proj:-}" ]]; do
  proj=$(echo "${proj:-}" | tr -d '\r"' | xargs)
  [[ -z "$proj" || "$proj" == "project_id" ]] && continue

  ds=$(echo "$ds" | tr -d '\r"' | xargs)
  loc=$(echo "$loc" | tr -d '\r"' | xargs)
  loc_lc=$(echo "$loc" | tr '[:upper:]' '[:lower:]')
  model=$(echo "$model" | tr -d '\r"' | tr '[:lower:]' '[:upper:]' | xargs)
  savings=$(echo "${savings:-0}" | tr -d '\r"' | xargs)
  rec=$(echo "${rec:-false}" | tr -d '\r"' | tr '[:upper:]' '[:lower:]' | xargs)

  printf '%s\n' "$VALID_PROJS" | grep -qx "$proj"   || continue
  printf '%s\n' "$VALID_REGS"  | grep -qx "$loc_lc" || continue
  [[ "$model" == "PHYSICAL" ]] && continue

  ELIGIBLE=$(awk -v s="$savings" -v m="$MIN_MONTHLY_SAVINGS" -v r="$rec" 'BEGIN { print (r=="true" && s+0 > m+0) ? 1 : 0 }')
  [[ "$ELIGIBLE" != "1" ]] && continue

  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] bq update --dataset --storage_billing_model=PHYSICAL ${proj}:${ds}  # est. \$${savings}/mes"
    echo "${TS},${proj},${ds},${loc},${savings},DRY_RUN" >> "$STORAGE_RESULTS_CSV"
    MIGRATED=$((MIGRATED + 1))
  elif bq update --dataset --storage_billing_model=PHYSICAL "${proj}:${ds}" >/dev/null 2>&1; then
    echo "[INFO] Migrado ${proj}.${ds} (${loc}) -> PHYSICAL"
    echo "${TS},${proj},${ds},${loc},${savings},MIGRATED" >> "$STORAGE_RESULTS_CSV"
    MIGRATED=$((MIGRATED + 1))
  else
    echo "[ERROR] Falló migración de ${proj}.${ds}" >&2
    echo "${TS},${proj},${ds},${loc},${savings},FAILED" >> "$STORAGE_RESULTS_CSV"
    FAILED=$((FAILED + 1))
  fi
done < <(awk 'NR>1 {print}' "$STORAGE_CSV")

echo "[INFO] Almacenamiento procesado: ${MIGRATED} dataset(s), ${FAILED} con error -> ${STORAGE_RESULTS_CSV}"
[[ "$FAILED" -gt 0 ]] && exit 1 || exit 0
