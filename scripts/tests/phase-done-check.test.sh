#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/../phase-done-check.sh"
TMP_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0

fail() {
  echo "FAIL: $1"
  exit 1
}

make_fixture() {
  local name="$1"
  local repo="$TMP_ROOT/$name"

  mkdir -p "$repo/bin" "$repo/app/api/legacy"
  git -C "$repo" init -q
  git -C "$repo" config user.email "phase-done-test@example.invalid"
  git -C "$repo" config user.name "Phase Done Test"

  cat > "$repo/package.json" <<'JSON'
{
  "private": true,
  "scripts": {
    "type-check": "fixture",
    "lint": "fixture",
    "test": "fixture"
  }
}
JSON

  cat > "$repo/app/api/legacy/route.ts" <<'TS'
export async function GET() {
  return client.from('legacy_table').select('*')
}
TS

  cat > "$repo/bin/pnpm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  type-check)
    [ "${FAIL_TYPECHECK:-0}" = "1" ] && { echo "toolchain unavailable"; exit 2; }
    ;;
  lint)
    [ "${FAIL_LINT:-0}" = "1" ] && { echo "linter unavailable"; exit 2; }
    ;;
  test)
    for arg in "$@"; do
      [ "$arg" != "--passWithNoTests" ] || { echo "invalid root test option"; exit 3; }
    done
    [ "${FAIL_TEST:-0}" = "1" ] && { echo "test runner unavailable"; exit 2; }
    ;;
esac
exit 0
SH
  chmod +x "$repo/bin/pnpm"

  cat > "$repo/bin/semgrep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[ "${FAIL_SEMGREP:-0}" = "1" ] && { echo "semgrep engine unavailable"; exit 2; }
exit 0
SH
  chmod +x "$repo/bin/semgrep"

  cat > "$repo/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

is_diff=0
is_ls_files=0
for arg in "$@"; do
  [ "$arg" = "diff" ] && is_diff=1
  [ "$arg" = "ls-files" ] && is_ls_files=1
done

[ "${FAIL_GIT_DIFF:-0}" = "1" ] && [ "$is_diff" -eq 1 ] && exit 2
[ "${FAIL_GIT_LS_FILES:-0}" = "1" ] && [ "$is_ls_files" -eq 1 ] && exit 2

exec "$REAL_GIT_PATH" "$@"
SH
  chmod +x "$repo/bin/git"

  git -C "$repo" add package.json app/api/legacy/route.ts bin/pnpm bin/semgrep bin/git
  git -C "$repo" commit -q -m "fixture baseline"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD

  echo "$repo"
}

run_check() {
  local repo="$1"
  shift
  (
    cd "$repo"
    env PATH="$repo/bin:/usr/bin:/bin:/usr/sbin:/sbin" REAL_GIT_PATH="$REAL_GIT" "$@" bash "$CHECK_SCRIPT"
  )
}

expect_pass() {
  local name="$1"
  shift
  local output
  if ! output="$("$@" 2>&1)"; then
    echo "$output"
    fail "$name should pass"
  fi
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $name"
}

expect_fail_with() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  if output="$("$@" 2>&1)"; then
    echo "$output"
    fail "$name should fail"
  fi
  echo "$output" | grep -Fq "$expected" || {
    echo "$output"
    fail "$name did not report: $expected"
  }
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $name"
}

