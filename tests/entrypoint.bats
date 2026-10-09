#!/usr/bin/env bats

setup() {
  load 'test_helper/mocks'
  setup_mocks

  # Default valid inputs
  export INPUT_PROMPT="Summarize these changes"
  export INPUT_INPUT_TEXT=""
  export INPUT_OPENAI_API_KEY="sk-test-key-12345"
  export INPUT_CODEX_CONFIG=""
  export INPUT_CODEX_CONFIG_TOML=""
  export INPUT_IMAGE_VERSION="0.115.0"
  export INPUT_MODEL=""
  export INPUT_REASONING_EFFORT=""
  export INPUT_NETWORK_ACCESS="true"
  export INPUT_QUIET="false"
  export INPUT_TIMEOUT="300"
  unset OPENAI_API_KEY

  # Set mock docker to return some output
  echo "Test output from codex" > "${DOCKER_MOCK_OUTPUT}"
}

teardown() {
  teardown_mocks
}

# --- Validation Tests ---

@test "fails when neither auth method is provided" {
  export INPUT_OPENAI_API_KEY=""
  export INPUT_CODEX_CONFIG=""
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Exactly one of openai_api_key or codex_config must be provided"* ]]
}

@test "fails when both auth methods are provided" {
  export INPUT_OPENAI_API_KEY="sk-test-key"
  export INPUT_CODEX_CONFIG="dGVzdA=="
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Exactly one of openai_api_key or codex_config must be provided"* ]]
}

@test "fails when prompt is empty" {
  export INPUT_PROMPT=""
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"prompt is required"* ]]
}

@test "fails when codex_config is invalid base64" {
  export INPUT_OPENAI_API_KEY=""
  export INPUT_CODEX_CONFIG="!!!not-base64!!!"
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"codex_config is not valid base64"* ]]
}

# --- Auth Tests ---

run_recording_runtime_acquisition() {
  export RUNTIME_ACQUISITIONS="${BATS_TEST_TMPDIR}/runtime_acquisitions"
  : > "$RUNTIME_ACQUISITIONS"
  run bash -c '
    mktemp() { printf "acquired\n" >> "$RUNTIME_ACQUISITIONS"; command mktemp "$@"; }
    export -f mktemp
    if [[ -n "${PATH_WITHOUT_TIMEOUT:-}" ]]; then PATH=$PATH_WITHOUT_TIMEOUT; fi
    if [[ "${REMOVE_TIMEOUT_MOCKS:-}" == true ]]; then unset -f timeout gtimeout; fi
    exec bash entrypoint.sh
  '
}

assert_invalid_timeout() {
  local auth
  export INPUT_TIMEOUT="$1"
  for auth in api config; do
    : > "$DOCKER_CALLS"
    if [[ "$auth" == config ]]; then
      export INPUT_OPENAI_API_KEY="" INPUT_CODEX_CONFIG=e30=
    fi
    run_recording_runtime_acquisition
    [ "$status" -eq 1 ]
    [[ "$output" == *"timeout must be a positive integer number of seconds"* ]]
    [ "$(docker_call_count)" -eq 0 ]
    [ ! -s "$RUNTIME_ACQUISITIONS" ]
  done
}

@test "timeout: rejects zero before setup and Docker" { assert_invalid_timeout 0; }
@test "timeout: rejects zero-padded zero before setup and Docker" { assert_invalid_timeout 000; }
@test "timeout: rejects negative before setup and Docker" { assert_invalid_timeout -1; }
@test "timeout: rejects fraction before setup and Docker" { assert_invalid_timeout 1.5; }
@test "timeout: rejects unit suffix before setup and Docker" { assert_invalid_timeout 1s; }
@test "timeout: rejects text before setup and Docker" { assert_invalid_timeout abc; }
@test "timeout: rejects whitespace before setup and Docker" { assert_invalid_timeout ' '; }

@test "timeout: missing timeout and gtimeout fails before setup and bootstrap" {
  setup_path_without_timeout
  export REMOVE_TIMEOUT_MOCKS=true
  run_recording_runtime_acquisition
  [ "$status" -eq 1 ]
  [[ "$output" == *"timeout or gtimeout is required"* ]]
  [ "$(docker_call_count)" -eq 0 ]
  [ ! -s "$RUNTIME_ACQUISITIONS" ]
}

