#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 03_verify_editions.sh - Verifica las reservas Editions en cada target_admin_project
#                         de editions.csv y confirma en projects.csv / regions.csv
#                         que ninguna reserva Flat-Rate retenga asignaciones.
# Salida                : editions_verification.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"

if [[ ! -f "$PROJECTS_CSV" || ! -f "$REGIONS_CSV" ]]; then
  echo "[ERROR] Faltan ${PROJECTS_CSV} o ${REGIONS_CSV}. Ejecuta primero 00_setup.sh." >&2
  exit 1
fi

echo "timestamp_utc,check_type,resource,location,expected,actual,status" > "$EDITIONS_VERIFY_CSV"
PASS=0
FAIL=0

# 1. Verificar cada reserva Editions destino definida en editions.csv
if [[ -f "$EDITIONS_CSV" ]]; then
  while IFS=',' read -r src_admin loc flat_res _ _ dst_admin target_res edition base_slots max_slots _ _ || [[ -n "${src_admin:-}" ]]; do
    src_admin=$(echo "${src_admin:-}" | tr -d '\r"' | xargs)
    [[ -z "$src_admin" || "$src_admin" == "source_admin_project" ]] && continue
    dst_admin=$(echo "${dst_admin:-$src_admin}" | tr -d '\r"' | xargs)
    loc=$(echo "$loc" | tr -d '\r"' | xargs)
    target_res=$(echo "$target_res" | tr -d '\r"' | xargs)
    edition=$(echo "$edition" | tr -d '\r"' | tr '[:lower:]' '[:upper:]' | xargs)
    base_slots=$(echo "${base_slots:-0}" | tr -d '\r"' | xargs)
    max_slots=$(echo "${max_slots:-0}" | tr -d '\r"' | xargs)
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if RES_JSON=$(bq show --reservation --project_id="$dst_admin" --location="$loc" --format=json "$target_res" 2>/dev/null); then
      ACT_ED=$(echo "$RES_JSON" | jq -r '.edition // "NONE"')
      ACT_BASE=$(echo "$RES_JSON" | jq -r '.slotCapacity // 0')
      ACT_MAX=$(echo "$RES_JSON" | jq -r '.autoscale.maxSlots // 0')
      if [[ "$ACT_ED" == "$edition" && "$ACT_BASE" == "$base_slots" && "$ACT_MAX" == "$max_slots" ]]; then
        STATUS="PASS"; PASS=$((PASS + 1))
      else
        STATUS="FAIL"; FAIL=$((FAIL + 1))
      fi
      echo "${TS},TARGET_RESERVATION,${dst_admin}:${loc}.${target_res},${loc},${edition}:${base_slots}/${max_slots},${ACT_ED}:${ACT_BASE}/${ACT_MAX},${STATUS}" >> "$EDITIONS_VERIFY_CSV"
    else
      FAIL=$((FAIL + 1))
      echo "${TS},TARGET_RESERVATION,${dst_admin}:${loc}.${target_res},${loc},${edition}:${base_slots}/${max_slots},NOT_FOUND,FAIL" >> "$EDITIONS_VERIFY_CSV"
    fi
  done < <(awk 'NR>1 {print}' "$EDITIONS_CSV")
fi

# 2. Barrido organizacional: confirmar cero asignaciones activas en reservas Flat-Rate
while IFS= read -r proj; do
  [[ -z "$proj" ]] && continue
  while IFS= read -r region; do
    [[ -z "$region" ]] && continue
    RAW_RES=$(bq ls --reservation --project_id="$proj" --location="$region" --format=json 2>/dev/null || true)
    [[ "$RAW_RES" != \[* ]] && continue

    while IFS='|' read -r res_name loc; do
      [[ -z "$res_name" ]] && continue
      RAW_ASS=$(bq ls --reservation_assignment --project_id="$proj" --location="$loc" --format=json "${proj}:${loc}.${res_name}" 2>/dev/null || true)
      ASS_CNT=0
      [[ "$RAW_ASS" == \[* ]] && ASS_CNT=$(echo "$RAW_ASS" | jq 'length')
      TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      if [[ "$ASS_CNT" -eq 0 ]]; then
        STATUS="PASS"; PASS=$((PASS + 1))
      else
        STATUS="FAIL"; FAIL=$((FAIL + 1))
      fi
      echo "${TS},FLATRATE_DRAINED,${proj}:${loc}.${res_name},${loc},assignments=0,assignments=${ASS_CNT},${STATUS}" >> "$EDITIONS_VERIFY_CSV"
    done < <(echo "$RAW_RES" | jq -r '.[] | select((.edition // "EDITION_UNSPECIFIED") == "EDITION_UNSPECIFIED" or (.edition // "") == "") | "\(.name | split("/") | last)|\(.name | split("/")[3])"')
  done < <(list_csv "$REGIONS_CSV")
done < <(list_csv "$PROJECTS_CSV")

echo "[INFO] Verificación Editions completada: ${PASS} PASS, ${FAIL} FAIL -> ${EDITIONS_VERIFY_CSV}"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
