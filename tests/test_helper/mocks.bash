# Mock docker command — captures all invocations for assertion
# Each call appends args to DOCKER_CALLS file (one line per call)
# Stdin is captured to DOCKER_STDIN_N files (one per call)
# Output is read from DOCKER_MOCK_OUTPUT if set, otherwise empty
# Exit code is read from DOCKER_MOCK_EXIT_CODES array file (one per line, per call)
docker() {
  local call_num
  call_num=$(wc -l < "${DOCKER_CALLS}" | tr -d ' ')
  echo "$*" >> "${DOCKER_CALLS}"

  # Capture stdin if available
  if [[ ! -t 0 ]]; then
    cat > "${BATS_TEST_TMPDIR}/docker_stdin_${call_num}"
  fi

  # Per-invocation exit code: read line N from exit codes file
  local exit_code=0
  if [[ -f "${DOCKER_MOCK_EXIT_CODES}" ]]; then
    local line
    line=$(sed -n "$((call_num + 1))p" "${DOCKER_MOCK_EXIT_CODES}")
    exit_code="${line:-0}"
  fi

  if [[ -f "${DOCKER_MOCK_OUTPUT:-/dev/null}" ]] && [[ "${exit_code}" -eq 0 ]]; then
    cat "${DOCKER_MOCK_OUTPUT}"
  fi

  return "${exit_code}"
}
export -f docker

# Mock timeout/gtimeout — execute command directly without timeout enforcement
# This ensures the mock docker function (exported via export -f) is reachable,
# since the real timeout binary uses execvp which bypasses bash functions.
timeout() {
  shift  # discard the timeout seconds argument
  "$@"
}
export -f timeout

gtimeout() {
  shift
  "$@"
}
export -f gtimeout

setup_mocks() {
  export DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker_calls"
  export DOCKER_MOCK_OUTPUT="${BATS_TEST_TMPDIR}/docker_mock_output"
  export DOCKER_MOCK_EXIT_CODES="${BATS_TEST_TMPDIR}/docker_mock_exit_codes"
  touch "${DOCKER_CALLS}"

  # Default: all calls succeed (file is empty → fallback to 0)
  touch "${DOCKER_MOCK_EXIT_CODES}"

  # Mock GITHUB_OUTPUT
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
  touch "${GITHUB_OUTPUT}"

  # Mock GITHUB_WORKSPACE
  export GITHUB_WORKSPACE="${BATS_TEST_TMPDIR}/workspace"
  mkdir -p "${GITHUB_WORKSPACE}"
}

teardown_mocks() {
  rm -rf "${BATS_TEST_TMPDIR}"
}

# Helper: get the Nth docker call (0-indexed)
docker_call() {
  sed -n "$((${1} + 1))p" "${DOCKER_CALLS}"
}

# Helper: count docker invocations
docker_call_count() {
  wc -l < "${DOCKER_CALLS}" | tr -d ' '
}

# Helper: get stdin captured for the Nth docker call (0-indexed)
docker_stdin() {
  local file="${BATS_TEST_TMPDIR}/docker_stdin_${1}"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  fi
}

# Helper: set per-call exit codes (pass as arguments: 0 0 1 → call0=0, call1=0, call2=1)
set_docker_exit_codes() {
  printf '%s\n' "$@" > "${DOCKER_MOCK_EXIT_CODES}"
}

# Helper: read the captured GITHUB_OUTPUT result value
github_output_result() {
  # Parse multiline output format: result<<DELIM\n...content...\nDELIM
  local in_result=false
  local delimiter=""
  local result=""
  while IFS= read -r line; do
    if [[ "${in_result}" == false ]] && [[ "${line}" =~ ^result\<\<(.+)$ ]]; then
      delimiter="${BASH_REMATCH[1]}"
      in_result=true
    elif [[ "${in_result}" == true ]] && [[ "${line}" == "${delimiter}" ]]; then
      in_result=false
    elif [[ "${in_result}" == true ]]; then
      if [[ -n "${result}" ]]; then
        result="${result}"$'\n'"${line}"
      else
        result="${line}"
      fi
    fi
  done < "${GITHUB_OUTPUT}"
  echo "${result}"
}
