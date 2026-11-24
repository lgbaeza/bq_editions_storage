#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi
set +o posix; unset POSIXLY_CORRECT
# ==============================================================================
# 01_b_analyze_storage_strategy.sh - Analiza compresión y eficiencia de costos
#                                    (LOGICAL vs PHYSICAL) sobre projects.csv y
#                                    regions.csv sin requerir un admin project global.
# Salida                           : storage_strategy.csv
# ==============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/params.sh"

if [[ ! -f "$PROJECTS_CSV" || ! -f "$REGIONS_CSV" ]]; then
  echo "[ERROR] Faltan ${PROJECTS_CSV} o ${REGIONS_CSV}. Ejecuta primero 00_setup.sh." >&2
  exit 1
fi

get_rates() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    southamerica-west1|southamerica-east1) echo "0.023 0.016 0.046 0.032" ;;
    *) echo "0.02 0.01 0.04 0.02" ;;
  esac
}

echo "project_id,dataset_id,location,current_billing_model,table_count,active_logical_gib,long_term_logical_gib,billable_active_physical_gib,long_term_physical_gib,effective_compression_ratio,logical_monthly_cost_usd,physical_monthly_cost_usd,monthly_savings_usd,recommend_migrate" > "$STORAGE_CSV"

while IFS= read -r region; do
  [[ -z "$region" ]] && continue
  read -r act_log lt_log act_phys lt_phys <<< "$(get_rates "$region")"

  while IFS= read -r proj; do
    [[ -z "$proj" ]] && continue
    SQL="
    WITH billing AS (
      SELECT schema_name AS dataset_id, UPPER(TRIM(option_value, '\"')) AS model
      FROM \`${proj}\`.\`region-${region}\`.INFORMATION_SCHEMA.SCHEMATA_OPTIONS
      WHERE option_name = 'storage_billing_model'
    ),
    storage AS (
      SELECT
        project_id,
        table_schema AS dataset_id,
        COUNT(DISTINCT table_name) AS table_count,
        SUM(active_logical_bytes) / POW(1024, 3) AS act_log_gib,
        SUM(long_term_logical_bytes) / POW(1024, 3) AS lt_log_gib,
        SUM(active_physical_bytes + fail_safe_physical_bytes) / POW(1024, 3) AS act_phys_gib,
        SUM(long_term_physical_bytes) / POW(1024, 3) AS lt_phys_gib,
        SAFE_DIVIDE(
          SUM(active_logical_bytes + long_term_logical_bytes),
          SUM(active_physical_bytes + fail_safe_physical_bytes + long_term_physical_bytes)
        ) AS compression_ratio
      FROM \`${proj}\`.\`region-${region}\`.INFORMATION_SCHEMA.TABLE_STORAGE
      WHERE deleted = FALSE
      GROUP BY project_id, dataset_id
    ),
    costs AS (
      SELECT
        s.*,
        COALESCE(b.model, 'LOGICAL') AS current_billing_model,
        ((s.act_log_gib * ${act_log}) + (s.lt_log_gib * ${lt_log})) * ${DISCOUNT_MULTIPLIER} AS log_cost,
        ((s.act_phys_gib * ${act_phys}) + (s.lt_phys_gib * ${lt_phys})) * ${DISCOUNT_MULTIPLIER} AS phys_cost
      FROM storage s
      LEFT JOIN billing b USING (dataset_id)
    )
    SELECT
      project_id,
      dataset_id,
      '${region}' AS location,
      current_billing_model,
      table_count,
      ROUND(act_log_gib, 4),
      ROUND(lt_log_gib, 4),
      ROUND(act_phys_gib, 4),
      ROUND(lt_phys_gib, 4),
      ROUND(COALESCE(compression_ratio, 0), 2),
      ROUND(log_cost, 2),
      ROUND(phys_cost, 2),
      ROUND(log_cost - phys_cost, 2) AS monthly_savings_usd,
      IF(ROUND(log_cost - phys_cost, 2) > 0 AND current_billing_model != 'PHYSICAL', TRUE, FALSE) AS recommend_migrate
    FROM costs
    ORDER BY monthly_savings_usd DESC"

    if OUT=$(bq query --project_id="$proj" --location="$region" --use_legacy_sql=false --format=csv --max_rows=100000 --quiet "$SQL" 2>/dev/null); then
      [[ -n "$OUT" ]] && echo "$OUT" | tail -n +2 >> "$STORAGE_CSV"
    fi
  done < <(list_csv "$PROJECTS_CSV")
done < <(list_csv "$REGIONS_CSV")

TOTAL=$(tail -n +2 "$STORAGE_CSV" | sed '/^$/d' | wc -l | xargs)
BENEFICIAL=$(awk -F',' 'NR>1 && tolower($14)=="true" {c++} END {print c+0}' "$STORAGE_CSV")
SAVINGS=$(awk -F',' 'NR>1 && tolower($14)=="true" {s+=$13} END {printf "%.2f", s}' "$STORAGE_CSV")
echo "[INFO] Analizados ${TOTAL} dataset(s): ${BENEFICIAL} recomendados para PHYSICAL (${STORAGE_CSV}, Dif. Est.: \$${SAVINGS}/mes)"
