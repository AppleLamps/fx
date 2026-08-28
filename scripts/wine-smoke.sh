#!/usr/bin/env bash
#
# Exercises a Windows fx build without a Windows host.
#
# Wine is not Windows. It is a reimplementation, and its fidelity is weakest in
# exactly the areas this port cares most about: Job Objects, ACLs, and console
# behavior. Treat a pass here as evidence that the binary starts and its
# non-interactive surface works, not as a substitute for the `windows-latest`
# job. A *failure* here is always real; a pass is suggestive.
#
# Usage:
#   zig build -Dtarget=x86_64-windows
#   ./scripts/wine-smoke.sh [path/to/fx.exe]

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

exe="${1:-zig-out/bin/fx.exe}"

if [[ ! -f "$exe" ]]; then
  printf 'No Windows build at %s. Run: zig build -Dtarget=x86_64-windows\n' "$exe" >&2
  exit 1
fi

# Debian and Ubuntu ship the loader here; the `wine` wrapper on PATH comes from
# a separate package that pulls in 32-bit support this does not need.
wine_bin=""
for candidate in /usr/lib/wine/wine64 "$(command -v wine64 || true)" "$(command -v wine || true)"; do
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    wine_bin="$candidate"
    break
  fi
done

if [[ -z "$wine_bin" ]]; then
  printf 'wine not found. Install it with: apt-get install -y --no-install-recommends wine64\n' >&2
  exit 1
fi

export WINEDEBUG="${WINEDEBUG:--all}"
export WINEPREFIX="${WINEPREFIX:-${TMPDIR:-/tmp}/fx-wine-prefix}"

# First use of a prefix makes wine write setup chatter to stderr, which would
# otherwise be misattributed to the first case's stderr assertion.
"$wine_bin" wineboot --init >/dev/null 2>&1 || true

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "$stdout_file" "$stderr_file"' EXIT

failures=0

# Mirrors the assertions the native jobs make in .github/workflows/full-ci.yml:
# a populated stdout and a completely silent stderr.
run_case() {
  local name="$1"
  shift

  if ! timeout 300 "$wine_bin" "$exe" "$@" >"$stdout_file" 2>"$stderr_file"; then
    printf 'FAIL %-18s exited nonzero\n' "$name"
    failures=$((failures + 1))
    return
  fi
  if [[ ! -s "$stdout_file" ]]; then
    printf 'FAIL %-18s stdout was empty\n' "$name"
    failures=$((failures + 1))
    return
  fi
  if [[ -s "$stderr_file" ]]; then
    printf 'FAIL %-18s stderr was not empty:\n' "$name"
    head -5 "$stderr_file" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'ok   %-18s %s bytes stdout, empty stderr\n' "$name" "$(wc -c <"$stdout_file")"
}

printf 'wine:   %s\n' "$wine_bin"
printf 'binary: %s\n\n' "$exe"

run_case "--version" --version
run_case "help" help
run_case "status --json" status --json

printf '\n'
if (( failures > 0 )); then
  printf '%d smoke case(s) failed.\n' "$failures" >&2
  exit 1
fi
printf 'All smoke cases passed under wine. This is not a substitute for a real Windows run.\n'
