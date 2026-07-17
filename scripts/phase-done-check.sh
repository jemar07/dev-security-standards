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
noop_skip() { echo "  ⏭️  SKIP — $1"; }

# Generic no-op-script detector: true if every ; / && / || separated segment's
# first token is a shell builtin that does nothing observable (echo/true/:/exit).
# Not repo-specific — doesn't name any linter, so it works for any package.json.
is_noop_script() {
  local script="$1"
  [ -z "$script" ] && return 0
  local segment first_word had_segment=0
  while IFS= read -r segment; do
    segment="${segment#"${segment%%[![:space:]]*}"}"
    segment="${segment%"${segment##*[![:space:]]}"}"
    [ -z "$segment" ] && continue
    had_segment=1
    first_word=$(printf '%s' "$segment" | awk '{print $1}')
    case "$first_word" in
      echo|true|:|exit) ;;
      *) return 1 ;;
    esac
  done < <(printf '%s\n' "$script" | sed -E 's/(&&|\|\||;)/\n/g')
  [ "$had_segment" -eq 1 ] || return 0
  return 0
}

# Extracts the string value of package.json's scripts.<key>, using a real JSON
# parser so it works regardless of formatting (pretty-printed, single-line,
# minified — any valid JSON). Prints the value and exits 0 if <key> exists and
# is a string; prints nothing and exits 1 if the key is absent, not a string,
# or the file fails to parse.
#
# GATE-001 cycle 2 fix: the previous grep+sed implementation assumed one
# "key": "value" pair per line. On minified/single-line JSON, grep -m1 returns
# the ENTIRE line (every key on it), and the sed anchor `^[^:]*:` matches up to
# the FIRST colon in the file — not the target key's colon — so it silently
# fails to extract anything and the caller falls through to a false PASS. A
# real parser has no such assumption.
#
# Prefers node (already required elsewhere in this ecosystem's tooling), then
# python3, then falls back to the original line-based regex ONLY if neither
# interpreter is present — that fallback is a documented best-effort for
# pretty-printed JSON and is not relied on to catch minified no-ops.
extract_package_script() {
  local pkg="$1" key="$2"
  if command -v node >/dev/null 2>&1; then
    node -e '
      const fs = require("fs");
      const key = process.argv[1];
      const pkgPath = process.argv[2];
      try {
        const data = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
        const val = data && data.scripts && data.scripts[key];
        if (typeof val === "string") {
          process.stdout.write(val);
          process.exit(0);
        }
      } catch (e) {}
      process.exit(1);
    ' "$key" "$pkg" 2>/dev/null
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json, sys
key = sys.argv[1]
path = sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    val = (data.get("scripts") or {}).get(key)
    if isinstance(val, str):
        sys.stdout.write(val)
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$key" "$pkg" 2>/dev/null
    return $?
  fi
  # Last-resort fallback: neither node nor python3 is on PATH. Only reliable
  # for pretty-printed, one-key-per-line JSON — documented limitation.
  local line
  line=$(grep -m1 "\"$key\"[[:space:]]*:[[:space:]]*\"" "$pkg" 2>/dev/null)
  [ -z "$line" ] && return 1
  printf '%s' "$line" | sed -E "s/^[^:]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\\1/"
  return 0
}

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
if [ -f "$REPO_ROOT/package.json" ] && LINT_SCRIPT_VALUE=$(extract_package_script "$REPO_ROOT/package.json" lint); then
  if is_noop_script "$LINT_SCRIPT_VALUE" || printf '%s' "$LINT_SCRIPT_VALUE" | grep -qi "disabled"; then
    noop_skip "Lint script is a no-op (\"$LINT_SCRIPT_VALUE\") — cannot verify lint cleanliness. This does NOT count as a pass."
  elif $FIX_MODE; then
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

  # A sibling worktree must validate its own committed migration set. Falling
  # back to the shared checkout is only for repos that do not own this script.
  WORKTREE_DRIFT_SCRIPT="$REPO_ROOT/scripts/check-migration-drift.sh"
  FALLBACK_DRIFT_SCRIPT="$HOME/Developer/rama-shared/scripts/check-migration-drift.sh"
  if [ -x "$WORKTREE_DRIFT_SCRIPT" ]; then
    DRIFT_SCRIPT="$WORKTREE_DRIFT_SCRIPT"
  else
    DRIFT_SCRIPT="$FALLBACK_DRIFT_SCRIPT"
  fi
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

