#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/../phase-done-check.sh"
TMP_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Real-semgrep toolchain path, used only by the GATE-001 defect-1 regression
# tests below (finding-level diff-awareness). The rest of this suite runs
# semgrep as a scripted mock under a deliberately narrow PATH — that's correct
# for testing scope-computation and output-formatting logic in isolation, but
# defect 1 is specifically about semgrep's real JSON line-number shape, so
# those tests need the real binary. Skipped (not failed) if unavailable.
SEMGREP_AVAILABLE=0
SEMGREP_BIN_DIR=""
if command -v semgrep >/dev/null 2>&1; then
  SEMGREP_AVAILABLE=1
  SEMGREP_BIN_DIR="$(dirname "$(command -v semgrep)")"
fi
SEMGREP_TOOLCHAIN_PATH="$SEMGREP_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin"

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

# Minimal git-only fixture for the real-semgrep finding-level tests: no fake
# pnpm/semgrep/git binaries (Gates 1/2/8 just skip — no package.json; Gate 4
# stays clean — nothing under app/api), just a real repo with a real
# .semgrep/ rule so real semgrep produces real JSON with real line numbers.
make_semgrep_fixture() {
  local name="$1"
  local repo="$TMP_ROOT/$name"
  mkdir -p "$repo/.semgrep" "$repo/lib"
  git -C "$repo" init -q
  git -C "$repo" config user.email "phase-done-test@example.invalid"
  git -C "$repo" config user.name "Phase Done Test"
  cat > "$repo/.semgrep/no-eval.yaml" <<'YAML'
rules:
  - id: no-eval
    languages: [javascript]
    message: "eval() is dangerous"
    severity: ERROR
    pattern: eval(...)
YAML
  git -C "$repo" add .semgrep/no-eval.yaml
  git -C "$repo" commit -q -m "fixture baseline: semgrep rule"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD
  echo "$repo"
}

