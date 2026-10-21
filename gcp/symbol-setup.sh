#!/usr/bin/env bash
# Symbol Cloud Connect for GCP - guided setup (CLOUD-SETUP-CONTRACT-V2 §5.5-§5.6).
#
# Run from Google Cloud Shell, signed in as an administrator of the project (see
# PERMISSIONS.md). Symbol shows the exact command; it clones this repository at a pinned
# tag and commit, then runs:
#
#   gcp/symbol-setup.sh --org <org> --session <uuid> --template gcp-vX.Y.Z \
#     --modules finops,monitoring,security --identity-mode auto|symbol_principal|key_upload \
#     [--finops-principal <email>] [--observability-principal <email>] \
#     [--cert-base-url https://<symbol>/api/cloud-connections/setup/public/sessions/<uuid>/keys] \
#     [--project <project>] [--billing-dataset billing_export] \
#     [--scope project|folder:<id>|organization:<id>] [--scc] [--state-location US] [--yes]
#
#   gcp/symbol-setup.sh --destroy --org <org> [--project <project>] [--yes]
#
# Steps (contract §5.6): 1 project, 2 Terraform, 3 APIs, 4 organisation + org policies ->
# identity mode, 5 billing detection, 6 state bucket + init, 7 plan / confirm / apply,
# 8 connection code. Nothing secret is read, written or printed.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TF_DIR="${SCRIPT_DIR}"

# Terraform installed when the local one is missing or older than TERRAFORM_MIN.
# The SHA-256 of each archive is pinned here AND checked against HashiCorp's signed
# SHA256SUMS (GPG signature verified when gpg is available).
readonly TERRAFORM_MIN="1.5.0"
readonly TERRAFORM_VERSION="1.16.6"
readonly TERRAFORM_SHA256_linux_amd64="38034b38d03096399a7a1264a14561a8029b2b496fd1f169452656e53968f1b7"
readonly TERRAFORM_SHA256_linux_arm64="a750b5a11038f165846b2658c40c88cd7070aa67a61bab431a14ba27928ea9ea"
readonly TERRAFORM_SHA256_darwin_amd64="794a36c3f7ebf6c58f2089c226068a539d1705ba358a5679b51671c8dc7ebc7b"
readonly TERRAFORM_SHA256_darwin_arm64="85e1bc78ab45bdc5f82a7bac3929e37d072834a584d22583a2498dc67bb624cd"
# HashiCorp's release-signing key (https://www.hashicorp.com/trust/security).
readonly HASHICORP_PGP_FINGERPRINT="C874011F0AB405110D02105534365D9472D7468F"
readonly HASHICORP_PGP_KEY_URL="https://www.hashicorp.com/.well-known/pgp-key.txt"
readonly INSTALL_DIR="${HOME}/.symbol/bin"

# Validation patterns (contract §4.4 / §5.7).
readonly RE_ORG='^[A-Za-z0-9_-]{1,64}$'
readonly RE_UUID='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
readonly RE_TEMPLATE='^gcp-v[0-9]+\.[0-9]+\.[0-9]+$'
readonly RE_PROJECT='^[a-z][a-z0-9-]{4,28}[a-z0-9]$'
readonly RE_SA_EMAIL='^[a-z][a-z0-9-]{4,28}[a-z0-9]@[a-z][a-z0-9-]{4,28}[a-z0-9]\.iam\.gserviceaccount\.com$'
readonly RE_HTTPS_URL='^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~%/-]*)?$'
readonly RE_DATASET='^[A-Za-z_][A-Za-z0-9_]*$'
readonly RE_SCOPE='^(project|folder:[0-9]{1,20}|organization:[0-9]{1,20})$'
readonly RE_LOCATION='^[A-Za-z][A-Za-z0-9-]{1,29}$'
readonly RE_BILLING_ACCOUNT='^[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}$'
readonly RE_NUMBER='^[0-9]{1,20}$'

ORG=""
SESSION=""
TEMPLATE=""
MODULES=""
IDENTITY_MODE="auto"
FINOPS_PRINCIPAL=""
OBSERVABILITY_PRINCIPAL=""
CERT_BASE_URL=""
PROJECT=""
BILLING_DATASET="billing_export"
SCOPE="project"
ENABLE_SCC="false"
STATE_LOCATION="US"
ASSUME_YES="false"
DESTROY="false"

TF=""
WORK_DIR=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

info() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
note() { printf '    %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_match() { # value regex what
  if [[ ! "$1" =~ $2 ]]; then
    die "Invalid $3: '$1'"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed. Run this script from Google Cloud Shell."
}

