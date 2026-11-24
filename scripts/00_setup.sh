#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 00_setup.sh - Descubre proyectos activos y regiones con datasets o reservas en
#               uso a partir de la organización textual definida en params.sh.
# Salidas     : projects.csv, regions.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"

if [[ "$ORG_NAME" =~ ^[0-9]+$ ]]; then
  ORG_ID="$ORG_NAME"
else
  ORG_ID=$(gcloud organizations list --filter="displayName=${ORG_NAME}" --format="value(ID)" | head -n 1)
fi

if [[ -z "$ORG_ID" ]]; then
  echo "[ERROR] No se encontró la organización '${ORG_NAME}'." >&2
  exit 1
fi
echo "[INFO] Organización '${ORG_NAME}' -> ID: ${ORG_ID}"

TMP_PAIRS=$(mktemp)
trap 'rm -f "$TMP_PAIRS"' EXIT

# Vía rápida: Cloud Asset Inventory (datasets + reservas); respaldo: carpetas + bq ls
if ASSET_JSON=$(gcloud asset search-all-resources --quiet \
    --scope="organizations/${ORG_ID}" \
    --asset-types="bigquery.googleapis.com/Dataset,bigqueryreservation.googleapis.com/Reservation" \
    --format="json(name,location)" 2>/dev/null) && [[ "$ASSET_JSON" == \[* ]]; then
  echo "[INFO] Descubriendo proyectos y regiones vía Cloud Asset Inventory..."
  echo "$ASSET_JSON" | jq -r '
    .[]
    | (.name | split("/")[4]) as $proj
    | (.location | ascii_downcase) as $loc
    | select(($loc | startswith("aws-") or startswith("azure-")) | not)
    | "\($proj),\($loc)"
  ' > "$TMP_PAIRS"
else
  echo "[INFO] Descubriendo estructura de carpetas y proyectos activos con uso de BigQuery..."
  QUEUE=($(gcloud resource-manager folders list --organization="$ORG_ID" --format="value(ID)" 2>/dev/null || true))
  PARENTS=("$ORG_ID" ${QUEUE[@]+"${QUEUE[@]}"})
  while [[ ${#QUEUE[@]} -gt 0 ]]; do
    CURR="${QUEUE[0]}"
    if [[ ${#QUEUE[@]} -gt 1 ]]; then
      QUEUE=("${QUEUE[@]:1}")
    else
      QUEUE=()
    fi
    for sub in $(gcloud resource-manager folders list --folder="$CURR" --format="value(ID)" 2>/dev/null || true); do
      [[ -n "$sub" ]] && QUEUE+=("$sub") && PARENTS+=("$sub")
    done
  done

  ORG_PROJS=()
  while IFS=',' read -r pid parent_id; do
    [[ -z "$pid" ]] && continue
    for p in "${PARENTS[@]}"; do
      if [[ "$parent_id" == "$p" ]]; then
        ORG_PROJS+=("$pid")
        DS_JSON=$(bq ls --project_id="$pid" --max_results=1000 --format=json 2>/dev/null || true)
        if [[ "$DS_JSON" == \[* ]]; then
          echo "$DS_JSON" | jq -r --arg P "$pid" '
            .[]
            | select((.type // "DEFAULT") == "DEFAULT")
            | (.location | ascii_downcase) as $loc
            | select(($loc | startswith("aws-") or startswith("azure-")) | not)
            | "\($P),\($loc)"
          ' >> "$TMP_PAIRS"
        fi
        break
      fi
    done
  done < <(gcloud projects list --filter="lifecycleState:ACTIVE" --format="csv[no-heading](projectId,parent.id)")

  # Incluir también proyectos que solo administran reservas (sin datasets propios)
  KNOWN_REGS=$(cut -d',' -f2 "$TMP_PAIRS" | sed '/^$/d' | sort -u)
  for pid in ${ORG_PROJS[@]+"${ORG_PROJS[@]}"}; do
    grep -q "^${pid}," "$TMP_PAIRS" 2>/dev/null && continue
    for reg in $KNOWN_REGS; do
      RES_JSON=$(bq ls --reservation --project_id="$pid" --location="$reg" --format=json 2>/dev/null || true)
      if [[ "$RES_JSON" == \[* ]]; then
        echo "${pid},${reg}" >> "$TMP_PAIRS"
      fi
    done
  done
fi

{ echo "project_id"; cut -d',' -f1 "$TMP_PAIRS" | sed '/^$/d' | sort -u; } > "$PROJECTS_CSV"
{ echo "region"; cut -d',' -f2 "$TMP_PAIRS" | sed '/^$/d' | sort -u; } > "$REGIONS_CSV"

echo "[INFO] Proyectos detectados ($(( $(wc -l < "$PROJECTS_CSV") - 1 ))) -> ${PROJECTS_CSV}"
echo "[INFO] Regiones detectadas  ($(( $(wc -l < "$REGIONS_CSV") - 1 ))) -> ${REGIONS_CSV}"
