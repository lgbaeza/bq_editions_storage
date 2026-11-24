#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 02_migrate_editions.sh - Migra reservas Flat-Rate hacia el target_admin_project
#                          y configuración validados manualmente en editions.csv.
# Salida                 : editions_migration_results.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

if [[ ! -f "$EDITIONS_CSV" ]]; then
  echo "[ERROR] No existe ${EDITIONS_CSV}. Ejecuta 01_a_list_flatrate.sh y valida el archivo." >&2
  exit 1
fi

echo "timestamp_utc,source_admin_project,target_admin_project,location,flat_rate_reservation,target_reservation,target_edition,moved_assignments,deleted_flat_rate,status" > "$EDITIONS_RESULTS_CSV"

FAILED=0
COUNT=0

while IFS=',' read -r src_admin loc flat_res _ _ dst_admin target_res edition base_slots max_slots idle del_flat || [[ -n "${src_admin:-}" ]]; do
  src_admin=$(echo "${src_admin:-}" | tr -d '\r"' | xargs)
  [[ -z "$src_admin" || "$src_admin" == "source_admin_project" ]] && continue

  loc=$(echo "$loc" | tr -d '\r"' | xargs)
  flat_res=$(echo "$flat_res" | tr -d '\r"' | xargs)
  dst_admin=$(echo "${dst_admin:-$src_admin}" | tr -d '\r"' | xargs)
  target_res=$(echo "$target_res" | tr -d '\r"' | xargs)
  edition=$(echo "${edition:-$TARGET_EDITION}" | tr -d '\r"' | tr '[:lower:]' '[:upper:]' | xargs)
  base_slots=$(echo "${base_slots:-0}" | tr -d '\r"' | xargs)
  max_slots=$(echo "${max_slots:-0}" | tr -d '\r"' | xargs)
  idle=$(echo "${idle:-false}" | tr -d '\r"' | tr '[:upper:]' '[:lower:]' | xargs)
  del_flat=$(echo "${del_flat:-false}" | tr -d '\r"' | tr '[:upper:]' '[:lower:]' | xargs)

  COUNT=$((COUNT + 1))
  TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  if [[ "$dst_admin" == "$src_admin" && "$target_res" == "$flat_res" ]]; then
    echo "[ERROR] En el mismo proyecto (${dst_admin}), target_reservation debe ser distinto de flat_rate_reservation (${flat_res})." >&2
    echo "${TS},${src_admin},${dst_admin},${loc},${flat_res},${target_res},${edition},0,false,FAILED" >> "$EDITIONS_RESULTS_CSV"
    FAILED=$((FAILED + 1))
    continue
  fi

  FLAGS=(--project_id="$dst_admin" --location="$loc" --slots="$base_slots" --ignore_idle_slots="$idle")
  [[ "$max_slots" -gt 0 ]] && FLAGS+=(--autoscale_max_slots="$max_slots")

  # 1. Crear o actualizar la reserva Editions en target_admin_project
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] bq mk --reservation --edition=${edition} ${FLAGS[*]} ${target_res}"
  elif bq show --reservation --project_id="$dst_admin" --location="$loc" "$target_res" >/dev/null 2>&1; then
    bq update --reservation "${FLAGS[@]}" "$target_res"
  elif ! bq mk --reservation --edition="$edition" "${FLAGS[@]}" "$target_res"; then
    echo "${TS},${src_admin},${dst_admin},${loc},${flat_res},${target_res},${edition},0,false,FAILED" >> "$EDITIONS_RESULTS_CSV"
    FAILED=$((FAILED + 1))
    continue
  fi

  # 2. Mover asignaciones desde source_admin_project hacia target_admin_project
  MOVED=0
  MOVE_ERR=0
  RAW_ASS=$(bq ls --reservation_assignment --project_id="$src_admin" --location="$loc" --format=json "${src_admin}:${loc}.${flat_res}" 2>/dev/null || true)
  if [[ "$RAW_ASS" == \[* ]]; then
    while IFS='|' read -r ass_id assignee job_type; do
      [[ -z "$ass_id" ]] && continue
      DEST="${dst_admin}:${loc}.${target_res}"
      SRC="${src_admin}:${loc}.${flat_res}.${ass_id}"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Mover asignación ${SRC} -> ${DEST} (${assignee}, ${job_type})"
        MOVED=$((MOVED + 1))
      elif bq update --reservation_assignment --project_id="$src_admin" --location="$loc" --destination_reservation_id="$DEST" "$SRC" >/dev/null 2>&1; then
        MOVED=$((MOVED + 1))
      elif [[ "$dst_admin" != "$src_admin" ]]; then
        ASS_TYPE=$(echo "$assignee" | cut -d'/' -f1 | sed 's/s$//' | tr '[:lower:]' '[:upper:]')
        ASS_VAL=$(echo "$assignee" | cut -d'/' -f2)
        if bq rm --reservation_assignment --force --project_id="$src_admin" --location="$loc" "$SRC" >/dev/null 2>&1 && \
           bq mk --reservation_assignment --project_id="$dst_admin" --location="$loc" --reservation_id="$DEST" \
             --assignee_type="$ASS_TYPE" --assignee_id="$ASS_VAL" --job_type="$job_type" >/dev/null 2>&1; then
          MOVED=$((MOVED + 1))
        else
          MOVE_ERR=$((MOVE_ERR + 1))
        fi
      else
        MOVE_ERR=$((MOVE_ERR + 1))
      fi
    done < <(echo "$RAW_ASS" | jq -r '.[] | "\(.name | split("/") | last)|\(.assignee)|\(.jobType)"')
  fi

  # 3. Eliminar opcionalmente la reserva Flat-Rate vaciada en source_admin_project
  DELETED="false"
  if [[ "$del_flat" == "true" && "$MOVE_ERR" -eq 0 ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[DRY-RUN] bq rm --reservation --force --project_id=${src_admin} --location=${loc} ${flat_res}"
      DELETED="dry_run"
    elif bq rm --reservation --force --project_id="$src_admin" --location="$loc" "$flat_res" >/dev/null 2>&1; then
      DELETED="true"
    fi
  fi

  STATUS="MIGRATED"
  [[ "$DRY_RUN" == "true" ]] && STATUS="DRY_RUN"
  if [[ "$MOVE_ERR" -gt 0 ]]; then STATUS="PARTIAL_FAILURE"; FAILED=$((FAILED + 1)); fi
  echo "${TS},${src_admin},${dst_admin},${loc},${flat_res},${target_res},${edition},${MOVED},${DELETED},${STATUS}" >> "$EDITIONS_RESULTS_CSV"
done < <(awk 'NR>1 {print}' "$EDITIONS_CSV")

echo "[INFO] Reservas procesadas: ${COUNT} -> ${EDITIONS_RESULTS_CSV}"
[[ "$FAILED" -gt 0 ]] && exit 1 || exit 0