baseline_repo="$(make_fixture baseline)"
expect_pass "legacy route debt is baselined" run_check "$baseline_repo"
baseline_output="$(run_check "$baseline_repo")"
echo "$baseline_output" | grep -Fq "Baseline visibility: 1 route-layer call(s)" || {
  echo "$baseline_output"
  fail "full-tree baseline count is not visible"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: full-tree baseline count remains visible"

tracked_repo="$(make_fixture tracked-route)"
mkdir -p "$tracked_repo/app/api/new"
cat > "$tracked_repo/app/api/new/route.ts" <<'TS'
export async function GET() {
  return client.from('new_table').select('*')
}
TS
git -C "$tracked_repo" add app/api/new/route.ts
git -C "$tracked_repo" commit -q -m "add route violation"
expect_fail_with "committed route violation" "app/api/new/route.ts" run_check "$tracked_repo"

staged_repo="$(make_fixture staged-route)"
mkdir -p "$staged_repo/app/api/staged"
cat > "$staged_repo/app/api/staged/route.ts" <<'TS'
export async function GET() {
  return client.from('staged_table').select('*')
}
TS
git -C "$staged_repo" add app/api/staged/route.ts
expect_fail_with "staged route violation" "app/api/staged/route.ts" run_check "$staged_repo"

staged_cancel_repo="$(make_fixture staged-cancellation)"
cat >> "$staged_cancel_repo/app/api/legacy/route.ts" <<'TS'
export const stagedCancellation = client.from('staged_cancellation')
TS
git -C "$staged_cancel_repo" add app/api/legacy/route.ts
git -C "$staged_cancel_repo" restore --worktree --source=HEAD -- app/api/legacy/route.ts
expect_fail_with "staged violation hidden by worktree restore" "stagedCancellation" \
  run_check "$staged_cancel_repo"

unstaged_repo="$(make_fixture unstaged-route)"
cat >> "$unstaged_repo/app/api/legacy/route.ts" <<'TS'

export async function POST() {
  return client.from('unstaged_table').insert({})
}
TS
expect_fail_with "unstaged route violation" "app/api/legacy/route.ts" run_check "$unstaged_repo"

committed_cancel_repo="$(make_fixture committed-cancellation)"
cat >> "$committed_cancel_repo/app/api/legacy/route.ts" <<'TS'
export const committedCancellation = client.from('committed_cancellation')
TS
git -C "$committed_cancel_repo" add app/api/legacy/route.ts
git -C "$committed_cancel_repo" commit -q -m "commit route violation"
git -C "$committed_cancel_repo" restore --worktree --source=origin/main -- app/api/legacy/route.ts
expect_fail_with "committed violation hidden by worktree restore" "committedCancellation" \
  run_check "$committed_cancel_repo"

route_root_cancel_repo="$(make_fixture route-root-cancellation)"
git -C "$route_root_cancel_repo" rm -q app/api/legacy/route.ts
git -C "$route_root_cancel_repo" commit -q -m "remove baseline route root"
git -C "$route_root_cancel_repo" update-ref refs/remotes/origin/main HEAD
mkdir -p "$route_root_cancel_repo/app/api/new"
cat > "$route_root_cancel_repo/app/api/new/route.ts" <<'TS'
export const routeRootCancellation = client.from('route_root_cancellation')
TS
git -C "$route_root_cancel_repo" add app/api/new/route.ts
git -C "$route_root_cancel_repo" commit -q -m "commit route-root violation"
rm -rf "$route_root_cancel_repo/app/api"
expect_fail_with "committed violation hidden by removing entire route root" "routeRootCancellation" \
  run_check "$route_root_cancel_repo"

untracked_repo="$(make_fixture untracked-route)"
mkdir -p "$untracked_repo/app/api/untracked"
cat > "$untracked_repo/app/api/untracked/route.ts" <<'TS'
export async function GET() {
  return client.from('untracked_table').select('*')
}
TS
expect_fail_with "untracked route violation" "app/api/untracked/route.ts" run_check "$untracked_repo"

diff_error_repo="$(make_fixture diff-error)"
expect_fail_with "git diff scanner error fails closed" "committed diff scan failed" \
  run_check "$diff_error_repo" FAIL_GIT_DIFF=1

inventory_error_repo="$(make_fixture inventory-error)"
expect_fail_with "git file inventory error fails closed" "working-tree file inventory failed" \
  run_check "$inventory_error_repo" FAIL_GIT_LS_FILES=1

typecheck_repo="$(make_fixture typecheck-exit)"
expect_fail_with "typecheck nonzero exit" "TypeScript errors" \
  run_check "$typecheck_repo" FAIL_TYPECHECK=1

lint_repo="$(make_fixture lint-exit)"
expect_fail_with "lint nonzero exit" "Lint errors" \
  run_check "$lint_repo" FAIL_LINT=1

test_repo="$(make_fixture test-exit)"
expect_fail_with "test nonzero exit" "Tests failed" \
  run_check "$test_repo" FAIL_TEST=1

semgrep_repo="$(make_fixture semgrep-exit)"
mkdir -p "$semgrep_repo/.semgrep"
expect_fail_with "semgrep nonzero exit" "Semgrep violations" \
  run_check "$semgrep_repo" FAIL_SEMGREP=1

drift_repo="$(make_fixture drift-exit)"
mkdir -p "$drift_repo/supabase/migrations" "$drift_repo/home/Developer/rama-shared/scripts"
cat > "$drift_repo/supabase/migrations/20260713000000_fixture.sql" <<'SQL'
select 1;
SQL
cat > "$drift_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh" <<'SH'
#!/usr/bin/env bash
echo "database connection unavailable"
exit 2
SH
chmod +x "$drift_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh"
git -C "$drift_repo" add supabase/migrations/20260713000000_fixture.sql
git -C "$drift_repo" commit -q -m "add fixture migration"
expect_fail_with "drift-check nonzero exit" "Migration drift check failed with exit 2" \
  run_check "$drift_repo" HOME="$drift_repo/home"

drift_detected_repo="$(make_fixture drift-detected)"
mkdir -p "$drift_detected_repo/supabase/migrations" "$drift_detected_repo/home/Developer/rama-shared/scripts"
cat > "$drift_detected_repo/supabase/migrations/20260713000001_fixture.sql" <<'SQL'
select 1;
SQL
cat > "$drift_detected_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh" <<'SH'
#!/usr/bin/env bash
echo "fixture drift"
exit 1
SH
chmod +x "$drift_detected_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh"
git -C "$drift_detected_repo" add supabase/migrations/20260713000001_fixture.sql
git -C "$drift_detected_repo" commit -q -m "add drift fixture"
expect_fail_with "drift exit one is detected" "Database migration drift detected" \
  run_check "$drift_detected_repo" HOME="$drift_detected_repo/home"

drift_clean_repo="$(make_fixture drift-clean)"
mkdir -p "$drift_clean_repo/supabase/migrations" "$drift_clean_repo/home/Developer/rama-shared/scripts"
cat > "$drift_clean_repo/supabase/migrations/20260713000002_fixture.sql" <<'SQL'
select 1;
SQL
cat > "$drift_clean_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh" <<'SH'
#!/usr/bin/env bash
echo "fixture in sync"
exit 0
SH
chmod +x "$drift_clean_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh"
git -C "$drift_clean_repo" add supabase/migrations/20260713000002_fixture.sql
git -C "$drift_clean_repo" commit -q -m "add clean drift fixture"
expect_pass "drift exit zero passes" run_check "$drift_clean_repo" HOME="$drift_clean_repo/home"

drift_worktree_repo="$(make_fixture drift-worktree)"
mkdir -p "$drift_worktree_repo/supabase/migrations" "$drift_worktree_repo/scripts" "$drift_worktree_repo/home/Developer/rama-shared/scripts"
cat > "$drift_worktree_repo/supabase/migrations/20260713000003_fixture.sql" <<'SQL'
select 1;
SQL
cat > "$drift_worktree_repo/scripts/check-migration-drift.sh" <<'SH'
#!/usr/bin/env bash
echo "worktree migration set in sync"
exit 0
SH
cat > "$drift_worktree_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh" <<'SH'
#!/usr/bin/env bash
echo "shared checkout must not be used"
exit 1
SH
chmod +x "$drift_worktree_repo/scripts/check-migration-drift.sh" "$drift_worktree_repo/home/Developer/rama-shared/scripts/check-migration-drift.sh"
git -C "$drift_worktree_repo" add supabase/migrations/20260713000003_fixture.sql scripts/check-migration-drift.sh
git -C "$drift_worktree_repo" commit -q -m "add worktree drift fixture"
expect_pass "worktree drift checker takes precedence" run_check "$drift_worktree_repo" HOME="$drift_worktree_repo/home"

missing_base_repo="$(make_fixture missing-base)"
git -C "$missing_base_repo" update-ref -d refs/remotes/origin/main
expect_fail_with "missing route-layer base fails closed" "base ref 'origin/main' is unavailable" \
  run_check "$missing_base_repo"

override_base_repo="$(make_fixture override-base)"
git -C "$override_base_repo" update-ref refs/remotes/origin/develop HEAD
git -C "$override_base_repo" update-ref -d refs/remotes/origin/main
expect_pass "explicit trusted base override" run_check "$override_base_repo" PHASE_DONE_BASE_REF=origin/develop

overflow_repo="$(make_fixture overflow)"
mkdir -p "$overflow_repo/app/api/overflow"
for i in $(seq 1 12); do
  printf "export const q%s = client.from('table_%s')\n" "$i" "$i" >> "$overflow_repo/app/api/overflow/route.ts"
done
overflow_output=""
if overflow_output="$(run_check "$overflow_repo" 2>&1)"; then
  echo "$overflow_output"
  fail "overflow route violations should fail"
fi
echo "$overflow_output" | grep -Fq "12 new Supabase queries" || {
  echo "$overflow_output"
  fail "overflow route violations did not report the exact count"
}
echo "$overflow_output" | grep -Fq "2 more violation(s) omitted" || {
  echo "$overflow_output"
  fail "overflow route violations did not report the omitted count"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: route violation output is bounded and counted"

scan_error_overflow_repo="$(make_fixture scan-error-overflow)"
mkdir -p "$scan_error_overflow_repo/app/api/errors"
for i in $(seq 1 12); do
  ln -s "missing-$i" "$scan_error_overflow_repo/app/api/errors/error-$i.ts"
done
scan_error_overflow_output=""
if scan_error_overflow_output="$(run_check "$scan_error_overflow_repo" 2>&1)"; then
  echo "$scan_error_overflow_output"
  fail "overflow route scan errors should fail"
fi
echo "$scan_error_overflow_output" | grep -Fq "2 more scan error(s) omitted" || {
  echo "$scan_error_overflow_output"
  fail "overflow route scan errors did not report the omitted count"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: route scan-error output is bounded and counted"

echo ""
echo "All $PASS_COUNT phase-done regression checks passed."
