#!/usr/bin/env bash
# Calculate the next MomoBox release version.
#
# By default, releases are inferred from Conventional Commit messages:
#   feat: ...                    -> minor
#   fix:, perf:, revert: ...     -> patch
#   type!: ... / BREAKING CHANGE -> major
# Other commits are intentionally ignored.
#
# Set RELEASE_EVERY_PUSH=true for the default branch pipeline to create one
# patch release for every push. RELEASE_SEQUENCE can provide a unique workflow
# sequence number for overlapping pushes. A tag already pointing at HEAD is
# reused so rerunning the same workflow does not create another version.
set -euo pipefail

readonly semver_tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+$'
readonly conventional_pattern='^([a-z]+)(\([^)]+\))?(!)?:[[:space:]]+.+$'

write_output() {
  local key="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

read_manifest_version() {
  local version
  version="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)(\+[0-9]+)?[[:space:]]*$/\1/p' pubspec.yaml | head -n 1)"

  if [[ -z "$version" ]]; then
    echo 'Unable to read a semantic version from pubspec.yaml.' >&2
    exit 1
  fi

  printf '%s\n' "$version"
}

latest_release_tag() {
  git tag --merged HEAD --list 'v*' \
    | grep -E "$semver_tag_pattern" \
    | sort -V \
    | tail -n 1 \
    || true
}

increment_version() {
  local version="$1"
  local level="$2"
  local major minor patch

  IFS='.' read -r major minor patch <<< "$version"
  case "$level" in
    major) printf '%d.0.0\n' "$((major + 1))" ;;
    minor) printf '%d.%d.0\n' "$major" "$((minor + 1))" ;;
    patch) printf '%d.%d.%d\n' "$major" "$minor" "$((patch + 1))" ;;
    *)
      echo "Unsupported version increment: $level" >&2
      exit 1
      ;;
  esac
}

contains_breaking_change() {
  local commit_body="$1"
  grep -Eqi '(^|[[:space:]])BREAKING[ -]CHANGE:' <<< "$commit_body"
}

release_for_every_push() {
  local previous_tag previous_version next_version existing_head_tag
  local major minor patch next_patch release_sequence

  # A rerun of a workflow must update the same Release rather than bumping
  # the version again.
  existing_head_tag="$(git tag --points-at HEAD --list 'v*' | grep -E "$semver_tag_pattern" | sort -V | tail -n 1 || true)"
  if [[ -n "$existing_head_tag" ]]; then
    next_version="${existing_head_tag#v}"
    write_output 'release_required' 'true'
    write_output 'previous_tag' "$existing_head_tag"
    write_output 'release_level' 'patch'
    write_output 'version' "$next_version"
    write_output 'tag' "$existing_head_tag"
    printf 'Reusing release %s for the current HEAD.\n' "$existing_head_tag"
    return 0
  fi

  previous_tag="$(latest_release_tag)"
  if [[ -n "$previous_tag" ]]; then
    previous_version="${previous_tag#v}"
    IFS='.' read -r major minor patch <<< "$previous_version"
    next_patch="$((patch + 1))"
    release_sequence="${RELEASE_SEQUENCE:-}"
    if [[ "$release_sequence" =~ ^[0-9]+$ ]] && (( release_sequence > next_patch )); then
      next_patch="$release_sequence"
    fi
    next_version="${major}.${minor}.${next_patch}"
  else
    next_version="$(read_manifest_version)"
  fi

  write_output 'release_required' 'true'
  write_output 'previous_tag' "$previous_tag"
  write_output 'release_level' 'patch'
  write_output 'version' "$next_version"
  write_output 'tag' "v${next_version}"
  printf 'Release v%s (patch) created for every push.\n' "$next_version"
}

main() {
  local previous_tag previous_version range commit_hash subject body
  local release_level='' ignored_count=0 releasable_count=0

  if [[ "${RELEASE_EVERY_PUSH:-false}" == 'true' ]]; then
    release_for_every_push
    return 0
  fi

  previous_tag="$(latest_release_tag)"
  if [[ -n "$previous_tag" ]]; then
    previous_version="${previous_tag#v}"
    range="${previous_tag}..HEAD"
  else
    previous_version="$(read_manifest_version)"
    # A first release uses the version declared in pubspec.yaml instead of
    # incrementing it. Subsequent releases are calculated from Git tags.
    # Passing HEAD to git log includes the full reachable history, including
    # the repository's initial commit.
    range="HEAD"
  fi

  while IFS= read -r commit_hash; do
    [[ -z "$commit_hash" ]] && continue

    subject="$(git show -s --format=%s "$commit_hash")"
    body="$(git show -s --format=%B "$commit_hash")"

    if [[ "$subject" =~ $conventional_pattern ]]; then
      local type="${BASH_REMATCH[1]}"
      local breaking_marker="${BASH_REMATCH[3]}"

      if [[ "$breaking_marker" == '!' ]] || contains_breaking_change "$body"; then
        release_level='major'
        ((releasable_count += 1))
      else
        case "$type" in
          feat)
            if [[ "$release_level" != 'major' ]]; then
              release_level='minor'
            fi
            ((releasable_count += 1))
            ;;
          fix|perf|revert)
            if [[ -z "$release_level" ]]; then
              release_level='patch'
            fi
            ((releasable_count += 1))
            ;;
          *)
            ((ignored_count += 1))
            ;;
        esac
      fi
    else
      ((ignored_count += 1))
    fi
  done < <(git log --format='%H' "$range")

  if [[ -z "$release_level" ]]; then
    write_output 'release_required' 'false'
    write_output 'previous_tag' "$previous_tag"
    printf 'No releasable Conventional Commit found since %s. Ignored commits: %d.\n' \
      "${previous_tag:-repository start}" "$ignored_count"
    return 0
  fi

  local next_version
  if [[ -z "$previous_tag" ]]; then
    next_version="$previous_version"
  else
    next_version="$(increment_version "$previous_version" "$release_level")"
  fi

  write_output 'release_required' 'true'
  write_output 'previous_tag' "$previous_tag"
  write_output 'release_level' "$release_level"
  write_output 'version' "$next_version"
  write_output 'tag' "v${next_version}"

  printf 'Release %s (%s) calculated from %d releasable commit(s); ignored commits: %d.\n' \
    "v${next_version}" "$release_level" "$releasable_count" "$ignored_count"
}

main "$@"