confirm() { # prompt -> 0 when the user typed y/yes
  local answer=""
  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r answer </dev/tty || answer=""
  [[ "${answer}" =~ ^([yY]|[yY][eE][sS])$ ]]
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

need_value() { # flag remaining-args-count
  if [[ "$2" -lt 2 ]]; then
    die "$1 needs a value"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --org) need_value "$1" "$#"; ORG="$2"; shift 2 ;;
      --session) need_value "$1" "$#"; SESSION="$2"; shift 2 ;;
      --template) need_value "$1" "$#"; TEMPLATE="$2"; shift 2 ;;
      --modules) need_value "$1" "$#"; MODULES="$2"; shift 2 ;;
      --identity-mode) need_value "$1" "$#"; IDENTITY_MODE="$2"; shift 2 ;;
      --finops-principal) need_value "$1" "$#"; FINOPS_PRINCIPAL="$2"; shift 2 ;;
      --observability-principal) need_value "$1" "$#"; OBSERVABILITY_PRINCIPAL="$2"; shift 2 ;;
      --cert-base-url) need_value "$1" "$#"; CERT_BASE_URL="${2%/}"; shift 2 ;;
      --project) need_value "$1" "$#"; PROJECT="$2"; shift 2 ;;
      --billing-dataset) need_value "$1" "$#"; BILLING_DATASET="$2"; shift 2 ;;
      --scope) need_value "$1" "$#"; SCOPE="$2"; shift 2 ;;
      --state-location) need_value "$1" "$#"; STATE_LOCATION="$2"; shift 2 ;;
      --scc) ENABLE_SCC="true"; shift ;;
      --yes) ASSUME_YES="true"; shift ;;
      --destroy) DESTROY="true"; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "Unknown argument '$1' (see --help)" ;;
    esac
  done

  [[ -n "${ORG}" ]] || die "--org is required"
  require_match "${ORG}" "${RE_ORG}" "--org"
  if [[ -n "${PROJECT}" ]]; then
    require_match "${PROJECT}" "${RE_PROJECT}" "--project"
  fi

  if [[ "${DESTROY}" == "true" ]]; then
    return 0 # the other values come from the saved variables (see destroy_flow)
  fi
  validate_setup_args
}

