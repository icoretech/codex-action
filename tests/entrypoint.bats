#!/usr/bin/env bats

setup() {
  load 'test_helper/mocks'
  setup_mocks

  # Default valid inputs
  export INPUT_PROMPT="Summarize these changes"
  export INPUT_INPUT_TEXT=""
  export INPUT_OPENAI_API_KEY="sk-test-key-12345"
  export INPUT_CODEX_CONFIG=""
  export INPUT_IMAGE_VERSION="0.114.0"
  export INPUT_MODEL=""
  export INPUT_REASONING_EFFORT=""
  export INPUT_TIMEOUT="300"

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

@test "api key auth: runs codex-bootstrap then exec" {
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [ "$(docker_call_count)" -eq 2 ]

  # First call: bootstrap api-key-login
  [[ "$(docker_call 0)" == *"codex-bootstrap api-key-login"* ]]
  [[ "$(docker_call 0)" == *"-e OPENAI_API_KEY=sk-test-key-12345"* ]]

  # Second call: exec
  [[ "$(docker_call 1)" == *"exec --ephemeral --skip-git-repo-check"* ]]
  [[ "$(docker_call 1)" == *"--full-auto"* ]]
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

@test "image version: uses custom version in docker calls" {
  export INPUT_IMAGE_VERSION="1.0.0"
  run bash entrypoint.sh
  [ "$status" -eq 0 ]
  [[ "$(docker_call 0)" == *"ghcr.io/icoretech/codex-docker:1.0.0"* ]]
  [[ "$(docker_call 1)" == *"ghcr.io/icoretech/codex-docker:1.0.0"* ]]
}
