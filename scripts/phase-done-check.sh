#!/usr/bin/env bash
# phase-done-check.sh — Universal
#
# Run before closing any phase or opening a PR, in any repo.
# All gates must pass. Auto-detects repo capabilities.
#
# Usage (run from the repo root):
#   bash ~/Developer/dev-security-standards/scripts/phase-done-check.sh
#   bash ~/Developer/dev-security-standards/scripts/phase-done-check.sh --fix

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
  TS_OUT=$(cd "$REPO_ROOT" && pnpm type-check 2>&1 || true)
  if echo "$TS_OUT" | grep -q "error TS"; then
    red "TypeScript errors — run: pnpm type-check"
    echo "$TS_OUT" | grep "error TS" | head -10
  else
    green "No TypeScript errors"
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
    LINT_OUT=$(cd "$REPO_ROOT" && pnpm lint 2>&1 || true)
    if echo "$LINT_OUT" | grep -qE "^[0-9]+ error|error  "; then
      red "Lint errors — run: pnpm lint --fix"
      echo "$LINT_OUT" | grep -E "error" | head -10
    else
      green "No lint errors"
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
LAYER_VIOLATIONS=$(grep -r "\.from(" \
  "$REPO_ROOT/app/api" "$REPO_ROOT/apps/web/app/api" \
  --include="*.ts" --include="*.tsx" \
  2>/dev/null | grep -v "//.*\.from(" | grep -v node_modules || true)
if [ -n "$LAYER_VIOLATIONS" ]; then
  red "Supabase queries in route handlers — move to lib/:"
  echo "$LAYER_VIOLATIONS" | head -10
else
  green "No layer violations"
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
    if "$DRIFT_SCRIPT" 2>&1 | grep -q "DRIFT"; then
      red "DB schema drift detected — DB has changes not in git"
    fi
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
  SEMGREP_OUT=$(cd "$REPO_ROOT" && semgrep --config .semgrep/ --error --quiet . 2>&1 || true)
  if echo "$SEMGREP_OUT" | grep -qE "findings|›"; then
    red "Semgrep violations found:"
    echo "$SEMGREP_OUT" | grep -v "^$" | head -15
  else
    green "No semgrep violations"
  fi
elif ! command -v semgrep >/dev/null 2>&1; then
  skip "semgrep not installed (pip install semgrep)"
else
  skip "No .semgrep/ config in this repo"
fi

# ── GATE 8: Tests ─────────────────────────────────────────────────────────────
echo "Gate 8 — Tests"
if [ -f "$REPO_ROOT/package.json" ] && grep -q '"test"' "$REPO_ROOT/package.json" 2>/dev/null; then
  TEST_OUT=$(cd "$REPO_ROOT" && pnpm test --passWithNoTests 2>&1 || true)
  if echo "$TEST_OUT" | grep -qE "FAIL|failed"; then
    red "Tests failed — run: pnpm test"
    echo "$TEST_OUT" | grep -E "FAIL|✗|×" | head -10
  else
    green "Tests pass"
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