validate_setup_args() {
  [[ -n "${SESSION}" ]] || die "--session is required"
  [[ -n "${TEMPLATE}" ]] || die "--template is required"
  [[ -n "${MODULES}" ]] || die "--modules is required"
  require_match "${SESSION}" "${RE_UUID}" "--session (expected a UUID)"
  require_match "${TEMPLATE}" "${RE_TEMPLATE}" "--template (expected gcp-vX.Y.Z)"

  local module seen=","
  local -a list=()
  IFS=',' read -r -a list <<<"${MODULES}"
  [[ ${#list[@]} -gt 0 ]] || die "--modules is empty"
  for module in "${list[@]}"; do
    case "${module}" in
      finops | monitoring | security) ;;
      *) die "Unknown module '${module}' (allowed: finops, monitoring, security)" ;;
    esac
    [[ "${seen}" != *",${module},"* ]] || die "Module '${module}' listed twice"
    seen="${seen}${module},"
  done

  case "${IDENTITY_MODE}" in
    auto | symbol_principal | key_upload) ;;
    *) die "--identity-mode must be auto, symbol_principal or key_upload" ;;
  esac
  if [[ -n "${FINOPS_PRINCIPAL}" ]]; then
    require_match "${FINOPS_PRINCIPAL}" "${RE_SA_EMAIL}" "--finops-principal"
  fi
  if [[ -n "${OBSERVABILITY_PRINCIPAL}" ]]; then
    require_match "${OBSERVABILITY_PRINCIPAL}" "${RE_SA_EMAIL}" "--observability-principal"
  fi
  if [[ -n "${CERT_BASE_URL}" ]]; then
    require_match "${CERT_BASE_URL}" "${RE_HTTPS_URL}" "--cert-base-url (must be an https URL)"
  fi
  require_match "${BILLING_DATASET}" "${RE_DATASET}" "--billing-dataset"
  [[ ${#BILLING_DATASET} -le 1024 ]] || die "--billing-dataset is too long"
  require_match "${SCOPE}" "${RE_SCOPE}" "--scope (project, folder:<number> or organization:<number>)"
  require_match "${STATE_LOCATION}" "${RE_LOCATION}" "--state-location"
  if [[ "${ENABLE_SCC}" == "true" && "${SCOPE}" != organization:* ]]; then
    die "--scc needs --scope organization:<id> (Security Command Center notifications are organisation resources)"
  fi
  if [[ "${ENABLE_SCC}" == "true" && ",${MODULES}," != *",monitoring,"* ]]; then
    die "--scc needs the monitoring module"
  fi
}

has_module() { [[ ",${MODULES}," == *",$1,"* ]]; }
needs_finops() { has_module finops; }
needs_observability() { has_module monitoring || has_module security; }

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

check_environment() {
  require_cmd gcloud
  require_cmd curl
  require_cmd unzip
  require_cmd python3
  if [[ "${ASSUME_YES}" != "true" && ! -t 0 ]]; then
    die "Run this script in an interactive terminal (Cloud Shell). --yes exists for CI only."
  fi
  local account
  account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1 || true)"
  [[ -n "${account}" ]] || die "gcloud has no active account. Run 'gcloud auth login' (Cloud Shell does this for you)."
  info "Signed in to gcloud as ${account}"
}

# Step 1 -------------------------------------------------------------------

resolve_project() {
  if [[ -z "${PROJECT}" ]]; then
    PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
    [[ "${PROJECT}" != "(unset)" ]] || PROJECT=""
  fi
  [[ -n "${PROJECT}" ]] || die "No project selected. Run 'gcloud config set project <PROJECT_ID>' (the project that hosts your billing export dataset), or pass --project."
  require_match "${PROJECT}" "${RE_PROJECT}" "project id"
  gcloud projects describe "${PROJECT}" --format='value(projectId)' >/dev/null 2>&1 \
    || die "Project ${PROJECT} not found, or you cannot read it."
  info "Project: ${PROJECT}"
}

# Step 2 -------------------------------------------------------------------

version_ge() { # a b -> a >= b
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" == "$2" ]]
}

terraform_version_of() {
  "$1" version -json 2>/dev/null | sed -n 's/.*"terraform_version": *"\([0-9][0-9.]*\)".*/\1/p' | head -n 1
}

install_terraform() {
  local os arch expected base zip sums sig actual listed gnupg status
  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) die "Unsupported OS $(uname -s): install Terraform >= ${TERRAFORM_MIN} yourself." ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch="amd64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) die "Unsupported CPU $(uname -m): install Terraform >= ${TERRAFORM_MIN} yourself." ;;
  esac
  case "${os}_${arch}" in
    linux_amd64) expected="${TERRAFORM_SHA256_linux_amd64}" ;;
    linux_arm64) expected="${TERRAFORM_SHA256_linux_arm64}" ;;
    darwin_amd64) expected="${TERRAFORM_SHA256_darwin_amd64}" ;;
    darwin_arm64) expected="${TERRAFORM_SHA256_darwin_arm64}" ;;
  esac
  local -a sha256=(sha256sum)
  if ! command -v sha256sum >/dev/null 2>&1; then
    require_cmd shasum
    sha256=(shasum -a 256)
  fi

  base="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"
  zip="terraform_${TERRAFORM_VERSION}_${os}_${arch}.zip"
  sums="terraform_${TERRAFORM_VERSION}_SHA256SUMS"
  sig="${sums}.sig"
  info "Installing Terraform ${TERRAFORM_VERSION} (${os}_${arch}) into ${INSTALL_DIR}"
  local dl="${WORK_DIR}/terraform-download"
  mkdir -p "${dl}"
  curl --proto '=https' --tlsv1.2 -fsSL -o "${dl}/${zip}" "${base}/${zip}"
  curl --proto '=https' --tlsv1.2 -fsSL -o "${dl}/${sums}" "${base}/${sums}"
  curl --proto '=https' --tlsv1.2 -fsSL -o "${dl}/${sig}" "${base}/${sig}"

  # 1. The signed SHA256SUMS file (when gpg is available).
  if command -v gpg >/dev/null 2>&1; then
    gnupg="${WORK_DIR}/gnupg"
    mkdir -p "${gnupg}"
    curl --proto '=https' --tlsv1.2 -fsSL -o "${dl}/hashicorp.asc" "${HASHICORP_PGP_KEY_URL}"
    GNUPGHOME="${gnupg}" gpg --batch --quiet --import "${dl}/hashicorp.asc" 2>/dev/null \
      || die "Could not import HashiCorp's signing key."
    status="$(GNUPGHOME="${gnupg}" gpg --batch --status-fd 1 --verify "${dl}/${sig}" "${dl}/${sums}" 2>/dev/null || true)"
    # VALIDSIG <subkey fpr> ... <primary key fpr>: the last field must be HashiCorp's key.
    if ! printf '%s\n' "${status}" | grep -Eq "^\[GNUPG:\] VALIDSIG .* ${HASHICORP_PGP_FINGERPRINT}\$"; then
      die "The signature of ${sums} is not HashiCorp's (${HASHICORP_PGP_FINGERPRINT}). Aborting."
    fi
    note "SHA256SUMS signature verified (HashiCorp key ${HASHICORP_PGP_FINGERPRINT})."
  else
    warn "gpg not found: the SHA256SUMS signature is not checked (the archive checksum pinned in this script still is)."
  fi

  # 2. The archive against the signed list AND against the checksum pinned here.
  actual="$("${sha256[@]}" "${dl}/${zip}" | cut -d ' ' -f 1)"
  listed="$(awk -v f="${zip}" '$2 == f { print $1 }' "${dl}/${sums}")"
  [[ "${actual}" == "${expected}" ]] || die "Checksum mismatch for ${zip}: got ${actual}, pinned ${expected}."
  [[ "${actual}" == "${listed}" ]] || die "Checksum mismatch for ${zip}: got ${actual}, SHA256SUMS lists '${listed}'."
  note "Archive checksum verified (${actual})."

  mkdir -p "${INSTALL_DIR}"
  unzip -o -q "${dl}/${zip}" terraform -d "${dl}/x"
  install -m 0755 "${dl}/x/terraform" "${INSTALL_DIR}/terraform"
}

