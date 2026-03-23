#!/bin/bash

###############################################################################
# vsphere-2-harvester.sh
#
# Migration of VMware vSphere VMs to Harvester 
# using the vm-import-controller and Harvester API.
#
# Usage:
#   ./vsphere-2-harvester.sh [--verbose|-v] [--help|-h]
#
# Author: Paul Dresch @ FIS-ASP
###############################################################################

set -euo pipefail

# --- Configuration defaults ---
LOG_DIR="/var/log/vsphere-2-harvester"
GENERAL_LOG_FILE="$LOG_DIR/general.log"
SCRIPT_NAME="VSPHERE-2-HARVESTER"
TMUX_SESSION_PREFIX="v2h"
VERBOSE=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_BOOTSTRAP_FILE="${SCRIPT_DIR}/.vault-bootstrap"
VAULT_TOKEN=""
VAULT_LAST_STATUS=""
VAULT_ADDR=""
VAULT_NAMESPACE=""
VAULT_KV_MOUNT="vsphere-2-harvester"
VAULT_KV_PREFIX="profiles"
VAULT_AUTH_PATH="auth/approle/login"
VAULT_ROLE_ID=""
VAULT_SECRET_ID=""
VAULT_SKIP_VERIFY="false"
VAULT_CACERT=""
VAULT_TEMP_KUBECONFIG=""

declare -ag VCENTER_PROFILES=()
declare -ag HARVESTER_PROFILES=()
declare -ag MIGRATION_PROFILES=()

declare -Ag MIGRATION_VCENTERS=()
declare -Ag MIGRATION_HARVESTERS=()
declare -Ag MIGRATION_DATACENTERS=()
declare -Ag MIGRATION_SRC_NETS=()
declare -Ag MIGRATION_DST_NETS=()
declare -Ag MIGRATION_NAMESPACES=()
declare -Ag MIGRATION_SOCKETS=()

SELECTED_VCENTER_PROFILE=""
SELECTED_HARVESTER_PROFILE=""
SELECTED_MIGRATION_PROFILE=""
VSPHERE_SECRET_NAME=""
VMWARE_SOURCE_NAME=""

# Import helper functions
if [[ -f "$SCRIPT_DIR/import_monitor.sh" ]]; then
  source "$SCRIPT_DIR/import_monitor.sh"
else
  echo "[${SCRIPT_NAME}] $(date '+%Y-%m-%d %H:%M:%S') [ERROR]: Missing required file: import_monitor.sh" >&2
  exit 1
fi

# --- Default migration parameters ---
DEFAULT_VSPHERE_DC="ASP"
DEFAULT_SRC_NET="RHV-Testing"
DEFAULT_DST_NET="default/rhv-testing"
DEFAULT_NAMESPACE="har-fasp-02"
POST_MIGRATE_SOCKETS="2"

HARVESTER_NAMESPACE="${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}"
HARVESTER_CONTEXT="${HARVESTER_CONTEXT:-}"

reset_profile_config() {
  VCENTER_PROFILES=()
  HARVESTER_PROFILES=()
  MIGRATION_PROFILES=()

  MIGRATION_VCENTERS=()
  MIGRATION_HARVESTERS=()
  MIGRATION_DATACENTERS=()
  MIGRATION_SRC_NETS=()
  MIGRATION_DST_NETS=()
  MIGRATION_NAMESPACES=()
  MIGRATION_SOCKETS=()
}

slugify_name() {
  local raw="$1"
  local slug

  slug=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')
  echo "${slug:0:50}"
}

resource_name() {
  local prefix="$1"
  local profile_name="$2"
  local slug

  slug=$(slugify_name "$profile_name")
  if [[ -z "$slug" ]]; then
    slug="default"
  fi

  echo "${prefix}-${slug}"
}

cleanup_runtime_artifacts() {
  if [[ -n "${VAULT_TEMP_KUBECONFIG:-}" && -f "$VAULT_TEMP_KUBECONFIG" ]]; then
    rm -f "$VAULT_TEMP_KUBECONFIG"
  fi

  unset VAULT_TOKEN VSPHERE_USER VSPHERE_PASS CATTLE_ACCESS_KEY CATTLE_SECRET_KEY
}

trap cleanup_runtime_artifacts EXIT

configure_kubectl_access() {
  local kubeconfig_b64

  if [[ -n "${VAULT_TEMP_KUBECONFIG:-}" && -f "$VAULT_TEMP_KUBECONFIG" ]]; then
    export KUBECONFIG="$VAULT_TEMP_KUBECONFIG"
    return 0
  fi

  kubeconfig_b64=$(vault_kv_get_field "harvesters/${SELECTED_HARVESTER_PROFILE}" "kubeconfig_b64")
  if [[ -z "$kubeconfig_b64" ]]; then
    show_error "Harvester profile '$SELECTED_HARVESTER_PROFILE' does not contain kubeconfig_b64"
    return 1
  fi

  VAULT_TEMP_KUBECONFIG=$(mktemp "${TMPDIR:-/tmp}/v2h-kubeconfig-XXXXXX")
  chmod 600 "$VAULT_TEMP_KUBECONFIG"

  if ! echo "$kubeconfig_b64" | base64 -d >"$VAULT_TEMP_KUBECONFIG" 2>/dev/null; then
    rm -f "$VAULT_TEMP_KUBECONFIG"
    VAULT_TEMP_KUBECONFIG=""
    show_error "Failed to decode kubeconfig for Harvester profile '$SELECTED_HARVESTER_PROFILE'"
    return 1
  fi

  export KUBECONFIG="$VAULT_TEMP_KUBECONFIG"
}

