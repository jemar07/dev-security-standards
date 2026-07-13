#!/usr/bin/env bash
# phase-done-check.sh — Universal
#
# Run before closing any phase or opening a PR, in any repo.
# All gates must pass. Auto-detects repo capabilities.
#
# Usage (run from the repo root):
#   bash ~/Developer/dev-security-standards/scripts/phase-done-check.sh
#   bash ~/Developer/dev-security-standards/scripts/phase-done-check.sh --fix
#   PHASE_DONE_BASE_REF=origin/develop bash ~/Developer/dev-security-standards/scripts/phase-done-check.sh
#
# PHASE_DONE_BASE_REF defaults to origin/main and controls only the route-layer
# diff ratchet. The ref must resolve to a trusted review base or Gate 4 fails.

FIX_MODE=false
[ "$1" = "--fix" ] && FIX_MODE=true

PASS=0
FAIL=0
WARNINGS=()

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_NAME=$(basename "$REPO_ROOT")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

green() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
red()   { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
warn()  { echo "  ⚠️  $1"; WARNINGS+=("$1"); }
skip()  { echo "  ⏭️  $1 — skipped (not applicable)"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase Done Check — $REPO_NAME"
echo "  $(date '+%Y-%m-%d %H:%M')  |  branch: $BRANCH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── GATE 1: TypeScript ────────────────────────────────────────────────────────
echo "Gate 1 — TypeScript (strict)"
if [ -f "$REPO_ROOT/package.json" ] && grep -q "type-check\|typecheck" "$REPO_ROOT/package.json" 2>/dev/null; then
  if TS_OUT=$(cd "$REPO_ROOT" && pnpm type-check 2>&1); then
    green "No TypeScript errors"
  else
    red "TypeScript errors — run: pnpm type-check"
    echo "$TS_OUT" | tail -20
  fi
else
  skip "No type-check script in package.json"
fi

# ── GATE 2: Lint ──────────────────────────────────────────────────────────────
echo "Gate 2 — ESLint"
if [ -f "$REPO_ROOT/package.json" ] && grep -q '"lint"' "$REPO_ROOT/package.json" 2>/dev/null; then
  if $FIX_MODE; then
    cd "$REPO_ROOT" && pnpm lint --fix 2>/dev/null \
      && green "Lint clean (auto-fixed where possible)" \
      || red "Lint errors remain after --fix"
  else
    if LINT_OUT=$(cd "$REPO_ROOT" && pnpm lint 2>&1); then
      green "No lint errors"
    else
      red "Lint errors — run: pnpm lint --fix"
      echo "$LINT_OUT" | tail -20
    fi
  fi
else
  skip "No lint script in package.json"
fi

# ── GATE 3: No live secrets ───────────────────────────────────────────────────
echo "Gate 3 — Live secrets in source"
SECRET_HITS=$(grep -rE "(sk_live_|pk_live_)[a-zA-Z0-9]{20,}|whsec_live_[a-zA-Z0-9]{20,}|SUPABASE_SERVICE_ROLE_KEY\s*=\s*['\"]?ey[a-zA-Z0-9]" \
  "$REPO_ROOT" \
  --include="*.ts" --include="*.tsx" --include="*.js" \
  --exclude-dir=node_modules --exclude-dir=.git \
  -l 2>/dev/null || true)
if [ -n "$SECRET_HITS" ]; then
  red "Live secrets found — remove before PR:"
  echo "$SECRET_HITS" | while read -r line; do echo "     $line"; done
else
  green "No live secrets in source files"
fi

# ── GATE 4: Layer violations ──────────────────────────────────────────────────
echo "Gate 4 — Layer violations (Supabase calls in route handlers)"
ROUTE_PATHS=("app/api" "apps/web/app/api")

  scan_route_file() {
    local file="$1"
    awk -v path="$file" '
      /\.from\(/ && $0 !~ /\/\/.*\.from\(/ {
        print path ":" FNR ":" $0
      }
    ' "$REPO_ROOT/$file"
  }

  scan_route_diff() {
    local scan_name="$1"
    shift
    local diff_output
    local hits

    if ! diff_output=$(git -C "$REPO_ROOT" diff --unified=0 --no-color "$@" -- "${ROUTE_PATHS[@]}" 2>&1); then
      echo "$scan_name diff command failed" >&2
      return 2
    fi
    if ! hits=$(printf '%s\n' "$diff_output" | awk '
        /^\+\+\+ b\// { file = substr($0, 7); next }
        /^\+[^+]/ && /\.from\(/ && $0 !~ /\/\/.*\.from\(/ {
          print file ":" substr($0, 2)
        }
      '); then
      echo "$scan_name diff parser failed" >&2
      return 2
    fi
    printf '%s\n' "$hits"
  }

  LAYER_SCAN_ERRORS=()
  ALL_ROUTE_FILES=""
  UNTRACKED_ROUTE_FILES=""
  FULL_TREE_LAYER_VIOLATIONS=""

  if ! ALL_ROUTE_FILES=$(git -C "$REPO_ROOT" ls-files --cached --others --exclude-standard -- "${ROUTE_PATHS[@]}" 2>&1); then
    LAYER_SCAN_ERRORS+=("working-tree file inventory failed")
  else
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      case "$file" in
        *.ts|*.tsx) ;;
        *) continue ;;
      esac
      [ -f "$REPO_ROOT/$file" ] || continue
      if ! FILE_HITS=$(scan_route_file "$file" 2>&1); then
        LAYER_SCAN_ERRORS+=("working-tree scan failed for $file")
        continue
      fi
      if [ -n "$FILE_HITS" ]; then
        FULL_TREE_LAYER_VIOLATIONS="${FULL_TREE_LAYER_VIOLATIONS}${FULL_TREE_LAYER_VIOLATIONS:+$'\n'}${FILE_HITS}"
      fi
    done <<< "$ALL_ROUTE_FILES"
  fi

  if [ "${#LAYER_SCAN_ERRORS[@]}" -eq 0 ]; then
    FULL_TREE_LAYER_COUNT=$(printf '%s\n' "$FULL_TREE_LAYER_VIOLATIONS" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "  Baseline visibility: $FULL_TREE_LAYER_COUNT route-layer call(s) exist in the working tree."
  else
    echo "  Baseline visibility: unavailable because the scanner failed."
  fi

  LAYER_BASE_REF="${PHASE_DONE_BASE_REF:-origin/main}"
  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "${LAYER_BASE_REF}^{commit}" >/dev/null 2>&1; then
    LAYER_SCAN_ERRORS+=("base ref '$LAYER_BASE_REF' is unavailable; set PHASE_DONE_BASE_REF to a trusted review base")
  else
    LAYER_BASE=$(git -C "$REPO_ROOT" merge-base "$LAYER_BASE_REF" HEAD 2>/dev/null || true)
    if [ -z "$LAYER_BASE" ]; then
      LAYER_SCAN_ERRORS+=("merge base with '$LAYER_BASE_REF' is unavailable")
    else
      if ! COMMITTED_LAYER_VIOLATIONS=$(scan_route_diff "committed" "$LAYER_BASE" HEAD); then
        LAYER_SCAN_ERRORS+=("committed diff scan failed")
      fi
      if ! STAGED_LAYER_VIOLATIONS=$(scan_route_diff "staged" --cached HEAD); then
        LAYER_SCAN_ERRORS+=("staged diff scan failed")
      fi
      if ! UNSTAGED_LAYER_VIOLATIONS=$(scan_route_diff "unstaged"); then
        LAYER_SCAN_ERRORS+=("unstaged diff scan failed")
      fi

      if ! UNTRACKED_ROUTE_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard -- "${ROUTE_PATHS[@]}" 2>&1); then
        LAYER_SCAN_ERRORS+=("untracked file inventory failed")
      else
        UNTRACKED_LAYER_VIOLATIONS=""
        while IFS= read -r file; do
          [ -n "$file" ] || continue
          case "$file" in
            *.ts|*.tsx) ;;
            *) continue ;;
          esac
          if ! FILE_HITS=$(scan_route_file "$file" 2>&1); then
            LAYER_SCAN_ERRORS+=("untracked scan failed for $file")
            continue
          fi
          if [ -n "$FILE_HITS" ]; then
            UNTRACKED_LAYER_VIOLATIONS="${UNTRACKED_LAYER_VIOLATIONS}${UNTRACKED_LAYER_VIOLATIONS:+$'\n'}${FILE_HITS}"
          fi
        done <<< "$UNTRACKED_ROUTE_FILES"
      fi

      if [ "${#LAYER_SCAN_ERRORS[@]}" -eq 0 ]; then
        if ! LAYER_VIOLATIONS=$(printf '%s\n%s\n%s\n%s\n' \
          "$COMMITTED_LAYER_VIOLATIONS" \
          "$STAGED_LAYER_VIOLATIONS" \
          "$UNSTAGED_LAYER_VIOLATIONS" \
          "$UNTRACKED_LAYER_VIOLATIONS" \
          | awk 'NF && !seen[$0]++'); then
          LAYER_SCAN_ERRORS+=("violation deduplication failed")
        fi
      fi

      if [ "${#LAYER_SCAN_ERRORS[@]}" -eq 0 ] && [ -n "$LAYER_VIOLATIONS" ]; then
        LAYER_VIOLATION_COUNT=$(printf '%s\n' "$LAYER_VIOLATIONS" | wc -l | tr -d ' ')
        if [ "$LAYER_VIOLATION_COUNT" -eq 1 ]; then
          LAYER_VIOLATION_LABEL="query"
        else
          LAYER_VIOLATION_LABEL="queries"
        fi
        red "$LAYER_VIOLATION_COUNT new Supabase $LAYER_VIOLATION_LABEL in route handlers — move to lib/:"
        echo "$LAYER_VIOLATIONS" | head -10
        if [ "$LAYER_VIOLATION_COUNT" -gt 10 ]; then
          echo "     ... $((LAYER_VIOLATION_COUNT - 10)) more violation(s) omitted"
        fi
      elif [ "${#LAYER_SCAN_ERRORS[@]}" -eq 0 ]; then
        green "No new layer violations"
      fi
    fi
  fi

  if [ "${#LAYER_SCAN_ERRORS[@]}" -gt 0 ]; then
    red "Route-layer scan failed closed:"
    LAYER_SCAN_ERROR_COUNT=${#LAYER_SCAN_ERRORS[@]}
    for ((scan_error_index = 0; scan_error_index < LAYER_SCAN_ERROR_COUNT && scan_error_index < 10; scan_error_index++)); do
      echo "     ${LAYER_SCAN_ERRORS[$scan_error_index]}"
    done
    if [ "$LAYER_SCAN_ERROR_COUNT" -gt 10 ]; then
      echo "     ... $((LAYER_SCAN_ERROR_COUNT - 10)) more scan error(s) omitted"
    fi
  fi

# ── GATE 5: Migration drift ───────────────────────────────────────────────────
echo "Gate 5 — Migration drift"
MIGRATION_DIR="$REPO_ROOT/supabase/migrations"
if [ -d "$MIGRATION_DIR" ]; then
  UNCOMMITTED_SQL=$(git status --short "$MIGRATION_DIR" 2>/dev/null | grep "\.sql" || true)
  if [ -n "$UNCOMMITTED_SQL" ]; then
    red "Uncommitted migration files — commit before PR:"
    echo "$UNCOMMITTED_SQL" | while read -r line; do echo "     $line"; done
  else
    green "All migration files committed"
  fi

  DRIFT_SCRIPT="$HOME/Developer/rama-shared/scripts/check-migration-drift.sh"
  if [ -x "$DRIFT_SCRIPT" ]; then
    if DRIFT_OUT=$("$DRIFT_SCRIPT" 2>&1); then
      green "No database migration drift"
    else
      DRIFT_STATUS=$?
      if [ "$DRIFT_STATUS" -eq 1 ]; then
        red "Database migration drift detected"
      else
        red "Migration drift check failed with exit $DRIFT_STATUS"
      fi
      echo "$DRIFT_OUT" | tail -20
    fi
  else
    skip "No executable migration drift checker"
  fi
else
  skip "No supabase/migrations directory"
fi

# ── GATE 6: Uncommitted changes ───────────────────────────────────────────────
echo "Gate 6 — Uncommitted changes"
UNCOMMITTED=$(git status --short 2>/dev/null || true)
if [ -n "$UNCOMMITTED" ]; then
  warn "Uncommitted changes — commit or stash before marking phase done"
  git status --short | head -10
else
  green "Working tree clean"
fi

# ── GATE 7: Semgrep (repo-local config only) ──────────────────────────────────
echo "Gate 7 — Semgrep security rules"
if command -v semgrep >/dev/null 2>&1 && [ -d "$REPO_ROOT/.semgrep" ]; then
  if SEMGREP_OUT=$(cd "$REPO_ROOT" && semgrep --config .semgrep/ --error --quiet . 2>&1); then
    green "No semgrep violations"
  else
    red "Semgrep violations found:"
    echo "$SEMGREP_OUT" | grep -v "^$" | tail -20
  fi
elif ! command -v semgrep >/dev/null 2>&1; then
  skip "semgrep not installed (pip install semgrep)"
else
  skip "No .semgrep/ config in this repo"
fi

# ── GATE 8: Tests ─────────────────────────────────────────────────────────────
echo "Gate 8 — Tests"
if [ -f "$REPO_ROOT/package.json" ] && grep -q '"test"' "$REPO_ROOT/package.json" 2>/dev/null; then
  if TEST_OUT=$(cd "$REPO_ROOT" && pnpm test 2>&1); then
    green "Tests pass"
  else
    red "Tests failed — run: pnpm test"
    echo "$TEST_OUT" | tail -20
  fi
else
  skip "No test script in package.json"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $PASS passed · $FAIL failed · ${#WARNINGS[@]} warnings"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo ""
  echo "  Warnings (non-blocking):"
  for w in "${WARNINGS[@]}"; do echo "  ⚠️  $w"; done
fi

echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  🔴 PHASE NOT COMPLETE — $FAIL gate(s) failed."
  echo "     Fix failures above before marking this phase done or opening a PR."
  echo ""
  exit 1
else
  echo "  🟢 ALL GATES PASSED — phase is complete."
  echo ""
  exit 0
fi
