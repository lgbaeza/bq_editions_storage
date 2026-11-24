#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 01_a_list_flatrate.sh - Lista todas las reservas Flat-Rate en todos los
#                         proyectos (projects.csv) y regiones (regions.csv).
#                         Permite mapear cada reserva al target_admin_project
#                         que corresponda en editions.csv.
# Salida                : editions.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"

if [[ ! -f "$PROJECTS_CSV" || ! -f "$REGIONS_CSV" ]]; then
  echo "[ERROR] Faltan ${PROJECTS_CSV} o ${REGIONS_CSV}. Ejecuta primero 00_setup.sh." >&2
  exit 1
fi

echo "source_admin_project,location,flat_rate_reservation,current_slots,assignment_count,target_admin_project,target_reservation,target_edition,baseline_slots,autoscale_max_slots,ignore_idle_slots,delete_flat_rate" > "$EDITIONS_CSV"

FOUND=0

while IFS= read -r proj; do
  [[ -z "$proj" ]] && continue
  while IFS= read -r region; do
    [[ -z "$region" ]] && continue

    RAW_RES=$(bq ls --reservation --project_id="$proj" --location="$region" --format=json 2>/dev/null || true)
    [[ "$RAW_RES" != \[* ]] && continue

    while IFS='|' read -r res_name loc slots ignore_idle; do
      [[ -z "$res_name" ]] && continue
      RAW_ASS=$(bq ls --reservation_assignment --project_id="$proj" --location="$loc" --format=json "${proj}:${loc}.${res_name}" 2>/dev/null || true)
      ass_count=0
      [[ "$RAW_ASS" == \[* ]] && ass_count=$(echo "$RAW_ASS" | jq 'length')

      if [[ "$slots" -gt 0 ]]; then
        autoscale_max=$(( (slots + 49) / 50 * 50 ))
      else
        autoscale_max=100
      fi

      echo "${proj},${loc},${res_name},${slots},${ass_count},${proj},${res_name}-editions,${TARGET_EDITION},0,${autoscale_max},${ignore_idle},false" >> "$EDITIONS_CSV"
      echo "[INFO] Reserva Flat-Rate detectada: ${proj}:${loc}.${res_name} (slots=${slots}, asignaciones=${ass_count})"
      FOUND=$((FOUND + 1))
    done < <(echo "$RAW_RES" | jq -r '
      .[]
      | select((.edition // "EDITION_UNSPECIFIED") == "EDITION_UNSPECIFIED" or (.edition // "") == "")
      | "\(.name | split("/") | last)|\(.name | split("/")[3])|\(.slotCapacity // 0)|\(.ignoreIdleSlots // false)"
    ')
  done < <(list_csv "$REGIONS_CSV")
done < <(list_csv "$PROJECTS_CSV")

echo "[INFO] Total reservas Flat-Rate encontradas: ${FOUND} -> ${EDITIONS_CSV}"