run_kubectl() {
  if [[ -n "${HARVESTER_CONTEXT:-}" ]]; then
    kubectl --context "$HARVESTER_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}
export -f run_kubectl

command_exists() {
  command -v "$1" &>/dev/null
}

check_vault_dependencies() {
  local cmd
  for cmd in curl jq; do
    if ! command_exists "$cmd"; then
      show_error "Missing required command: $cmd"
      exit 11
    fi
  done
}

is_profile_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

prompt_for_profile_name() {
  local var="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local input

  while true; do
    input=$(gum input --placeholder "$prompt" --value "$default_value")
    if [[ $? -eq 130 ]]; then
      return 1
    fi

    if [[ -z "$input" ]]; then
      input="$default_value"
    fi

    if [[ -n "$input" ]] && is_profile_name "$input"; then
      printf -v "$var" '%s' "$input"
      return 0
    fi

    gum style --foreground 196 "Invalid profile name. Use letters, digits, '.', '_' or '-' only."
  done
}

vault_bootstrap_exists() {
  [[ -f "$VAULT_BOOTSTRAP_FILE" ]]
}

vault_error_summary() {
  local body="${1:-}"
  local summary

  if [[ -z "$body" ]]; then
    echo "No response body returned"
    return 0
  fi

  summary=$(echo "$body" | jq -r 'if .errors then (.errors | join("; ")) else empty end' 2>/dev/null || true)
  if [[ -n "$summary" ]]; then
    echo "$summary"
  else
    echo "Unexpected Vault response: $(vault_response_preview "$body")"
  fi
}

vault_response_preview() {
  local body="${1:-}"
  local preview

  if [[ -z "$body" ]]; then
    echo "empty-body"
    return 0
  fi

  preview=$(printf '%s' "$body" | tr '\r\n\t' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [[ ${#preview} -gt 160 ]]; then
    preview="${preview:0:160}..."
  fi

  echo "$preview"
}

vault_response_shape() {
  local body="${1:-}"
  local shape

  if [[ -z "$body" ]]; then
    echo "empty-body"
    return 0
  fi

  shape=$(echo "$body" | jq -c '{top_level_keys:(keys), has_auth:(has("auth")), auth_keys:(.auth|keys? // []), has_data:(has("data")), has_errors:(has("errors")), warnings:(.warnings // null)}' 2>/dev/null || true)
  if [[ -n "$shape" ]]; then
    echo "$shape"
  else
    echo "non-json-body"
  fi
}

vault_response_is_json() {
  local body="${1:-}"

  if [[ -z "$body" ]]; then
    return 0
  fi

  echo "$body" | jq -e . >/dev/null 2>&1
}

load_bootstrap_config() {
  if ! vault_bootstrap_exists; then
    log "$SCRIPT_NAME" "WARNING" "Vault bootstrap file not found at $VAULT_BOOTSTRAP_FILE"
    return 1
  fi

  # shellcheck source=/dev/null
  source "$VAULT_BOOTSTRAP_FILE"

  VAULT_KV_MOUNT="${VAULT_KV_MOUNT:-vsphere-2-harvester}"
  VAULT_KV_PREFIX="${VAULT_KV_PREFIX:-profiles}"
  VAULT_AUTH_PATH="${VAULT_AUTH_PATH:-auth/approle/login}"
  VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"

  if [[ -z "${VAULT_ADDR:-}" || -z "${VAULT_ROLE_ID:-}" || -z "${VAULT_SECRET_ID:-}" ]]; then
    log "$SCRIPT_NAME" "ERROR" "Vault bootstrap file is present but missing required settings"
    show_error "Vault bootstrap file is missing required settings"
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "Loaded Vault bootstrap from $VAULT_BOOTSTRAP_FILE"
  log "$SCRIPT_NAME" "DEBUG" "Vault bootstrap settings: addr=${VAULT_ADDR}, mount=${VAULT_KV_MOUNT}, prefix=${VAULT_KV_PREFIX}, namespace=${VAULT_NAMESPACE:-none}, skip_verify=${VAULT_SKIP_VERIFY}"

  return 0
}

save_bootstrap_config() {
  cat <<EOF >"$VAULT_BOOTSTRAP_FILE"
VAULT_ADDR="${VAULT_ADDR}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-}"
VAULT_KV_MOUNT="${VAULT_KV_MOUNT}"
VAULT_KV_PREFIX="${VAULT_KV_PREFIX}"
VAULT_AUTH_PATH="${VAULT_AUTH_PATH}"
VAULT_ROLE_ID="${VAULT_ROLE_ID}"
VAULT_SECRET_ID="${VAULT_SECRET_ID}"
VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY}"
VAULT_CACERT="${VAULT_CACERT:-}"
EOF
  chmod 600 "$VAULT_BOOTSTRAP_FILE"
  log "$SCRIPT_NAME" "INFO" "Saved Vault bootstrap to $VAULT_BOOTSTRAP_FILE"
}

vault_api_request() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local response_meta http_code content_type body error_summary response_preview temp_body temp_headers
  local -a curl_args

  log "$SCRIPT_NAME" "DEBUG" "Vault request: method=${method} path=${path}"

  curl_args=(curl -sS -X "$method")
  if [[ "$VAULT_SKIP_VERIFY" == "true" ]]; then
    curl_args+=(-k)
  fi
  if [[ -n "${VAULT_CACERT:-}" ]]; then
    curl_args+=(--cacert "$VAULT_CACERT")
  fi
  if [[ -n "${VAULT_NAMESPACE:-}" ]]; then
    curl_args+=(-H "X-Vault-Namespace: ${VAULT_NAMESPACE}")
  fi
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    curl_args+=(-H "X-Vault-Token: ${VAULT_TOKEN}")
  fi
  curl_args+=(-H 'Accept: application/json')
  if [[ -n "$payload" ]]; then
    curl_args+=(-H 'Content-Type: application/json' --data "$payload")
  fi

  temp_body=$(mktemp "${TMPDIR:-/tmp}/v2h-vault-body-XXXXXX")
  temp_headers=$(mktemp "${TMPDIR:-/tmp}/v2h-vault-headers-XXXXXX")

  if ! response_meta=$("${curl_args[@]}" -D "$temp_headers" -o "$temp_body" "${VAULT_ADDR%/}/v1/${path}" -w "%{http_code}|%{content_type}"); then
    rm -f "$temp_body" "$temp_headers"
    log "$SCRIPT_NAME" "ERROR" "Vault request failed before receiving an HTTP response: method=${method} path=${path}"
    return 1
  fi

  http_code="${response_meta%%|*}"
  content_type="${response_meta#*|}"
  body=$(cat "$temp_body")
  rm -f "$temp_body" "$temp_headers"
  VAULT_LAST_STATUS="$http_code"
  log "$SCRIPT_NAME" "DEBUG" "Vault response: method=${method} path=${path} status=${http_code} content_type=${content_type:-unknown}"

  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    error_summary=$(vault_error_summary "$body")
    log "$SCRIPT_NAME" "ERROR" "Vault request failed: method=${method} path=${path} status=${http_code} error=${error_summary}"
    echo "$body"
    return 1
  fi

  if ! vault_response_is_json "$body"; then
    response_preview=$(vault_response_preview "$body")
    log "$SCRIPT_NAME" "ERROR" "Vault returned a non-JSON response: method=${method} path=${path} status=${http_code} content_type=${content_type:-unknown} preview=${response_preview}"
    log "$SCRIPT_NAME" "ERROR" "Verify VAULT_ADDR points to the Vault API base URL or reverse-proxy prefix so ${VAULT_ADDR%/}/v1/${path} returns JSON"
    echo "$body"
    return 1
  fi

  echo "$body"
}

vault_health_check() {
  local -a curl_args
  local response_meta http_code content_type body response_preview temp_body temp_headers

  curl_args=(curl -sS)
  if [[ "$VAULT_SKIP_VERIFY" == "true" ]]; then
    curl_args+=(-k)
  fi
  if [[ -n "${VAULT_CACERT:-}" ]]; then
    curl_args+=(--cacert "$VAULT_CACERT")
  fi
  curl_args+=(-H 'Accept: application/json')

  log "$SCRIPT_NAME" "INFO" "Checking Vault health at ${VAULT_ADDR}"

  temp_body=$(mktemp "${TMPDIR:-/tmp}/v2h-vault-health-body-XXXXXX")
  temp_headers=$(mktemp "${TMPDIR:-/tmp}/v2h-vault-health-headers-XXXXXX")

  if ! response_meta=$("${curl_args[@]}" -D "$temp_headers" -o "$temp_body" "${VAULT_ADDR%/}/v1/sys/health" -w "%{http_code}|%{content_type}"); then
    rm -f "$temp_body" "$temp_headers"
    log "$SCRIPT_NAME" "ERROR" "Vault health check request failed for ${VAULT_ADDR}"
    return 1
  fi

  http_code="${response_meta%%|*}"
  content_type="${response_meta#*|}"
  body=$(cat "$temp_body")
  rm -f "$temp_body" "$temp_headers"
  log "$SCRIPT_NAME" "DEBUG" "Vault health check status=${http_code} content_type=${content_type:-unknown}"

  if [[ ! "$http_code" =~ ^(200|429|472|473)$ ]]; then
    return 1
  fi

  if ! vault_response_is_json "$body"; then
    response_preview=$(vault_response_preview "$body")
    log "$SCRIPT_NAME" "ERROR" "Vault health endpoint returned a non-JSON response: status=${http_code} content_type=${content_type:-unknown} preview=${response_preview}"
    log "$SCRIPT_NAME" "ERROR" "Set VAULT_ADDR to the Vault API base URL or proxy prefix so ${VAULT_ADDR%/}/v1/sys/health returns JSON"
    return 1
  fi

  return 0
}

vault_authenticate() {
  local payload response token error_summary response_shape

  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    log "$SCRIPT_NAME" "DEBUG" "Reusing existing Vault token in current process"
    return 0
  fi

  log "$SCRIPT_NAME" "INFO" "Authenticating to Vault using AppRole"
  payload=$(jq -cn --arg role_id "$VAULT_ROLE_ID" --arg secret_id "$VAULT_SECRET_ID" '{role_id:$role_id, secret_id:$secret_id}')
  if ! response=$(vault_api_request POST "$VAULT_AUTH_PATH" "$payload"); then
    error_summary=$(vault_error_summary "$response")
    log "$SCRIPT_NAME" "ERROR" "Vault authentication failed at path ${VAULT_AUTH_PATH}: ${error_summary}"
    log "$SCRIPT_NAME" "ERROR" "If /v1/sys/health returns JSON but AppRole login does not, verify the auth mount path and whether a proxy/WAF is intercepting POST ${VAULT_ADDR%/}/v1/${VAULT_AUTH_PATH}"
    show_error "Vault authentication failed"
    return 1
  fi

  token=$(echo "$response" | jq -r '.auth.client_token // empty')
  if [[ -z "$token" ]]; then
    response_shape=$(vault_response_shape "$response")
    log "$SCRIPT_NAME" "ERROR" "Vault auth response shape: ${response_shape}"
    log "$SCRIPT_NAME" "ERROR" "Vault authentication response did not contain a client token"
    show_error "Vault login did not return a client token"
    return 1
  fi

  VAULT_TOKEN="$token"
  export VAULT_TOKEN
  log "$SCRIPT_NAME" "INFO" "Vault authentication succeeded"
  return 0
}

vault_data_path() {
  echo "${VAULT_KV_MOUNT}/data/${VAULT_KV_PREFIX}/$1"
}

vault_metadata_path() {
  echo "${VAULT_KV_MOUNT}/metadata/${VAULT_KV_PREFIX}/$1"
}

vault_kv_get_json() {
  local secret_path="$1"
  local response error_summary

  if ! response=$(vault_api_request GET "$(vault_data_path "$secret_path")"); then
    error_summary=$(vault_error_summary "$response")
    log "$SCRIPT_NAME" "ERROR" "Failed to read Vault secret at ${secret_path}: ${error_summary}"
    return 1
  fi

  echo "$response" | jq -c '.data.data'
}

vault_kv_get_field() {
  local secret_path="$1"
  local field="$2"
  local response

  response=$(vault_kv_get_json "$secret_path") || return 1
  echo "$response" | jq -r --arg field "$field" '.[$field] // empty'
}

vault_kv_put_json() {
  local secret_path="$1"
  local object_json="$2"
  local payload response error_summary

  payload=$(jq -cn --argjson data "$object_json" '{data:$data}')
  if ! response=$(vault_api_request POST "$(vault_data_path "$secret_path")" "$payload"); then
    error_summary=$(vault_error_summary "$response")
    log "$SCRIPT_NAME" "ERROR" "Failed to write Vault secret at ${secret_path}: ${error_summary}"
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "Stored Vault secret at ${secret_path}"
}

vault_kv_delete() {
  local secret_path="$1"
  local response error_summary

  if ! response=$(vault_api_request DELETE "$(vault_data_path "$secret_path")"); then
    error_summary=$(vault_error_summary "$response")
    log "$SCRIPT_NAME" "ERROR" "Failed to delete Vault secret at ${secret_path}: ${error_summary}"
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "Deleted Vault secret at ${secret_path}"
}

vault_kv_list() {
  local prefix="$1"
  local response error_summary

  if ! response=$(vault_api_request GET "$(vault_metadata_path "$prefix")?list=true"); then
    if [[ "${VAULT_LAST_STATUS:-}" == "404" ]]; then
      log "$SCRIPT_NAME" "WARNING" "Vault list path not found: ${prefix}"
      return 0
    fi

    error_summary=$(vault_error_summary "$response")
    log "$SCRIPT_NAME" "ERROR" "Failed to list Vault path ${prefix}: ${error_summary}"
    return 1
  fi

  log "$SCRIPT_NAME" "DEBUG" "Listed Vault path ${prefix}"
  echo "$response" | jq -r '.data.keys[]?'
}

array_contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    if [[ "$item" == "$needle" ]]; then
      return 0
    fi
  done
  return 1
}

load_vault_catalog() {
  local profile_json profile_name

  reset_profile_config
  log "$SCRIPT_NAME" "INFO" "Loading Vault profile catalog"

  mapfile -t VCENTER_PROFILES < <(vault_kv_list "vcenters")
  mapfile -t HARVESTER_PROFILES < <(vault_kv_list "harvesters")
  mapfile -t MIGRATION_PROFILES < <(vault_kv_list "migrations")

  log "$SCRIPT_NAME" "DEBUG" "Vault catalog counts: vcenters=${#VCENTER_PROFILES[@]} harvesters=${#HARVESTER_PROFILES[@]} migrations=${#MIGRATION_PROFILES[@]}"

  for profile_name in "${MIGRATION_PROFILES[@]}"; do
    profile_json=$(vault_kv_get_json "migrations/${profile_name}") || {
      log "$SCRIPT_NAME" "ERROR" "Failed while loading migration profile ${profile_name} from Vault catalog"
      show_error "Failed to load migration profile '$profile_name' from Vault"
      return 1
    }

    MIGRATION_VCENTERS["$profile_name"]=$(echo "$profile_json" | jq -r '.vcenter_profile // empty')
    MIGRATION_HARVESTERS["$profile_name"]=$(echo "$profile_json" | jq -r '.harvester_profile // empty')
    MIGRATION_DATACENTERS["$profile_name"]=$(echo "$profile_json" | jq -r '.datacenter // empty')
    MIGRATION_SRC_NETS["$profile_name"]=$(echo "$profile_json" | jq -r '.src_network // empty')
    MIGRATION_DST_NETS["$profile_name"]=$(echo "$profile_json" | jq -r '.dst_network // empty')
    MIGRATION_NAMESPACES["$profile_name"]=$(echo "$profile_json" | jq -r '.namespace // empty')
    MIGRATION_SOCKETS["$profile_name"]=$(echo "$profile_json" | jq -r '.cpu_sockets // empty')
  done

}

validate_profile_config() {
  local profile

  if [[ ${#MIGRATION_PROFILES[@]} -eq 0 ]]; then
    show_error "No migration profiles found in Vault"
    return 1
  fi

  for profile in "${MIGRATION_PROFILES[@]}"; do
    if [[ -z "${MIGRATION_VCENTERS[$profile]:-}" || -z "${MIGRATION_HARVESTERS[$profile]:-}" ]]; then
      show_error "Migration profile '$profile' is missing required references"
      return 1
    fi

    if ! array_contains "${MIGRATION_VCENTERS[$profile]}" "${VCENTER_PROFILES[@]}"; then
      show_error "Migration profile '$profile' references unknown vCenter profile '${MIGRATION_VCENTERS[$profile]}'"
      return 1
    fi

    if ! array_contains "${MIGRATION_HARVESTERS[$profile]}" "${HARVESTER_PROFILES[@]}"; then
      show_error "Migration profile '$profile' references unknown Harvester profile '${MIGRATION_HARVESTERS[$profile]}'"
      return 1
    fi
  done
}

load_config() {
  check_vault_dependencies
  log "$SCRIPT_NAME" "INFO" "Initializing Vault-backed configuration"

  if ! load_bootstrap_config; then
    return 1
  fi

  if ! vault_health_check; then
    log "$SCRIPT_NAME" "ERROR" "Vault health check failed for ${VAULT_ADDR}"
    show_error "Vault health check failed for ${VAULT_ADDR}"
    return 1
  fi

  vault_authenticate || return 1
  load_vault_catalog || return 1
  validate_profile_config || return 1
  log "$SCRIPT_NAME" "INFO" "Vault-backed configuration loaded successfully"
}

resolve_runtime_context() {
  local migration_profile="${SELECTED_MIGRATION_PROFILE:-}"
  local vcenter_profile harvester_profile
  local vcenter_json harvester_json

  if [[ -z "$migration_profile" ]]; then
    migration_profile="${MIGRATION_PROFILES[0]}"
  fi

  if [[ -z "${MIGRATION_VCENTERS[$migration_profile]:-}" ]]; then
    log "$SCRIPT_NAME" "ERROR" "Requested migration profile ${migration_profile} is not defined in current Vault catalog"
    show_error "Migration profile '$migration_profile' is not defined"
    return 1
  fi

  vcenter_profile="${MIGRATION_VCENTERS[$migration_profile]}"
  harvester_profile="${MIGRATION_HARVESTERS[$migration_profile]}"

  vcenter_json=$(vault_kv_get_json "vcenters/${vcenter_profile}") || {
    log "$SCRIPT_NAME" "ERROR" "Unable to resolve selected vCenter profile ${vcenter_profile}"
    show_error "Failed to load vCenter profile '$vcenter_profile'"
    return 1
  }
  harvester_json=$(vault_kv_get_json "harvesters/${harvester_profile}") || {
    log "$SCRIPT_NAME" "ERROR" "Unable to resolve selected Harvester profile ${harvester_profile}"
    show_error "Failed to load Harvester profile '$harvester_profile'"
    return 1
  }

  SELECTED_MIGRATION_PROFILE="$migration_profile"
  SELECTED_VCENTER_PROFILE="$vcenter_profile"
  SELECTED_HARVESTER_PROFILE="$harvester_profile"

  VSPHERE_ENDPOINT=$(echo "$vcenter_json" | jq -r '.endpoint // empty')
  VSPHERE_DC="${MIGRATION_DATACENTERS[$migration_profile]:-$(echo "$vcenter_json" | jq -r '.datacenter // empty')}"

  HARVESTER_URL=$(echo "$harvester_json" | jq -r '.url // empty')
  HARVESTER_CONTEXT=$(echo "$harvester_json" | jq -r '.context // empty')
  SRC_NET="${MIGRATION_SRC_NETS[$migration_profile]:-$DEFAULT_SRC_NET}"
  DST_NET="${MIGRATION_DST_NETS[$migration_profile]:-$DEFAULT_DST_NET}"
  HARVESTER_NAMESPACE="${MIGRATION_NAMESPACES[$migration_profile]:-$DEFAULT_NAMESPACE}"
  POST_MIGRATE_SOCKETS="${MIGRATION_SOCKETS[$migration_profile]:-${POST_MIGRATE_SOCKETS:-2}}"

  VSPHERE_SECRET_NAME="$(resource_name "vsphere-credentials" "$migration_profile")"
  VMWARE_SOURCE_NAME="$(resource_name "vmwaresource" "$migration_profile")"

  log "$SCRIPT_NAME" "INFO" "Resolved migration profile ${migration_profile}: vcenter=${vcenter_profile} harvester=${harvester_profile} namespace=${HARVESTER_NAMESPACE}"

  export VSPHERE_ENDPOINT VSPHERE_DC HARVESTER_URL HARVESTER_CONTEXT
  export SRC_NET DST_NET HARVESTER_NAMESPACE POST_MIGRATE_SOCKETS
  export SELECTED_MIGRATION_PROFILE SELECTED_VCENTER_PROFILE SELECTED_HARVESTER_PROFILE
  export VSPHERE_SECRET_NAME VMWARE_SOURCE_NAME

  configure_kubectl_access || return 1
}

select_migration_profile() {
  local options=()
  local profile vcenter_profile harvester_profile marker choice
  local default_profile="${SELECTED_MIGRATION_PROFILE:-${MIGRATION_PROFILES[0]:-}}"

  if [[ ${#MIGRATION_PROFILES[@]} -eq 0 ]]; then
    show_error "No migration profiles are available in Vault"
    return 1
  fi

  for profile in "${MIGRATION_PROFILES[@]}"; do
    vcenter_profile="${MIGRATION_VCENTERS[$profile]}"
    harvester_profile="${MIGRATION_HARVESTERS[$profile]}"
    marker=""
    if [[ "$profile" == "$default_profile" ]]; then
      marker=" [default]"
    fi
    options+=("${profile} | vCenter=${vcenter_profile} | Harvester=${harvester_profile}${marker}")
  done

  choice=$(gum choose \
    --header "$(gum style --foreground 212 --bold 'Select Migration Profile')" \
    --height 12 \
    "${options[@]}")

  if [[ $? -eq 130 ]]; then
    USER_ABORTED=1
    return 1
  fi

  SELECTED_MIGRATION_PROFILE="${choice%% |*}"
  resolve_runtime_context
  return 0
}

# --- Helper: Show usage/help ---
show_help() {
  cat <<EOF
$SCRIPT_NAME

Quickly and safely migrate VMware vSphere VMs to Harvester.

Usage:
  $0 [--verbose|-v] [--help|-h]

Options:
  -v, --verbose   Enable verbose (DEBUG) logging
  --skip-config-menu  Reuse the already selected migration profile and runtime overrides
  -h, --help      Show this help message and exit

Vault bootstrap: $VAULT_BOOTSTRAP_FILE
Logs:            $GENERAL_LOG_FILE

Author: Paul Dresch @ FIS-ASP
EOF
}

# --- Parse CLI arguments ---
SKIP_CONFIG_MENU=0
for arg in "$@"; do
  case "$arg" in
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    --skip-config-menu)
      SKIP_CONFIG_MENU=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      ;;
  esac
done

# --- Ensure log directory exists ---
if ! mkdir -p "$LOG_DIR"; then
  echo "[${SCRIPT_NAME}] $(date '+%Y-%m-%d %H:%M:%S') [ERROR]: Failed to create log directory: $LOG_DIR" >&2
  exit 2
fi

# --- Logging function ---
log() {
  local label="$1"
  local level="$2"
  local message="$3"
  local priority
  local timestamp; timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local formatted="[$label] $timestamp [$level]: $message"

  if [[ "$level" == "DEBUG" && "$VERBOSE" -ne 1 ]]; then return; fi

  case "$level" in
    DEBUG)   priority="user.debug" ;;
    INFO)    priority="user.info" ;;
    WARNING) priority="user.warning" ;;
    ERROR)   priority="user.err" ;;
    *)       priority="user.notice" ;;
  esac

  if ! logger -t "$label" -p "$priority" "$message"; then
    echo "[$label] $timestamp [WARNING]: Failed to write to syslog" >> "$GENERAL_LOG_FILE"
  fi

  echo "$formatted" >> "$GENERAL_LOG_FILE"

  if [[ -n "${VM_NAME:-}" ]]; then
    echo "$formatted" >> "$LOG_DIR/${VM_NAME}.log"
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    echo "$formatted" >&2
  fi
}

setup_log_rotation() {
  local logrotate_config="/etc/logrotate.d/vsphere-2-harvester"
  local log_dir="$LOG_DIR"

  log "$SCRIPT_NAME" "DEBUG" "Checking logrotate configuration for $log_dir"

  if [[ ! -f "$logrotate_config" ]]; then
    echo "Setting up logrotate for $log_dir (requires sudo)..."
    sudo tee "$logrotate_config" >/dev/null <<EOF
$log_dir/*.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 root root
    dateext
    maxage 30
}
EOF
    log "$SCRIPT_NAME" "INFO" "Logrotate configuration created at $logrotate_config"
  else
    log "$SCRIPT_NAME" "INFO" "Logrotate configuration already exists at $logrotate_config"
  fi
}

# --- GUM UX Helper Functions ---

check_gum_available() {
  log "$SCRIPT_NAME" "DEBUG" "Checking for gum availability..."
  if ! command -v gum &>/dev/null; then
    echo "ERROR: 'gum' not found. Please install it: brew install gum"
    log "$SCRIPT_NAME" "ERROR" "gum not installed. Exiting."
    exit 1
  fi
  log "$SCRIPT_NAME" "INFO" "gum is available."
}

show_step_header() {
  local step="$1"
  local title="$2"
  gum style --border double --border-foreground 57 --padding "1 2" \
    "$(gum style --foreground 57 --bold "$step: $title")"
}

show_success() {
  local message="$1"
  gum style --foreground 46 "[OK] $message"
  log "$SCRIPT_NAME" "INFO" "$message"
}

show_error() {
  local message="$1"
  gum style --foreground 196 "[ERROR] $message"
  log "$SCRIPT_NAME" "ERROR" "$message"
}

show_info() {
  local message="$1"
  gum style --foreground 33 "[INFO] $message"
  log "$SCRIPT_NAME" "INFO" "$message"
}

show_warning() {
  local message="$1"
  gum style --foreground 226 "[WARNING] $message"
  log "$SCRIPT_NAME" "WARNING" "$message"
}

confirm_action() {
  local prompt="$1"
  if gum confirm --prompt.foreground 212 "$prompt"; then
    return 0
  else
    return 1
  fi
}


is_rfc1123() {
    local name="$1"
    local max_length=63

    # 1. Check if the string is empty
    if [[ -z "$name" ]]; then
        return 1
    fi

    # 2. Check the maximum length
    if [[ ${#name} -gt $max_length ]]; then
        return 1
    fi

    # 3. Regex check for RFC 1123 compliance
    # ^[a-z0-9]        -> Must start with alphanumeric
    # (...)?           -> Makes the rest optional (allows single-char names like "a")
    # [-a-z0-9]* -> Middle part (hyphens allowed)
    # [a-z0-9]$        -> Must end with alphanumeric
    if [[ ! "$name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
        return 1
    fi

    return 0
}

prompt_for_var() {
  local var="$1"
  local prompt="$2"
  local default="$3"
  local secret="${4:-0}"
  local input
  local current="${!var:-}"

  while true; do
    if [[ "$secret" == "1" ]]; then
      input=$(gum input --password --placeholder "$prompt")
    else
      input=$(gum input \
        --placeholder "$prompt" \
        --value "${current}" \
        --width 70)
    fi

    if [[ $? -eq 130 ]]; then
      return 1
    fi

    # Decide candidate (input > current > default)
    local candidate
    if [[ -n "$input" ]]; then
      candidate="$input"
    elif [[ -n "$current" ]]; then
      candidate="$current"
    else
      candidate="$default"
    fi

    # Only validate when setting VM_NAME (Kubernetes RFC 1123 label)
    if [[ "$var" == "VM_NAME" ]]; then
      # IMPORTANT: No normalization; validate exactly what the user entered/chosen.
      if ! is_rfc1123 "$candidate"; then
        gum style --foreground 196 "Invalid Kubernetes name: '$candidate'"
        gum style --foreground 244 "Must comply with RFC 1123 label: lowercase alphanumeric or '-', 1–63 characters, starting and ending with an alphanumeric."
        gum style --foreground 214 "Please rename the VMware VM to a compliant name (-> no fqdn -> e.g. bransible, vm01, ...) before proceeding."
        # Re-prompt
        continue
      fi
    fi

    # Export using original assignment semantics + logging
    if [[ -n "$input" ]]; then
      export "$var"="$input"
      log "$SCRIPT_NAME" "INFO" "$var set to user input"
    elif [[ -n "$current" ]]; then
      export "$var"="$current"
    else
      export "$var"="$default"
    fi

    # Done
    break
  done
}

show_vault_setup_guide() {
  show_step_header "Vault" "Vault Setup Guide"

  cat <<EOF
Before this script can use Vault, prepare Vault with these steps:

1. In the Vault web console, make sure a KV v2 secrets engine exists.
   Navigate to:
     Secrets Engines
   Then either:
     - verify an existing KV v2 mount named '${VAULT_KV_MOUNT:-vsphere-2-harvester}', or
     - enable a new KV v2 engine with that mount path.

2. In the Vault web console, make sure AppRole auth is enabled.
   Navigate to:
     Access -> Auth Methods
   Then either:
     - verify an existing AppRole auth method, or
     - enable AppRole.

3. Create a policy that allows this tool to manage its paths.
   In the web console navigate to:
     Policies
   Create or update a policy with access to these paths.
   You can do this either in the policy editor or in the Vault web CLI.
   Required paths:
     ${VAULT_KV_MOUNT:-vsphere-2-harvester}/data/${VAULT_KV_PREFIX:-profiles}/vcenters/*
     ${VAULT_KV_MOUNT:-vsphere-2-harvester}/data/${VAULT_KV_PREFIX:-profiles}/harvesters/*
     ${VAULT_KV_MOUNT:-vsphere-2-harvester}/data/${VAULT_KV_PREFIX:-profiles}/migrations/*
     ${VAULT_KV_MOUNT:-vsphere-2-harvester}/metadata/${VAULT_KV_PREFIX:-profiles}/*

   Policy example:
     path "${VAULT_KV_MOUNT:-vsphere-2-harvester}/data/${VAULT_KV_PREFIX:-profiles}/*" {
       capabilities = ["create", "read", "update", "delete", "list"]
     }
     path "${VAULT_KV_MOUNT:-vsphere-2-harvester}/metadata/${VAULT_KV_PREFIX:-profiles}/*" {
       capabilities = ["read", "list", "delete"]
     }

   Web CLI example:
     vault policy write vsphere-2-harvester - <<'EOF_POLICY'
     path "${VAULT_KV_MOUNT:-vsphere-2-harvester}/data/${VAULT_KV_PREFIX:-profiles}/*" {
       capabilities = ["create", "read", "update", "delete", "list"]
     }
     path "${VAULT_KV_MOUNT:-vsphere-2-harvester}/metadata/${VAULT_KV_PREFIX:-profiles}/*" {
       capabilities = ["read", "list", "delete"]
     }
     EOF_POLICY

4. Create an AppRole bound to that policy.
   In the web console navigate to:
     Access -> Auth Methods -> AppRole
   Create a role such as:
     vsphere-2-harvester
   Attach the policy you created in the previous step.
   This can also be done in the Vault web CLI:
     vault write auth/approle/role/vsphere-2-harvester token_policies="vsphere-2-harvester"

5. Read the AppRole identifiers for the bootstrap wizard.
   From the AppRole view in the web console, collect:
     - role_id
     - a generated secret_id
   Or use the Vault web CLI:
     vault read auth/approle/role/vsphere-2-harvester/role-id
     vault write -f auth/approle/role/vsphere-2-harvester/secret-id

6. After the connection wizard succeeds, use this script to populate Vault data.
   The wizard stores entries at:
     vcenters/<name>
     harvesters/<name>
     migrations/<name>

Vault URL rule:
  Enter the Vault base URL or reverse-proxy prefix that makes this endpoint return JSON:
    ${VAULT_ADDR:-https://vault.example.com}/v1/sys/health
  Do not paste a web UI path such as /ui/ or /ui/vault.
  If Vault is published behind a proxy path such as /vault, use that prefix in the URL.

Profile field expectations:
  vcenters/<name>
    username, password, endpoint, datacenter

  harvesters/<name>
    url, access_key, secret_key, kubeconfig_b64, context

  migrations/<name>
    vcenter_profile, harvester_profile, datacenter, src_network,
    dst_network, namespace, cpu_sockets

If your Vault administrators prefer the CLI or Terraform, they can create the same mount, policy, and AppRole outside the web console. The script only needs the resulting URL, mount, prefix, role_id, and secret_id.
EOF

  echo
  gum style --foreground 244 "The bootstrap wizard only stores Vault connection data locally in ${VAULT_BOOTSTRAP_FILE}."
}

ensure_vault_session() {
  check_vault_dependencies

  if ! load_bootstrap_config; then
    show_error "Vault bootstrap is not configured. Run 'Show Vault Setup Guide' and then 'Configure Vault Connection'."
    return 1
  fi

  if ! vault_health_check; then
    show_error "Vault health check failed for ${VAULT_ADDR}"
    return 1
  fi

  vault_authenticate
}

configure_vault_connection_wizard() {
  show_step_header "Vault" "Configure Vault Connection"

  show_vault_setup_guide
  echo
  if ! confirm_action "Continue with Vault bootstrap setup?"; then
    return 1
  fi

  prompt_for_var "VAULT_ADDR" "Vault base URL or proxy prefix" "${VAULT_ADDR:-https://vault.example.com}"
  prompt_for_var "VAULT_NAMESPACE" "Vault Namespace (optional)" "${VAULT_NAMESPACE:-}"
  prompt_for_var "VAULT_KV_MOUNT" "Vault KV mount" "${VAULT_KV_MOUNT:-vsphere-2-harvester}"
  prompt_for_var "VAULT_KV_PREFIX" "Vault KV prefix" "${VAULT_KV_PREFIX:-profiles}"
  prompt_for_var "VAULT_AUTH_PATH" "Vault AppRole login path" "${VAULT_AUTH_PATH:-auth/approle/login}"
  prompt_for_var "VAULT_ROLE_ID" "Vault AppRole role_id" "${VAULT_ROLE_ID:-}"
  prompt_for_var "VAULT_SECRET_ID" "Vault AppRole secret_id" "${VAULT_SECRET_ID:-}" 1
  prompt_for_var "VAULT_CACERT" "CA bundle path (optional)" "${VAULT_CACERT:-}"

  if confirm_action "Skip TLS verification for Vault?"; then
    VAULT_SKIP_VERIFY="true"
  else
    VAULT_SKIP_VERIFY="false"
  fi

  save_bootstrap_config

  if ensure_vault_session; then
    show_success "Vault bootstrap saved and validated"
  else
    show_error "Vault bootstrap saved, but connection validation failed"
    return 1
  fi
}

test_vault_connection() {
  show_step_header "Vault" "Test Vault Connection"
  if ensure_vault_session; then
    show_success "Vault connection succeeded"
    return 0
  fi

  return 1
}

select_from_options() {
  local result_var="$1"
  local header="$2"
  shift 2
  local options=("$@")
  local choice

  if [[ ${#options[@]} -eq 0 ]]; then
    return 1
  fi

  choice=$(gum choose --header "$(gum style --foreground 212 --bold "$header")" "${options[@]}")
  if [[ $? -eq 130 ]]; then
    return 1
  fi

  printf -v "$result_var" '%s' "$choice"
  return 0
}

wizard_add_vcenter_profile() {
  local profile_name username password endpoint datacenter payload

  show_step_header "Vault" "Add vCenter Profile"
  ensure_vault_session || return 1

  prompt_for_profile_name profile_name "vCenter profile name"
  prompt_for_var "username" "vCenter username" ""
  prompt_for_var "password" "vCenter password" "" 1
  prompt_for_var "endpoint" "vCenter endpoint" "https://vcenter.example.com/sdk"
  prompt_for_var "datacenter" "Default datacenter" "$DEFAULT_VSPHERE_DC"

  payload=$(jq -cn \
    --arg username "$username" \
    --arg password "$password" \
    --arg endpoint "$endpoint" \
    --arg datacenter "$datacenter" \
    '{username:$username, password:$password, endpoint:$endpoint, datacenter:$datacenter}')

  vault_kv_put_json "vcenters/${profile_name}" "$payload"
  show_success "vCenter profile '$profile_name' stored in Vault"
}

wizard_add_harvester_profile() {
  local profile_name url access_key secret_key kubeconfig_path kubeconfig_b64 context payload

  show_step_header "Vault" "Add Harvester Profile"
  ensure_vault_session || return 1

  prompt_for_profile_name profile_name "Harvester profile name"
  prompt_for_var "url" "Harvester URL" "https://harvester.example.com"
  prompt_for_var "access_key" "Harvester access key" ""
  prompt_for_var "secret_key" "Harvester secret key" "" 1

  while true; do
    prompt_for_var "kubeconfig_path" "Path to kubeconfig file" ""
    if [[ -f "$kubeconfig_path" ]]; then
      break
    fi
    gum style --foreground 196 "File not found: $kubeconfig_path"
  done

  prompt_for_var "context" "kubectl context (optional)" ""
  kubeconfig_b64=$(base64 -w 0 < "$kubeconfig_path")

  payload=$(jq -cn \
    --arg url "$url" \
    --arg access_key "$access_key" \
    --arg secret_key "$secret_key" \
    --arg kubeconfig_b64 "$kubeconfig_b64" \
    --arg context "$context" \
    '{url:$url, access_key:$access_key, secret_key:$secret_key, kubeconfig_b64:$kubeconfig_b64, context:$context}')

  vault_kv_put_json "harvesters/${profile_name}" "$payload"
  show_success "Harvester profile '$profile_name' stored in Vault"
}

wizard_add_migration_profile() {
  local profile_name vcenter_profile harvester_profile datacenter src_network dst_network namespace cpu_sockets payload

  show_step_header "Vault" "Add Migration Profile"
  ensure_vault_session || return 1
  load_vault_catalog || return 1

  if [[ ${#VCENTER_PROFILES[@]} -eq 0 || ${#HARVESTER_PROFILES[@]} -eq 0 ]]; then
    show_error "You need at least one vCenter profile and one Harvester profile in Vault first"
    return 1
  fi

  prompt_for_profile_name profile_name "Migration profile name"
  select_from_options vcenter_profile "Select vCenter Profile" "${VCENTER_PROFILES[@]}" || return 1
  select_from_options harvester_profile "Select Harvester Profile" "${HARVESTER_PROFILES[@]}" || return 1
  prompt_for_var "datacenter" "Datacenter override" "$DEFAULT_VSPHERE_DC"
  prompt_for_var "src_network" "Source network" "$DEFAULT_SRC_NET"
  prompt_for_var "dst_network" "Destination network" "$DEFAULT_DST_NET"
  prompt_for_var "namespace" "Namespace" "$DEFAULT_NAMESPACE"
  prompt_for_var "cpu_sockets" "CPU sockets" "2"

  payload=$(jq -cn \
    --arg vcenter_profile "$vcenter_profile" \
    --arg harvester_profile "$harvester_profile" \
    --arg datacenter "$datacenter" \
    --arg src_network "$src_network" \
    --arg dst_network "$dst_network" \
    --arg namespace "$namespace" \
    --arg cpu_sockets "$cpu_sockets" \
    '{vcenter_profile:$vcenter_profile, harvester_profile:$harvester_profile, datacenter:$datacenter, src_network:$src_network, dst_network:$dst_network, namespace:$namespace, cpu_sockets:$cpu_sockets}')

  vault_kv_put_json "migrations/${profile_name}" "$payload"
  show_success "Migration profile '$profile_name' stored in Vault"
}

wizard_list_profiles() {
  local profile

  show_step_header "Vault" "List Stored Profiles"
  ensure_vault_session || return 1
  load_vault_catalog || return 1

  gum style --foreground 33 "vCenter profiles:"
  for profile in "${VCENTER_PROFILES[@]}"; do
    echo "  - $profile"
  done

  gum style --foreground 33 "Harvester profiles:"
  for profile in "${HARVESTER_PROFILES[@]}"; do
    echo "  - $profile"
  done

  gum style --foreground 33 "Migration profiles:"
  for profile in "${MIGRATION_PROFILES[@]}"; do
    echo "  - $profile -> ${MIGRATION_VCENTERS[$profile]} => ${MIGRATION_HARVESTERS[$profile]}"
  done
}

wizard_remove_profile() {
  local entity_type profile_name
  local -a blockers=()
  local migration_profile

  show_step_header "Vault" "Remove Stored Profile"
  ensure_vault_session || return 1
  load_vault_catalog || return 1

  select_from_options entity_type "What do you want to remove?" "vCenter Profile" "Harvester Profile" "Migration Profile" || return 1

  case "$entity_type" in
    "vCenter Profile")
      select_from_options profile_name "Select vCenter Profile" "${VCENTER_PROFILES[@]}" || return 1
      for migration_profile in "${MIGRATION_PROFILES[@]}"; do
        if [[ "${MIGRATION_VCENTERS[$migration_profile]}" == "$profile_name" ]]; then
          blockers+=("$migration_profile")
        fi
      done
      if [[ ${#blockers[@]} -gt 0 ]]; then
        show_warning "Cannot remove '$profile_name'. Referenced by migration profiles: ${blockers[*]}"
        return 1
      fi
      confirm_action "Remove vCenter profile '$profile_name' from Vault?" || return 1
      vault_kv_delete "vcenters/${profile_name}"
      ;;
    "Harvester Profile")
      select_from_options profile_name "Select Harvester Profile" "${HARVESTER_PROFILES[@]}" || return 1
      for migration_profile in "${MIGRATION_PROFILES[@]}"; do
        if [[ "${MIGRATION_HARVESTERS[$migration_profile]}" == "$profile_name" ]]; then
          blockers+=("$migration_profile")
        fi
      done
      if [[ ${#blockers[@]} -gt 0 ]]; then
        show_warning "Cannot remove '$profile_name'. Referenced by migration profiles: ${blockers[*]}"
        return 1
      fi
      confirm_action "Remove Harvester profile '$profile_name' from Vault?" || return 1
      vault_kv_delete "harvesters/${profile_name}"
      ;;
    "Migration Profile")
      select_from_options profile_name "Select Migration Profile" "${MIGRATION_PROFILES[@]}" || return 1
      confirm_action "Remove migration profile '$profile_name' from Vault?" || return 1
      vault_kv_delete "migrations/${profile_name}"
      ;;
  esac

  show_success "Removed '$profile_name' from Vault"
}

show_main_menu() {
  gum choose \
    --header "$(gum style --foreground 212 --bold 'Select Action')" \
    "Show Vault Setup Guide" \
    "Configure Vault Connection" \
    "Test Vault Connection" \
    "Add vCenter Profile" \
    "Add Harvester Profile" \
    "Add Migration Profile" \
    "List Stored Profiles" \
    "Remove Stored Profile" \
    "Run Migration" \
    "Exit"
}


# --- Refactored: adjust_config_menu using gum ---
adjust_config_menu() {
  USER_ABORTED=0

  if ! select_migration_profile; then
    return 1
  fi

  while true; do
    local choice
    choice=$(gum choose \
      --header "$(gum style --foreground 212 --bold 'Migration Configuration')" \
      --height 16 \
      "1) Migration Profile: ${SELECTED_MIGRATION_PROFILE:-(not set)}" \
      "2) vCenter Profile: ${SELECTED_VCENTER_PROFILE:-(not set)}" \
      "3) Harvester Profile: ${SELECTED_HARVESTER_PROFILE:-(not set)}" \
      "4) vSphere Datacenter: ${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}" \
      "5) Source Network: ${SRC_NET:-$DEFAULT_SRC_NET}" \
      "6) Destination Network: ${DST_NET:-$DEFAULT_DST_NET}" \
      "7) Namespace: ${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}" \
      "8) VM Name: ${VM_NAME:-(not set)}" \
      "9) VM Folder: ${VM_FOLDER:-(optional)}" \
      "10) CPU Sockets: ${POST_MIGRATE_SOCKETS:-2}" \
      "$(gum style --foreground 46 '[Continue]')" \
      "$(gum style --foreground 196 '[Cancel]')")

    if [[ $? -eq 130 ]]; then
      USER_ABORTED=1
      break
    fi

    case "$choice" in
      *"[Continue]"*) break ;;
      *"[Cancel]"*) USER_ABORTED=1; break ;;
      "1)"*) select_migration_profile || break ;;
      "4)"*) prompt_for_var "VSPHERE_DC" "Datacenter" "${VSPHERE_DC:-$DEFAULT_VSPHERE_DC}" ;;
      "5)"*) prompt_for_var "SRC_NET" "Source Network" "${SRC_NET:-$DEFAULT_SRC_NET}" ;;
      "6)"*) prompt_for_var "DST_NET" "Destination Network" "${DST_NET:-$DEFAULT_DST_NET}" ;;
      "7)"*) prompt_for_var "HARVESTER_NAMESPACE" "Namespace" "${HARVESTER_NAMESPACE:-$DEFAULT_NAMESPACE}" ;;
      "8)"*) prompt_for_var "VM_NAME" "VM Name" "${VM_NAME:-}" ;;
      "9)"*) prompt_for_var "VM_FOLDER" "VM Folder (optional)" "${VM_FOLDER:-}" ;;
      "10)"*) prompt_for_var "POST_MIGRATE_SOCKETS" "Socket Count" "${POST_MIGRATE_SOCKETS:-2}" ;;
    esac
  done
}

save_config() {
  return 0
}

# --- tmux session management ---
check_tmux_available() {
  log "$SCRIPT_NAME" "DEBUG" "Checking for tmux availability..."
  if ! command -v tmux &>/dev/null; then
    log "$SCRIPT_NAME" "WARNING" "tmux not installed, running inline."
    return 1
  fi
  log "$SCRIPT_NAME" "INFO" "tmux is available."
  return 0
}

run_in_tmux_session() {
  local safe_vm_name="${VM_NAME//./_}"
  local session_name="${TMUX_SESSION_PREFIX}-${safe_vm_name}"
  local detach_mode="${1:-false}"
  local kubectl_completion_cmd="source <(kubectl completion bash) 2>/dev/null || true"

  if [[ -n "${TMUX:-}" ]]; then
    log "$SCRIPT_NAME" "INFO" "Already running in tmux session. Running migration inline."
    return 1
  fi

  if ! check_tmux_available; then
    return 1
  fi

  if tmux has-session -t "$session_name" 2>/dev/null; then
    log "$SCRIPT_NAME" "INFO" "Killing existing tmux session: $session_name"
    tmux kill-session -t "$session_name"
  fi

  log "$SCRIPT_NAME" "INFO" "Creating tmux session: $session_name"
  tmux new-session -d -s "$session_name" -x 200 -y 50 -c "$(pwd)" \
    bash --noprofile --norc -i -c "
      source /etc/bashrc 2>/dev/null || true
      export SELECTED_MIGRATION_PROFILE=\"${SELECTED_MIGRATION_PROFILE:-}\"
      export VM_NAME=\"${VM_NAME:-}\"
      export VM_FOLDER=\"${VM_FOLDER:-}\"
      export VSPHERE_DC=\"${VSPHERE_DC:-}\"
      export SRC_NET=\"${SRC_NET:-}\"
      export DST_NET=\"${DST_NET:-}\"
      export HARVESTER_NAMESPACE=\"${HARVESTER_NAMESPACE:-}\"
      export POST_MIGRATE_SOCKETS=\"${POST_MIGRATE_SOCKETS:-}\"
      ${kubectl_completion_cmd}
      exec '$0' --verbose --skip-config-menu
    "

  if [[ "$detach_mode" == "true" ]]; then
    show_info "Migration started in tmux session: $session_name (detached)"
    echo "View session: tmux attach-session -t $session_name"
    log "$SCRIPT_NAME" "INFO" "Migration running detached in tmux session: $session_name"
    return 0
  else
    show_info "Migration starting in tmux session: $session_name (attaching)..."
    sleep 2
    tmux attach-session -t "$session_name"
    return 0
  fi
}

# --- Shared VM Action Helper Functions ---

send_harvester_vm_action() {
  local action="$1"
  local vm_name="$2"
  local namespace="${3:-$HARVESTER_NAMESPACE}"
  local base_url="${HARVESTER_URL%/}/v1/harvester/kubevirt.io.virtualmachines/${namespace}/${vm_name}"
  local url="${base_url}?action=${action}"
  local response http_code curl_error access_key secret_key

  access_key=$(vault_kv_get_field "harvesters/${SELECTED_HARVESTER_PROFILE}" "access_key") || return 1
  secret_key=$(vault_kv_get_field "harvesters/${SELECTED_HARVESTER_PROFILE}" "secret_key") || return 1

  log "$SCRIPT_NAME" "INFO" "Attempting VM action '$action' for '$vm_name'."
  log "$SCRIPT_NAME" "DEBUG" "API URL: $url"

  sleep 2

  response=$(curl -sSL -w "\n%{http_code}" -u "${access_key}:${secret_key}" \
    -X POST \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    "$url" 2>&1)
  curl_error=$?
  http_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | sed '$d')

  log "$SCRIPT_NAME" "DEBUG" "HTTP status code: $http_code"
  log "$SCRIPT_NAME" "DEBUG" "Raw API response: $response"

  if [[ $curl_error -ne 0 ]]; then
    log "$SCRIPT_NAME" "ERROR" "curl command failed with exit code $curl_error: $response"
    return 2
  fi

  if [[ "$http_code" -ge 400 ]]; then
    log "$SCRIPT_NAME" "ERROR" "API call '$action' returned HTTP $http_code. Response: $response"
    return 3
  fi

  if echo "$response" | grep -q '"type":"error"'; then
    log "$SCRIPT_NAME" "ERROR" "API action '$action' failed for VM '$vm_name'. API error: $response"
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "API action '$action' triggered for VM '$vm_name' (HTTP $http_code)."
  return 0
}

wait_for_vm_status() {
  local desired_status="$1"
  local vm_name="$2"
  local namespace="${3:-$HARVESTER_NAMESPACE}"
  local timeout="${4:-60}"

  if ! gum spin --spinner dot --title "Waiting for VM to enter $desired_status state..." -- \
      bash -c "
        for ((i=0; i<$timeout; i+=2)); do
          current_status=\$(run_kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo 'Unknown')
          if [[ \"\$current_status\" == \"$desired_status\" ]]; then
            exit 0
          fi
          sleep 2
        done
        exit 1
      "; then
    log "$SCRIPT_NAME" "ERROR" "Timeout waiting for VM status '$desired_status'."
    return 1
  fi

  log "$SCRIPT_NAME" "INFO" "VM status is now '$desired_status'."
  show_success "VM is now in $desired_status state"
  return 0
}

# --- Technical Functions ---

check_prerequisites() {
  show_step_header "Step 1" "Prerequisite Check"

  if ! gum spin --spinner dot --title "Checking kubectl..." -- \
      bash -c "command -v kubectl &>/dev/null"; then
    show_error "kubectl not found. Please install and configure it."
    log "$SCRIPT_NAME" "ERROR" "kubectl not found. Exiting."
    exit 10
  fi

  if ! command_exists base64; then
    show_error "base64 not found. Please install it."
    exit 12
  fi

  show_success "kubectl is available and configured"
  log "$SCRIPT_NAME" "INFO" "kubectl found: $(command -v kubectl)"
  log "$SCRIPT_NAME" "DEBUG" "kubectl version: $(run_kubectl version --client 2>&1)"
}

create_vsphere_secret() {
  local vsphere_user vsphere_pass

  show_step_header "Step 2" "Create vSphere Secret"

  vsphere_user=$(vault_kv_get_field "vcenters/${SELECTED_VCENTER_PROFILE}" "username") || return 1
  vsphere_pass=$(vault_kv_get_field "vcenters/${SELECTED_VCENTER_PROFILE}" "password") || return 1

  gum spin --spinner dot --title "Creating vSphere credentials secret..." -- \
    bash -c "
      if ! run_kubectl get secret '$VSPHERE_SECRET_NAME' -n '$HARVESTER_NAMESPACE' &>/dev/null; then
        run_kubectl create secret generic '$VSPHERE_SECRET_NAME' \
          --from-literal=username='$vsphere_user' \
          --from-literal=password='$vsphere_pass' \
          -n '$HARVESTER_NAMESPACE' 2>&1
        echo 'Secret created'
      else
        echo 'Secret already exists'
      fi
    " || true

  show_success "vSphere secret ready"
}

create_vmware_source() {
  show_step_header "Step 3" "Create VmwareSource"

  gum spin --spinner dot --title "Setting up VmwareSource resource..." -- \
    bash -c "
      run_kubectl apply -f - <<'EOFVMWARE'
apiVersion: migration.harvesterhci.io/v1beta1
kind: VmwareSource
metadata:
  name: $VMWARE_SOURCE_NAME
  namespace: $HARVESTER_NAMESPACE
spec:
  endpoint: \"$VSPHERE_ENDPOINT\"
  dc: \"$VSPHERE_DC\"
  credentials:
    name: $VSPHERE_SECRET_NAME
    namespace: $HARVESTER_NAMESPACE
EOFVMWARE
    " || true

  show_success "VmwareSource created"
  log "$SCRIPT_NAME" "INFO" "VmwareSource '$VMWARE_SOURCE_NAME' created."
}

wait_for_vmware_source_ready() {
  show_step_header "Step 4" "Wait for VmwareSource Ready"

  if gum spin --spinner dot --title "Waiting for VmwareSource to be ready..." -- \
    bash -c "
      for i in {1..20}; do
        STATUS=\$(run_kubectl get vmwaresource.migration '$VMWARE_SOURCE_NAME' -n '$HARVESTER_NAMESPACE' -o jsonpath='{.status.status}' 2>/dev/null || echo 'notfound')
        if [[ \"\$STATUS\" == \"clusterReady\" ]]; then
          exit 0
        fi
        sleep 5
      done
      exit 1
    " 2>&1; then
    show_success "VmwareSource is ready"
    log "$SCRIPT_NAME" "INFO" "VmwareSource is ready."
  else
    show_error "VmwareSource did not become ready"
    run_kubectl get vmwaresource.migration "$VMWARE_SOURCE_NAME" -n "$HARVESTER_NAMESPACE" -o yaml | tee -a "$GENERAL_LOG_FILE"
    log "$SCRIPT_NAME" "ERROR" "VmwareSource did not become ready."
    exit 20
  fi
}

create_virtual_machine_import() {
  show_step_header "Step 5" "Create VirtualMachineImport"

  gum spin --spinner dot --title "Creating VirtualMachineImport for $VM_NAME..." -- \
    bash -c "
      if ! run_kubectl get virtualmachineimport.migration '$VM_NAME' -n '$HARVESTER_NAMESPACE' &>/dev/null; then
        run_kubectl apply -f - <<'EOFVMI'
apiVersion: migration.harvesterhci.io/v1beta1
kind: VirtualMachineImport
metadata:
  name: $VM_NAME
  namespace: $HARVESTER_NAMESPACE
spec:
  virtualMachineName: \"$VM_NAME\"
  $( [[ -n "$VM_FOLDER" ]] && echo "folder: \"$VM_FOLDER\"" )
  networkMapping:
    - sourceNetwork: \"$SRC_NET\"
      destinationNetwork: \"$DST_NET\"
  sourceCluster:
    name: $VMWARE_SOURCE_NAME
    namespace: $HARVESTER_NAMESPACE
    kind: VmwareSource
    apiVersion: migration.harvesterhci.io/v1beta1
EOFVMI
      fi
    " || true

  show_success "VirtualMachineImport created"
  log "$SCRIPT_NAME" "INFO" "VirtualMachineImport '$VM_NAME' created."
}

switch_vm_disks_to_virtio() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"

  show_step_header "Step 6a" "Adjust VM Disks"

  gum spin --spinner dot --title "Adjusting disk configuration for $vm_name..." -- \
    bash -c "
      disk_names=(\$(run_kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.spec.template.spec.domain.devices.disks[*].name}' 2>/dev/null || true))
      disk_count=\${#disk_names[@]}

      if [[ \$disk_count -eq 0 ]]; then
        exit 0
      fi

      for ((i=0; i<disk_count; i++)); do
        current_bus=\$(run_kubectl get vm '$vm_name' -n '$namespace' -o jsonpath=\"{.spec.template.spec.domain.devices.disks[\$i].disk.bus}\" 2>/dev/null || echo '')
        if [[ \"\$current_bus\" != \"virtio\" && -n \"\$current_bus\" ]]; then
          run_kubectl patch vm '$vm_name' -n '$namespace' --type='json' \
            -p=\"[{'op': 'replace', 'path': '/spec/template/spec/domain/devices/disks/\$i/disk/bus', 'value':'virtio'}]\" || true
        fi
      done
    " || true

  show_success "Disk configuration updated"
  log "$SCRIPT_NAME" "INFO" "Ensured all disks for VM '$vm_name' use bus: virtio"
}

ensure_vm_stopped() {
  local vm_name="$1"
  local namespace="$2"
  local status

  status=$(run_kubectl get vm "$vm_name" -n "$namespace" -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "NotFound")

  if [[ "$status" == "Running" ]]; then
    log "$SCRIPT_NAME" "INFO" "VM is running. Attempting to stop it."
    show_info "VM is running. Stopping it gracefully..."

    if ! send_harvester_vm_action "stop" "$vm_name" "$namespace"; then
      show_error "Failed to send stop command."
      return 1
    fi

    if ! wait_for_vm_status "Stopped" "$vm_name" "$namespace"; then
      show_warning "Graceful stop failed or timed out. Attempting forceStop..."
      log "$SCRIPT_NAME" "WARNING" "Graceful stop failed. Trying forceStop."

      if ! send_harvester_vm_action "forceStop" "$vm_name" "$namespace" || \
         ! wait_for_vm_status "Stopped" "$vm_name" "$namespace"; then
        show_error "Failed to stop VM even with forceStop."
        return 1
      fi
    fi
    return 0
  elif [[ "$status" == "Stopped" ]]; then
    log "$SCRIPT_NAME" "INFO" "VM '$vm_name' is already stopped."
    show_info "VM is already stopped."
    return 0
  else
    log "$SCRIPT_NAME" "WARNING" "VM status is '$status'."
    show_warning "VM status is '$status'. Proceeding with caution."
    return 0
  fi
}

adjust_vm_cpu_topology() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"
  local desired_sockets="${3:-}"

  if [[ -z "$desired_sockets" || ! "$desired_sockets" =~ ^[0-9]+$ || "$desired_sockets" -le 0 ]]; then
    log "$SCRIPT_NAME" "INFO" "POST_MIGRATE_SOCKETS not set or invalid. Skipping CPU topology adjustment."
    return 0
  fi

  show_step_header "Step 6b" "Adjust VM CPU Topology"

  if ! ensure_vm_stopped "$vm_name" "$namespace"; then
    return 1
  fi

  gum spin --spinner dot --title "Adjusting CPU topology to $desired_sockets sockets and setting eviction strategy..." -- \
    bash -c "
      current_sockets=\$(run_kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.spec.template.spec.domain.cpu.sockets}')
      current_cores=\$(run_kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.spec.template.spec.domain.cpu.cores}')
      total_vcpus=\$((current_sockets * current_cores))

      if (( total_vcpus % $desired_sockets != 0 )); then
        exit 1
      fi

      new_cores=\$((total_vcpus / $desired_sockets))

      run_kubectl patch vm '$vm_name' -n '$namespace' --type='json' \
        -p=\"[
          {'op': 'replace', 'path': '/spec/template/spec/domain/cpu/sockets', 'value':$desired_sockets},
          {'op': 'replace', 'path': '/spec/template/spec/domain/cpu/cores', 'value':\$new_cores},
          {'op': 'add', 'path': '/spec/template/spec/evictionStrategy', 'value':'LiveMigrateIfPossible'}
        ]\"
    " || {
    show_error "Failed to adjust CPU topology and eviction strategy."
    log "$SCRIPT_NAME" "ERROR" "Failed to patch VM '$vm_name' with new CPU topology and eviction strategy."
    return 1
  }

  show_success "CPU topology and eviction strategy updated"
  log "$SCRIPT_NAME" "INFO" "Successfully patched VM '$vm_name' CPU topology and eviction strategy."
}

start_vm_via_api() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"

  show_step_header "Step 7" "Starting VM Post-Configuration"

  gum spin --spinner dot --title "Checking for restart requirements..." -- \
    bash -c "
      if run_kubectl get vm '$vm_name' -n '$namespace' -o jsonpath='{.status.conditions[?(@.type==\"RestartRequired\")].status}' | grep -q 'True'; then
        run_kubectl delete vmi '$vm_name' -n '$namespace' --ignore-not-found || true
      fi
    " || true

  if ! send_harvester_vm_action "start" "$vm_name" "$namespace"; then
    show_error "Failed to send start command for VM '$vm_name'."
    log "$SCRIPT_NAME" "ERROR" "Failed to send start command for VM '$vm_name'."
    return 1
  fi

  if wait_for_vm_status "Running" "$vm_name" "$namespace" 300; then
    show_success "VM started successfully and is now Running"
    log "$SCRIPT_NAME" "INFO" "VM '$vm_name' started successfully."
    return 0
  else
    show_error "VM did not reach 'Running' state after start command"
    log "$SCRIPT_NAME" "ERROR" "VM '$vm_name' did not reach 'Running' state."
    return 1
  fi
}

cleanup_virtual_machine_import() {
  local vm_name="$1"
  local namespace="${2:-$HARVESTER_NAMESPACE}"

  show_step_header "Step 8" "Cleaning up VirtualMachineImport"

  gum spin --spinner dot --title "Removing VirtualMachineImport resource..." -- \
    bash -c "
      if run_kubectl get virtualmachineimport.migration '$vm_name' -n '$namespace' &>/dev/null; then
        run_kubectl delete virtualmachineimport.migration '$vm_name' -n '$namespace' --ignore-not-found || true
      fi
    " || true

  show_success "VirtualMachineImport resource cleaned up"
  log "$SCRIPT_NAME" "INFO" "Cleanup completed for VM '$vm_name'."
}

run_migration_workflow() {
  check_prerequisites
  create_vsphere_secret
  create_vmware_source
  wait_for_vmware_source_ready
  create_virtual_machine_import

  echo

  show_step_header "Step 5" "Monitor Import Status"
  import_monitor_status "$VM_NAME" "$HARVESTER_NAMESPACE"

  echo

  switch_vm_disks_to_virtio "$VM_NAME" "$HARVESTER_NAMESPACE"
  adjust_vm_cpu_topology "$VM_NAME" "$HARVESTER_NAMESPACE" "$POST_MIGRATE_SOCKETS"

  echo

  gum spin --spinner dot --title "Waiting 60 seconds before VM startup..." -- sleep 60

  echo

  start_vm_via_api "$VM_NAME" "$HARVESTER_NAMESPACE"
  cleanup_virtual_machine_import "$VM_NAME" "$HARVESTER_NAMESPACE"

  echo

  gum style --border double --border-foreground 46 --padding "1 2" \
    "$(gum style --foreground 46 --bold 'Migration Complete')" \
    "" \
    "VM '$VM_NAME' has been migrated to Harvester." \
    "" \
    "$(gum style --foreground 226 'IMPORTANT - Next Steps:')" \
    "  1. Verify the VM is running in Harvester" \
    "  2. Test VM connectivity and services" \
    "  3. Clean up/decommission the VM in vSphere"
}

# Helper to pause before exit
pause_before_exit() {
  local duration="${1:-60}"
  echo
  gum style --border rounded --border-foreground 240 --padding "1 2" \
    "$(gum style --foreground 240 "Session will close in $duration seconds")" \
    "Press any key to exit now, or wait..."
  
  read -t "$duration" -n 1 -r || true
  
  if [[ $? -eq 0 ]]; then
    gum style --foreground 46 "Exiting..."
  else
    gum style --foreground 33 "Auto-closing session..."
  fi
}

# --- Main Workflow ---

main() {
  local action

  log "$SCRIPT_NAME" "INFO" "Starting vSphere-to-Harvester Migration Tool"

  setup_log_rotation
  check_gum_available

  gum style --border double --border-foreground 212 --padding "1 2" \
    "$(gum style --foreground 212 --bold 'vSphere -> Harvester Migration')" \
    "$(gum style --foreground 240 'Quickly and safely migrate VMs')"

  echo

  if [[ "$SKIP_CONFIG_MENU" -eq 1 ]]; then
    ensure_vault_session || exit 1
    load_vault_catalog || exit 1
    resolve_runtime_context || exit 1
    show_info "Vault configuration loaded for migration profile '$SELECTED_MIGRATION_PROFILE'"
    echo
    run_migration_workflow
    log "$SCRIPT_NAME" "INFO" "Migration process completed for VM: $VM_NAME"
    return 0
  fi

  while true; do
    action=$(show_main_menu)
    if [[ $? -eq 130 ]]; then
      exit 0
    fi

    case "$action" in
      "Show Vault Setup Guide")
        show_vault_setup_guide
        ;;
      "Configure Vault Connection")
        configure_vault_connection_wizard
        ;;
      "Test Vault Connection")
        test_vault_connection
        ;;
      "Add vCenter Profile")
        wizard_add_vcenter_profile
        ;;
      "Add Harvester Profile")
        wizard_add_harvester_profile
        ;;
      "Add Migration Profile")
        wizard_add_migration_profile
        ;;
      "List Stored Profiles")
        wizard_list_profiles
        ;;
      "Remove Stored Profile")
        wizard_remove_profile
        ;;
      "Run Migration")
        ensure_vault_session || continue
        load_vault_catalog || continue
        adjust_config_menu
        if [[ "${USER_ABORTED:-0}" -eq 1 ]]; then
          show_warning "Migration cancelled"
          continue
        fi

        echo

        if [[ -z "${TMUX:-}" ]]; then
          run_in_tmux_session "false"
          exit $?
        fi

        run_migration_workflow
        return 0
        ;;
      "Exit")
        exit 0
        ;;
    esac

    echo
  done
}

main "$@"
