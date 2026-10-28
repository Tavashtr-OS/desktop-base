#!/bin/bash
set -Eeuo pipefail

package_deb=${1:?Usage: test-package-lifecycle.sh /path/to/desktop-base.deb}

export DEBIAN_FRONTEND=noninteractive

apt-get update

# Install the archive version first so dpkg exercises the upgrade path when
# the workflow-built package has a newer version.
apt-get install --yes --no-install-recommends desktop-base
previous_version=$(dpkg-query --show --showformat='${Version}' desktop-base)
package_paths=$(mktemp)
package_alternative_groups=$(mktemp)
trap 'rm -f "$package_paths" "$package_alternative_groups"' EXIT
dpkg-query --listfiles desktop-base | sort -u > "$package_paths"

built_version=$(dpkg-deb --field "$package_deb" Version)
printf 'Trixie archive version: %s\nWorkflow build version: %s\n' \
    "$previous_version" "$built_version"

if dpkg --compare-versions "$built_version" gt "$previous_version"; then
    echo 'The workflow-built package will upgrade the archive version.'
else
    echo 'The workflow-built package is not newer than the Trixie archive version.'
fi

apt-get install --yes --no-install-recommends --allow-downgrades "$package_deb"
dpkg --configure --pending
dpkg --verify desktop-base

# Retain file ownership paths from the archive version and add those from the
# workflow build. This also lets cleanup checks find alternatives left behind
# for files that the new version no longer ships.
dpkg-query --listfiles desktop-base >> "$package_paths"
sort -u -o "$package_paths" "$package_paths"

alternative_targets() {
    awk '
        /^[[:space:]]*$/ {
            if (in_slaves) in_slaves = 0
            next
        }
        /^Alternative: / {
            in_alternative = 1
            in_slaves = 0
            sub(/^Alternative: /, "")
            print
            next
        }
        in_alternative && /^Slaves:$/ {
            in_slaves = 1
            next
        }
        in_slaves && /^[[:space:]]/ {
            slave = $0
            sub(/^[[:space:]]+[^[:space:]]+[[:space:]]+/, "", slave)
            print slave
            next
        }
        in_slaves && !/^[[:space:]]/ { in_slaves = 0 }
    ' <<< "$1"
}

echo 'Checking update-alternatives groups registered by desktop-base.'
while read -r group _; do
    query=$(update-alternatives --query "$group" 2>/dev/null) || continue
    mapfile -t candidates < <(alternative_targets "$query")
    [[ ${#candidates[@]} -gt 0 ]] || continue

    package_owns_alternative=false
    for candidate in "${candidates[@]}"; do
        if grep -Fqx -- "$candidate" "$package_paths"; then
            package_owns_alternative=true
            break
        fi
    done
    [[ "$package_owns_alternative" == true ]] || continue

    printf '%s\n' "$group" >> "$package_alternative_groups"
    value=$(sed -n 's/^Value: //p' <<< "$query")
    if [[ -z "$value" || "$value" == none || ! -e "$value" ]]; then
        printf 'Alternative group %s resolves to a missing path: %s\n' "$group" "$value" >&2
        exit 1
    fi
    printf 'Alternative group %s resolves to %s\n' "$group" "$value"

    for candidate in "${candidates[@]}"; do
        if [[ ! -e "$candidate" ]]; then
            printf 'Alternative group %s registers a missing target: %s\n' \
                "$group" "$candidate" >&2
            exit 1
        fi
    done
done < <(update-alternatives --get-selections)

printf 'Discovered %s desktop-base alternative group(s).\n' \
    "$(wc -l < "$package_alternative_groups")"

apt-get remove --yes desktop-base
while IFS= read -r group; do
    query=$(update-alternatives --query "$group" 2>/dev/null) || continue
    mapfile -t candidates < <(alternative_targets "$query")
    value=$(sed -n 's/^Value: //p' <<< "$query")

    if [[ -n "$value" && "$value" != none && ! -e "$value" ]]; then
        printf 'Alternative group %s resolves to a missing path after removal: %s\n' \
            "$group" "$value" >&2
        exit 1
    fi

    for candidate in "${candidates[@]}"; do
        if grep -Fqx -- "$candidate" "$package_paths"; then
            printf 'Alternative group %s still registers a desktop-base file after removal: %s\n' \
                "$group" "$candidate" >&2
            exit 1
        fi
        if [[ ! -e "$candidate" ]]; then
            printf 'Alternative group %s registers a missing target after removal: %s\n' \
                "$group" "$candidate" >&2
            exit 1
        fi
    done
done < "$package_alternative_groups"

apt-get purge --yes desktop-base
if dpkg-query --show --showformat='${db:Status-Status}' desktop-base 2>/dev/null | grep -q installed; then
    echo 'desktop-base remains installed after purge.' >&2
    exit 1
fi

echo 'Package install, upgrade, alternative validation, removal, and purge checks passed.'
