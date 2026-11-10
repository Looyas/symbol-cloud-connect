#!/usr/bin/env bash
# Symbol Cloud Connect for Azure - guided setup (CLOUD-SETUP-CONTRACT-V2 §6.5-§6.6, azure-v1).
#
# Run from Azure Cloud Shell, signed in as an administrator of the subscription (see
# PERMISSIONS.md). Symbol shows the exact command; it clones this repository at a pinned
# tag and commit, then runs:
#
#   azure/symbol-setup.sh --org <org> --session <uuid> --template azure-vX.Y.Z \
#     --modules signin,finops,monitoring,security [--subscription <guid>] \
#     [--location westeurope] [--existing-export <account>/<rg>/<container>/<dir>/<name>] \
#     [--existing-eventhub <namespace>/<rg>/<hub>] \
#     [--rotate finops|observability] [--yes]
#
#   azure/symbol-setup.sh --destroy --org <org> [--subscription <guid>] [--yes]
#
# Steps: 1 environment, 2 subscription and directory, 3 the directory's app-registration
# policy, 4 resource providers, 5 state storage + init, 6 plan / confirm / apply,
# 7 the connection code. The code is SECRET: it carries the client secret of each
# application Symbol will sign in as. It is printed once, for Symbol, and never written
# to a file by this script.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TF_DIR="${SCRIPT_DIR}"

readonly TERRAFORM_MIN="1.5.0"
readonly STATE_RESOURCE_GROUP="symbol-cloud-connect-state"
readonly STATE_CONTAINER="tfstate"

# Resource providers every module needs registered. Registering one already registered
# changes nothing.
readonly REQUIRED_PROVIDERS=(
  "Microsoft.CostManagement"
  "Microsoft.EventHub"
  "Microsoft.Insights"
  "Microsoft.Storage"
)

ORG=""
SESSION=""
TEMPLATE=""
MODULES=""
SUBSCRIPTION=""
LOCATION="westeurope"
ROTATE=""
DESTROY="false"
ASSUME_YES="false"
EXISTING_EXPORT=""
EXISTING_EVENTHUB=""
SECRET_MONTHS="12"

TENANT=""
OWNER_OID=""
STATE_ACCOUNT=""
VAR_FILE=""
TF="terraform"

# ---------------------------------------------------------------------------
# Output and failure
# ---------------------------------------------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  # The var file carries no secret (every secret is generated in Azure and read back
  # through the state), but it names the organisation and session: not left behind.
  [[ -n "${VAR_FILE}" && -f "${VAR_FILE}" ]] && rm -f "${VAR_FILE}"
  return 0
}
trap cleanup EXIT

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_match() { # value regex what
  [[ "$1" =~ $2 ]] || die "$3"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required and was not found. Run this from Azure Cloud Shell, where it is installed."
}

