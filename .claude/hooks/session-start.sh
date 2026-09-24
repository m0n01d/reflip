#!/bin/bash
# SessionStart hook — get a fresh cloud sandbox ready for ReScript work.
#
# A claude.ai/code container clones this repo and nothing else: no node_modules,
# no resq, no compiled ReScript. This installs all three so the session can
# build and edit .res files with resq immediately. Adapted from dippa's hook,
# which is the workspace template (see claude-conventions CLAUDE.md).
#
# Local Macs already have this set up, so the whole thing is remote-only.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/../..}"

# resq goes here; export it now so later steps in this script can see it too.
CARGO_BIN="$HOME/.cargo/bin"
export PATH="$CARGO_BIN:$PATH"

echo "==> npm dependencies"
# install, not ci: the container state is cached after this hook, and install
# reuses an existing node_modules instead of deleting and refetching it.
npm install --no-fund --no-audit

echo "==> ReScript build"
npx rescript build

# resq — structural .res/.resi editing. See "Bootstrapping resq in a fresh
# environment" in CLAUDE.md. Deliberately non-fatal: resq is a convenience, and
# a network blip should not stop the session from starting. The installer is
# idempotent and exits early when resq is already present.
echo "==> resq"
if command -v resq >/dev/null 2>&1; then
  echo "  already installed: $(resq --version)"
elif curl -fsSL https://raw.githubusercontent.com/m0n01d/resq/main/scripts/install.sh | sh; then
  echo "  installed: $(resq --version 2>/dev/null || echo 'built, not yet on PATH')"
else
  echo "  WARNING: resq install failed — edit .res files directly, nothing else breaks" >&2
fi

# Persist PATH for the session so `resq` resolves without the full path.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo 'export PATH="$HOME/.cargo/bin:$PATH"' >> "$CLAUDE_ENV_FILE"
fi

echo "==> ready"