ensure_terraform() {
  local candidate version
  for candidate in "$(command -v terraform 2>/dev/null || true)" "${INSTALL_DIR}/terraform"; do
    [[ -n "${candidate}" && -x "${candidate}" ]] || continue
    version="$(terraform_version_of "${candidate}")"
    if [[ -n "${version}" ]] && version_ge "${version}" "${TERRAFORM_MIN}"; then
      TF="${candidate}"
      info "Terraform ${version} (${TF})"
      return 0
    fi
  done
  install_terraform
  TF="${INSTALL_DIR}/terraform"
  version="$(terraform_version_of "${TF}")"
  [[ "${version}" == "${TERRAFORM_VERSION}" ]] || die "Terraform installation failed."
  info "Terraform ${version} (${TF})"
}

# Step 3 -------------------------------------------------------------------

enable_apis() {
  info "Enabling the bootstrap APIs in ${PROJECT} (no-op when already enabled)"
  gcloud services enable --project="${PROJECT}" \
    serviceusage.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com \
    storage.googleapis.com bigquery.googleapis.com pubsub.googleapis.com logging.googleapis.com \
    cloudasset.googleapis.com recommender.googleapis.com cloudbilling.googleapis.com \
    || die "Could not enable the APIs. You need roles/serviceusage.serviceUsageAdmin on ${PROJECT} (see PERMISSIONS.md)."
}

# Step 4 -------------------------------------------------------------------

ORGANIZATION_ID=""
DRS_STATE="unknown"         # allow_all | restricted | unknown
KEY_UPLOAD_STATE="unknown"  # allowed | disabled | unknown
SELECTED_MODE=""
SCOPE_TYPE="project"
SCOPE_ID=""

detect_organization() {
  ORGANIZATION_ID="$(gcloud projects get-ancestors "${PROJECT}" --format='value(type,id)' 2>/dev/null \
    | awk '$1 == "organization" { print $2 }' | head -n 1 || true)"
  if [[ -n "${ORGANIZATION_ID}" ]]; then
    require_match "${ORGANIZATION_ID}" "${RE_NUMBER}" "organisation id"
    info "Organisation: ${ORGANIZATION_ID}"
    gcloud services enable --project="${PROJECT}" orgpolicy.googleapis.com >/dev/null 2>&1 \
      || warn "Could not enable orgpolicy.googleapis.com; organisation policies may not be readable."
  else
    info "Project ${PROJECT} has no organisation."
  fi
}

# Prints one word for the effective policy of a constraint on the project:
#   boolean constraints: enforced | not_enforced | unknown
#   list constraints:    allow_all | restricted | unknown
# Reads Org Policy v2 (gcloud org-policies describe --effective) and falls back to the
# v1 format (gcloud resource-manager org-policies describe --effective).
policy_state() { # constraint kind(boolean|list)
  local json=""
  json="$(gcloud org-policies describe "$1" --effective --project="${PROJECT}" --format=json 2>/dev/null || true)"
  if [[ -z "${json}" ]]; then
    json="$(gcloud resource-manager org-policies describe "constraints/$1" --effective --project="${PROJECT}" --format=json 2>/dev/null || true)"
  fi
  if [[ -z "${json}" ]]; then
    # NOT_FOUND on a boolean effective policy means the default (not enforced) for
    # legacy constraints; an unreadable policy is reported as unknown by the caller.
    printf 'unknown\n'
    return 0
  fi
  printf '%s' "${json}" | python3 -c '
import json, sys
kind = sys.argv[1]
try:
    p = json.load(sys.stdin)
except ValueError:
    print("unknown"); sys.exit(0)
rules = (p.get("spec") or {}).get("rules")
if rules is not None:                                   # Org Policy v2
    if kind == "boolean":
        print("enforced" if any(r.get("enforce") is True for r in rules) else "not_enforced")
    else:
        if not rules or any(r.get("allowAll") is True and not r.get("condition") for r in rules):
            print("allow_all")
        else:
            print("restricted")
    sys.exit(0)
if "booleanPolicy" in p or kind == "boolean" and "listPolicy" not in p:   # v1 boolean
    print("enforced" if (p.get("booleanPolicy") or {}).get("enforced") is True else "not_enforced")
    sys.exit(0)
lp = p.get("listPolicy")
if lp is None:
    print("allow_all")                                  # no policy = default = allow all
elif lp.get("allValues") == "ALLOW":
    print("allow_all")
elif lp.get("allowedValues") or lp.get("deniedValues") or lp.get("allValues") == "DENY":
    print("restricted")
else:
    print("allow_all")
' "$2"
}

