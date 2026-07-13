#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

print_bounded() {
  local content="$1"
  local limit="${2:-10}"
  printf '%s\n' "$content" | awk -v limit="$limit" '
    NF {
      count++
      if (count <= limit) print
    }
    END {
      if (count > limit) printf "... %d more line(s) omitted\n", count - limit
    }
  '
}

echo "=== dev-security-standards Verification ==="

echo "[1/5] Scanning for live secret values..."
SECRET_PATTERN="(sk_live_|pk_live_)[A-Za-z0-9]{20,}|whsec_live_[A-Za-z0-9]{20,}|dp[.]pt[.][A-Za-z0-9]{16,}|SUPABASE_SERVICE_ROLE_KEY[[:space:]]*=[[:space:]]*['\"]?ey[A-Za-z0-9_-]{20,}"
SECRET_INVENTORY=$(mktemp)
trap 'rm -f "$SECRET_INVENTORY"' EXIT
if ! git ls-files -z --cached --others --exclude-standard > "$SECRET_INVENTORY"; then
  echo "FAIL: secret file inventory failed."
  exit 1
fi
SECRET_HITS=""
SECRET_SCAN_ERRORS=""
while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue
  SECRET_SCAN_STATUS=0
  SECRET_SCAN_OUT=$(grep -lE "$SECRET_PATTERN" -- "$file" 2>&1) || SECRET_SCAN_STATUS=$?
  if [ "$SECRET_SCAN_STATUS" -eq 0 ]; then
    SECRET_HITS="${SECRET_HITS}${SECRET_HITS:+$'\n'}${file}"
  elif [ "$SECRET_SCAN_STATUS" -ne 1 ]; then
    SECRET_SCAN_ERRORS="${SECRET_SCAN_ERRORS}${SECRET_SCAN_ERRORS:+$'\n'}secret scan failed for $file (exit $SECRET_SCAN_STATUS)"
  fi
done < "$SECRET_INVENTORY"
if [ -n "$SECRET_SCAN_ERRORS" ]; then
  print_bounded "$SECRET_SCAN_ERRORS"
  echo "FAIL: live-secret scanner failed."
  exit 1
fi
if [ -n "$SECRET_HITS" ]; then
  print_bounded "$SECRET_HITS"
  echo "FAIL: possible live secret value detected. Move it to Doppler and rotate it."
  exit 1
fi
echo "PASS"

echo "[2/5] Checking for local or tracked environment files..."
if ! LOCAL_ENV_FILES=$(find . -type f -name '.env*' ! -name '.env.example' -not -path '*/.git/*' -print 2>&1); then
  print_bounded "$LOCAL_ENV_FILES"
  echo "FAIL: local environment-file scan failed."
  exit 1
fi
if ! TRACKED_FILES=$(git ls-files 2>&1); then
  print_bounded "$TRACKED_FILES"
  echo "FAIL: tracked environment-file inventory failed."
  exit 1
fi
if ! TRACKED_ENV_FILES=$(printf '%s\n' "$TRACKED_FILES" | awk '
    /(^|\/)\.env($|\.)/ && $0 !~ /(^|\/)\.env\.example$/ { print }
  '); then
  echo "FAIL: tracked environment-file filter failed."
  exit 1
fi
if [ -n "$LOCAL_ENV_FILES" ] || [ -n "$TRACKED_ENV_FILES" ]; then
  print_bounded "$(printf '%s\n%s\n' "$LOCAL_ENV_FILES" "$TRACKED_ENV_FILES")"
  echo "FAIL: environment files are forbidden; use Doppler."
  exit 1
fi
echo "PASS"

echo "[3/5] Checking Bash syntax..."
if ! BASH_SCRIPTS=$(find scripts -type f -name '*.sh' -print 2>&1); then
  print_bounded "$BASH_SCRIPTS"
  echo "FAIL: Bash file inventory failed."
  exit 1
fi
while IFS= read -r script; do
  [ -n "$script" ] || continue
  bash -n "$script"
done <<< "$BASH_SCRIPTS"
echo "PASS"

echo "[4/5] Running phase-done regression tests..."
bash scripts/tests/phase-done-check.test.sh
bash scripts/tests/verify.test.sh
echo "PASS"

echo "[5/5] Checking patch whitespace..."
VERIFY_BASE_REF="${VERIFY_BASE_REF:-origin/main}"
if ! git rev-parse --verify --quiet "${VERIFY_BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "FAIL: verification base ref '$VERIFY_BASE_REF' is unavailable."
  exit 1
fi
VERIFY_BASE=$(git merge-base "$VERIFY_BASE_REF" HEAD 2>/dev/null || true)
if [ -z "$VERIFY_BASE" ]; then
  echo "FAIL: merge base with '$VERIFY_BASE_REF' is unavailable."
  exit 1
fi
git diff --check "$VERIFY_BASE" HEAD --
git diff --cached --check
git diff --check
if ! UNTRACKED_FILES=$(git ls-files --others --exclude-standard 2>&1); then
  print_bounded "$UNTRACKED_FILES"
  echo "FAIL: untracked-file inventory failed."
  exit 1
fi
UNTRACKED_WHITESPACE_ERRORS=""
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ -f "$file" ] || continue
  NO_INDEX_STATUS=0
  NO_INDEX_OUT=$(git diff --no-index --check /dev/null "$file" 2>&1) || NO_INDEX_STATUS=$?
  WHITESPACE_DIAGNOSTIC=$(printf '%s\n' "$NO_INDEX_OUT" | awk '
    /trailing whitespace\.|space before tab in indent\.|new blank line at EOF\./ { found = 1 }
    { lines[NR] = $0 }
    END {
      if (found) for (i = 1; i <= NR; i++) print lines[i]
    }
  ')
  if [ "$NO_INDEX_STATUS" -gt 1 ] && [ -z "$WHITESPACE_DIAGNOSTIC" ]; then
    print_bounded "$NO_INDEX_OUT"
    echo "FAIL: whitespace scan failed for untracked file $file."
    exit 1
  fi
  if [ -n "$WHITESPACE_DIAGNOSTIC" ]; then
    UNTRACKED_WHITESPACE_ERRORS="${UNTRACKED_WHITESPACE_ERRORS}${UNTRACKED_WHITESPACE_ERRORS:+$'\n'}${WHITESPACE_DIAGNOSTIC}"
  fi
done <<< "$UNTRACKED_FILES"
if [ -n "$UNTRACKED_WHITESPACE_ERRORS" ]; then
  print_bounded "$UNTRACKED_WHITESPACE_ERRORS"
  echo "FAIL: whitespace errors found in untracked files."
  exit 1
fi
echo "PASS"

echo ""
echo "=== All checks passed. Safe to push. ==="