confirm() { # prompt -> 0 when the user typed y/yes
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  local reply=""
  printf '%s [y/N] ' "$1" >&2
  read -r reply || true
  [[ "${reply}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

need_value() { # flag remaining-args-count
  [[ "$2" -ge 2 ]] || die "$1 needs a value."
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org) need_value "$1" "$#"; ORG="$2"; shift 2 ;;
      --session) need_value "$1" "$#"; SESSION="$2"; shift 2 ;;
      --template) need_value "$1" "$#"; TEMPLATE="$2"; shift 2 ;;
      --modules) need_value "$1" "$#"; MODULES="$2"; shift 2 ;;
      --subscription) need_value "$1" "$#"; SUBSCRIPTION="$2"; shift 2 ;;
      --location) need_value "$1" "$#"; LOCATION="$2"; shift 2 ;;
      --existing-export) need_value "$1" "$#"; EXISTING_EXPORT="$2"; shift 2 ;;
      --existing-eventhub) need_value "$1" "$#"; EXISTING_EVENTHUB="$2"; shift 2 ;;
      --secret-months) need_value "$1" "$#"; SECRET_MONTHS="$2"; shift 2 ;;
      --rotate) need_value "$1" "$#"; ROTATE="$2"; shift 2 ;;
      --destroy) DESTROY="true"; shift ;;
      --yes) ASSUME_YES="true"; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  require_match "${ORG}" '^[A-Za-z0-9_-]{1,44}$' \
    "--org must be 1-44 characters of letters, digits, '_' and '-'."

  if [[ "${DESTROY}" == "true" ]]; then
    return 0
  fi

  require_match "${SESSION}" '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
    "--session must be the setup session UUID Symbol gave you."
  require_match "${TEMPLATE}" '^azure-v[0-9]+\.[0-9]+\.[0-9]+$' \
    "--template must be 'azure-vX.Y.Z'."
  require_match "${MODULES}" '^[a-z,]{1,64}$' \
    "--modules must be a comma-separated list."
  require_match "${LOCATION}" '^[a-z0-9]{3,40}$' \
    "--location must be an Azure region name such as 'westeurope'."
  require_match "${SECRET_MONTHS}" '^([1-9]|1[0-9]|2[0-4])$' \
    "--secret-months must be between 1 and 24."

  local module
  for module in ${MODULES//,/ }; do
    case "${module}" in
      signin | finops | monitoring | security) ;;
      *) die "Unknown module '${module}'. Known: signin, finops, monitoring, security." ;;
    esac
  done

  case "${ROTATE}" in
    "") ;;
    finops)
      has_module finops || die "--rotate finops needs the finops module." ;;
    observability)
      has_module monitoring || has_module security \
        || die "--rotate observability needs the monitoring or security module." ;;
    *) die "--rotate must be finops or observability." ;;
  esac
}

has_module() { [[ ",${MODULES}," == *",$1,"* ]]; }
needs_finops() { has_module finops; }
needs_observability() { has_module monitoring || has_module security; }

# ---------------------------------------------------------------------------
# Step 1: the environment
# ---------------------------------------------------------------------------