detect_org_policies() {
  if [[ -z "${ORGANIZATION_ID}" ]]; then
    DRS_STATE="allow_all"
    KEY_UPLOAD_STATE="allowed"
    return 0
  fi
  local drs drs_managed upload upload_managed
  drs="$(policy_state iam.allowedPolicyMemberDomains list)"
  drs_managed="$(policy_state iam.managed.allowedPolicyMemberDomains boolean)"
  upload="$(policy_state iam.disableServiceAccountKeyUpload boolean)"
  upload_managed="$(policy_state iam.managed.disableServiceAccountKeyUpload boolean)"

  if [[ "${drs}" == "restricted" || "${drs_managed}" == "enforced" ]]; then
    DRS_STATE="restricted"
  elif [[ "${drs}" == "allow_all" ]]; then
    DRS_STATE="allow_all"
  fi
  if [[ "${upload}" == "enforced" || "${upload_managed}" == "enforced" ]]; then
    KEY_UPLOAD_STATE="disabled"
  elif [[ "${upload}" == "not_enforced" || "${upload_managed}" == "not_enforced" ]]; then
    KEY_UPLOAD_STATE="allowed"
  fi
  note "iam.allowedPolicyMemberDomains: ${drs} (managed variant: ${drs_managed})"
  note "iam.disableServiceAccountKeyUpload: ${upload} (managed variant: ${upload_managed})"
}

select_identity_mode() {
  local principals_ready="false" certs_ready="false"
  if { ! needs_finops || [[ -n "${FINOPS_PRINCIPAL}" ]]; } && { ! needs_observability || [[ -n "${OBSERVABILITY_PRINCIPAL}" ]]; }; then
    principals_ready="true"
  fi
  [[ -n "${CERT_BASE_URL}" ]] && certs_ready="true"

  case "${IDENTITY_MODE}" in
    symbol_principal)
      [[ "${principals_ready}" == "true" ]] || die "identity mode symbol_principal, but Symbol's principals were not passed. Start a new setup in Symbol."
      if [[ "${DRS_STATE}" == "restricted" ]]; then
        warn "Domain restricted sharing (iam.allowedPolicyMemberDomains) is enforced on ${PROJECT}. Granting roles to Symbol's service accounts will fail unless your organisation allows Symbol's Google Workspace customer ID. Ask Symbol for key-upload mode otherwise."
      fi
      SELECTED_MODE="symbol_principal"
      ;;
    key_upload)
      [[ "${certs_ready}" == "true" ]] || die "identity mode key_upload, but --cert-base-url was not passed. Start a new setup in Symbol."
      [[ "${KEY_UPLOAD_STATE}" != "disabled" ]] || die "Service account key upload is disabled by iam.disableServiceAccountKeyUpload (or iam.managed.disableServiceAccountKeyUpload) on ${PROJECT}. Use Symbol-principal mode, or ask your organisation administrator for an exception on this project."
      SELECTED_MODE="key_upload"
      ;;
    auto)
      if [[ "${principals_ready}" == "true" && "${DRS_STATE}" != "restricted" ]]; then
        SELECTED_MODE="symbol_principal"
        if [[ "${DRS_STATE}" == "unknown" ]]; then
          note "Could not read iam.allowedPolicyMemberDomains (you may lack orgpolicy.policy.get); trying Symbol-principal mode."
        fi
      elif [[ "${certs_ready}" == "true" && "${KEY_UPLOAD_STATE}" != "disabled" ]]; then
        SELECTED_MODE="key_upload"
        if [[ "${DRS_STATE}" == "restricted" ]]; then
          note "Domain restricted sharing is enforced: roles cannot be granted to Symbol's own service accounts"
          note "(this script cannot tell whether Symbol's customer ID is in your allow-list), so key-upload mode is used:"
          note "two service accounts are created in ${PROJECT} with Symbol's public certificates as their keys."
        fi
      else
        die "No identity mode is possible: iam.allowedPolicyMemberDomains blocks Symbol's principals$([[ "${principals_ready}" == "true" ]] || printf ' (or none was prepared)') and iam.disableServiceAccountKeyUpload / iam.managed.disableServiceAccountKeyUpload blocks key upload$([[ "${certs_ready}" == "true" ]] || printf ' (or no certificate was prepared)'). Ask your organisation administrator to allow Symbol's customer ID or key upload on ${PROJECT}."
      fi
      ;;
  esac
  info "Identity mode: ${SELECTED_MODE}"
}

