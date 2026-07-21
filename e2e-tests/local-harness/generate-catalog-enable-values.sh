#!/bin/bash
#
# Emits (to stdout) a Helm values fragment that enables EVERY package declared
# by the catalog index, for the cluster-based sanity-plugins deployment:
#
#   global:
#     dynamic:
#       plugins:
#         - package: "<each declared ref>"
#           disabled: false
#
# Merged UNDER the curated values via `helm::merge_values merge` (fragment as
# base, curated file as diff), so curated entries keep their pluginConfig while
# every other index package gets enabled dynamically. This replaces the frozen
# hand-maintained plugin list: the enabled set now follows the index passed via
# CATALOG_INDEX_IMAGE (e.g. an RC index through Gangway --catalog-index-image).
#
# When a curated values file is passed as $2, index packages whose NAME already
# appears there are omitted from the fragment. Dedup by exact ref is not
# enough: curated entries pin old tags, so the same plugin under a newer index
# ref would otherwise be enabled TWICE (duplicate pluginId -> backend crash).
#
# Includes the `./dynamic-plugins/dist/*` refs on purpose: those plugins live
# inside the product image, so enabling them exercises the image content.
#
# Requires skopeo and jq. Usage:
#   generate-catalog-enable-values.sh <catalog-index-image> [curated-values.yaml] > enable-values.yaml
set -e

IMAGE="${1:?usage: generate-catalog-enable-values.sh <catalog-index-image> [curated-values.yaml]}"
CURATED_FILE="${2:-}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stable identity for a package ref: image/dist basename without tag or digest,
# plus the !plugin-name suffix when present (one OCI image can carry several
# plugins). Examples:
#   oci://ghcr.io/x/argo-cd-backend:bs_1.49__4.8.0        -> argo-cd-backend
#   oci://registry/x/argo-cd-backend@sha256:...!argocd    -> argo-cd-backend!argocd
#   ./dynamic-plugins/dist/backstage-plugin-techdocs      -> backstage-plugin-techdocs
#
# The trailing `-dynamic` is stripped because the SAME plugin is named
# differently by the two sources this dedup compares: the index ships
# `…-module-msgraph` while the in-image dist directory (and therefore every
# curated entry) is `…-module-msgraph-dynamic`. Without this the curated entry
# and the index entry look like two plugins, both get enabled, and the install
# CLI aborts the deployment with "Config key '…' defined differently for 2
# dynamic plugins".
ref_key() {
  local r="$1" suffix=""
  if [[ "$r" == *"!"* ]]; then
    suffix="!${r##*!}"
    r="${r%%!*}"
  fi
  r="${r#oci://}"
  r="${r##*/}"
  r="${r%%@*}"
  r="${r%%:*}"
  r="${r%-dynamic}"
  echo "${r}${suffix}"
}

curated_keys=""
if [[ -n "$CURATED_FILE" && -f "$CURATED_FILE" ]]; then
  curated_refs="$(grep -E '^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?(oci://|\./dynamic-plugins/dist/)' "$CURATED_FILE" \
    | sed -E 's/^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?//; s/"[[:space:]]*$//' || true)"
  while read -r ref; do
    [[ -z "$ref" ]] && continue
    curated_keys+="$(ref_key "$ref")"$'\n'
  done <<< "$curated_refs"
fi

refs="$("$DIR/catalog-index-refs.sh" "$IMAGE")"

if [[ -z "$refs" ]]; then
  echo "No packages found in dynamic-plugins.default.yaml of ${IMAGE}" >&2
  exit 1
fi

envscan_dir="$(mktemp -d)"
trap 'rm -rf "$envscan_dir"' EXIT
"$DIR/catalog-index-refs.sh" --dump-yaml "$IMAGE" > "${envscan_dir}/default.yaml"

