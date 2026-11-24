#!/usr/bin/env bash
# ==============================================================================
# params.sh - Configuración Global de Migración BigQuery (Nivel Organización)
# ==============================================================================
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dominio textual de la organización GCP
ORG_NAME="lgbaeza.altostrat.com"

# Parámetros por defecto para sugerencias iniciales y umbrales
TARGET_EDITION="ENTERPRISE"      # STANDARD | ENTERPRISE | ENTERPRISE_PLUS
DISCOUNT_MULTIPLIER="1.0"        # Multiplicador contractual sobre precio lista (ej. 0.85)
MIN_MONTHLY_SAVINGS="0.0"        # Ahorro mínimo mensual (USD) para recomendar cambio a PHYSICAL
DRY_RUN="false"                  # "true" previsualiza mutaciones sin aplicar cambios

# Archivos CSV compartidos entre etapas (00 -> 05)
PROJECTS_CSV="${ROOT_DIR}/projects.csv"
REGIONS_CSV="${ROOT_DIR}/regions.csv"
EDITIONS_CSV="${ROOT_DIR}/editions.csv"
STORAGE_CSV="${ROOT_DIR}/storage_strategy.csv"
EDITIONS_RESULTS_CSV="${ROOT_DIR}/editions_migration_results.csv"
EDITIONS_VERIFY_CSV="${ROOT_DIR}/editions_verification.csv"
STORAGE_RESULTS_CSV="${ROOT_DIR}/storage_migration_results.csv"
STORAGE_VERIFY_CSV="${ROOT_DIR}/storage_verification.csv"

# Helper: lee valores únicos no vacíos de un CSV de 1 columna (tolera ausencia de salto de línea final)
list_csv() {
  awk 'NR>1 {gsub(/["\r ]/, ""); if ($0 != "") print $0}' "$1" | sort -u
}