parse_scope() {
  case "${SCOPE}" in
    project) SCOPE_TYPE="project"; SCOPE_ID="" ;;
    folder:*) SCOPE_TYPE="folder"; SCOPE_ID="${SCOPE#folder:}" ;;
    organization:*) SCOPE_TYPE="organization"; SCOPE_ID="${SCOPE#organization:}" ;;
  esac
  if [[ "${SCOPE_TYPE}" != "project" && -z "${ORGANIZATION_ID}" ]]; then
    die "Scope ${SCOPE} needs a project inside an organisation; ${PROJECT} has none. Use --scope project."
  fi
  if [[ "${SCOPE_TYPE}" == "organization" && "${SCOPE_ID}" != "${ORGANIZATION_ID}" ]]; then
    die "Scope organization:${SCOPE_ID} is not the organisation of ${PROJECT} (${ORGANIZATION_ID})."
  fi
}

# Step 5 -------------------------------------------------------------------

BILLING_ACCOUNT=""
DATASET_EXISTS="false"
EXPORT_DETECTED="false"
VIEW_EXISTS="false"
DATASET_LOCATION="US"

bq_q() { bq --headless --quiet --project_id="${PROJECT}" "$@"; }

detect_billing() {
  needs_finops || return 0
  require_cmd bq
  local name tables candidates count
  name="$(gcloud billing projects describe "${PROJECT}" --format='value(billingAccountName)' 2>/dev/null || true)"
  BILLING_ACCOUNT="${name#billingAccounts/}"
  if [[ -n "${BILLING_ACCOUNT}" && ! "${BILLING_ACCOUNT}" =~ ${RE_BILLING_ACCOUNT} ]]; then
    BILLING_ACCOUNT=""
  fi

  if bq_q show --format=prettyjson "${PROJECT}:${BILLING_DATASET}" >/dev/null 2>&1; then
    DATASET_EXISTS="true"
    DATASET_LOCATION="$(bq_q show --format=prettyjson "${PROJECT}:${BILLING_DATASET}" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("location","US"))' 2>/dev/null || printf 'US')"
    tables="$(bq_q ls --format=json --max_results=10000 "${PROJECT}:${BILLING_DATASET}" 2>/dev/null \
      | python3 -c 'import json,sys
for t in json.load(sys.stdin):
    print(t.get("tableReference",{}).get("tableId",""))' 2>/dev/null || true)"
    candidates="$(printf '%s\n' "${tables}" | grep -E '^gcp_billing_export_resource_v1_[0-9A-F]{6}_[0-9A-F]{6}_[0-9A-F]{6}$' || true)"
    if [[ -n "${BILLING_ACCOUNT}" ]] && printf '%s\n' "${candidates}" | grep -qx "gcp_billing_export_resource_v1_${BILLING_ACCOUNT//-/_}"; then
      EXPORT_DETECTED="true"
    else
      count="$(printf '%s\n' "${candidates}" | grep -c . || true)"
      if [[ "${count}" == "1" ]]; then
        # The dataset receives the export of another billing account than the
        # project's own: the table name is authoritative.
        BILLING_ACCOUNT="$(printf '%s' "${candidates#gcp_billing_export_resource_v1_}" | tr '_' '-')"
        EXPORT_DETECTED="true"
        note "Detailed export found for billing account ${BILLING_ACCOUNT}."
      elif [[ "${count}" -gt 1 ]]; then
        warn "Several detailed export tables are in ${BILLING_DATASET}; the one of the project's billing account (${BILLING_ACCOUNT:-unknown}) is not among them. Skipping the FOCUS view."
      fi
    fi
    if printf '%s\n' "${tables}" | grep -qx 'gcp_focus_v1'; then
      VIEW_EXISTS="true"
    fi
  fi
  info "Billing: account ${BILLING_ACCOUNT:-unknown}, dataset ${BILLING_DATASET} $([[ "${DATASET_EXISTS}" == "true" ]] && printf 'exists' || printf 'will be created'), detailed export ${EXPORT_DETECTED}, gcp_focus_v1 $([[ "${VIEW_EXISTS}" == "true" ]] && printf 'exists' || printf 'absent')"
}

# Step 6 -------------------------------------------------------------------

STATE_BUCKET=""
STATE_PREFIX=""

ensure_state_bucket() {
  local create="$1"
  STATE_BUCKET="${PROJECT}-symbol-tfstate"
  STATE_PREFIX="symbol-cloud-connect/${ORG}"
  local listed
  listed="$(gcloud storage buckets list --project="${PROJECT}" --filter="name=${STATE_BUCKET}" --format='value(name)' 2>/dev/null || true)"
  if [[ "${listed}" != "${STATE_BUCKET}" ]]; then
    if gcloud storage buckets describe "gs://${STATE_BUCKET}" --format='value(name)' >/dev/null 2>&1; then
      die "Bucket gs://${STATE_BUCKET} exists but does not belong to ${PROJECT}. Refusing to store Terraform state in it."
    fi
    [[ "${create}" == "true" ]] || die "State bucket gs://${STATE_BUCKET} not found in ${PROJECT}: nothing to destroy from this project."
    info "Creating the state bucket gs://${STATE_BUCKET} (${STATE_LOCATION}, uniform access, public access prevention, versioning)"
    gcloud storage buckets create "gs://${STATE_BUCKET}" --project="${PROJECT}" --location="${STATE_LOCATION}" \
      --uniform-bucket-level-access --public-access-prevention >/dev/null
  fi
  gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning >/dev/null
  info "Terraform state: gs://${STATE_BUCKET}/${STATE_PREFIX}"
  (cd "${TF_DIR}" && "${TF}" init -input=false -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" -backend-config="prefix=${STATE_PREFIX}" >/dev/null) \
    || die "terraform init failed."
}

in_state() {
  (cd "${TF_DIR}" && "${TF}" state list 2>/dev/null) | grep -Fxq "$1"
}

# Step 7 -------------------------------------------------------------------

VAR_FILE=""

json_bool() { [[ "$1" == "true" ]] && printf 'true' || printf 'false'; }

write_var_file() {
  local create_dataset create_view
  create_dataset="false"
  create_view="false"
  if needs_finops; then
    # Keep managing what an earlier run created (otherwise an upgrade would delete it).
    if [[ "${DATASET_EXISTS}" != "true" ]] || in_state 'module.finops[0].google_bigquery_dataset.billing[0]'; then
      create_dataset="true"
    fi
    if [[ "${EXPORT_DETECTED}" == "true" ]] && { [[ "${VIEW_EXISTS}" != "true" ]] || in_state 'module.finops[0].google_bigquery_table.focus[0]'; }; then
      create_view="true"
    fi
  fi
  local cert_finops="" cert_obs=""
  if [[ "${SELECTED_MODE}" == "key_upload" ]]; then
    cert_finops="${CERT_BASE_URL}/finops.crt"
    cert_obs="${CERT_BASE_URL}/observability.crt"
  fi

  VAR_FILE="${WORK_DIR}/symbol.tfvars.json"
  # Every value below was validated against a strict pattern (no quote, backslash or
  # control character can reach this JSON).
  cat >"${VAR_FILE}" <<JSON
{
  "symbol_org_id": "${ORG}",
  "setup_session_id": "${SESSION}",
  "template_version": "${TEMPLATE}",
  "project_id": "${PROJECT}",
  "organization_id": "${ORGANIZATION_ID}",
  "enable_finops": $(needs_finops && printf 'true' || printf 'false'),
  "enable_monitoring": $(has_module monitoring && printf 'true' || printf 'false'),
  "enable_security": $(has_module security && printf 'true' || printf 'false'),
  "identity_mode": "${SELECTED_MODE}",
  "finops_principal": "$([[ "${SELECTED_MODE}" == "symbol_principal" ]] && printf '%s' "${FINOPS_PRINCIPAL}")",
  "observability_principal": "$([[ "${SELECTED_MODE}" == "symbol_principal" ]] && printf '%s' "${OBSERVABILITY_PRINCIPAL}")",
  "finops_certificate_url": "${cert_finops}",
  "observability_certificate_url": "${cert_obs}",
  "scope_type": "${SCOPE_TYPE}",
  "scope_id": "${SCOPE_ID}",
  "billing_dataset": "${BILLING_DATASET}",
  "billing_dataset_location": "${DATASET_LOCATION}",
  "billing_account_id": "${BILLING_ACCOUNT}",
  "create_dataset": ${create_dataset},
  "billing_export_detected": $(json_bool "${EXPORT_DETECTED}"),
  "create_focus_view": ${create_view},
  "enable_scc": $(json_bool "${ENABLE_SCC}")
}
JSON
}

plan_and_apply() {
  info "Planning (nothing is changed yet)"
  (cd "${TF_DIR}" && "${TF}" plan -input=false -var-file="${VAR_FILE}" -out=symbol.tfplan) \
    || die "terraform plan failed (see above). Nothing was changed."
  printf '\n' >&2
  note "Review the plan above: every IAM grant is listed (PERMISSIONS.md explains each one)."
  confirm "Apply?" || die "Cancelled. Nothing was changed."
  (cd "${TF_DIR}" && "${TF}" apply -input=false symbol.tfplan) \
    || die "terraform apply failed (see above). Fix the cause and run the same command again: it resumes from the saved state."
  rm -f -- "${TF_DIR}/symbol.tfplan"
  # Saved next to the state so that '--destroy' works later without the setup command.
  gcloud storage cp --quiet "${VAR_FILE}" "gs://${STATE_BUCKET}/${STATE_PREFIX}/symbol.tfvars.json" >/dev/null \
    || warn "Could not save the variables to the state bucket; '--destroy' will then need the full setup arguments."
}

# Step 8 -------------------------------------------------------------------

print_code() {
  local code line
  code="$(cd "${TF_DIR}" && "${TF}" output -raw symbol_connection_code)"
  [[ "${code}" == SYMBOL-GCP-1.* ]] || die "Unexpected connection code output."
  line="$(printf '%*s' 78 '' | tr ' ' '=')"
  printf '\n%s\n' "${line}"
  printf '  SYMBOL CONNECTION CODE - copy the whole line below and paste it into Symbol\n'
  printf '%s\n\n' "${line}"
  printf '%s\n\n' "${code}"
  printf '%s\n' "${line}"
  printf '  It contains identifiers only (no secret). It is accepted once, for this setup session.\n'
  printf '%s\n\n' "${line}"
  (cd "${TF_DIR}" && "${TF}" output -raw symbol_connection_summary) || true
  printf '\n'

  if needs_finops && [[ "${EXPORT_DETECTED}" != "true" ]]; then
    warn "Cloud Billing export to BigQuery is not enabled for this dataset. Enable 'Detailed usage cost' into ${PROJECT}.${BILLING_DATASET}:"
    if [[ -n "${BILLING_ACCOUNT}" ]]; then
      note "https://console.cloud.google.com/billing/${BILLING_ACCOUNT}/export"
    else
      note "https://console.cloud.google.com/billing (Billing export > BigQuery export)"
    fi
    note "Then run the same command again to create the FOCUS view gcp_focus_v1."
  fi
  if needs_finops; then
    note "Billing data reaches BigQuery a few hours after the export is enabled (no history before that):"
    note "Symbol shows 'waiting for billing data' until the first rows arrive."
  fi
  if has_module monitoring; then
    note "Audit-log events reach Symbol within minutes of the sink being created."
  fi
}

# ---------------------------------------------------------------------------
# Flows
# ---------------------------------------------------------------------------

setup_flow() {
  resolve_project
  ensure_terraform
  enable_apis
  detect_organization
  detect_org_policies
  select_identity_mode
  parse_scope
  detect_billing
  ensure_state_bucket true
  write_var_file
  plan_and_apply
  print_code
}

destroy_flow() {
  resolve_project
  ensure_terraform
  ensure_state_bucket false
  VAR_FILE="${WORK_DIR}/symbol.tfvars.json"
  if ! gcloud storage cp --quiet "gs://${STATE_BUCKET}/${STATE_PREFIX}/symbol.tfvars.json" "${VAR_FILE}" >/dev/null 2>&1; then
    warn "Saved variables not found in gs://${STATE_BUCKET}/${STATE_PREFIX}; using the arguments of this command."
    validate_setup_args
    detect_organization
    parse_scope
    SELECTED_MODE="${IDENTITY_MODE}"
    [[ "${SELECTED_MODE}" != "auto" ]] || die "Pass --identity-mode symbol_principal or key_upload (the mode used at setup)."
    write_var_file
  fi

  # The billing dataset holds customer billing data: never deleted, only released.
  if in_state 'module.finops[0].google_bigquery_dataset.billing[0]'; then
    (cd "${TF_DIR}" && "${TF}" state rm 'module.finops[0].google_bigquery_dataset.billing[0]' >/dev/null)
    note "The billing dataset is kept (no longer managed by this template)."
  fi

  info "Planning the removal of everything this template created"
  (cd "${TF_DIR}" && "${TF}" plan -destroy -input=false -var-file="${VAR_FILE}" -var=destroy_mode=true -out=symbol-destroy.tfplan) \
    || die "terraform plan -destroy failed (see above)."
  confirm "Destroy? Symbol loses all access granted by this template." || die "Cancelled. Nothing was changed."
  (cd "${TF_DIR}" && "${TF}" apply -input=false symbol-destroy.tfplan) || die "terraform destroy failed (see above)."
  rm -f -- "${TF_DIR}/symbol-destroy.tfplan"
  gcloud storage rm --quiet "gs://${STATE_BUCKET}/${STATE_PREFIX}/symbol.tfvars.json" >/dev/null 2>&1 || true
  info "Done. Symbol's access is revoked. The state bucket gs://${STATE_BUCKET} (versioned) and the billing dataset are kept; delete them yourself if you no longer need them."
}

main() {
  parse_args "$@"
  check_environment
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/symbol-setup.XXXXXXXX")"
  if [[ "${DESTROY}" == "true" ]]; then
    destroy_flow
  else
    setup_flow
  fi
}

main "$@"