version_ge() { # a b -> a >= b
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

check_environment() {
  require_cmd az
  require_cmd python3
  require_cmd terraform

  local version
  version="$(terraform version -json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || true)"
  [[ -n "${version}" ]] || die "Could not read the Terraform version. Run this from Azure Cloud Shell."
  version_ge "${version}" "${TERRAFORM_MIN}" \
    || die "Terraform ${version} is older than ${TERRAFORM_MIN}. Azure Cloud Shell ships a newer one; run this there."
  info "Terraform ${version}"
}

# ---------------------------------------------------------------------------
# Step 2: the subscription and the directory
# ---------------------------------------------------------------------------

resolve_account() {
  local account
  account="$(az account show -o json 2>/dev/null || true)"
  [[ -n "${account}" ]] || die "Not signed in to Azure. Run 'az login' (Cloud Shell does it for you) and try again."

  if [[ -n "${SUBSCRIPTION}" ]]; then
    require_match "${SUBSCRIPTION}" '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' \
      "--subscription must be a subscription id (a GUID)."
    az account set --subscription "${SUBSCRIPTION}" 2>/dev/null \
      || die "Could not select subscription ${SUBSCRIPTION}. Check that you have access to it."
    account="$(az account show -o json)"
  fi

  SUBSCRIPTION="$(printf '%s' "${account}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  TENANT="$(printf '%s' "${account}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tenantId"])')"

  OWNER_OID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  [[ -n "${OWNER_OID}" ]] \
    || die "Could not read your own directory object. The setup needs to make you the owner of the applications it creates, so that you can manage them afterwards."

  info "Subscription ${SUBSCRIPTION}"
  note "Directory (tenant): ${TENANT}"
}

# ---------------------------------------------------------------------------
# Step 3: may this account register an application?
#
# The Entra analogue of GCP's service-account key policy. Checked BEFORE anything is
# created, because the failure otherwise lands halfway through an apply with a Graph
# error that does not say what to do about it.
# ---------------------------------------------------------------------------

check_app_registration_allowed() {
  local allowed=""
  allowed="$(az rest --method GET \
    --url 'https://graph.microsoft.com/v1.0/policies/authorizationPolicy' \
    --query 'defaultUserRolePermissions.allowedToCreateApps' -o tsv 2>/dev/null || true)"

  if [[ "${allowed}" == "false" ]]; then
    # Being refused by the tenant setting is not final: a directory role grants it.
    local roles=""
    roles="$(az rest --method GET \
      --url "https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole?\$select=displayName" \
      --query 'value[].displayName' -o tsv 2>/dev/null || true)"
    if ! printf '%s' "${roles}" | grep -qiE 'Application Administrator|Cloud Application Administrator|Application Developer|Global Administrator'; then
      die "This directory does not let ordinary users register applications (authorizationPolicy.allowedToCreateApps = false), and you do not hold a role that overrides it.

Ask a directory administrator to either:
  * grant you the 'Application Developer' role in Microsoft Entra ID, or
  * run this setup themselves.

Symbol's automatic setup creates two applications in YOUR directory -- 'Symbol Finops' and 'Symbol Observability' -- each read-only and owned by you."
    fi
    note "Users cannot register applications in this directory, but your directory role allows it."
  fi
  info "Application registration is permitted for this account"
}

# ---------------------------------------------------------------------------
# Step 4: resource providers
# ---------------------------------------------------------------------------

register_providers() {
  local namespace state
  for namespace in "${REQUIRED_PROVIDERS[@]}"; do
    state="$(az provider show --namespace "${namespace}" --query registrationState -o tsv 2>/dev/null || true)"
    if [[ "${state}" != "Registered" ]]; then
      info "Registering resource provider ${namespace}"
      az provider register --namespace "${namespace}" --wait 2>/dev/null \
        || die "Could not register ${namespace}. You need Contributor or Owner on subscription ${SUBSCRIPTION} (see PERMISSIONS.md)."
    fi
  done
  info "Resource providers registered"
}

# ---------------------------------------------------------------------------
# Step 5: Terraform state, in the customer's own subscription
#
# The state holds the client secrets this template creates, so the account is private,
# versioned and encrypted, and lives in the customer's subscription -- never in
# Symbol's. SECURITY.md says so plainly rather than leaving it to be discovered.
# ---------------------------------------------------------------------------

state_account_name() {
  # Deterministic: a re-run after a lost local checkout finds the SAME account instead
  # of creating a second one beside it. 24 characters, lower-case alphanumerics.
  local hash
  hash="$(printf '%s-%s' "$(printf '%s' "${SUBSCRIPTION}" | tr 'A-Z' 'a-z')" "$(printf '%s' "${ORG}" | tr 'A-Z' 'a-z')" \
    | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().strip().encode()).hexdigest())')"
  printf 'symboltf%s' "${hash:0:16}"
}

ensure_state() {
  local create="$1"
  STATE_ACCOUNT="$(state_account_name)"

  if ! az group show --name "${STATE_RESOURCE_GROUP}" >/dev/null 2>&1; then
    [[ "${create}" == "true" ]] \
      || die "Resource group ${STATE_RESOURCE_GROUP} not found in subscription ${SUBSCRIPTION}: there is nothing to destroy from here."
    info "Creating the state resource group ${STATE_RESOURCE_GROUP}"
    az group create --name "${STATE_RESOURCE_GROUP}" --location "${LOCATION}" -o none \
      || die "Could not create ${STATE_RESOURCE_GROUP}. You need Contributor or Owner on the subscription."
  fi

  if ! az storage account show --name "${STATE_ACCOUNT}" --resource-group "${STATE_RESOURCE_GROUP}" >/dev/null 2>&1; then
    [[ "${create}" == "true" ]] \
      || die "State storage account ${STATE_ACCOUNT} not found: there is nothing to destroy from here."
    info "Creating the state storage account ${STATE_ACCOUNT} (private, versioned)"
    az storage account create \
      --name "${STATE_ACCOUNT}" \
      --resource-group "${STATE_RESOURCE_GROUP}" \
      --location "${LOCATION}" \
      --sku Standard_LRS \
      --kind StorageV2 \
      --min-tls-version TLS1_2 \
      --allow-blob-public-access false \
      -o none \
      || die "Could not create the state storage account ${STATE_ACCOUNT}."
    az storage account blob-service-properties update \
      --account-name "${STATE_ACCOUNT}" \
      --resource-group "${STATE_RESOURCE_GROUP}" \
      --enable-versioning true -o none 2>/dev/null || true
  fi

  local key
  key="$(az storage account keys list --account-name "${STATE_ACCOUNT}" \
    --resource-group "${STATE_RESOURCE_GROUP}" --query '[0].value' -o tsv 2>/dev/null || true)"
  [[ -n "${key}" ]] || die "Could not read the key of the state storage account ${STATE_ACCOUNT}."
  export ARM_ACCESS_KEY="${key}"

  az storage container create --name "${STATE_CONTAINER}" \
    --account-name "${STATE_ACCOUNT}" --account-key "${key}" -o none 2>/dev/null || true

  info "Terraform state: ${STATE_ACCOUNT}/${STATE_CONTAINER}/symbol-cloud-connect/${ORG}.tfstate"
  (cd "${TF_DIR}" && "${TF}" init -input=false -reconfigure \
    -backend-config="resource_group_name=${STATE_RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${STATE_ACCOUNT}" \
    -backend-config="container_name=${STATE_CONTAINER}" \
    -backend-config="key=symbol-cloud-connect/${ORG}.tfstate" >/dev/null) \
    || die "terraform init failed."
}

# ---------------------------------------------------------------------------
# Step 6: the variables, the plan and the apply
# ---------------------------------------------------------------------------

# The secret_rotation_ids of the previous run, with --rotate's identity set to this
# session: a plain re-run keeps every secret Symbol holds, and only an explicit
# rotation replaces one.
resolve_rotation_ids() {
  local previous="{}"
  previous="$(cd "${TF_DIR}" && "${TF}" output -json secret_rotation_ids 2>/dev/null || printf '{}')"
  ROTATE="${ROTATE}" SESSION="${SESSION}" python3 -c '
import json, os, sys
try:
    current = json.loads(sys.stdin.read() or "{}")
    if not isinstance(current, dict):
        current = {}
except Exception:
    current = {}
rotate = os.environ.get("ROTATE") or ""
if rotate:
    current[rotate] = os.environ["SESSION"]
for identity in ("finops", "observability"):
    current.setdefault(identity, "initial")
print(json.dumps(current))
' <<<"${previous}"
}

split_export() { # account/rg/container/dir/name
  IFS='/' read -r EXPORT_ACCOUNT EXPORT_RG EXPORT_CONTAINER EXPORT_DIR EXPORT_NAME <<<"$1"
  [[ -n "${EXPORT_ACCOUNT}" && -n "${EXPORT_RG}" && -n "${EXPORT_CONTAINER}" && -n "${EXPORT_NAME}" ]] \
    || die "--existing-export must be <storage-account>/<resource-group>/<container>/<directory>/<export-name>."
}

split_eventhub() { # namespace/rg/hub
  IFS='/' read -r HUB_NAMESPACE HUB_RG HUB_NAME <<<"$1"
  [[ -n "${HUB_NAMESPACE}" && -n "${HUB_RG}" && -n "${HUB_NAME}" ]] \
    || die "--existing-eventhub must be <namespace>/<resource-group>/<hub>."
}

module_bool() { has_module "$1" && printf 'true' || printf 'false'; }

# Every value reaches Python through the ENVIRONMENT, never interpolated into the
# heredoc. A storage account name or a region cannot then end a quote, and the script
# has one fewer way to build a var file that does not say what it reads like.
write_var_file() {
  VAR_FILE="$(mktemp "${TMPDIR:-/tmp}/symbol-azure-XXXXXX.tfvars.json")"

  local create_export="true" create_hub="true"
  local export_account="" export_rg="" export_container="" export_dir="" export_name=""
  local hub_namespace="" hub_rg="" hub_name=""

  if [[ -n "${EXISTING_EXPORT}" ]]; then
    split_export "${EXISTING_EXPORT}"
    create_export="false"
    export_account="${EXPORT_ACCOUNT}"; export_rg="${EXPORT_RG}"
    export_container="${EXPORT_CONTAINER}"; export_dir="${EXPORT_DIR}"
    export_name="${EXPORT_NAME}"
  fi
  if [[ -n "${EXISTING_EVENTHUB}" ]]; then
    split_eventhub "${EXISTING_EVENTHUB}"
    create_hub="false"
    hub_namespace="${HUB_NAMESPACE}"; hub_rg="${HUB_RG}"; hub_name="${HUB_NAME}"
  fi

  SYMBOL_ORG="${ORG}" \
  SYMBOL_SESSION="${SESSION}" \
  SYMBOL_TEMPLATE="${TEMPLATE}" \
  SYMBOL_TENANT="${TENANT}" \
  SYMBOL_SUBSCRIPTION="${SUBSCRIPTION}" \
  SYMBOL_LOCATION="${LOCATION}" \
  SYMBOL_DESTROY="${DESTROY}" \
  SYMBOL_SIGNIN="$(module_bool signin)" \
  SYMBOL_FINOPS="$(module_bool finops)" \
  SYMBOL_MONITORING="$(module_bool monitoring)" \
  SYMBOL_SECURITY="$(module_bool security)" \
  SYMBOL_CREATE_EXPORT="${create_export}" \
  SYMBOL_EXPORT_ACCOUNT="${export_account}" \
  SYMBOL_EXPORT_RG="${export_rg}" \
  SYMBOL_EXPORT_CONTAINER="${export_container}" \
  SYMBOL_EXPORT_DIR="${export_dir}" \
  SYMBOL_EXPORT_NAME="${export_name}" \
  SYMBOL_CREATE_HUB="${create_hub}" \
  SYMBOL_HUB_NAMESPACE="${hub_namespace}" \
  SYMBOL_HUB_RG="${hub_rg}" \
  SYMBOL_HUB_NAME="${hub_name}" \
  SYMBOL_SECRET_MONTHS="${SECRET_MONTHS}" \
  SYMBOL_ROTATION="$(resolve_rotation_ids)" \
  python3 - "${VAR_FILE}" <<'PYTHON'
import json, os, sys

def flag(name):
    return os.environ[name] == "true"

values = {
    "symbol_org_id": os.environ["SYMBOL_ORG"],
    "setup_session_id": os.environ["SYMBOL_SESSION"],
    "template_version": os.environ["SYMBOL_TEMPLATE"],
    "tenant_id": os.environ["SYMBOL_TENANT"],
    "subscription_id": os.environ["SYMBOL_SUBSCRIPTION"],
    "location": os.environ["SYMBOL_LOCATION"],
    "destroy_mode": flag("SYMBOL_DESTROY"),
    "enable_signin": flag("SYMBOL_SIGNIN"),
    "enable_finops": flag("SYMBOL_FINOPS"),
    "enable_monitoring": flag("SYMBOL_MONITORING"),
    "enable_security": flag("SYMBOL_SECURITY"),
    "create_cost_export": flag("SYMBOL_CREATE_EXPORT"),
    "existing_export_storage_account": os.environ["SYMBOL_EXPORT_ACCOUNT"],
    "existing_export_resource_group": os.environ["SYMBOL_EXPORT_RG"],
    "existing_export_container": os.environ["SYMBOL_EXPORT_CONTAINER"],
    "existing_export_directory": os.environ["SYMBOL_EXPORT_DIR"],
    "existing_export_name": os.environ["SYMBOL_EXPORT_NAME"],
    "create_eventhub": flag("SYMBOL_CREATE_HUB"),
    "existing_eventhub_namespace": os.environ["SYMBOL_HUB_NAMESPACE"],
    "existing_eventhub_resource_group": os.environ["SYMBOL_HUB_RG"],
    "existing_eventhub_name": os.environ["SYMBOL_HUB_NAME"],
    "secret_valid_months": int(os.environ["SYMBOL_SECRET_MONTHS"]),
    "secret_rotation_ids": json.loads(os.environ["SYMBOL_ROTATION"] or "{}"),
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(values, handle, indent=2)
PYTHON
}

plan_and_apply() {
  info "Planning"
  (cd "${TF_DIR}" && "${TF}" plan -input=false -var-file="${VAR_FILE}" -out=symbol.tfplan) \
    || die "terraform plan failed. Nothing was created."

  if ! confirm "Apply this plan to subscription ${SUBSCRIPTION}?"; then
    (cd "${TF_DIR}" && rm -f symbol.tfplan)
    die "Cancelled. Nothing was created."
  fi

  info "Applying"
  (cd "${TF_DIR}" && "${TF}" apply -input=false symbol.tfplan) \
    || die "terraform apply failed. Run the command again: Terraform continues from where it stopped."
  (cd "${TF_DIR}" && rm -f symbol.tfplan)
}

destroy() {
  warn "This removes the Symbol applications, their secrets, the role assignments, and the export and Event Hub this template created in subscription ${SUBSCRIPTION}."
  if ! confirm "Destroy everything Symbol Cloud Connect created?"; then
    die "Cancelled. Nothing was removed."
  fi
  info "Destroying"
  (cd "${TF_DIR}" && "${TF}" destroy -input=false -auto-approve -var-file="${VAR_FILE}") \
    || die "terraform destroy failed."
  info "Done. Disconnect Azure in Symbol as well, so it stops trying to read this subscription."
}

# ---------------------------------------------------------------------------
# Step 7: the connection code
# ---------------------------------------------------------------------------

print_code() {
  local code summary
  summary="$(cd "${TF_DIR}" && "${TF}" output -raw symbol_connection_summary 2>/dev/null || true)"
  code="$(cd "${TF_DIR}" && "${TF}" output -raw symbol_connection_code 2>/dev/null || true)"
  [[ -n "${code}" ]] || die "The connection code could not be read from the Terraform output."

  printf '\n%s\n' "${summary}" >&2
  printf '\n\033[1;31m%s\033[0m\n' "+------------------------------------------------------------------+" >&2
  printf '\033[1;31m%s\033[0m\n' "|  SECRET - this code contains the client secrets of the two       |" >&2
  printf '\033[1;31m%s\033[0m\n' "|  applications. Paste it into Symbol and nowhere else. Do not     |" >&2
  printf '\033[1;31m%s\033[0m\n' "|  save it to a file, a ticket or a chat message.                  |" >&2
  printf '\033[1;31m%s\033[0m\n\n' "+------------------------------------------------------------------+" >&2
  printf '%s\n\n' "${code}"
  printf 'Paste it in Symbol: Administration > Cloud configuration > Azure.\n' >&2
  if has_module signin; then
    printf '\nSign-in still needs ONE more step: a directory administrator must grant\nadmin consent to Symbol'"'"'s sign-in application, from the link Symbol shows\nafter you paste the code.\n' >&2
  fi
}

# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  validate_args

  check_environment
  resolve_account

  if [[ "${DESTROY}" == "true" ]]; then
    ensure_state "false"
    MODULES="${MODULES:-finops,monitoring,security}"
    write_var_file
    destroy
    exit 0
  fi

  check_app_registration_allowed
  register_providers
  ensure_state "true"
  write_var_file
  plan_and_apply
  print_code
}

main "$@"