# ── GATE 7: Semgrep (diff-aware — only NEW findings in changed files can fail) ─
echo "Gate 7 — Semgrep security rules"
if command -v semgrep >/dev/null 2>&1 && [ -d "$REPO_ROOT/.semgrep" ]; then
  SEMGREP_SCOPE_ERROR=""
  SEMGREP_BASE_REF="${PHASE_DONE_BASE_REF:-origin/main}"

  if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "${SEMGREP_BASE_REF}^{commit}" >/dev/null 2>&1; then
    SEMGREP_SCOPE_ERROR="base ref '$SEMGREP_BASE_REF' is unavailable; set PHASE_DONE_BASE_REF to a trusted review base"
  else
    SEMGREP_MERGE_BASE=$(git -C "$REPO_ROOT" merge-base "$SEMGREP_BASE_REF" HEAD 2>/dev/null || true)
    [ -z "$SEMGREP_MERGE_BASE" ] && SEMGREP_SCOPE_ERROR="merge base with '$SEMGREP_BASE_REF' is unavailable"
  fi

  if [ -z "$SEMGREP_SCOPE_ERROR" ] && ! SEMGREP_COMMITTED_FILES=$(git -C "$REPO_ROOT" diff --name-only --no-color "$SEMGREP_MERGE_BASE" HEAD 2>&1); then
    SEMGREP_SCOPE_ERROR="committed file diff failed"
  fi
  if [ -z "$SEMGREP_SCOPE_ERROR" ] && ! SEMGREP_STAGED_FILES=$(git -C "$REPO_ROOT" diff --name-only --no-color --cached HEAD 2>&1); then
    SEMGREP_SCOPE_ERROR="staged file diff failed"
  fi
  if [ -z "$SEMGREP_SCOPE_ERROR" ] && ! SEMGREP_UNSTAGED_FILES=$(git -C "$REPO_ROOT" diff --name-only --no-color 2>&1); then
    SEMGREP_SCOPE_ERROR="unstaged file diff failed"
  fi
  if [ -z "$SEMGREP_SCOPE_ERROR" ] && ! SEMGREP_UNTRACKED_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>&1); then
    SEMGREP_SCOPE_ERROR="untracked file inventory failed"
  fi

  if [ -n "$SEMGREP_SCOPE_ERROR" ]; then
    red "Semgrep diff scope failed closed: $SEMGREP_SCOPE_ERROR"
  else
    SEMGREP_CHANGED_FILES=$(printf '%s\n%s\n%s\n%s\n' \
      "$SEMGREP_COMMITTED_FILES" "$SEMGREP_STAGED_FILES" "$SEMGREP_UNSTAGED_FILES" "$SEMGREP_UNTRACKED_FILES" \
      | awk 'NF && !seen[$0]++')

    SEMGREP_SCAN_TARGETS=()
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$REPO_ROOT/$f" ] && SEMGREP_SCAN_TARGETS+=("$f")
    done <<< "$SEMGREP_CHANGED_FILES"

    # Informational only — the full-repo count is never allowed to fail the gate.
    SEMGREP_FULL_OUT=$(cd "$REPO_ROOT" && semgrep --config .semgrep/ --error --quiet --json . 2>/dev/null)
    SEMGREP_FULL_EXIT=$?
    if [ "$SEMGREP_FULL_EXIT" -eq 0 ] || [ "$SEMGREP_FULL_EXIT" -eq 1 ]; then
      SEMGREP_FULL_COUNT=$(printf '%s' "$SEMGREP_FULL_OUT" | grep -o '"check_id"' | wc -l | tr -d ' ')
    else
      SEMGREP_FULL_COUNT="unavailable"
    fi

    if [ "${#SEMGREP_SCAN_TARGETS[@]}" -eq 0 ]; then
      green "No changed files in semgrep scope — clean pass (0 new / $SEMGREP_FULL_COUNT pre-existing)"
    else
      SEMGREP_OUT=$(cd "$REPO_ROOT" && semgrep --config .semgrep/ --error --quiet --json "${SEMGREP_SCAN_TARGETS[@]}" 2>&1)
      SEMGREP_SCAN_EXIT=$?
      if [ "$SEMGREP_SCAN_EXIT" -eq 0 ]; then
        # --error guarantees exit 0 means zero findings at all — nothing to
        # filter, and no JSON parse needed for this fast path.
        green "No new semgrep findings in ${#SEMGREP_SCAN_TARGETS[@]} changed file(s) (0 new / $SEMGREP_FULL_COUNT pre-existing)"
      else
        # GATE-001 cycle 2 defect 1 fix: a nonzero exit here previously meant
        # "fail the gate" outright, scanning each changed file's FULL current
        # content — so a branch that merely touched a file already carrying a
        # pre-existing finding failed Gate 7, misreported as "1 new". That is
        # file-level scoping; Gate 4 in this same script already demonstrates
        # the correct finding-level pattern (git diff --unified=0, inspect
        # only added lines). Reused here: a finding only counts as NEW if its
        # line number is one this branch actually added.
        #
        # Step 1 — compute, per changed file, the set of line numbers this
        # branch added (relative to the merge-base), matching exactly what
        # semgrep scanned (the on-disk working-tree content): `git diff
        # <merge-base> -- file` (no --cached) diffs the merge-base against the
        # working tree directly, so it already reflects staged+unstaged+
        # committed changes as they exist on disk. Untracked (never-added)
        # files have no git history to diff against, so every line in them
        # counts as added.
        SEMGREP_ADD_LINE_ERROR=""
        SEMGREP_TRACKED_TARGETS=()
        SEMGREP_UNTRACKED_TARGETS=()
        for semgrep_target_file in "${SEMGREP_SCAN_TARGETS[@]}"; do
          if printf '%s\n' "$SEMGREP_UNTRACKED_FILES" | grep -qxF "$semgrep_target_file"; then
            SEMGREP_UNTRACKED_TARGETS+=("$semgrep_target_file")
          else
            SEMGREP_TRACKED_TARGETS+=("$semgrep_target_file")
          fi
        done

        SEMGREP_ADDED_LINES_FILE=$(mktemp "${TMPDIR:-/tmp}/phase-done-semgrep-added.XXXXXX")
        : > "$SEMGREP_ADDED_LINES_FILE"

        if [ "${#SEMGREP_TRACKED_TARGETS[@]}" -gt 0 ]; then
          if ! SEMGREP_TRACKED_DIFF=$(git -C "$REPO_ROOT" diff --unified=0 --no-color "$SEMGREP_MERGE_BASE" -- "${SEMGREP_TRACKED_TARGETS[@]}" 2>&1); then
            SEMGREP_ADD_LINE_ERROR="added-line diff failed for changed files"
          else
            printf '%s\n' "$SEMGREP_TRACKED_DIFF" | awk '
              /^\+\+\+ b\// { file = substr($0, 7); next }
              /^@@/ {
                if (!file) next
                line = $0
                sub(/^@@ -[0-9]+(,[0-9]+)? \+/, "", line)
                sub(/ @@.*/, "", line)
                n = split(line, parts, ",")
                start = parts[1] + 0
                count = (n > 1 ? parts[2] + 0 : 1)
                for (i = 0; i < count; i++) print file ":" (start + i)
              }
            ' >> "$SEMGREP_ADDED_LINES_FILE"
          fi
        fi

        if [ -z "$SEMGREP_ADD_LINE_ERROR" ]; then
          for semgrep_target_file in "${SEMGREP_UNTRACKED_TARGETS[@]}"; do
            if ! awk -v file="$semgrep_target_file" '{ print file ":" NR }' \
              "$REPO_ROOT/$semgrep_target_file" >> "$SEMGREP_ADDED_LINES_FILE" 2>/dev/null; then
              SEMGREP_ADD_LINE_ERROR="added-line enumeration failed for untracked file $semgrep_target_file"
              break
            fi
          done
        fi

        if [ -n "$SEMGREP_ADD_LINE_ERROR" ]; then
          red "Semgrep diff scope failed closed: $SEMGREP_ADD_LINE_ERROR"
          rm -f "$SEMGREP_ADDED_LINES_FILE"
        else
          # Step 2 — parse semgrep's JSON to (path, start line, check_id) per
          # finding. Requires a real JSON parser: a regex/grep pass here would
          # reintroduce exactly the class of bug this fix targets (silent
          # misparsing), so this fails closed rather than falling back.
          SEMGREP_JSON_PARSER=""
          if command -v node >/dev/null 2>&1; then
            SEMGREP_JSON_PARSER="node"
          elif command -v python3 >/dev/null 2>&1; then
            SEMGREP_JSON_PARSER="python3"
          fi

          if [ -z "$SEMGREP_JSON_PARSER" ]; then
            red "Semgrep diff scope failed closed: no JSON parser (node or python3) available to filter findings to added lines"
            rm -f "$SEMGREP_ADDED_LINES_FILE"
          else
            SEMGREP_FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/phase-done-semgrep-findings.XXXXXX")
            if [ "$SEMGREP_JSON_PARSER" = "node" ]; then
              printf '%s' "$SEMGREP_OUT" | node -e '
                let raw = "";
                process.stdin.on("data", (d) => { raw += d; });
                process.stdin.on("end", () => {
                  let data;
                  try { data = JSON.parse(raw); } catch (e) { process.exit(2); }
                  const results = Array.isArray(data.results) ? data.results : [];
                  for (const r of results) {
                    const p = r && r.path;
                    const line = r && r.start && r.start.line;
                    const checkId = (r && r.check_id) || "unknown";
                    if (typeof p === "string" && typeof line === "number") {
                      process.stdout.write(p + ":" + line + ":" + checkId + "\n");
                    }
                  }
                });
              ' > "$SEMGREP_FINDINGS_FILE" 2>/dev/null
              SEMGREP_PARSE_EXIT=$?
            else
              printf '%s' "$SEMGREP_OUT" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
