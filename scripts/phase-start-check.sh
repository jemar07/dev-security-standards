#!/usr/bin/env bash
# phase-start-check.sh — Universal
#
# Run at the START of every phase, in any repo, before writing new code.
# Auto-detects repo capabilities and runs only what applies.
#
# Usage (run from the repo root):
#   bash ~/Developer/dev-security-standards/scripts/phase-start-check.sh
#   bash ~/Developer/dev-security-standards/scripts/phase-start-check.sh "Phase 2 — Auth"

PHASE_LABEL="${1:-}"
ISSUES=0
WARNINGS=0

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_NAME=$(basename "$REPO_ROOT")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")

green() { echo "  ✅ $1"; }
red()   { echo "  🔴 $1"; ISSUES=$((ISSUES + 1)); }
warn()  { echo "  ⚠️  $1"; WARNINGS=$((WARNINGS + 1)); }
skip()  { echo "  ⏭️  $1 — skipped (not applicable)"; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Phase Start Check — $REPO_NAME"
[ -n "$PHASE_LABEL" ] && echo "  $PHASE_LABEL"
echo "  $(date '+%Y-%m-%d %H:%M')  |  branch: $BRANCH"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── CHECK 1: Unpushed commits ─────────────────────────────────────────────────
echo "Check 1 — Unpushed commits"
UNPUSHED=$(git log "origin/$BRANCH..HEAD" --oneline 2>/dev/null || true)
if [ -n "$UNPUSHED" ]; then
  warn "Unpushed commits — push before starting new phase to avoid drift:"
  echo "$UNPUSHED" | while read -r line; do echo "     $line"; done
  echo "     → git push origin $BRANCH"
else
  green "All commits pushed"
fi

# ── CHECK 2: Uncommitted work ─────────────────────────────────────────────────
echo "Check 2 — Uncommitted work"
DIRTY=$(git status --short 2>/dev/null || true)
if [ -n "$DIRTY" ]; then
  warn "Uncommitted changes from previous phase:"
  git status --short | while read -r line; do echo "     $line"; done
  echo "     → Commit, stash, or discard before starting."
else
  green "Working tree clean"
fi

# ── CHECK 3: Behind origin/main ───────────────────────────────────────────────
echo "Check 3 — Behind origin/main"
git fetch origin --quiet 2>/dev/null || true
BEHIND=$(git log HEAD..origin/main --oneline 2>/dev/null | wc -l | tr -d ' ')
if [ "$BEHIND" -gt 0 ]; then
  warn "Branch is $BEHIND commit(s) behind origin/main"
  git log HEAD..origin/main --oneline | while read -r line; do echo "     $line"; done
  echo "     → git rebase origin/main"
else
  green "Up to date with origin/main"
fi

# ── CHECK 4: Migration drift ──────────────────────────────────────────────────
echo "Check 4 — Migration drift"
MIGRATION_DIR="$REPO_ROOT/supabase/migrations"
if [ -d "$MIGRATION_DIR" ]; then
  UNCOMMITTED_SQL=$(git status --short "$MIGRATION_DIR" 2>/dev/null | grep "\.sql" || true)
  if [ -n "$UNCOMMITTED_SQL" ]; then
    red "Uncommitted migration files — DB may be ahead of git:"
    echo "$UNCOMMITTED_SQL" | while read -r line; do echo "     $line"; done
    echo "     → Commit migration files before starting new phase work."
  else
    green "All migration files committed"
  fi

  # Rama-shared drift script (rama-os only)
  DRIFT_SCRIPT="$HOME/Developer/rama-shared/scripts/check-migration-drift.sh"
  if [ -x "$DRIFT_SCRIPT" ]; then
    DRIFT_OUT=$("$DRIFT_SCRIPT" 2>&1 || true)
    if echo "$DRIFT_OUT" | grep -q "DRIFT"; then
      red "DB schema drift — changes applied but not in git:"
      echo "$DRIFT_OUT" | head -10
    fi
  fi
else
  skip "No supabase/migrations directory in this repo"
fi

# ── CHECK 5: Secrets in code ──────────────────────────────────────────────────
echo "Check 5 — Live secrets in code"
SECRET_HITS=$(grep -rE "(sk_live_|pk_live_)[a-zA-Z0-9]{20,}|whsec_live_[a-zA-Z0-9]{20,}|SUPABASE_SERVICE_ROLE_KEY\s*=\s*['\"]?ey[a-zA-Z0-9]" \
  "$REPO_ROOT" \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.env*" \
  --exclude-dir=node_modules --exclude-dir=.git \
  -l 2>/dev/null || true)
if [ -n "$SECRET_HITS" ]; then
  red "Live secrets found in source files:"
  echo "$SECRET_HITS" | while read -r line; do echo "     $line"; done
else
  green "No live secrets in source files"
fi

# ── CHECK 6: .env.local present ───────────────────────────────────────────────
echo "Check 6 — .env.local (should not exist — use Doppler)"
if [ -f "$REPO_ROOT/.env.local" ]; then
  # rama-throttle is exempt
  if [ "$REPO_NAME" = "rama-throttle" ]; then
    skip ".env.local present — rama-throttle is exempt from Doppler requirement"
  else
    warn ".env.local exists — secrets should be in Doppler, not local files"
    echo "     → Delete .env.local and add secrets to Doppler instead"
  fi
else
  green "No .env.local present"
fi

# ── CHECK 7: TypeScript baseline ──────────────────────────────────────────────
echo "Check 7 — TypeScript baseline"
if [ -f "$REPO_ROOT/package.json" ] && grep -q "type-check\|typecheck" "$REPO_ROOT/package.json" 2>/dev/null; then
  TS_OUT=$(cd "$REPO_ROOT" && pnpm type-check 2>&1 || true)
  if echo "$TS_OUT" | grep -q "error TS"; then
    red "TypeScript errors from previous phase:"
    echo "$TS_OUT" | grep "error TS" | head -10
  else
    green "TypeScript baseline clean"
  fi
else
  skip "No type-check script in package.json"
fi

# ── CHECK 8: Semgrep (repo-local config only) ─────────────────────────────────
echo "Check 8 — Semgrep security rules"
if command -v semgrep >/dev/null 2>&1 && [ -d "$REPO_ROOT/.semgrep" ]; then
  SEMGREP_OUT=$(cd "$REPO_ROOT" && semgrep --config .semgrep/ --error --quiet . 2>&1 || true)
  if echo "$SEMGREP_OUT" | grep -qE "findings|›"; then
    red "Semgrep violations inherited from previous phase:"
    echo "$SEMGREP_OUT" | grep -v "^$" | head -15
  else
    green "No semgrep violations"
  fi
elif ! command -v semgrep >/dev/null 2>&1; then
  skip "semgrep not installed (pip install semgrep)"
else
  skip "No .semgrep/ config in this repo"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: $ISSUES blocker(s) · $WARNINGS warning(s)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$ISSUES" -gt 0 ]; then
  echo "  🔴 DO NOT START THIS PHASE — $ISSUES blocker(s) found."
  echo "     Fix the issues above first."
  echo ""
  exit 1
elif [ "$WARNINGS" -gt 0 ]; then
  echo "  🟡 PROCEED WITH CAUTION — $WARNINGS warning(s) need attention before this phase closes."
  echo ""
  exit 0
else
  echo "  🟢 CLEAN BASE — safe to start this phase."
  echo ""
  exit 0
fi
