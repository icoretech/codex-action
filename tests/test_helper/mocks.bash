# Mock docker command — captures all invocations for assertion
# Each call appends args to DOCKER_CALLS file (one line per call)
# Stdin is captured to DOCKER_STDIN_N files (one per call)
# Output is written to the -o output file (via -v mount) if present,
# otherwise to stdout.
# Exit code is read from DOCKER_MOCK_EXIT_CODES array file (one per line, per call)
docker() {
  local fake_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  case "$1" in
    inspect)
      printf '%s\n' "$*" >> "$DOCKER_LIFECYCLE"
      [[ -f "$BATS_TEST_TMPDIR/container_present" ]] || return 1
      [[ "${DOCKER_MOCK_INSPECT_FAILURE:-}" != true ]] || return 1
      printf '%s %s /%s\n' "$fake_id" "${DOCKER_MOCK_OWNER_OVERRIDE:-$(cat "$BATS_TEST_TMPDIR/container_owner")}" "$(cat "$BATS_TEST_TMPDIR/container_name")"
      return 0 ;;
    rm)
      printf '%s\n' "$*" >> "$DOCKER_LIFECYCLE"
      [[ "${DOCKER_MOCK_REMOVE_FAILURE:-}" != true ]] || return 1
      command rm -f "$BATS_TEST_TMPDIR/container_present"
      return 0 ;;
    start)
      printf '%s\n' "$*" >> "$DOCKER_LIFECYCLE"
      local invocation
      invocation=$(cat "$BATS_TEST_TMPDIR/container_call")
      cat > "${BATS_TEST_TMPDIR}/docker_stdin_${invocation}"
      return "$(cat "$BATS_TEST_TMPDIR/container_exit")" ;;
  esac
  local call_num
  call_num=$(wc -l < "${DOCKER_CALLS}" | tr -d ' ')
  echo "$*" >> "${DOCKER_CALLS}"
  printf '%s\0' "$@" > "${BATS_TEST_TMPDIR}/docker_argv_${call_num}"
  # Read through a child process so an unexported shell variable cannot pass.
  bash -c 'printf "%s" "${OPENAI_API_KEY:-}"' > "${BATS_TEST_TMPDIR}/docker_api_key_${call_num}"
  local owned_mount
  for owned_mount in "$@"; do
    case "$owned_mount" in
      *:/home/codex|*:/tmp/codex_out) printf '%s\n' "${owned_mount%%:*}" >> "$BATS_TEST_TMPDIR/owned_mounts" ;;
    esac
  done

  # Resolve the declared container Git config through the actual bind mounts.
  local arg container_gitconfig="" host_gitconfig="" source target
  for arg in "$@"; do
    [[ "$arg" == GIT_CONFIG_GLOBAL=* ]] && container_gitconfig=${arg#GIT_CONFIG_GLOBAL=}
  done
  if [[ -n "$container_gitconfig" ]]; then
    for arg in "$@"; do
      if [[ "$arg" == *:/* ]]; then
        source=${arg%%:*}
        target=${arg#*:}
        if [[ "$container_gitconfig" == "$target/"* ]]; then
          host_gitconfig="$source/${container_gitconfig#"$target/"}"
        fi
      fi
    done
    printf '%s' "$host_gitconfig" > "${BATS_TEST_TMPDIR}/docker_gitconfig_path_${call_num}"
    stat -c %a "$host_gitconfig" 2>/dev/null > "${BATS_TEST_TMPDIR}/docker_gitconfig_mode_${call_num}" || stat -f %Lp "$host_gitconfig" > "${BATS_TEST_TMPDIR}/docker_gitconfig_mode_${call_num}"
    GIT_CONFIG_GLOBAL="$host_gitconfig" GIT_CONFIG_NOSYSTEM=1 git config --global --get-all safe.directory > "${BATS_TEST_TMPDIR}/docker_gitconfig_safe_dirs_${call_num}"
  fi

  if [[ "${DOCKER_MOCK_RUNTIME_AUDIT:-}" == true ]]; then
    local mount auth_path=""
    for mount in "$@"; do
      case "$mount" in
        *:/home/codex/.codex) auth_path=${mount%:/home/codex/.codex}; printf '%s\n' "$auth_path" >> "$RUNTIME_PATHS" ;;
        *:/home/codex) auth_path=${mount%:/home/codex}/.codex; printf '%s\n' "${mount%:/home/codex}" >> "$RUNTIME_PATHS" ;;
        *:/tmp/codex_out) printf '%s\n' "${mount%:/tmp/codex_out}" >> "$RUNTIME_PATHS" ;;
      esac
    done
    audit_runtime_modes docker_start
    if [[ "$*" == *"codex-bootstrap api-key-login"* ]]; then
      # The real CLI writes private credentials even before a later failure.
      (umask 077; printf '{}' > "${auth_path}/auth.json")
    fi
  fi

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

  if [[ "$1" == create ]]; then
    local previous=""
    for arg in "$@"; do
      case "$previous" in
        --cidfile) printf '%s\n' "$fake_id" > "$arg" ;;
        --name) printf '%s' "$arg" > "$BATS_TEST_TMPDIR/container_name" ;;
        --label) printf '%s' "${arg#*=}" > "$BATS_TEST_TMPDIR/container_owner" ;;
      esac
      previous=$arg
    done
    : > "$BATS_TEST_TMPDIR/container_present"
    printf '%s' "$call_num" > "$BATS_TEST_TMPDIR/container_call"
    printf '%s' "$exit_code" > "$BATS_TEST_TMPDIR/container_exit"
  fi

  # Emit mock stderr if configured
  if [[ -f "${DOCKER_MOCK_STDERR:-/dev/null}" ]]; then
    cat "${DOCKER_MOCK_STDERR}" >&2
  fi

  if [[ -f "${DOCKER_MOCK_OUTPUT:-/dev/null}" ]] && [[ "${exit_code}" -eq 0 ]]; then
    # Detect the -v mount for /tmp/codex_out and write mock output to the
    # result file, simulating the -o flag behavior inside the container.
    local host_output_dir=""
    local args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      if [[ "${args[$i]}" == -v ]] && [[ "${args[$((i+1))]:-}" == *":/tmp/codex_out"* ]]; then
        host_output_dir="${args[$((i+1))]%%:*}"
        break
      fi
    done

    if [[ -n "${host_output_dir}" ]]; then
      cat "${DOCKER_MOCK_OUTPUT}" > "${host_output_dir}/result.txt"
    else
      cat "${DOCKER_MOCK_OUTPUT}"
    fi
  fi

  if [[ "${DOCKER_MOCK_RUNTIME_AUDIT:-}" == true ]]; then
    audit_runtime_modes docker_end
  fi
  [[ "$1" != create ]] || return 0
  return "${exit_code}"
}
export -f docker

audit_runtime_modes() {
  local root path mode kind
  while IFS= read -r root; do
    [[ -d "$root" ]] || continue
    while IFS= read -r path; do
      mode=$(stat -c %a "$path" 2>/dev/null || stat -f %Lp "$path")
      kind="file"
      [[ -d "$path" ]] && kind=directory
      printf '%s %s %s\n' "$1" "$kind" "$mode" >> "$RUNTIME_MODES"
    done < <(find "$root" -type d -o -type f)
  done < "$RUNTIME_PATHS"
}
export -f audit_runtime_modes

rm() {
  if [[ "${DOCKER_MOCK_RUNTIME_AUDIT:-}" == true && -f "${RUNTIME_PATHS}" ]]; then
    local arg root
    for arg in "$@"; do
      while IFS= read -r root; do
        if [[ "$arg" == "$root" && -d "$root" ]]; then
          audit_runtime_modes before_remove
        fi
      done < "$RUNTIME_PATHS"
    done
  fi
  command rm "$@"
}
export -f rm

# Mock timeout/gtimeout — execute command directly without timeout enforcement
# This ensures the mock docker function (exported via export -f) is reachable,
# since the real timeout binary uses execvp which bypasses bash functions.
timeout() {
  if [[ "$1" == -k ]]; then shift 2; fi
  if [[ "$3" != inspect && "$3" != rm ]]; then printf 'timeout %s\n' "$1" >> "$TIMEOUT_CALLS"; fi
  shift  # discard the timeout seconds argument
  "$@"
}
export -f timeout

gtimeout() {
  if [[ "$1" == -k ]]; then shift 2; fi
  if [[ "$3" != inspect && "$3" != rm ]]; then printf 'gtimeout %s\n' "$1" >> "$TIMEOUT_CALLS"; fi
  shift
  "$@"
}
export -f gtimeout

setup_mocks() {
  unset DOCKER_MOCK_RUNTIME_AUDIT REMOVE_TIMEOUT_MOCKS PATH_WITHOUT_TIMEOUT RUNTIME_ACQUISITIONS
  unset DOCKER_MOCK_OWNER_OVERRIDE DOCKER_MOCK_INSPECT_FAILURE DOCKER_MOCK_REMOVE_FAILURE
  export DOCKER_LIFECYCLE="${BATS_TEST_TMPDIR}/docker_lifecycle"
  touch "$DOCKER_LIFECYCLE"
  export TIMEOUT_CALLS="${BATS_TEST_TMPDIR}/timeout_calls"
  touch "$TIMEOUT_CALLS"
  export RUNTIME_PATHS="${BATS_TEST_TMPDIR}/runtime_paths"
  export RUNTIME_MODES="${BATS_TEST_TMPDIR}/runtime_modes"
  touch "$RUNTIME_PATHS" "$RUNTIME_MODES"
  export DOCKER_CALLS="${BATS_TEST_TMPDIR}/docker_calls"
  export DOCKER_MOCK_OUTPUT="${BATS_TEST_TMPDIR}/docker_mock_output"
  export DOCKER_MOCK_STDERR="${BATS_TEST_TMPDIR}/docker_mock_stderr"
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

# Isolate timer lookup from installed tools without hiding action dependencies.
setup_path_without_timeout() {
  local utility executable
  export PATH_WITHOUT_TIMEOUT="${BATS_TEST_TMPDIR}/no-timeout-bin"
  mkdir "$PATH_WITHOUT_TIMEOUT"
  for utility in bash base64 cat chmod date find git grep head id mkdir mktemp rm sed stat tail tr wc; do
    executable=$(type -P "$utility")
    ln -s "$executable" "$PATH_WITHOUT_TIMEOUT/$utility"
  done
}

# Enable with VERIFY_CODEX_CLI=1 to check the installed action-pinned image.
# Empty stdin reaches config/parser validation without requesting a model turn.
assert_installed_exec_parser() {
  [[ "${VERIFY_CODEX_CLI:-}" == 1 ]] || return 0
  local arg image="" docker_binary contract_home owner rc=0
  local cli_args=()
  docker_binary=$(type -P docker)
  while IFS= read -r -d '' arg; do
    if [[ -n "$image" ]]; then
      cli_args+=("$arg")
    elif [[ "$arg" == ghcr.io/icoretech/codex-docker:* ]]; then
      image=$arg
    fi
  done < "${BATS_TEST_TMPDIR}/docker_argv_1"
  "$docker_binary" image inspect "$image" >/dev/null
  contract_home="${BATS_TEST_TMPDIR}/cli-home"
  (umask 077; mkdir -p "$contract_home/.codex")
  owner="codex-action-test-${BATS_TEST_NUMBER}-$$"
  "$docker_binary" run --rm --pull never --network none --label "codex-action-test=$owner" \
    --user "$(id -u):$(id -g)" -e HOME=/home/codex -e CODEX_HOME=/home/codex/.codex \
    -v "$contract_home:/home/codex" "$image" "${cli_args[@]}" </dev/null \
    > "${BATS_TEST_TMPDIR}/cli.stdout" 2> "${BATS_TEST_TMPDIR}/cli.stderr" || rc=$?
  if [[ "$rc" -ne 1 ]]; then
    sed -n '/^error:/p' "${BATS_TEST_TMPDIR}/cli.stderr" >&2
    return 1
  fi
  grep -q '^No prompt provided via stdin\.$' "${BATS_TEST_TMPDIR}/cli.stderr"
  [ -z "$("$docker_binary" ps -aq --filter "label=codex-action-test=$owner")" ]
}

teardown_mocks() {
  unset DOCKER_MOCK_RUNTIME_AUDIT
  local owned_path
  if [[ -f "$BATS_TEST_TMPDIR/owned_mounts" ]]; then
    while IFS= read -r owned_path; do
      command rm -rf "$owned_path"
    done < "$BATS_TEST_TMPDIR/owned_mounts"
  fi
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
