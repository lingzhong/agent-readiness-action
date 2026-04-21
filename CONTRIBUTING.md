# Contributing

Thanks for your interest. This repo is intentionally narrow: a single
composite GitHub Action + its callable bash script. Please check the
README before opening a feature request.

## Development

```bash
git clone https://github.com/lingzhong/agent-readiness-action
cd agent-readiness-action

# Run the test suite (Python 3, curl, jq, bash 4+).
bash tests/test.sh

# Lint. Requires shellcheck and actionlint on PATH.
shellcheck scripts/check-readiness.sh tests/test.sh tests/mock-server.sh
actionlint
```

## Adding tests

`tests/test.sh` runs the script against a local mock scanner backed by
JSON fixtures in `tests/fixtures/`. To exercise a new scenario, add a
fixture file and a `run_case` call.

Scanner response fixtures are anonymized — don't commit fixture files
that contain real site URLs, user IDs, or timestamps tied to specific
deployments.

## Commit messages

Keep commits atomic and scoped. Prefer commit-message conventions that
map to release-drafter labels (`enhancement`, `bug`, `chore`, `docs`,
`dependencies`, `breaking`) so the changelog drafts cleanly.

## Code of Conduct

See [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).