@test "timeout: defaults to 300 when unset or empty" {
  unset INPUT_TIMEOUT
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$TIMEOUT_CALLS")" = 'timeout 300' ]
  : > "$TIMEOUT_CALLS"
  export INPUT_TIMEOUT=''
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$TIMEOUT_CALLS")" = 'timeout 300' ]
}

@test "timeout: positive integer uses timeout before gtimeout" {
  export INPUT_TIMEOUT=600
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$TIMEOUT_CALLS")" = 'timeout 600' ]
}

@test "timeout: normalizes zero-padded positive integer as decimal" {
  export INPUT_TIMEOUT=0008
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$TIMEOUT_CALLS")" = 'timeout 8' ]
}

@test "timeout: gtimeout fallback retains bounded invocation" {
  setup_path_without_timeout
  run bash -c 'unset -f timeout; PATH=$PATH_WITHOUT_TIMEOUT; exec bash entrypoint.sh'
  [ "$status" -eq 0 ]
  [ "$(cat "$TIMEOUT_CALLS")" = 'gtimeout 300' ]
}

@test "api key auth: runs codex-bootstrap then exec" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 2 ]

  # First call: bootstrap api-key-login
  [[ "$(docker_call 0)" == *"codex-bootstrap api-key-login"* ]]
  [[ "$(docker_call 0)" == *"-e OPENAI_API_KEY "* ]]
  [ "$(cat "${BATS_TEST_TMPDIR}/docker_api_key_0")" = "${INPUT_OPENAI_API_KEY}" ]
  assert_api_key_absent_from_docker_argv

  # Second call: exec
  [[ "$(docker_call 1)" == *"exec --ephemeral --skip-git-repo-check"* ]]
  [[ "$(docker_call 1)" == *"--full-auto"* ]]
}

assert_api_key_absent_from_docker_argv() {
  local argv_file arg
  for argv_file in "${BATS_TEST_TMPDIR}"/docker_argv_*; do
    while IFS= read -r -d '' arg; do
      [[ "${arg}" != *"${INPUT_OPENAI_API_KEY}"* ]] || return 1
      [[ "${arg}" != OPENAI_API_KEY=* ]] || return 1
    done < "${argv_file}"
  done
}

@test "api key auth: credential value is absent from every Docker argument" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 2 ]
  assert_api_key_absent_from_docker_argv
}

@test "api key auth: selected input replaces inherited key in child environment only" {
  export OPENAI_API_KEY="different-inherited-fixture"
  export INPUT_OPENAI_API_KEY="synthetic key with spaces"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 2 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/docker_api_key_0")" = "${INPUT_OPENAI_API_KEY}" ]
  assert_api_key_absent_from_docker_argv
}

@test "config auth: decodes base64 and runs single exec" {
  export INPUT_OPENAI_API_KEY=""
  local config_content
  config_content=$(cat tests/fixtures/sample_auth.json)
  export INPUT_CODEX_CONFIG
  INPUT_CODEX_CONFIG=$(echo "${config_content}" | base64)

  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 1 ]
  [[ "$(docker_call 0)" == *"exec --ephemeral --skip-git-repo-check"* ]]
}

assert_private_runtime_lifecycle() {
  local phase kind mode path expected
  [ -s "$RUNTIME_MODES" ]
  grep -q '^docker_start ' "$RUNTIME_MODES"
  grep -q '^before_remove ' "$RUNTIME_MODES"
  while read -r phase kind mode; do
    case "$kind" in
      directory) expected=700 ;;
      file) expected=600 ;;
    esac
    if [[ "$mode" != "$expected" ]]; then
      printf '%s %s mode=%s expected=%s\n' "$phase" "$kind" "$mode" "$expected" >&2
      return 1
    fi
  done < "$RUNTIME_MODES"
  while IFS= read -r path; do
    [ ! -e "$path" ] || return 1
  done < "$RUNTIME_PATHS"
}

