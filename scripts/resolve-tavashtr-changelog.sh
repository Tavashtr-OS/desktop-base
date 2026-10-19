#!/bin/sh
set -eu

usage() {
  echo "Usage: $0 <tavashtr-changelog> <debian-trixie-changelog> <output-path>" >&2
  exit 2
}

fail() {
  echo "resolve-tavashtr-changelog: error: $*" >&2
  exit 1
}

[ "$#" -eq 3 ] || usage

tavashtr_changelog=$1
debian_changelog=$2
output_path=$3
suffix="+tavashtr1"

for input in "$tavashtr_changelog" "$debian_changelog"; do
  [ -f "$input" ] || fail "input file does not exist: $input"
done

command -v dpkg-parsechangelog >/dev/null 2>&1 ||
  fail "dpkg-parsechangelog is required; install devscripts"

get_field() {
  dpkg-parsechangelog --file "$1" --show-field "$2"
}

first_entry_body() {
  awk '
    NR == 1 { next }
    /^ -- / { exit }
    {
      lines[NR] = $0
      if ($0 !~ /^[[:space:]]*$/) {
        last = NR
      }
    }
    END {
      first = 2
      while (first <= last && lines[first] ~ /^[[:space:]]*$/) {
        first++
      }
      for (i = first; i <= last; i++) {
        print lines[i]
      }
    }
  ' "$1"
}

package=$(get_field "$debian_changelog" Source)
tavashtr_package=$(get_field "$tavashtr_changelog" Source)
[ "$package" = "$tavashtr_package" ] ||
  fail "package mismatch: Debian has '$package', Tavashtr has '$tavashtr_package'"

debian_version=$(get_field "$debian_changelog" Version)
case "$debian_version" in *"$suffix")
    fail "Debian version already ends in '$suffix': $debian_version"
    ;;
esac
new_version="${debian_version}${suffix}"

urgency=$(get_field "$debian_changelog" Urgency)
maintainer=$(get_field "$tavashtr_changelog" Maintainer)
tavashtr_distribution=$(get_field "$tavashtr_changelog" Distribution)

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/resolve-tavashtr-changelog.XXXXXX")
output_tmp=""
cleanup() {
  if [ -n "$output_tmp" ] && [ -f "$output_tmp" ]; then
    rm -f "$output_tmp"
  fi
  if [ -n "${tmpdir:-}" ] && [ -d "$tmpdir" ]; then
    rm -rf "$tmpdir"
  fi
}
trap cleanup 0

first_entry_body "$debian_changelog" > "$tmpdir/debian.body"
first_entry_body "$tavashtr_changelog" > "$tmpdir/tavashtr.body"

[ -s "$tmpdir/debian.body" ] ||
  fail "Debian Trixie's latest entry has no change text"

if [ "$tavashtr_distribution" = "UNRELEASED" ]; then
  [ -s "$tmpdir/tavashtr.body" ] ||
    fail "Tavashtr's UNRELEASED entry has no change text"
else
  : > "$tmpdir/tavashtr.body"
fi

output_dir=$(dirname "$output_path")
mkdir -p "$output_dir"
output_tmp=$(mktemp "$output_dir/.$(basename "$output_path").XXXXXX")

{
  printf '%s (%s) tavashtr; urgency=%s\n\n' \
    "$package" "$new_version" "$urgency"

  if [ -s "$tmpdir/tavashtr.body" ]; then
    if grep -Eq '^[[:space:]]+\[.*\][[:space:]]*$' "$tmpdir/tavashtr.body"; then
      cat "$tmpdir/tavashtr.body"
    else
      printf '  [ Tavashtr ]\n'
      cat "$tmpdir/tavashtr.body"
    fi
    printf '\n'
  fi

  printf '  [ Debian ]\n'
  cat "$tmpdir/debian.body"
  printf '\n'

  printf '\n -- %s  %s\n\n' "$maintainer" "$(date -R)"
  cat "$tavashtr_changelog"
} > "$output_tmp"

parsed_version=$(get_field "$output_tmp" Version)
[ "$parsed_version" = "$new_version" ] ||
  fail "generated version mismatch: expected '$new_version', got '$parsed_version'"

mv "$output_tmp" "$output_path"
output_tmp=""

echo "Wrote $new_version changelog entry to $output_path"
