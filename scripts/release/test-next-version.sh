#!/usr/bin/env bash
# Lightweight, dependency-free regression tests for next-version.sh.
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly version_script="$script_dir/next-version.sh"
readonly temporary_root="$(mktemp -d)"

cleanup() {
  rm -rf "$temporary_root"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_output() {
  local output_file="$1"
  local expected_key="$2"
  local expected_value="$3"
  local actual_value

  actual_value="$(sed -nE "s/^${expected_key}=(.*)$/\\1/p" "$output_file" | tail -n 1)"
  [[ "$actual_value" == "$expected_value" ]] \
    || fail "expected ${expected_key}=${expected_value}, got ${actual_value:-<missing>}"
}

commit() {
  local subject="$1"
  local body="${2:-$subject}"

  printf '%s\n' "${RANDOM}${subject}${body}" >> changes.txt
  git add changes.txt
  git commit -qm "$subject" -m "$body"
}

run_version_script() {
  local output_file="$1"
  GITHUB_OUTPUT="$output_file" bash "$version_script" >/dev/null
}

new_repository() {
  local name="$1"
  local repository="$temporary_root/$name"

  mkdir -p "$repository"
  git init -q "$repository"
  (
    cd "$repository"
    git config user.name 'MomoBox release test'
    git config user.email 'release-test@example.invalid'
    cp "$version_script" next-version.sh
    cat > pubspec.yaml <<'PUBSPEC'
name: momo_box
version: 0.1.0+1
PUBSPEC
    git add next-version.sh pubspec.yaml
    git commit -qm 'chore: initialize release test fixture'
  )
  printf '%s\n' "$repository"
}

# First release takes the manifest base version, rather than incrementing it.
repository="$(new_repository initial-release)"
(
  cd "$repository"
  commit 'feat: add inventory import'
  output="$temporary_root/initial-release.out"
  run_version_script "$output"
  assert_output "$output" release_required true
  assert_output "$output" release_level minor
  assert_output "$output" version 0.1.0
  assert_output "$output" tag v0.1.0
)

# Patch, minor and major changes take precedence in that order from the latest tag.
repository="$(new_repository version-increments)"
(
  cd "$repository"
  git tag v0.1.0
  commit 'fix: correct expiry calculation'
  output="$temporary_root/patch.out"
  run_version_script "$output"
  assert_output "$output" version 0.1.1
  assert_output "$output" release_level patch

  git tag v0.1.1
  commit 'fix: handle an empty batch'
  commit 'feat: add batch barcode'
  output="$temporary_root/minor.out"
  run_version_script "$output"
  assert_output "$output" version 0.2.0
  assert_output "$output" release_level minor

  git tag v0.2.0
  commit 'feat!: change backup schema' 'feat!: change backup schema

BREAKING CHANGE: old backup files require migration.'
  output="$temporary_root/major.out"
  run_version_script "$output"
  assert_output "$output" version 1.0.0
  assert_output "$output" release_level major
)

# Non-release commits must not create a package or GitHub Release.
repository="$(new_repository ignored-commit)"
(
  cd "$repository"
  git tag v0.1.0
  commit 'docs: explain backups'
  output="$temporary_root/ignored.out"
  run_version_script "$output"
  assert_output "$output" release_required false
)

printf 'PASS: next-version.sh release calculation tests\n'