check_private_runtime() {
  local mask="$1" auth_method="$2" outcome="$3"
  export DOCKER_MOCK_RUNTIME_AUDIT=true
  export INPUT_CODEX_CONFIG_TOML
  INPUT_CODEX_CONFIG_TOML=$(printf 'model = "example"\n' | base64)
  if [[ "$auth_method" == config ]]; then
    export INPUT_OPENAI_API_KEY=""
    export INPUT_CODEX_CONFIG
    INPUT_CODEX_CONFIG=$(printf '{}' | base64)
  fi
  case "$outcome" in
    bootstrap_failure) set_docker_exit_codes 1 ;;
    exec_failure)
      if [[ "$auth_method" == config ]]; then
        set_docker_exit_codes 1
      else
        set_docker_exit_codes 0 1
      fi
      ;;
  esac
  run bash -c 'umask "$1"; exec bash entrypoint.sh' _ "$mask"
  if [[ "$outcome" == success ]]; then
    [ "$status" -eq 0 ]
  else
    [ "$status" -ne 0 ]
  fi
  assert_private_runtime_lifecycle
  [[ "$(docker_call 0)" == *"--user $(id -u):$(id -g) "* ]]
  if [[ "$(docker_call_count)" -eq 2 ]]; then
    [[ "$(docker_call 1)" == *"--user $(id -u):$(id -g) "* ]]
  fi
}

@test "private runtime: config auth at umask 022" {
  check_private_runtime 022 config success
}

@test "private runtime: config auth at umask 077" {
  check_private_runtime 077 config success
}

@test "private runtime: API bootstrap and exec at umask 022" {
  check_private_runtime 022 api success
}

@test "private runtime: API bootstrap and exec at umask 077" {
  check_private_runtime 077 api success
}

@test "private runtime: bootstrap failure at umask 022" {
  check_private_runtime 022 api bootstrap_failure
}

@test "private runtime: bootstrap failure at umask 077" {
  check_private_runtime 077 api bootstrap_failure
}

@test "private runtime: exec failure at umask 022" {
  check_private_runtime 022 api exec_failure
}

@test "private runtime: exec failure at umask 077" {
  check_private_runtime 077 api exec_failure
}

@test "private runtime: config exec failure at umask 022" {
  check_private_runtime 022 config exec_failure
}

@test "private runtime: config exec failure at umask 077" {
  check_private_runtime 077 config exec_failure
}

# --- Config TOML Tests ---

@test "codex_config_toml: decoded and written alongside api key auth" {
  export INPUT_CODEX_CONFIG_TOML
  INPUT_CODEX_CONFIG_TOML=$(echo 'model = "o4-mini"' | base64)
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 2 ]
}

@test "codex_config_toml: decoded and written alongside config auth" {
  export INPUT_OPENAI_API_KEY=""
  local config_content
  config_content=$(cat tests/fixtures/sample_auth.json)
  export INPUT_CODEX_CONFIG
  INPUT_CODEX_CONFIG=$(echo "${config_content}" | base64)
  export INPUT_CODEX_CONFIG_TOML
  INPUT_CODEX_CONFIG_TOML=$(echo 'model = "o4-mini"' | base64)
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 1 ]
}

@test "fails when codex_config_toml is invalid base64" {
  export INPUT_CODEX_CONFIG_TOML="!!!not-base64!!!"
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"codex_config_toml is not valid base64"* ]]
}

@test "secret masking: codex_config_toml is masked in workflow logs" {
  export INPUT_CODEX_CONFIG_TOML
  INPUT_CODEX_CONFIG_TOML=$(echo "test-toml" | base64)
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::${INPUT_CODEX_CONFIG_TOML}"* ]]
}

# --- Prompt Building Tests ---

@test "prompt only: stdin contains just the prompt" {
  export INPUT_INPUT_TEXT=""
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  # The exec call is docker call 1 (call 0 is bootstrap)
  local stdin_content
  stdin_content=$(docker_stdin 1)
  [[ "${stdin_content}" == "Summarize these changes" ]]
  # No separator present
  [[ "${stdin_content}" != *"---"* ]]
}

