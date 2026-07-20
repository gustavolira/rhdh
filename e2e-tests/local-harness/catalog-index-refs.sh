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

MODE="refs"
if [[ "${1:-}" == "--dump-yaml" ]]; then
  MODE="yaml"
  shift
fi

IMAGE="${1:?usage: catalog-index-refs.sh [--dump-yaml] <catalog-index-image>}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# The nightly calls this twice for the same image (cluster enable-values and the
# cluster-free populate), and --dump-yaml adds a third. Cache the extracted file
# per image ref so one job pulls the index once instead of three times.
cache_dir="${TMPDIR:-/tmp}/rhdh-catalog-index-cache"
cache_file="${cache_dir}/$(printf '%s' "$IMAGE" | cksum | tr -d ' ').yaml"
mkdir -p "$cache_dir"

if [[ -s "$cache_file" ]]; then
  default_yaml="$(cat "$cache_file")"
else
  # Extract dynamic-plugins.default.yaml from the catalog index OCI image.
  # Layer blobs in a `skopeo copy ... dir:` layout are named by their bare sha256
  # digest (no extension), so the layer list comes from manifest.json; tar
  # auto-detects gzip-compressed layers. Platform overrides keep instance
  # selection working on any host (multi-arch manifest lists otherwise fail on
  # e.g. macOS).
  skopeo copy --override-os linux --override-arch amd64 \
    "docker://${IMAGE}" "dir:${workdir}/idx" > /dev/null

  # Layers are listed base-first, so the EFFECTIVE copy of the file is the one in
  # the topmost layer that carries it (an index rebuilt as an overlay keeps a
  # stale copy in a lower layer). Walk top-down and take the first hit.
  default_yaml=""
  for digest in $(jq -r '.layers | reverse | .[].digest' "${workdir}/idx/manifest.json"); do
    layer="${workdir}/idx/${digest#sha256:}"
    [[ -f "$layer" ]] || continue
    if content="$(tar -xOf "$layer" dynamic-plugins.default.yaml 2> /dev/null)" && [[ -n "$content" ]]; then
      default_yaml="$content"
      break
    fi
  done

  if [[ -z "$default_yaml" ]]; then
    echo "dynamic-plugins.default.yaml not found in ${IMAGE}" >&2
    exit 1
  fi
  printf '%s\n' "$default_yaml" > "$cache_file"
fi

# Raw file, for callers that need the pluginConfig blocks (env var detection).
if [[ "$MODE" == "yaml" ]]; then
  printf '%s\n' "$default_yaml"
  exit 0
fi

# Known failures are extended-regex patterns, one per line. A missing excludes
# file must fail loudly: silently skipping the filter would install plugins
# documented as unable to boot, which aborts the whole backend and surfaces only
# as an opaque webServer timeout.
excludes_src="$DIR/plugin-sanity-excludes.txt"
if [[ ! -r "$excludes_src" ]]; then
  echo "excludes file not found or unreadable: ${excludes_src}" >&2
  exit 1
fi
# An all-comment file legitimately yields no patterns (grep exits 1).
grep -Ev '^[[:space:]]*(#|$)' "$excludes_src" > "$workdir/excludes.txt" || true

refs="$(
  echo "$default_yaml" \
    | grep -E '^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?(oci://|\./dynamic-plugins/dist/)' \
    | sed -E 's/^[[:space:]]*-[[:space:]]+package:[[:space:]]*"?//; s/"[[:space:]]*$//' \
    | sort -u
)"

# grep -vEf with an empty pattern file is not portable; skip the filter instead.
if [[ -s "$workdir/excludes.txt" ]]; then
  echo "$refs" | grep -vEf "$workdir/excludes.txt" || true
else
  echo "$refs"
fi
