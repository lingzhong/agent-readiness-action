# AGENTS.md

## Purpose and scope

This repository is a GitHub Actions composite action that probes a target URL against an agent-readiness scanner and gates the workflow on a minimum readiness level; this guide orients human and AI contributors to the codebase's conventions, commands, and invariants.

## Prerequisites

- bash 4+
- curl
- jq
- python3 (used by the mock server in the test suite)
- shellcheck
- actionlint

## Key commands

| Command | Purpose |
| --- | --- |
| `bash tests/test.sh` | Run the full test suite. |
| `shellcheck scripts/check-readiness.sh tests/test.sh tests/mock-server.sh` | Lint all shell sources. |
| `actionlint` | Lint `action.yml` and workflow files. |
| `URL=https://example.com ./scripts/check-readiness.sh` | Local smoke test against a real URL. |

## Architecture

The flow is: composite action (`action.yml`) -> `scripts/check-readiness.sh` -> `POST` to scanner API -> parse numeric `level` (0-5) from the JSON response -> compare to `min-level` -> `exit 0/1/2`.

There is no build step and no compiled output. The action is pure bash plus jq; everything ships directly from the repository.

## Repo map

| Path | Role |
| --- | --- |
| `action.yml` | Composite action definition: inputs, outputs, and the `runs.steps` that invoke the script. |
| `scripts/check-readiness.sh` | Main logic: request, parse, compare, annotate, set outputs. |
| `tests/test.sh` | Test harness that spawns the mock server and runs each case in a clean env. |
| `tests/mock-server.sh` | Python3-backed HTTP fixture server used by the test suite. |
| `tests/fixtures/` | JSON response fixtures (e.g. `level-0.json` ... `level-5.json`, malformed payloads). |
| `.github/workflows/` | CI: lint (shellcheck + actionlint), test, and release-drafter. |
| `examples/` | Copy-paste workflow snippets showing consumer usage. |

## Test suite mechanics (critical)

The mock server is addressed by **URL fragment selectors**. Fragments never leave the client, so they behave as test directives the harness interprets locally before rewriting the request:

- `#level=N` -> serve `tests/fixtures/level-N.json`
- `#malformed` -> serve malformed JSON
- `#scanner-500` -> return HTTP 500

Harness guarantees:

- Each case runs inside a clean `env -i PATH=... HOME=...` environment so host state cannot leak in.
- `GITHUB_OUTPUT` is redirected to a per-case temp file, which the harness reads back to assert outputs.

To add a test:

1. Drop a new fixture in `tests/fixtures/` (JSON, anonymized).
2. Add a `run_case` invocation in `tests/test.sh` referencing the fragment selector and expected exit code/outputs.

Fixtures must contain no personal user IDs, access tokens, or deployment-specific timestamps. Real public-site URLs are acceptable when they are the point of the capture (they document actual scanner behavior); scrub anything tied to a specific private deployment or user account.

## Script behaviour

- `set -euo pipefail` is set at the top of every shell file.
- Exit codes:
  - `0` -> pass, or soft scanner failure (default).
  - `1` -> level regression, scanner unreachable under strict mode, or any hard failure.
  - `2` -> missing URL input or missing dependency (curl/jq).
- Soft vs hard scanner failure: the default is soft (exit `0` when the scanner itself is unreachable). Set `INPUT_FAIL_ON_SCANNER_UNAVAILABLE=true` to make it hard (exit `1`).
- Annotations: `%`, `\r`, and `\n` are escaped per the GitHub Actions workflow-command spec before being emitted as `::error::` / `::warning::`.
- Multi-line outputs use **per-invocation heredoc delimiters** (random strings generated at runtime) to prevent GHSL-2024-177-class delimiter-injection attacks against `GITHUB_OUTPUT`.
- The `response` output is capped at roughly 900 KB to stay under GitHub Actions step output limits.

## Contribution conventions

- `shellcheck` and `actionlint` gates are enforced by CI (`.github/workflows/lint.yml`). PRs cannot merge red.
- Third-party GitHub Actions in `.github/workflows/` are pinned to commit SHAs with a `# vX.Y.Z` comment. Dependabot manages version bumps; do not edit the SHA manually.
- When `action.yml` changes, sync the inputs/outputs tables in `README.md` in the same PR.
- PR labels drive release-drafter:
  - `enhancement` -> minor bump
  - `bug`, `chore`, `docs`, `dependencies` -> patch bump
  - `breaking` -> major bump
- There is no manual `CHANGELOG.md`; release-drafter auto-generates release notes from merged PR labels.
- Floating tags are maintained: `v0.1.x` advances `v0.1`, `v1.x.x` advances `v1`, so consumers can pin to the major line.

## Security

- No `eval`. No shell interpolation of scanner response content; all parsing goes through `jq`.
- Annotation strings are escaped before being emitted as `::error::` / `::warning::` workflow commands.
- Heredoc delimiters for `GITHUB_OUTPUT` writes are per-invocation random strings.
- The `scanner-endpoint` input can be overridden. Do **not** accept endpoint overrides from untrusted `pull_request_target` contexts; treat that input as attacker-controlled in those workflows.

## Out of scope

This project is a GitHub Actions composite action only. There is no Node CLI, no Docker image, and no alternative distribution surface. Proposals to add those belong in a separate project.