@test "prompt + input_text: stdin contains prompt, separator, and input" {
  export INPUT_INPUT_TEXT="Here is the changelog content"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local stdin_content
  stdin_content=$(docker_stdin 1)
  [[ "${stdin_content}" == *"Summarize these changes"* ]]
  [[ "${stdin_content}" == *"---"* ]]
  [[ "${stdin_content}" == *"Here is the changelog content"* ]]
}

# --- Model Flag Tests ---

@test "model flag: passed when set" {
  export INPUT_MODEL="o4-mini"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 1)" == *"--model o4-mini"* ]]
}

@test "model flag: omitted when empty" {
  export INPUT_MODEL=""
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 1)" != *"--model"* ]]
}

# --- Output Tests ---

@test "output: captures multiline result to GITHUB_OUTPUT" {
  printf "Line 1\nLine 2\nLine 3" > "${DOCKER_MOCK_OUTPUT}"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  result=$(github_output_result)
  [[ "${result}" == *"Line 1"* ]]
  [[ "${result}" == *"Line 2"* ]]
  [[ "${result}" == *"Line 3"* ]]
}

@test "output: handles empty codex output gracefully" {
  echo -n "" > "${DOCKER_MOCK_OUTPUT}"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  # GITHUB_OUTPUT should still have the result delimiters
  [[ "$(cat "${GITHUB_OUTPUT}")" == *"result<<"* ]]
}

@test "output: fails when successful exec creates no result file" {
  rm "$DOCKER_MOCK_OUTPUT"
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
}

# --- Error Handling Tests ---

@test "error: non-zero exec exit propagates failure" {
  # Bootstrap (call 0) succeeds, exec (call 1) fails
  set_docker_exit_codes 0 1
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Codex execution failed"* ]]
}

@test "error: bootstrap failure aborts before exec" {
  # Bootstrap (call 0) fails
  set_docker_exit_codes 1
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  # Only one docker call made (bootstrap), exec never reached
  [ "$(docker_call_count)" -eq 1 ]
}

# --- Secret Masking Tests ---

@test "secret masking: api key is masked in workflow logs" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::sk-test-key-12345"* ]]
}

@test "secret masking: codex_config is masked in workflow logs" {
  export INPUT_OPENAI_API_KEY=""
  export INPUT_CODEX_CONFIG
  INPUT_CODEX_CONFIG=$(echo "test-config" | base64)
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"::add-mask::${INPUT_CODEX_CONFIG}"* ]]
}

# --- Reasoning Effort Tests ---

@test "reasoning effort: passed when set" {
  export INPUT_REASONING_EFFORT="low"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 1)" == *'-c model_reasoning_effort="low"'* ]]
}

@test "reasoning effort: omitted when empty" {
  export INPUT_REASONING_EFFORT=""
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 1)" != *"reasoning_effort"* ]]
}

# --- Output Flag Tests ---

@test "exec uses -o flag for output capture" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 1)" == *"-o /tmp/codex_out/result.txt"* ]]
}

@test "exec reads prompt from stdin via dash argument" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  # The last argument should be "-" (read prompt from stdin)
  local exec_call
  exec_call=$(docker_call 1)
  [[ "${exec_call}" == *" -" ]]
}

# --- Image Version Tests ---

# --- Git Safe Directory Tests ---

@test "gitconfig: creates and removes a private runtime config" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local config_path
  config_path=$(cat "${BATS_TEST_TMPDIR}/docker_gitconfig_path_1")
  [[ "$config_path" != "$GITHUB_WORKSPACE/"* ]]
  [ "$(cat "${BATS_TEST_TMPDIR}/docker_gitconfig_mode_1")" = 600 ]
  [ "$(cat "${BATS_TEST_TMPDIR}/docker_gitconfig_safe_dirs_1")" = '*' ]
  [ ! -e "$config_path" ]
  [ ! -e "$GITHUB_WORKSPACE/.codex-gitconfig" ]
}

@test "gitconfig: passes GIT_CONFIG_GLOBAL env var to exec container" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local exec_call
  exec_call=$(docker_call 1)
  [[ "${exec_call}" == *"-e GIT_CONFIG_GLOBAL=/home/codex/.gitconfig"* ]]
}

