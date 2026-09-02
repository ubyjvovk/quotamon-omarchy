#!/usr/bin/env bash
# Install or update quotamon from the main repository's GitHub release, then
# bootstrap its config. By default the script installs the version named by the
# plugin's quotamon-<version>.sha256 sidecar. An explicit version can override
# that default only when its matching sidecar is present. The panel runs this
# only when Install is clicked; it is also safe to invoke by hand and never runs
# unattended.

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: fetch-quotamon.sh [<version>]" >&2
  exit 2
fi

version=${1:-}
if [[ $# -eq 1 && ! $version =~ ^[0-9]{4}\.(1[0-2]|[1-9])\.[0-9]+$ ]]; then
  echo "usage: fetch-quotamon.sh [<version>]" >&2
  exit 2
fi

# The plugin ships the SHA-256 of the exact core binaries it was released with.
# The sidecar lives in reviewed plugin code, which is why a version we carry no
# digest for is refused rather than installed unverified.
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
derived_version=false
if [[ -z $version ]]; then
  shopt -s nullglob
  pins=("$script_dir"/quotamon-*.sha256)
  shopt -u nullglob
  if (( ${#pins[@]} != 1 )); then
    echo "refusing to install: expected exactly one quotamon-<version>.sha256 beside this script, found ${#pins[@]}" >&2
    exit 2
  fi
  version=${pins[0]##*/quotamon-}; version=${version%.sha256}
  [[ $version =~ ^[0-9]{4}\.(1[0-2]|[1-9])\.[0-9]+$ ]] || { echo "refusing to install: sidecar name is not CalVer: ${pins[0]##*/}" >&2; exit 2; }
  derived_version=true
fi

pin_file="$script_dir/quotamon-$version.sha256"
if [[ ! -f $pin_file ]]; then
  echo "refusing to install: this plugin carries no digest for quotamon $version ($pin_file)" >&2
  echo "the plugin and the core version must match; update the plugin so the two versions match" >&2
  exit 2
fi

# The release origin is a constant, on purpose. Nothing in the environment can
# redirect where a binary that is about to be executed comes from; changing the
# origin means changing this reviewed file.
releases="https://github.com/ubyjvovk/quota_monitor/releases"
release_base="$releases/download/v$version"
bin_dir=${QUOTAMON_BIN_DIR:-"$HOME/.local/bin"}

# Tests and unusual systems can select an architecture explicitly. Otherwise,
# translate the kernel spelling to the names used by release assets.
if [[ -n ${QUOTAMON_ARCH:-} ]]; then
  arch=$QUOTAMON_ARCH
else
  case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)
      echo "Unsupported architecture: $(uname -m)" >&2
      exit 1
      ;;
  esac
fi

case $arch in
  amd64|arm64) ;;
  *)
    echo "Unsupported architecture: $arch (expected amd64 or arm64)" >&2
    exit 1
    ;;
esac

asset="quotamon-linux-$arch"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

# Download into an isolated directory. Nothing under the install prefix is
# touched until everything arrives and the selected asset verifies successfully.
if [[ $derived_version == true ]]; then
  echo "Using the plugin's pinned version $version"
fi
echo "Fetching quotamon $version from $release_base (pinned)"
curl --fail --silent --show-error --location \
     --proto '=https' --proto-redir '=https' \
     --connect-timeout 15 --max-time 180 \
     --max-filesize 33554432 \
     "$release_base/$asset" -o "$tmp_dir/$asset"

# Verify only the exact release filename. A missing checksum is just as unsafe
# as a mismatch, so either condition aborts before an install staging file exists.
checksum_line=$(grep -E "^[[:xdigit:]]{64}[[:space:]]+\\*?$asset$" "$pin_file") || {
  echo "${pin_file##*/} has no checksum for $asset; quotamon was not installed" >&2
  exit 1
}
(
  cd "$tmp_dir"
  printf '%s\n' "$checksum_line" | shasum -a 256 -c -
)

# Stage on the destination filesystem so the final rename replaces an existing
# binary atomically. The EXIT trap also removes a staging file after any failure.
mkdir -p "$bin_dir"
staged_bin=$(mktemp "$bin_dir/.quotamon.XXXXXX")
trap 'rm -rf -- "$tmp_dir"; rm -f -- "${staged_bin:-}"' EXIT
cp "$tmp_dir/$asset" "$staged_bin"
chmod +x "$staged_bin"
bin="$bin_dir/quotamon"
mv -f "$staged_bin" "$bin"
staged_bin=

# Exit 3 is quotamon's explicit "no config" signal. Other provider failures do
# not invalidate a correctly installed binary and remain visible on refresh.
providers_status=0
"$bin" providers >/dev/null 2>&1 || providers_status=$?
if [[ $providers_status -eq 3 ]]; then
  "$bin" setup --yes
  echo "DeepInfra can be added with: quotamon config set deepinfra --api-key-stdin"
fi

echo "Installed quotamon at $bin"
case :$PATH: in
  *:"$bin_dir":*) echo "$bin_dir is already on PATH" ;;
  *) echo "Add $bin_dir to PATH, or set the plugin's quotamon command to $bin" ;;
esac
