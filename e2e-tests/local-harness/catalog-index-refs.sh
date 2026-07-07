#!/bin/bash
#
# Prints every package ref declared by a catalog index image, one per line,
# with the documented known failures (plugin-sanity-excludes.txt) filtered out.
# Shared by populate-catalog-index.sh (cluster-free install config) and
# generate-catalog-enable-values.sh (Helm values fragment for the cluster
# deployment) so both flavors of the plugin sanity check enable the exact same
# dynamically-discovered set.
#
# Output includes BOTH ref kinds the index declares:
#   - oci://registry/name[:tag|@sha256:...][!plugin-name]
#   - ./dynamic-plugins/dist/<name>  (plugins built into the product image;
#     the install CLI skips them outside the image, the chart enables them
#     inside it)
#
# Only real (uncommented) `- package:` entries count: the index also carries
# commented-out refs, and treating those as declarations would install
# packages the index does not declare.
#
# Requires skopeo and jq. Usage:
#   catalog-index-refs.sh quay.io/rhdh/plugin-catalog-index:next
set -e

IMAGE="${1:?usage: catalog-index-refs.sh <catalog-index-image>}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# Extract dynamic-plugins.default.yaml from the catalog index OCI image.
# Layer blobs in a `skopeo copy ... dir:` layout are named by their bare sha256
# digest (no extension), so the layer list comes from manifest.json; tar
# auto-detects gzip-compressed layers. Platform overrides keep instance
# selection working on any host (multi-arch manifest lists otherwise fail on
# e.g. macOS).
skopeo copy --override-os linux --override-arch amd64 \
  "docker://${IMAGE}" "dir:${workdir}/idx" > /dev/null

default_yaml=""
for digest in $(jq -r '.layers[].digest' "${workdir}/idx/manifest.json"); do
  layer="${workdir}/idx/${digest#sha256:}"
  [ -f "$layer" ] || continue
  if content="$(tar -xOf "$layer" dynamic-plugins.default.yaml 2> /dev/null)" && [ -n "$content" ]; then
    default_yaml="$content"
    break
  fi
done

if [ -z "$default_yaml" ]; then
  echo "dynamic-plugins.default.yaml not found in ${IMAGE}" >&2
  exit 1
fi

# Known failures are extended-regex patterns, one per line.
grep -Ev '^[[:space:]]*(#|$)' "$DIR/plugin-sanity-excludes.txt" > "$workdir/excludes.txt" || true

echo "$default_yaml" \
  | grep -E '^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?(oci://|\./dynamic-plugins/dist/)' \
  | sed -E 's/^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?//; s/"[[:space:]]*$//' \
  | sort -u \
  | grep -vEf "$workdir/excludes.txt" || true
