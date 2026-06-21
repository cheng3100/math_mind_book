#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXTERNAL_DIR="${SCRIPT_DIR}/external"

REPOS=(
  "llama2.c|https://github.com/karpathy/llama2.c.git"
  "llama.cpp|https://github.com/ggml-org/llama.cpp.git"
  "vllm|https://github.com/vllm-project/vllm.git"
  "sglang|https://github.com/sgl-project/sglang.git"
  "TensorRT-LLM|https://github.com/NVIDIA/TensorRT-LLM.git"
)

usage() {
  cat <<'EOF'
Usage:
  ./ref_llm_learn/manage_repos.sh download [--depth N]
  ./ref_llm_learn/manage_repos.sh status
  ./ref_llm_learn/manage_repos.sh clean [--yes]

Commands:
  download    Clone missing reference repositories into ref_llm_learn/external/.
  status      Show local repository status and checked-out commit.
  clean       Remove ref_llm_learn/external/ after confirmation.

Options:
  --depth N   Use shallow clone depth N. Default: full clone.
  --yes       Skip confirmation for clean.

Reference repositories:
  karpathy/llama2.c
  ggml-org/llama.cpp
  vllm-project/vllm
  sgl-project/sglang
  NVIDIA/TensorRT-LLM
EOF
}

require_git() {
  if ! command -v git >/dev/null 2>&1; then
    echo "error: git is required but not found in PATH" >&2
    exit 1
  fi
}

repo_name() {
  echo "${1%%|*}"
}

repo_url() {
  echo "${1#*|}"
}

download_repos() {
  local depth=""

  while (($# > 0)); do
    case "$1" in
      --depth)
        if [[ $# -lt 2 || "$2" == --* ]]; then
          echo "error: --depth requires a numeric value" >&2
          exit 1
        fi
        depth="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown download option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  require_git
  mkdir -p "${EXTERNAL_DIR}"

  for repo in "${REPOS[@]}"; do
    local name url target
    name="$(repo_name "${repo}")"
    url="$(repo_url "${repo}")"
    target="${EXTERNAL_DIR}/${name}"

    if [[ -d "${target}/.git" ]]; then
      echo "skip: ${name} already exists at ${target}"
      continue
    fi

    if [[ -e "${target}" ]]; then
      echo "error: ${target} exists but is not a git repository" >&2
      exit 1
    fi

    echo "clone: ${url} -> ${target}"
    if [[ -n "${depth}" ]]; then
      git clone --depth "${depth}" "${url}" "${target}"
    else
      git clone "${url}" "${target}"
    fi
  done
}

show_status() {
  require_git

  for repo in "${REPOS[@]}"; do
    local name target commit branch
    name="$(repo_name "${repo}")"
    target="${EXTERNAL_DIR}/${name}"

    if [[ ! -d "${target}/.git" ]]; then
      echo "missing: ${name}"
      continue
    fi

    commit="$(git -C "${target}" rev-parse --short HEAD)"
    branch="$(git -C "${target}" branch --show-current || true)"
    if [[ -z "${branch}" ]]; then
      branch="detached"
    fi
    echo "present: ${name} ${commit} ${branch}"
  done
}

clean_repos() {
  local assume_yes="false"

  while (($# > 0)); do
    case "$1" in
      --yes)
        assume_yes="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown clean option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  if [[ ! -e "${EXTERNAL_DIR}" ]]; then
    echo "clean: ${EXTERNAL_DIR} does not exist"
    return
  fi

  if [[ "${assume_yes}" != "true" ]]; then
    read -r -p "Remove ${EXTERNAL_DIR}? [y/N] " answer
    case "${answer}" in
      y|Y|yes|YES)
        ;;
      *)
        echo "abort: clean cancelled"
        return
        ;;
    esac
  fi

  rm -rf "${EXTERNAL_DIR}"
  echo "clean: removed ${EXTERNAL_DIR}"
}

main() {
  if (($# == 0)); then
    usage
    exit 1
  fi

  local command="$1"
  shift

  case "${command}" in
    download)
      download_repos "$@"
      ;;
    status)
      show_status "$@"
      ;;
    clean)
      clean_repos "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "error: unknown command: ${command}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
