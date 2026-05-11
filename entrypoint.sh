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
  rm -f "${gitconfig_file:-}" 2>/dev/null || true
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
codex_config_toml="${INPUT_CODEX_CONFIG_TOML:-}"
# renovate: datasource=docker depName=ghcr.io/icoretech/codex-docker
image_version="${INPUT_IMAGE_VERSION:-0.130.0}"
model="${INPUT_MODEL:-}"
reasoning_effort="${INPUT_REASONING_EFFORT:-}"
network_access="${INPUT_NETWORK_ACCESS:-false}"
sandbox="${INPUT_SANDBOX:-full-auto}"
quiet="${INPUT_QUIET:-true}"
timeout_seconds="${INPUT_TIMEOUT:-300}"

image="ghcr.io/icoretech/codex-docker:${image_version}"

# --- Mask secrets from workflow logs ---

if [[ -n "${openai_api_key}" ]]; then
  echo "::add-mask::${openai_api_key}"
fi
if [[ -n "${codex_config}" ]]; then
  echo "::add-mask::${codex_config}"
fi
if [[ -n "${codex_config_toml}" ]]; then
  echo "::add-mask::${codex_config_toml}"
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

case "${sandbox}" in
  full-auto|danger-full-access) ;;
  *) die "sandbox must be 'full-auto' or 'danger-full-access', got '${sandbox}'" ;;
esac

# Validate base64 if codex_config is provided
if [[ -n "${codex_config}" ]]; then
  if ! echo "${codex_config}" | b64decode >/dev/null 2>&1; then
    die "codex_config is not valid base64"
  fi
fi

# Validate base64 if codex_config_toml is provided
if [[ -n "${codex_config_toml}" ]]; then
  if ! echo "${codex_config_toml}" | b64decode >/dev/null 2>&1; then
    die "codex_config_toml is not valid base64"
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

# --- Write optional config.toml ---

if [[ -n "${codex_config_toml}" ]]; then
  echo "${codex_config_toml}" | b64decode > "${auth_dir}/config.toml"
fi

# --- Build prompt ---

prompt_file=$(mktemp)

# When network access is disabled, prepend a policy instruction to the prompt.
network_policy=""
if [[ "${network_access}" != "true" ]]; then
  network_policy="NETWORK POLICY: You MUST NOT make any network requests. Do not use curl, wget, fetch, or any tool that accesses the internet. Work exclusively with local files and repositories already available in the workspace.

"
fi

if [[ -n "${input_text}" ]]; then
  printf '%s%s\n\n---\n\n%s' "${network_policy}" "${prompt}" "${input_text}" > "${prompt_file}"
else
  printf '%s%s' "${network_policy}" "${prompt}" > "${prompt_file}"
fi

# --- Run codex ---

output_dir=$(mktemp -d)
chmod 777 "${output_dir}"
output_file="${output_dir}/result.txt"

# Pre-configure git safe.directory so codex (running as a different uid inside
# Docker) can operate on repos cloned by the runner without "dubious ownership"
# errors. The file is mounted into the container and referenced via
# GIT_CONFIG_GLOBAL.
gitconfig_file="${GITHUB_WORKSPACE}/.codex-gitconfig"
printf '[safe]\n\tdirectory = *\n' > "${gitconfig_file}"
chmod 644 "${gitconfig_file}"

cmd=(docker run --rm -i
  -e CODEX_HOME=/home/codex/.codex
  -e GIT_CONFIG_GLOBAL=/workspace/.codex-gitconfig)

# When quiet mode is enabled, suppress verbose codex output (tool calls, grep
# results, file reads) from workflow logs.  --json routes exec output to stdout
# (which the action discards) and RUST_LOG=off silences tracing on stderr.
if [[ "${quiet}" == "true" ]]; then
  cmd+=(-e RUST_LOG=off)
fi

cmd+=(
  -v "${auth_dir}:/home/codex/.codex"
  -v "${GITHUB_WORKSPACE}:/workspace"
  -v "${output_dir}:/tmp/codex_out"
  "${image}"
  exec --ephemeral --skip-git-repo-check
  --full-auto)

# Override the sandbox when the user requests danger-full-access (recommended for
# CI/Docker where the container itself is already an isolation boundary).
if [[ "${sandbox}" == "danger-full-access" ]]; then
  cmd+=(--sandbox danger-full-access)
fi

cmd+=(-C /workspace -o /tmp/codex_out/result.txt)

if [[ "${quiet}" == "true" ]]; then
  cmd+=(--json)
fi

[[ -n "${model}" ]] && cmd+=(--model "${model}")
[[ -n "${reasoning_effort}" ]] && cmd+=(-c "model_reasoning_effort=\"${reasoning_effort}\"")

# Pipe prompt via stdin ("-" reads prompt from stdin).
# In quiet mode, stdout (JSONL events) is discarded and stderr is captured to a
# temp file so that critical errors (quota exceeded, auth failures, etc.) can be
# surfaced even when verbose logging is off.
if [[ "${quiet}" == "true" ]]; then
  stderr_log=$(mktemp)
  if ! run_with_timeout "${timeout_seconds}" "${cmd[@]}" - < "${prompt_file}" >/dev/null 2>"${stderr_log}"; then
    # Surface the last few lines of stderr so users can diagnose the failure
    if [[ -s "${stderr_log}" ]]; then
      echo "::group::Codex stderr output"
      tail -20 "${stderr_log}"
      echo "::endgroup::"
    fi
    rm -f "${stderr_log}" 2>/dev/null || true
    echo "::error::Codex execution failed (image: ${image})"
    exit 1
  fi
  rm -f "${stderr_log}" 2>/dev/null || true
else
  if ! run_with_timeout "${timeout_seconds}" "${cmd[@]}" - < "${prompt_file}"; then
    echo "::error::Codex execution failed (image: ${image})"
    exit 1
  fi
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
