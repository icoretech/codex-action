#!/usr/bin/env bash
set -euo pipefail

# --- Helpers ---

die() {
  echo "::error::$1" >&2
  exit 1
}

cleanup() {
  # auth_dir may contain files owned by the container user (uid 1000);
  # chmod before removal so the runner user can delete them.
  for dir in "${auth_dir:-}" "${output_dir:-}"; do
    if [[ -d "${dir}" ]]; then
      chmod -R 777 "${dir}" 2>/dev/null || true
      rm -rf "${dir}" 2>/dev/null || true
    fi
  done
  rm -f "${prompt_file:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Cross-platform base64 decode (GNU uses -d, macOS uses -D)
b64decode() {
  if base64 --help 2>&1 | grep -q '\-d'; then
    base64 -d
  else
    base64 -D
  fi
}

# Cross-platform timeout (GNU coreutils on Linux, gtimeout on macOS via brew)
run_with_timeout() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "${seconds}" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${seconds}" "$@"
  else
    "$@"
  fi
}

# --- Read inputs ---

prompt="${INPUT_PROMPT:-}"
input_text="${INPUT_INPUT_TEXT:-}"
openai_api_key="${INPUT_OPENAI_API_KEY:-}"
codex_config="${INPUT_CODEX_CONFIG:-}"
image_version="${INPUT_IMAGE_VERSION:-0.114.0}"
model="${INPUT_MODEL:-}"
reasoning_effort="${INPUT_REASONING_EFFORT:-}"
timeout_seconds="${INPUT_TIMEOUT:-300}"

image="ghcr.io/icoretech/codex-docker:${image_version}"

# --- Mask secrets from workflow logs ---

if [[ -n "${openai_api_key}" ]]; then
  echo "::add-mask::${openai_api_key}"
fi
if [[ -n "${codex_config}" ]]; then
  echo "::add-mask::${codex_config}"
fi

# --- Validate inputs ---

if [[ -z "${prompt}" ]]; then
  die "prompt is required"
fi

if [[ -n "${openai_api_key}" && -n "${codex_config}" ]]; then
  die "Exactly one of openai_api_key or codex_config must be provided, got both"
fi

if [[ -z "${openai_api_key}" && -z "${codex_config}" ]]; then
  die "Exactly one of openai_api_key or codex_config must be provided, got neither"
fi

# Validate base64 if codex_config is provided
if [[ -n "${codex_config}" ]]; then
  if ! echo "${codex_config}" | b64decode >/dev/null 2>&1; then
    die "codex_config is not valid base64"
  fi
fi

# --- Setup auth ---

auth_dir=$(mktemp -d)
chmod 777 "${auth_dir}"

if [[ -n "${openai_api_key}" ]]; then
  # API key auth: run codex-bootstrap to write credentials
  docker run --rm -i \
    -e CODEX_HOME=/home/codex/.codex \
    -e "OPENAI_API_KEY=${openai_api_key}" \
    -v "${auth_dir}:/home/codex/.codex" \
    "${image}" \
    codex-bootstrap api-key-login
elif [[ -n "${codex_config}" ]]; then
  # Config auth: decode and write auth.json
  echo "${codex_config}" | b64decode > "${auth_dir}/auth.json"
fi

# --- Build prompt ---

prompt_file=$(mktemp)
if [[ -n "${input_text}" ]]; then
  printf '%s\n\n---\n\n%s' "${prompt}" "${input_text}" > "${prompt_file}"
else
  printf '%s' "${prompt}" > "${prompt_file}"
fi

# --- Run codex ---

output_dir=$(mktemp -d)
chmod 777 "${output_dir}"
output_file="${output_dir}/result.txt"

cmd=(docker run --rm -i
  -e CODEX_HOME=/home/codex/.codex
  -v "${auth_dir}:/home/codex/.codex"
  -v "${GITHUB_WORKSPACE}:/workspace"
  -v "${output_dir}:/tmp/codex_out"
  "${image}"
  exec --ephemeral --skip-git-repo-check
  --full-auto -C /workspace
  -o /tmp/codex_out/result.txt)

[[ -n "${model}" ]] && cmd+=(--model "${model}")
[[ -n "${reasoning_effort}" ]] && cmd+=(-c "model_reasoning_effort=\"${reasoning_effort}\"")

# Pipe prompt via stdin ("-" reads prompt from stdin).
# Stderr passes through to workflow logs.
if ! run_with_timeout "${timeout_seconds}" "${cmd[@]}" - < "${prompt_file}"; then
  echo "::error::Codex execution failed (image: ${image})"
  exit 1
fi

# --- Capture output ---

delimiter="EOF_$(date +%s%N)"
{
  echo "result<<${delimiter}"
  cat "${output_file}"
  # Ensure a trailing newline before the delimiter
  echo ""
  echo "${delimiter}"
} >> "${GITHUB_OUTPUT}"