for r in (data.get("results") or []):
    p = r.get("path")
    start = r.get("start") or {}
    line = start.get("line")
    check_id = r.get("check_id", "unknown")
    if isinstance(p, str) and isinstance(line, int):
        print(f"{p}:{line}:{check_id}")
' > "$SEMGREP_FINDINGS_FILE" 2>/dev/null
              SEMGREP_PARSE_EXIT=$?
            fi

            if [ "$SEMGREP_PARSE_EXIT" -ne 0 ]; then
              # Not valid semgrep JSON — an engine-level failure (crash, OOM,
              # bad config), not a set of findings. Can't distinguish new from
              # pre-existing without it, so fail closed and show the raw
              # output rather than hiding it.
              red "New semgrep findings in changed files (could not parse semgrep output as JSON — treating as a failure; $SEMGREP_FULL_COUNT pre-existing repo-wide):"
              echo "$SEMGREP_OUT" | grep -v "^$" | head -20
            else
              # Step 3 — a finding is NEW only if "path:line" is a line this
              # branch actually added.
              SEMGREP_NEW_FINDINGS_FILE=$(mktemp "${TMPDIR:-/tmp}/phase-done-semgrep-new.XXXXXX")
              awk -F: '
                NR == FNR { added[$1 FS $2] = 1; next }
                { key = $1 FS $2; if (key in added) print }
              ' "$SEMGREP_ADDED_LINES_FILE" "$SEMGREP_FINDINGS_FILE" > "$SEMGREP_NEW_FINDINGS_FILE"

              # wc -l (not grep -c, which exits 1 — and on some greps prints
              # nothing at all — when the count is zero) so an empty
              # (all-pre-existing) result reliably yields "0", not a
              # fallback-doubled or empty value that breaks the -eq below.
              SEMGREP_NEW_COUNT=$(wc -l < "$SEMGREP_NEW_FINDINGS_FILE" | tr -d ' ')

              if [ "$SEMGREP_NEW_COUNT" -eq 0 ]; then
                green "No new semgrep findings in ${#SEMGREP_SCAN_TARGETS[@]} changed file(s) (0 new / $SEMGREP_FULL_COUNT pre-existing)"
              else
                red "New semgrep findings in changed files ($SEMGREP_NEW_COUNT new / $SEMGREP_FULL_COUNT pre-existing):"
                SEMGREP_PER_FILE=$(cut -d: -f1 "$SEMGREP_NEW_FINDINGS_FILE" \
                  | sort | uniq -c | sort -rn \
                  | awk '{count=$1; $1=""; sub(/^ /,""); print "     " $0 ": " count}')
                if [ -n "$SEMGREP_PER_FILE" ]; then
                  echo "$SEMGREP_PER_FILE" | head -20
                  SEMGREP_PER_FILE_LINES=$(echo "$SEMGREP_PER_FILE" | wc -l | tr -d ' ')
                  if [ "$SEMGREP_PER_FILE_LINES" -gt 20 ]; then
                    echo "     ... $((SEMGREP_PER_FILE_LINES - 20)) more file(s) omitted"
                  fi
                fi
              fi
              rm -f "$SEMGREP_NEW_FINDINGS_FILE"
            fi
            rm -f "$SEMGREP_FINDINGS_FILE"
          fi
          rm -f "$SEMGREP_ADDED_LINES_FILE"
        fi
      fi
    fi
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