check_workspace_gitconfig_preserved() {
  local kind="$1" outcome="$2" target mode
  target="$GITHUB_WORKSPACE/.codex-gitconfig"
  if [[ "$kind" == symlink ]]; then
    target="$BATS_TEST_TMPDIR/protected-gitconfig"
    ln -s ../protected-gitconfig "$GITHUB_WORKSPACE/.codex-gitconfig"
    mode=600
  else
    mode=640
  fi
  printf '[fixture]\n\tvalue = preserve exactly\n' > "$target"
  chmod "$mode" "$target"
  cp "$target" "$BATS_TEST_TMPDIR/original-gitconfig"
  if [[ "$kind" == tracked ]]; then
    git -C "$GITHUB_WORKSPACE" init -q
    git -C "$GITHUB_WORKSPACE" add .codex-gitconfig
  fi
  case "$outcome" in
    bootstrap_failure) set_docker_exit_codes 1 ;;
    exec_failure) set_docker_exit_codes 0 1 ;;
  esac
  run bash entrypoint.sh
  if [[ "$outcome" == success ]]; then
    [ "$status" -eq 0 ]
  else
    [ "$status" -ne 0 ]
  fi
  [ -f "$target" ]
  cmp "$target" "$BATS_TEST_TMPDIR/original-gitconfig"
  [ "$(stat -c %a "$target" 2>/dev/null || stat -f %Lp "$target")" = "$mode" ]
  if [[ "$kind" == symlink ]]; then
    [ -L "$GITHUB_WORKSPACE/.codex-gitconfig" ]
    [ "$(readlink "$GITHUB_WORKSPACE/.codex-gitconfig")" = ../protected-gitconfig ]
  elif [[ "$kind" == tracked ]]; then
    git -C "$GITHUB_WORKSPACE" diff --exit-code -- .codex-gitconfig
  fi
}

@test "gitconfig: preserves ordinary file on success" {
  check_workspace_gitconfig_preserved regular success
}

@test "gitconfig: preserves ordinary file on bootstrap failure" {
  check_workspace_gitconfig_preserved regular bootstrap_failure
}

@test "gitconfig: preserves ordinary file on exec failure" {
  check_workspace_gitconfig_preserved regular exec_failure
}

@test "gitconfig: preserves symlink and target on success" {
  check_workspace_gitconfig_preserved symlink success
}

@test "gitconfig: preserves symlink and target on bootstrap failure" {
  check_workspace_gitconfig_preserved symlink bootstrap_failure
}

@test "gitconfig: preserves symlink and target on exec failure" {
  check_workspace_gitconfig_preserved symlink exec_failure
}

@test "gitconfig: preserves tracked file on success" {
  check_workspace_gitconfig_preserved tracked success
}

@test "gitconfig: preserves tracked file on bootstrap failure" {
  check_workspace_gitconfig_preserved tracked bootstrap_failure
}

@test "gitconfig: preserves tracked file on exec failure" {
  check_workspace_gitconfig_preserved tracked exec_failure
}

# --- Image Version Tests ---

# --- Network Access Tests ---

@test "network access: disabled by default prepends policy to prompt" {
  export INPUT_NETWORK_ACCESS="false"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local stdin_content
  stdin_content=$(docker_stdin 1)
  [[ "${stdin_content}" == *"NETWORK POLICY"* ]]
  [[ "${stdin_content}" == *"MUST NOT make any network requests"* ]]
}

@test "network access: enabled skips network policy in prompt" {
  export INPUT_NETWORK_ACCESS="true"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local stdin_content
  stdin_content=$(docker_stdin 1)
  [[ "${stdin_content}" != *"NETWORK POLICY"* ]]
}

@test "network access: policy is prepended before user prompt" {
  export INPUT_NETWORK_ACCESS="false"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local stdin_content
  stdin_content=$(docker_stdin 1)
  # Policy should come before the user prompt
  [[ "${stdin_content}" == "NETWORK POLICY"* ]]
  [[ "${stdin_content}" == *"Summarize these changes" ]]
}