# Refs the index enables ITSELF (`enabled: true` in dynamic-plugins.default.yaml,
# which the container loads via `includes:`). These are on regardless of what this
# fragment says, so a curated entry for the same plugin under a DIFFERENT ref
# (typically the ./dynamic-plugins/dist copy) means the module gets registered
# twice and the backend dies with "is already registered". Skipping the ref here
# does not help - only removing the curated entry does.
index_enabled="$(
  awk '
    /^[[:space:]]*-[[:space:]]+package:/ {
      ref = $0
      sub(/^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?/, "", ref)
      sub(/"[[:space:]]*$/, "", ref)
    }
    /^[[:space:]]*enabled:[[:space:]]*true/ { if (ref != "") print ref }
  ' "${envscan_dir}/default.yaml"
)"

# Build the plugin entries first: emitting the `plugins:` key with an empty body
# yields `plugins: null`, which is a different shape from an empty list and would
# make the downstream yq merge fragile.
entries=""
enabled_refs=""
collisions=""
while read -r ref; do
  [[ -z "$ref" ]] && continue
  key="$(ref_key "$ref")"
  if [[ -n "$curated_keys" ]] && grep -qxF "$key" <<< "$curated_keys"; then
    echo "# skipped (curated entry exists for '${key}'): ${ref}" >&2
    if grep -qxF "$ref" <<< "$index_enabled"; then
      collisions+="  - ${key} (index ref: ${ref})"$'\n'
    fi
    continue
  fi
  entries+="      - package: \"$ref\""$'\n'
  entries+="        disabled: false"$'\n'
  enabled_refs+="${ref}"$'\n'
done <<< "$refs"

if [[ -n "$collisions" ]]; then
  {
    echo "# ERROR: the catalog index enables these packages itself (enabled: true), and"
    echo "# the curated values file enables the SAME plugin under a different ref. Both"
    echo "# will be installed and the module registered twice, which aborts startup with"
    echo "# \"is already registered\". Remove the curated entry - the index already covers it:"
    printf '%s' "$collisions"
  } >&2
  exit 1
fi

# The index ships pluginConfig with ${VAR} placeholders. A variable that is not
# in the pod environment expands to an EMPTY STRING, which fails config schema
# validation and takes the whole backend down - and the resulting error names
# the schema path, never the missing variable. Report the variables the enabled
# packages need so the next index bump is a one-line fix instead of an outage.
# (Supply them in .ci/pipelines/auth/secrets-rhdh-secrets.yaml; a dummy value is
# fine, the sanity check only needs the plugins to initialize.)
printf '%s' "$enabled_refs" > "${envscan_dir}/refs"

# Two-file awk: `awk -v` cannot carry embedded newlines portably.
needed_vars="$(
  awk '
    NR == FNR { if ($0 != "") want[$0] = 1; next }
    /^[[:space:]]*-[[:space:]]+package:/ {
      line = $0
      sub(/^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      active = (line in want)
    }
    active { print }
  ' "${envscan_dir}/refs" "${envscan_dir}/default.yaml" \
    | grep -oE '\$\{[A-Z0-9_]+\}' | tr -d '${}' | sort -u
)"

# What matters is the POD environment, which comes from the rhdh-secrets template
# - not this script's environment. Fall back to the live environment so local
# runs outside CI still get a useful answer.
SECRET_TEMPLATE="$DIR/../../.ci/pipelines/auth/secrets-rhdh-secrets.yaml"
missing_vars=""
while read -r var; do
  [[ -z "$var" ]] && continue
  if [[ -f "$SECRET_TEMPLATE" ]] && grep -qE "^[[:space:]]+${var}:" "$SECRET_TEMPLATE"; then
    continue
  fi
  # Indirect expansion: empty or unset both count as missing.
  [[ -n "${!var:-}" ]] || missing_vars+="  - \${${var}}"$'\n'
done <<< "$needed_vars"

if [[ -n "$missing_vars" ]]; then
  {
    echo "# WARNING: the catalog index references these variables in the pluginConfig of"
    echo "# packages being enabled, but they are unset in this environment. They will"
    echo "# expand to an empty string, which can abort backend startup:"
    printf '%s' "$missing_vars"
  } >&2
fi

echo "# Generated by generate-catalog-enable-values.sh for ${IMAGE}"
echo "global:"
echo "  dynamic:"
if [[ -z "$entries" ]]; then
  # Every index package already has a curated entry - nothing to add.
  echo "    plugins: []"
else
  echo "    plugins:"
  printf '%s' "$entries"
fi
