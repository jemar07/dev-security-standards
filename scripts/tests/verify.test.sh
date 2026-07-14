#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SOURCE="$SCRIPT_DIR/../../verify.sh"
TMP_ROOT="$(mktemp -d)"
REAL_GIT="$(command -v git)"
REAL_GREP="$(command -v grep)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS_COUNT=0

fail() {
  echo "FAIL: $1"
  exit 1
}

make_fixture() {
  local name="$1"
  local repo="$TMP_ROOT/$name"

  mkdir -p "$repo/bin" "$repo/scripts/tests"
  cp "$VERIFY_SOURCE" "$repo/verify.sh"
  chmod +x "$repo/verify.sh"

  cat > "$repo/scripts/tests/phase-done-check.test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$repo/scripts/tests/verify.test.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/scripts/tests/phase-done-check.test.sh" "$repo/scripts/tests/verify.test.sh"

  cat > "$repo/bin/grep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[ "${FAIL_GREP:-0}" = "1" ] && exit 2
exec "$REAL_GREP_PATH" "$@"
SH
  chmod +x "$repo/bin/grep"

  cat > "$repo/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

is_ls_files=0
for arg in "$@"; do
  [ "$arg" = "ls-files" ] && is_ls_files=1
done
[ "${FAIL_GIT_LS_FILES:-0}" = "1" ] && [ "$is_ls_files" -eq 1 ] && exit 2
exec "$REAL_GIT_PATH" "$@"
SH
  chmod +x "$repo/bin/git"

  git -C "$repo" init -q
  git -C "$repo" config user.email "verify-test@example.invalid"
  git -C "$repo" config user.name "Verify Test"
  git -C "$repo" add verify.sh scripts/tests bin/grep bin/git
  git -C "$repo" commit -q -m "fixture baseline"
  git -C "$repo" update-ref refs/remotes/origin/main HEAD

  echo "$repo"
}

run_verify() {
  local repo="$1"
  shift
  (
    cd "$repo"
    env PATH="$repo/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
      REAL_GIT_PATH="$REAL_GIT" REAL_GREP_PATH="$REAL_GREP" \
      "$@" ./verify.sh
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

clean_repo="$(make_fixture clean)"
expect_pass "clean verifier control" run_verify "$clean_repo"

grep_error_repo="$(make_fixture grep-error)"
expect_fail_with "secret scanner error fails closed" "live-secret scanner failed" \
  run_verify "$grep_error_repo" FAIL_GREP=1

git_error_repo="$(make_fixture git-error)"
expect_fail_with "secret file inventory error fails closed" "secret file inventory failed" \
  run_verify "$git_error_repo" FAIL_GIT_LS_FILES=1

self_scan_repo="$(make_fixture self-scan)"
live_prefix="sk""_live_"
printf '\n# %sAAAAAAAAAAAAAAAAAAAAAAAA\n' "$live_prefix" >> "$self_scan_repo/verify.sh"
expect_fail_with "verifier scans itself" "verify.sh" run_verify "$self_scan_repo"

arbitrary_extension_repo="$(make_fixture arbitrary-extension-secret)"
printf '%sAAAAAAAAAAAAAAAAAAAAAAAA\n' "$live_prefix" > "$arbitrary_extension_repo/leak.txt"
expect_fail_with "arbitrary-extension secret fails" "leak.txt" run_verify "$arbitrary_extension_repo"

env_example_repo="$(make_fixture env-example-secret)"
printf 'PAYMENT_KEY=%sAAAAAAAAAAAAAAAAAAAAAAAA\n' "$live_prefix" > "$env_example_repo/.env.example"
git -C "$env_example_repo" add .env.example
expect_fail_with "live value in allowed env example fails" ".env.example" run_verify "$env_example_repo"

doppler_repo="$(make_fixture doppler-secret)"
doppler_prefix="dp"".pt."
printf '%sAAAAAAAAAAAAAAAAAAAAAAAA\n' "$doppler_prefix" > "$doppler_repo/doppler-token.txt"
expect_fail_with "Doppler token fails" "doppler-token.txt" run_verify "$doppler_repo"

missing_base_repo="$(make_fixture missing-base)"
git -C "$missing_base_repo" update-ref -d refs/remotes/origin/main
expect_fail_with "missing whitespace base fails closed" "verification base ref 'origin/main' is unavailable" \
  run_verify "$missing_base_repo"

committed_whitespace_repo="$(make_fixture committed-whitespace)"
printf 'trailing whitespace   \n' > "$committed_whitespace_repo/committed.txt"
git -C "$committed_whitespace_repo" add committed.txt
git -C "$committed_whitespace_repo" commit -q -m "add whitespace"
expect_fail_with "committed whitespace fails" "trailing whitespace" run_verify "$committed_whitespace_repo"

staged_whitespace_repo="$(make_fixture staged-whitespace)"
printf 'staged whitespace   \n' > "$staged_whitespace_repo/staged.txt"
git -C "$staged_whitespace_repo" add staged.txt
expect_fail_with "staged whitespace fails" "trailing whitespace" run_verify "$staged_whitespace_repo"

untracked_whitespace_repo="$(make_fixture untracked-whitespace)"
printf 'untracked whitespace   \n' > "$untracked_whitespace_repo/untracked.txt"
expect_fail_with "untracked whitespace fails" "whitespace errors found in untracked files" \
  run_verify "$untracked_whitespace_repo"

bounded_repo="$(make_fixture bounded-output)"
for i in $(seq 1 12); do
  printf '%sAAAAAAAAAAAAAAAAAAAAAA%s\n' "$live_prefix" "$i" > "$bounded_repo/secret-$i.md"
done
bounded_output=""
if bounded_output="$(run_verify "$bounded_repo" 2>&1)"; then
  echo "$bounded_output"
  fail "bounded secret output should fail"
fi
echo "$bounded_output" | grep -Fq "2 more line(s) omitted" || {
  echo "$bounded_output"
  fail "bounded secret output did not report omitted lines"
}
PASS_COUNT=$((PASS_COUNT + 1))
echo "PASS: verifier diagnostics are bounded"

echo ""
echo "All $PASS_COUNT verifier regression checks passed."