@test "network access: policy works with input_text" {
  export INPUT_NETWORK_ACCESS="false"
  export INPUT_INPUT_TEXT="Some extra data"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local stdin_content
  stdin_content=$(docker_stdin 1)
  [[ "${stdin_content}" == "NETWORK POLICY"* ]]
  [[ "${stdin_content}" == *"Summarize these changes"* ]]
  [[ "${stdin_content}" == *"Some extra data"* ]]
}

# --- Sandbox Tests ---

@test "sandbox: defaults to full-auto without --sandbox flag" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local exec_call
  exec_call=$(docker_call 1)
  [[ "${exec_call}" == *"--full-auto"* ]]
  [[ "${exec_call}" != *"--sandbox"* ]]
}

@test "sandbox: danger-full-access adds --sandbox flag" {
  export INPUT_SANDBOX="danger-full-access"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local exec_call
  exec_call=$(docker_call 1)
  [[ "${exec_call}" == *"--full-auto"* ]]
  [[ "${exec_call}" == *"--sandbox danger-full-access"* ]]
}

@test "sandbox: rejects invalid values" {
  export INPUT_SANDBOX="yolo"
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"sandbox must be"* ]]
}

# --- Quiet Mode Tests ---

@test "quiet mode: adds --json flag and RUST_LOG=off when enabled" {
  export INPUT_QUIET="true"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local exec_call
  exec_call=$(docker_call 1)
  [[ "${exec_call}" == *"--json"* ]]
  [[ "${exec_call}" == *"RUST_LOG=off"* ]]
}

@test "quiet mode: surfaces stderr on failure" {
  export INPUT_QUIET="true"
  # Bootstrap succeeds (call 0), exec fails (call 1)
  set_docker_exit_codes 0 1
  echo "ERROR: Quota exceeded. Check your plan and billing details." > "${DOCKER_MOCK_STDERR}"
  run bash entrypoint.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"Quota exceeded"* ]]
}

@test "quiet mode: omits --json flag when disabled" {
  export INPUT_QUIET="false"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  local exec_call
  exec_call=$(docker_call 1)
  [[ "${exec_call}" != *"--json"* ]]
  [[ "${exec_call}" != *"RUST_LOG=off"* ]]
}

# --- Image Version Tests ---

@test "renovate watches action and codex-docker image pins" {
  [ -f renovate.json ]

  jq -e '.enabledManagers | index("github-actions") and index("custom.regex")' renovate.json >/dev/null
  jq -e '
    .customManagers
    | map(select(.depNameTemplate == "ghcr.io/icoretech/codex-docker" or (.matchStrings[]? | contains("depName=(?<depName>"))))
    | length >= 3
  ' renovate.json >/dev/null
  jq -e '.customManagers[].managerFilePatterns[] | select(. == "/^action\\.yml$/")' renovate.json >/dev/null
  jq -e '.customManagers[].managerFilePatterns[] | select(. == "/^entrypoint\\.sh$/")' renovate.json >/dev/null
  jq -e '.customManagers[].managerFilePatterns[] | select(. == "/^README\\.md$/")' renovate.json >/dev/null
  jq -e '
    .packageRules[]
    | select(.matchPackageNames[]? == "ghcr.io/icoretech/codex-docker")
    | select(.groupSlug == "codex-docker-image")
  ' renovate.json >/dev/null
}

@test "image version: uses custom version in docker calls" {
  export INPUT_IMAGE_VERSION="1.0.0"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 0)" == *"ghcr.io/icoretech/codex-docker:1.0.0"* ]]
  [[ "$(docker_call 1)" == *"ghcr.io/icoretech/codex-docker:1.0.0"* ]]
}

@test "image version: unset input uses the declared action default" {
  unset INPUT_IMAGE_VERSION
  local declared_version
  declared_version=$(awk '/^  image_version:/{in_image=1; next} in_image && /^    default:/{gsub(/\047/, "", $2); print $2; exit}' action.yml)
  [ -n "$declared_version" ]
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 0)" == *"ghcr.io/icoretech/codex-docker:${declared_version}"* ]]
  [[ "$(docker_call 1)" == *"ghcr.io/icoretech/codex-docker:${declared_version}"* ]]
}
