# Codex Action

[![Tests](https://github.com/icoretech/codex-action/actions/workflows/test.yml/badge.svg)](https://github.com/icoretech/codex-action/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Run OpenAI Codex CLI non-interactively in GitHub Actions workflows via [codex-docker](https://github.com/icoretech/codex-docker).

---

## Quick Start

```yaml
- name: Run Codex
  id: codex
  uses: icoretech/codex-action@v1
  with:
    prompt: "Summarize these changes for operators"
    openai_api_key: ${{ secrets.OPENAI_API_KEY }}

- name: Use result
  run: echo "${{ steps.codex.outputs.result }}"
```

---

## Authentication Setup

You must provide exactly one of `openai_api_key` or `codex_config`. Providing both or neither will cause the action to fail immediately.

### Option A: API Key

1. Get an API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
2. Add it as a repository secret named `OPENAI_API_KEY`:
   **Settings → Secrets and variables → Actions → New repository secret**
3. Reference it in your workflow:

   ```yaml
   openai_api_key: ${{ secrets.OPENAI_API_KEY }}
   ```

---

### Option B: OAuth / Device Auth (`codex_config`)

Authenticate once via device auth and store the resulting config as a secret. This uses your existing Codex account.

1. Pull the codex-docker image:

   ```bash
   docker pull ghcr.io/icoretech/codex-docker:0.112.0
   ```

2. Run the device auth flow:

   ```bash
   mkdir -p .codex
   docker run --rm -it \
     -v "$PWD/.codex:/home/codex/.codex" \
     ghcr.io/icoretech/codex-docker:0.112.0 \
     codex-bootstrap device-auth
   ```

3. Follow the browser prompt to complete authentication.

4. Encode the resulting config file:

   ```bash
   # Linux
   base64 -w0 .codex/config.toml

   # macOS
   base64 -i .codex/config.toml
   ```

5. Store the output as a repository secret named `CODEX_CONFIG_B64`:
   **Settings → Secrets and variables → Actions → New repository secret**

6. Reference it in your workflow:

   ```yaml
   codex_config: ${{ secrets.CODEX_CONFIG_B64 }}
   ```

> Tokens from device auth may expire over time. If authentication fails, repeat step 2 through 5 to refresh.

---

### Authentication Comparison

| | API Key | OAuth (Device Auth) |
|---|---|---|
| **Setup** | Simple (paste key) | Requires device-auth flow |
| **Token refresh** | Never expires (until revoked) | May need periodic refresh |

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `prompt` | Yes | — | Instructions for Codex (e.g., `"Summarize these changes for operators"`). |
| `input_text` | No | `""` | Data to process (e.g., changelog content). Appended after the prompt with a `---` separator when provided. |
| `openai_api_key` | No | `""` | OpenAI API key. Mutually exclusive with `codex_config`. |
| `codex_config` | No | `""` | Base64-encoded `config.toml` from a prior device-auth session. Mutually exclusive with `openai_api_key`. |
| `image_version` | No | `0.112.0` | codex-docker image version tag used for the container. |
| `model` | No | `""` | Model override passed to `codex exec --model`. When omitted, the model configured in your Codex config is used. |
| `reasoning_effort` | No | `""` | Reasoning effort level (`minimal`, `low`, `medium`, `high`, `xhigh`). Passed as `model_reasoning_effort` config override. |
| `timeout` | No | `300` | Maximum seconds allowed for Codex execution before the step is killed. |

---

## Outputs

| Output | Description |
|---|---|
| `result` | Text output produced by Codex. |

---

## Examples

### Changelog Summarization with git-cliff

Generate a changelog with [git-cliff](https://github.com/orhun/git-cliff), pass it to Codex for operator-friendly summarization, then use the result as a pull request body.

```yaml
name: Release Summary

on:
  push:
    tags:
      - 'v*'

jobs:
  summarize:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Generate changelog with git-cliff
        id: cliff
        run: |
          pip install git-cliff
          CHANGELOG=$(git cliff --latest --strip all)
          echo "changelog<<EOF" >> "$GITHUB_OUTPUT"
          echo "$CHANGELOG" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Summarize changelog with Codex
        id: codex
        uses: icoretech/codex-action@v1
        with:
          prompt: |
            You are a technical writer. Summarize the following changelog
            into a concise, human-readable release summary suitable for
            an operator audience. Focus on user impact, not implementation
            details. Use bullet points.
          input_text: ${{ steps.cliff.outputs.changelog }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}

      - name: Open release PR with summary
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SUMMARY: ${{ steps.codex.outputs.result }}
        run: |
          gh pr create \
            --title "Release ${{ github.ref_name }}" \
            --body "$SUMMARY" \
            --base main \
            --head "${{ github.ref_name }}"
```

---

### PR Description Generation

Automatically generate a pull request description by diffing the branch against the base.

```yaml
name: Generate PR Description

on:
  pull_request:
    types: [opened]

jobs:
  describe:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Get diff
        id: diff
        run: |
          DIFF=$(git diff origin/${{ github.base_ref }}...HEAD -- . ':(exclude)*.lock')
          echo "diff<<EOF" >> "$GITHUB_OUTPUT"
          echo "$DIFF" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Generate description with Codex
        id: codex
        uses: icoretech/codex-action@v1
        with:
          prompt: |
            You are a senior engineer reviewing a pull request. Given the
            following git diff, write a clear PR description with these
            sections: Summary, Changes, and Testing Notes.
          input_text: ${{ steps.diff.outputs.diff }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}

      - name: Update PR body
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          DESCRIPTION: ${{ steps.codex.outputs.result }}
        run: |
          gh pr edit ${{ github.event.pull_request.number }} \
            --body "$DESCRIPTION"
```

---

### Code Review Summary

Run an automated code review on every pull request and post the result as a comment.

```yaml
name: Code Review

on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write

    steps:
      - uses: actions/checkout@v6
        with:
          fetch-depth: 0

      - name: Get diff
        id: diff
        run: |
          DIFF=$(git diff origin/${{ github.base_ref }}...HEAD)
          echo "diff<<EOF" >> "$GITHUB_OUTPUT"
          echo "$DIFF" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Review with Codex
        id: codex
        uses: icoretech/codex-action@v1
        with:
          prompt: |
            You are an experienced software engineer performing a code review.
            Analyze the following diff and provide:
            - A brief summary of what changed
            - Any potential bugs or logic errors
            - Security concerns if applicable
            - Suggestions for improvement
            Be concise and constructive.
          input_text: ${{ steps.diff.outputs.diff }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}

      - name: Post review comment
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          REVIEW: ${{ steps.codex.outputs.result }}
        run: |
          gh pr comment ${{ github.event.pull_request.number }} \
            --body "## Automated Code Review

          $REVIEW

          ---
          *Generated by [codex-action](https://github.com/icoretech/codex-action)*"
```

---

### Custom Analysis with Model Override

Use the `model` input to target a specific model for a particular task.

```yaml
name: Deep Analysis

on:
  workflow_dispatch:
    inputs:
      target_file:
        description: File to analyze
        required: true

jobs:
  analyze:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v6

      - name: Read target file
        id: content
        run: |
          CONTENT=$(cat "${{ github.event.inputs.target_file }}")
          echo "content<<EOF" >> "$GITHUB_OUTPUT"
          echo "$CONTENT" >> "$GITHUB_OUTPUT"
          echo "EOF" >> "$GITHUB_OUTPUT"

      - name: Analyze with Codex
        id: codex
        uses: icoretech/codex-action@v1
        with:
          prompt: |
            Perform a thorough security and correctness analysis of the
            following source file. Identify any vulnerabilities, edge cases,
            and areas that need hardening.
          input_text: ${{ steps.content.outputs.content }}
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          model: o4-mini
          timeout: "600"

      - name: Print analysis
        run: echo "${{ steps.codex.outputs.result }}"
```

---

## Troubleshooting

### Authentication failure

**Symptoms:** The action fails early with an error referencing `codex-bootstrap api-key-login` or an authentication/authorization error from the Codex CLI.

**Fixes:**

- **API key auth:** Verify the secret `OPENAI_API_KEY` is set correctly in your repository and that the key is active at [platform.openai.com/api-keys](https://platform.openai.com/api-keys).
- **Config auth:** The OAuth token embedded in `config.toml` may have expired. Re-run the device-auth flow, re-encode the file, and update the `CODEX_CONFIG_B64` secret.

---

### Docker image pull failure

**Symptoms:** The action fails with a message like `Unable to find image 'ghcr.io/icoretech/codex-docker:...'` or an HTTP 429 / rate-limit error.

**Fixes:**

- Confirm the `image_version` input matches an available tag on [ghcr.io/icoretech/codex-docker](https://github.com/icoretech/codex-docker/pkgs/container/codex-docker).
- If you are hitting anonymous pull rate limits, authenticate your runner to GHCR by adding a `docker login` step before the action.

---

### Timeout

**Symptoms:** The step is killed after 300 seconds (the default) with a non-zero exit code.

**Fix:** Increase the `timeout` input:

```yaml
with:
  timeout: "600"
```

---

### Empty output

**Symptoms:** `steps.codex.outputs.result` is an empty string even though the step succeeded.

**Fixes:**

- Review your `prompt` — vague instructions can lead to empty or minimal responses.
- Check your OpenAI API status at [platform.openai.com/usage](https://platform.openai.com/usage).
- If using `input_text`, verify the input is not empty before the action runs.

---

### "Exactly one of openai_api_key or codex_config" error

**Symptoms:** The action fails immediately with:

```text
Exactly one of openai_api_key or codex_config must be provided, got both
```

or

```text
Exactly one of openai_api_key or codex_config must be provided, got neither
```

**Fix:** Provide exactly one authentication method. Remove the unused input or ensure the referenced secret is not empty. Both inputs default to `""`, so an unset secret resolves to an empty string and is treated as "not provided".

---

## Development

### Prerequisites

- [bats-core](https://github.com/bats-core/bats-core) for running the test suite
- [shellcheck](https://www.shellcheck.net/) for static analysis of the shell script

### Running tests

```bash
bats tests/entrypoint.bats
```

The test suite uses a mock `docker` binary (loaded from `tests/test_helper/mocks.bash`) so no real Docker daemon or network access is required.

### Running shellcheck

```bash
shellcheck entrypoint.sh
```

### How releases work

This repository uses [release-please](https://github.com/googleapis/release-please) with the `simple` release type. Merging a conventional-commit PR into `main` triggers release-please to open a release PR. When that release PR is merged:

1. A new semver tag (e.g., `v1.2.3`) is created automatically.
2. The `update-major-tag` job force-updates the corresponding major tag (e.g., `v1`) to point at the new release.

Users pinning to a major tag (e.g., `uses: icoretech/codex-action@v1`) always receive the latest patch and minor releases within that major automatically.
