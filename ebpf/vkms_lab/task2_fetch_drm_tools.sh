#!/usr/bin/env bash
set -euo pipefail

# TASK 2: Fetch libdrm, IGT and local dependency source code for source-level
# test analysis.

BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
EXTERNAL_DIR="$BASE_DIR/external"
LIBDRM_REPO="${LIBDRM_REPO:-https://gitlab.freedesktop.org/mesa/drm.git}"
IGT_REPO="${IGT_REPO:-https://gitlab.freedesktop.org/drm/igt-gpu-tools.git}"
KMOD_REPO="${KMOD_REPO:-https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git}"
PCIUTILS_REPO="${PCIUTILS_REPO:-https://git.kernel.org/pub/scm/utils/pciutils/pciutils.git}"

# Set these explicitly for reproducible experiments.
LIBDRM_COMMIT="${LIBDRM_COMMIT:-}"
IGT_COMMIT="${IGT_COMMIT:-}"
KMOD_COMMIT="${KMOD_COMMIT:-}"
PCIUTILS_COMMIT="${PCIUTILS_COMMIT:-}"

for tool in git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "TASK 2 error: missing host tool '$tool'. Run ebpf/env.sh or install it manually." >&2
    exit 1
  fi
done

mkdir -p "$EXTERNAL_DIR"

clone_or_update() {
  local repo_url="$1"
  local dst="$2"
  local commit="$3"

  if [ ! -d "$dst/.git" ]; then
    git clone "$repo_url" "$dst"
  else
    git -C "$dst" fetch --all --tags
  fi

  if [ -n "$commit" ]; then
    git -C "$dst" checkout "$commit"
  fi

  git -C "$dst" rev-parse HEAD
}

echo "libdrm commit:"
clone_or_update "$LIBDRM_REPO" "$EXTERNAL_DIR/libdrm" "$LIBDRM_COMMIT"

echo "igt-gpu-tools commit:"
clone_or_update "$IGT_REPO" "$EXTERNAL_DIR/igt-gpu-tools" "$IGT_COMMIT"

echo "kmod commit:"
clone_or_update "$KMOD_REPO" "$EXTERNAL_DIR/kmod" "$KMOD_COMMIT"

echo "pciutils commit:"
clone_or_update "$PCIUTILS_REPO" "$EXTERNAL_DIR/pciutils" "$PCIUTILS_COMMIT"
