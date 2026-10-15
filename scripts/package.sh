#!/usr/bin/env bash
# Builds the Resource Manager zip for a release.
#
#   scripts/package.sh oci-v1.0.0
#
# Output:
#   dist/symbol-oci-stack-v1.0.0.zip         root .tf files + schema.yaml at the zip root,
#                                            modules/ below (the layout Resource Manager expects)
#   dist/symbol-oci-stack-v1.0.0.zip.sha256  "<sha256>  <zip name>" (sha256sum -c format)
#
# The archive is reproducible: fixed file order, fixed timestamps, no extra attributes.
# Tests, examples, lock files, state and local variable files are never shipped.
set -euo pipefail

VERSION="${1:-${GITHUB_REF_NAME:-}}"
if [[ ! "${VERSION}" =~ ^oci-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 oci-vX.Y.Z (got '${VERSION}')" >&2
  exit 2
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/oci"
DIST="${ROOT}/dist"
SHORT="${VERSION#oci-}"                       # v1.0.0
ZIP_NAME="symbol-oci-stack-${SHORT}.zip"

# The release must carry its own version: the default of template_version is what ends
# up in every connection code, and the stack description names it too.
default_version="$(awk '/variable "template_version"/{f=1} f && /default/{gsub(/[" ]/,"",$0); split($0,a,"="); print a[2]; exit}' "${SRC}/variables.tf")"
if [[ "${default_version}" != "${VERSION}" ]]; then
  echo "variables.tf template_version default is '${default_version}', expected '${VERSION}'" >&2
  exit 1
fi
if ! grep -q "${VERSION}" "${SRC}/schema.yaml"; then
  echo "schema.yaml stackDescription does not mention ${VERSION}" >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

# Whitelist: root *.tf, schema.yaml, modules/**/*.tf. Nothing else.
(
  cd "${SRC}"
  find . -maxdepth 1 -type f -name '*.tf' -print
  echo ./schema.yaml
  find ./modules -type f -name '*.tf' -print
) | LC_ALL=C sort | while read -r f; do
  mkdir -p "${STAGE}/$(dirname "${f}")"
  cp "${SRC}/${f}" "${STAGE}/${f}"
done

mkdir -p "${DIST}"
rm -f "${DIST}/${ZIP_NAME}" "${DIST}/${ZIP_NAME}.sha256"

# Deterministic zip (sorted entries, fixed timestamp and permissions) written with
# Python's zipfile so the result does not depend on the local zip tool.
PYTHON="${PYTHON:-$(command -v python3 || command -v python)}"
stage_arg="${STAGE}"; out_arg="${DIST}/${ZIP_NAME}"
if command -v cygpath >/dev/null 2>&1; then   # Git Bash on Windows (local runs only)
  stage_arg="$(cygpath -w "${STAGE}")"; out_arg="$(cygpath -w "${out_arg}")"
fi
"${PYTHON}" - "${stage_arg}" "${out_arg}" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
files = []
for d, _, names in os.walk(stage):
    for n in names:
        full = os.path.join(d, n)
        files.append(os.path.relpath(full, stage).replace(os.sep, "/"))
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for rel in sorted(files):
        info = zipfile.ZipInfo(rel, date_time=(2020, 1, 1, 0, 0, 0))
        info.external_attr = 0o644 << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(stage, rel), "rb") as f:
            z.writestr(info, f.read())
PY

(
  cd "${DIST}"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${ZIP_NAME}" > "${ZIP_NAME}.sha256"
  else
    shasum -a 256 "${ZIP_NAME}" > "${ZIP_NAME}.sha256"
  fi
)

echo "Built ${DIST}/${ZIP_NAME}"
unzip -l "${DIST}/${ZIP_NAME}"
cat "${DIST}/${ZIP_NAME}.sha256"