run_check_real_semgrep() {
  local repo="$1"
  shift
  (
    cd "$repo"
    env PATH="$SEMGREP_TOOLCHAIN_PATH" REAL_GIT_PATH="$REAL_GIT" "$@" bash "$CHECK_SCRIPT"
  )
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

# Gate 7 is diff-aware: pre-existing (unchanged) findings must never fail the
# gate, only NEW findings in files that actually changed vs the review base.
semgrep_noop_repo="$(make_fixture semgrep-noop)"
mkdir -p "$semgrep_noop_repo/.semgrep"
semgrep_noop_output=""
if ! semgrep_noop_output="$(run_check "$semgrep_noop_repo" FAIL_SEMGREP=1 2>&1)"; then
  echo "$semgrep_noop_output"
  fail "semgrep pre-existing findings with zero changed files should still pass"
fi
echo "$semgrep_noop_output" | grep -Fq "No changed files in semgrep scope" || {
  echo "$semgrep_noop_output"
  fail "semgrep clean-scope pass message missing"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: semgrep ignores pre-existing findings when nothing changed"

semgrep_repo="$(make_fixture semgrep-exit)"
mkdir -p "$semgrep_repo/.semgrep" "$semgrep_repo/app/api/semgrep-target"
cat > "$semgrep_repo/app/api/semgrep-target/route.ts" <<'TS'
export async function GET() {
  return client.from('semgrep_target').select('*')
}
TS
git -C "$semgrep_repo" add app/api/semgrep-target/route.ts
git -C "$semgrep_repo" commit -q -m "add file for semgrep scope test"
expect_fail_with "semgrep nonzero exit on changed file" "New semgrep findings in changed files" \
  run_check "$semgrep_repo" FAIL_SEMGREP=1
semgrep_exit_output="$(run_check "$semgrep_repo" FAIL_SEMGREP=1 2>&1 || true)"
echo "$semgrep_exit_output" | grep -Fq "pre-existing" || {
  echo "$semgrep_exit_output"
  fail "semgrep failure output missing informational pre-existing count"
}
echo "$semgrep_exit_output" | grep -Fq "semgrep engine unavailable" || {
  echo "$semgrep_exit_output"
  fail "semgrep failure output missing raw fallback text when findings aren't JSON-parseable"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: semgrep failure output carries informational count + raw fallback"

semgrep_clean_repo="$(make_fixture semgrep-clean)"
mkdir -p "$semgrep_clean_repo/.semgrep" "$semgrep_clean_repo/lib/semgrep-clean"
cat > "$semgrep_clean_repo/lib/semgrep-clean/util.ts" <<'TS'
export const answer = 42
TS
git -C "$semgrep_clean_repo" add lib/semgrep-clean/util.ts
git -C "$semgrep_clean_repo" commit -q -m "add clean semgrep-scoped file"
expect_pass "semgrep passes on changed files with no findings" run_check "$semgrep_clean_repo"

# Per-file summary: 25 real new files, each with one real semgrep finding on
# its one added line, so both the per-file tally and the 20-line cap are
# exercised against genuine semgrep JSON (path + start.line), not a hand-typed
# payload. (A hand-typed payload without "start.line" — the previous version
# of this test — can no longer exercise Gate 7's finding-level filter at all:
# entries with no line number are correctly dropped as unverifiable, so that
# payload now trivially passes instead of exercising the cap/summary logic.)
if [ "$SEMGREP_AVAILABLE" -eq 1 ]; then
  semgrep_summary_repo="$(make_semgrep_fixture semgrep-summary)"
  mkdir -p "$semgrep_summary_repo/lib/summary-target"
  for i in $(seq -w 1 25); do
    cat > "$semgrep_summary_repo/lib/summary-target/file-$i.js" <<JS
function risky() { return eval("finding-$i"); }
JS
  done
  git -C "$semgrep_summary_repo" add lib/summary-target
  git -C "$semgrep_summary_repo" commit -q -m "add 25 new files, each with one new eval finding"

  semgrep_summary_output="$(run_check_real_semgrep "$semgrep_summary_repo" 2>&1 || true)"
  echo "$semgrep_summary_output" | grep -Eq "lib/summary-target/file-[0-9]+\.js: 1" || {
    echo "$semgrep_summary_output"
    fail "semgrep per-file summary did not report a per-file count"
  }
  echo "$semgrep_summary_output" | grep -Fq "more file(s) omitted" || {
    echo "$semgrep_summary_output"
    fail "semgrep per-file summary did not cap and report an omitted count"
  }
  echo "$semgrep_summary_output" | grep -Fq "(25 new / 25 pre-existing)" || {
    echo "$semgrep_summary_output"
    fail "semgrep per-file summary did not report the exact new/pre-existing counts"
  }
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: semgrep per-file summary is capped and counted, not a blind tail"
else
  echo "SKIP: semgrep per-file summary cap test (semgrep not installed)"
fi

# ─────────────────────────────────────────────────────────────────────────
# GATE-001 cycle 2, defect 1 (CRITICAL): Gate 7 must be diff-aware at the
# FINDING level, not the file level. A branch that merely touches a file
# already carrying a pre-existing finding — without adding a new one — must
# PASS. These three tests use REAL semgrep (not the scripted mock above)
# because the bug and the fix both live in how real semgrep's JSON (path +
# start.line) gets cross-referenced against added line numbers; a mock can't
# exercise that shape honestly.
# ─────────────────────────────────────────────────────────────────────────

if [ "$SEMGREP_AVAILABLE" -eq 1 ]; then
  # (a) Touching a file with a pre-existing finding, without touching the
  # violating line, must PASS. This is the exact scenario defect 1 named:
  # the previous (file-level) implementation re-scanned the whole file's
  # current content on every touch and reported the untouched pre-existing
  # eval() as "1 new".
  semgrep_untouched_repo="$(make_semgrep_fixture semgrep-preexisting-untouched)"
  cat > "$semgrep_untouched_repo/lib/risky.js" <<'JS'
function safe() {
  return 1;
}

function risky() {
  return eval("1+1");
}
JS
  git -C "$semgrep_untouched_repo" add lib/risky.js
  git -C "$semgrep_untouched_repo" commit -q -m "baseline: pre-existing eval finding"
  git -C "$semgrep_untouched_repo" update-ref refs/remotes/origin/main HEAD

  cat >> "$semgrep_untouched_repo/lib/risky.js" <<'JS'

function unrelatedFeature() {
  return 42;
}
JS
  git -C "$semgrep_untouched_repo" add lib/risky.js
  git -C "$semgrep_untouched_repo" commit -q -m "branch: touch the file without touching the violation"

  expect_pass "GATE-001 defect1(a): touching a file with a pre-existing finding, without adding one, passes Gate 7" \
    run_check_real_semgrep "$semgrep_untouched_repo"
  semgrep_untouched_output="$(run_check_real_semgrep "$semgrep_untouched_repo" 2>&1)"
  echo "$semgrep_untouched_output" | grep -Fq "(0 new / 1 pre-existing)" || {
    echo "$semgrep_untouched_output"
    fail "GATE-001 defect1(a): expected Gate 7 to report 0 new / 1 pre-existing"
  }
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: GATE-001 defect1(a) — pre-existing finding in a touched-but-not-modified file does not fail Gate 7"

  # (b) A branch that adds a line which itself introduces a finding must FAIL.
  # Proves the fix isn't just "never fail" — it still catches real new risk.
  semgrep_newfinding_repo="$(make_semgrep_fixture semgrep-new-finding)"
  cat > "$semgrep_newfinding_repo/lib/util.js" <<'JS'
function safe() {
  return 1;
}
JS
  git -C "$semgrep_newfinding_repo" add lib/util.js
  git -C "$semgrep_newfinding_repo" commit -q -m "baseline: clean file"
  git -C "$semgrep_newfinding_repo" update-ref refs/remotes/origin/main HEAD

  cat >> "$semgrep_newfinding_repo/lib/util.js" <<'JS'

function risky() {
  return eval("2+2");
}
JS
  git -C "$semgrep_newfinding_repo" add lib/util.js
  git -C "$semgrep_newfinding_repo" commit -q -m "branch: add a new eval finding"

  expect_fail_with "GATE-001 defect1(b): a newly added line that introduces a finding fails Gate 7" \
    "New semgrep findings in changed files (1 new" \
    run_check_real_semgrep "$semgrep_newfinding_repo"
  semgrep_newfinding_output="$(run_check_real_semgrep "$semgrep_newfinding_repo" 2>&1 || true)"
  echo "$semgrep_newfinding_output" | grep -Fq "lib/util.js: 1" || {
    echo "$semgrep_newfinding_output"
    fail "GATE-001 defect1(b): expected the new finding to be attributed to lib/util.js"
  }
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: GATE-001 defect1(b) — a newly added line that introduces a finding still fails Gate 7"

  # (c) Mixed file: one pre-existing (untouched) finding plus one genuinely
  # new finding, both in the SAME file. Must report exactly "1 new" — not 2.
  # This is the sharpest proof that filtering is happening at the finding
  # (line) level rather than the file level: the old implementation, on
  # seeing this file in the changed-files list, would re-scan its entire
  # current content and count both eval() calls as "new".
  semgrep_mixed_repo="$(make_semgrep_fixture semgrep-mixed-preexisting-and-new)"
  cat > "$semgrep_mixed_repo/lib/mixed.js" <<'JS'
function existingRisky() {
  return eval("1+1");
}

function safe() {
  return 1;
}
JS
  git -C "$semgrep_mixed_repo" add lib/mixed.js
  git -C "$semgrep_mixed_repo" commit -q -m "baseline: one pre-existing eval finding"
  git -C "$semgrep_mixed_repo" update-ref refs/remotes/origin/main HEAD

  cat >> "$semgrep_mixed_repo/lib/mixed.js" <<'JS'

function newRisky() {
  return eval("2+2");
}
JS
  git -C "$semgrep_mixed_repo" add lib/mixed.js
  git -C "$semgrep_mixed_repo" commit -q -m "branch: add a second, new eval finding to the same file"

  expect_fail_with "GATE-001 defect1(c): mixed file reports only the new finding, not the pre-existing one too" \
    "New semgrep findings in changed files (1 new / 2 pre-existing)" \
    run_check_real_semgrep "$semgrep_mixed_repo"
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: GATE-001 defect1(c) — a file with both a pre-existing and a new finding counts exactly 1 new"
else
  echo "SKIP: GATE-001 defect1 real-semgrep regression tests (semgrep not installed)"
fi

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

# Gate 2 must never report a real pass for a no-op lint script (e.g. rama-os's
# `"lint": "echo 'lint disabled...'"` after Next 16 dropped `next lint`) — it
# has to SKIP, distinctly from a real green pass, and not count toward PASS.
lint_echo_repo="$(make_fixture lint-echo-noop)"
cat > "$lint_echo_repo/package.json" <<'JSON'
{
  "private": true,
  "scripts": {
    "type-check": "fixture",
    "lint": "echo 'lint disabled — Next 16 dropped next lint'",
    "test": "fixture"
  }
}
JSON
lint_echo_output=""
if ! lint_echo_output="$(run_check "$lint_echo_repo" 2>&1)"; then
  echo "$lint_echo_output"
  fail "no-op echo lint script should not fail the overall run"
fi
echo "$lint_echo_output" | grep -Fq "⏭️  SKIP — Lint script is a no-op" || {
  echo "$lint_echo_output"
  fail "no-op echo lint script did not report a distinct SKIP"
}
echo "$lint_echo_output" | grep -Fq "✅ No lint errors" && {
  echo "$lint_echo_output"
  fail "no-op echo lint script must not report a real pass"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: no-op echo lint script is SKIP, not PASS"

# Generic detection (not echo-specific): "exit 0" / ":" style no-ops must also
# be caught — the detector must not be keyed to one repo's exact phrasing.
lint_exit_noop_repo="$(make_fixture lint-exit-noop)"
cat > "$lint_exit_noop_repo/package.json" <<'JSON'
{
  "private": true,
  "scripts": {
    "type-check": "fixture",
    "lint": "true && exit 0",
    "test": "fixture"
  }
}
JSON
lint_exit_noop_output=""
if ! lint_exit_noop_output="$(run_check "$lint_exit_noop_repo" 2>&1)"; then
  echo "$lint_exit_noop_output"
  fail "generic no-op lint script should not fail the overall run"
fi
echo "$lint_exit_noop_output" | grep -Fq "⏭️  SKIP — Lint script is a no-op" || {
  echo "$lint_exit_noop_output"
  fail "generic no-op lint script did not report a distinct SKIP"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: generic (non-echo) no-op lint script is also detected"

# GATE-001 cycle 2, defect 2 (HIGH): a single-line/minified package.json must
# be parsed correctly too. The previous grep+sed extractor assumed one
# "key": "value" pair per line: on a single-line file, grep -m1 returns the
# WHOLE line (every key on it), and the sed anchor `^[^:]*:` matches up to the
# FIRST colon in the file (e.g. after "private", not after "lint") — so
# extraction silently returns the raw unparsed line instead of "true", that
# raw text doesn't match the no-op detector, and the script falls through to
# actually invoking `pnpm lint` for real (which for this fixture's real
# `"lint": "true"` command exits 0) — reporting a false "✅ No lint errors"
# for what is a pure no-op. Must report SKIP instead.
lint_minified_repo="$(make_fixture lint-minified-noop)"
cat > "$lint_minified_repo/package.json" <<'JSON'
{"private":true,"scripts":{"type-check":"fixture","lint":"true","test":"fixture"}}
JSON
lint_minified_output=""
if ! lint_minified_output="$(run_check "$lint_minified_repo" 2>&1)"; then
  echo "$lint_minified_output"
  fail "minified no-op lint script should not fail the overall run"
fi
echo "$lint_minified_output" | grep -Fq "⏭️  SKIP — Lint script is a no-op (\"true\")" || {
  echo "$lint_minified_output"
  fail "minified no-op lint script did not report a distinct SKIP with the correctly extracted value"
}
echo "$lint_minified_output" | grep -Fq "✅ No lint errors" && {
  echo "$lint_minified_output"
  fail "minified no-op lint script must not report a real pass (the GATE-001 cycle 2 defect 2 regression)"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: single-line/minified package.json no-op lint script is SKIP, not PASS"

# Same defect, second shape: minified JSON where "lint" is entirely absent —
# must SKIP as "no script", never fall through to a false pass either.
lint_minified_absent_repo="$(make_fixture lint-minified-absent)"
cat > "$lint_minified_absent_repo/package.json" <<'JSON'
{"private":true,"scripts":{"type-check":"fixture","test":"fixture"}}
JSON
lint_minified_absent_output=""
if ! lint_minified_absent_output="$(run_check "$lint_minified_absent_repo" 2>&1)"; then
  echo "$lint_minified_absent_output"
  fail "minified package.json with no lint script should not fail the overall run"
fi
echo "$lint_minified_absent_output" | grep -Fq "No lint script in package.json" || {
  echo "$lint_minified_absent_output"
  fail "minified package.json with no lint script did not report the correct skip reason"
}
echo "$lint_minified_absent_output" | grep -Fq "✅ No lint errors" && {
  echo "$lint_minified_absent_output"
  fail "minified package.json with no lint script must not report a real pass"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: single-line/minified package.json with no lint key is skipped, not falsely passed"

# A real linter invocation must still run and still fail loudly on error —
# this is the existing "lint nonzero exit" fixture (script value "fixture",
# which is not a no-op), re-asserted here for clarity alongside the new cases.
lint_real_repo="$(make_fixture lint-real-still-checked)"
expect_fail_with "real lint script still runs and fails" "Lint errors" \
  run_check "$lint_real_repo" FAIL_LINT=1
lint_real_output="$(run_check "$lint_real_repo" 2>&1)"
echo "$lint_real_output" | grep -Fq "✅ No lint errors" || {
  echo "$lint_real_output"
  fail "real lint script should still report a genuine pass when it succeeds"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: real lint scripts are unaffected by no-op detection"

echo ""
echo "All $PASS_COUNT phase-done regression checks passed."
