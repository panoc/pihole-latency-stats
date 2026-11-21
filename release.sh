#!/bin/bash
# ==============================================================================
# release.sh - make a PHLS release in one step
#
#   ./release.sh 5.0.1                  release 5.0.1
#   ./release.sh 5.0.1 --dash 3.0.1     ... and set the dashboard's own version too
#   ./release.sh 5.1.0 --beta 2         a beta: shown as 5.1.0-beta.2 (publish it as a PRE-release)
#   ./release.sh --check                only show the versions written in the files
#
# It writes the version into every file that carries it, checks the scripts, and builds
# the three files to attach to the GitHub release (in ./release/):
#   install_phls.sh   phls_assets.tar.gz   phls_assets.tar.gz.sha256
#
# Run it from the repository folder. The PHLS files are taken from ./phls_assets/
# (or from the folder of this script if there is no phls_assets/ folder); install_phls.sh
# from the repository folder or from that same folder.
#
# Why: PHLS's update check compares the tag of the latest GitHub release with the version
# of the installed PHLS. If one file keeps an old number, the "update available" notice
# never goes away. This script keeps them all the same.
# ==============================================================================
set -e
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$PWD/phls_assets" ]; then SRC="$PWD/phls_assets"; ROOT="$PWD"
elif [ -d "$here/phls_assets" ]; then SRC="$here/phls_assets"; ROOT="$here"
else SRC="$here"; ROOT="$here"; fi
INST="$ROOT/install_phls.sh"; [ -f "$INST" ] || INST="$SRC/install_phls.sh"
OUT="$PWD/release"

die() { printf '✘ %s\n' "$*" >&2; exit 1; }
show() {
    printf '  %-26s %s\n' "phls (manager)" "$(sed -n 's/^PHLS_VERSION="\(.*\)"/\1/p' "$SRC/phls")$(sed -n 's/^PHLS_BUILD="\(..*\)"/-\1/p' "$SRC/phls")"
    printf '  %-26s %s\n' "pihole_stats.sh (engine)" "$(sed -n 's/^VERSION="v\{0,1\}\(.*\)"/\1/p' "$SRC/pihole_stats.sh" | head -n 1)"
    printf '  %-26s %s\n' "dash.html (dashboard)" "$(sed -n 's/^const currentDashVersion = "v\{0,1\}\(.*\)";/\1/p' "$SRC/dash.html")"
    printf '  %-26s %s\n' "version file" "$(tr '\n' ' ' < "$SRC/version")"
}

for f in phls pihole_stats.sh dash.html version lib/settings.sh cgi/settings favicon.png; do
    [ -e "$SRC/$f" ] || die "Missing $SRC/$f - run this from the repository folder (the one with phls_assets/)."
done
[ -f "$INST" ] || die "Missing install_phls.sh (looked in $ROOT and $SRC)."

if [ "$1" = "--check" ] || [ -z "$1" ]; then
    echo "Versions in $SRC:"; show
    [ -z "$1" ] && echo && sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

VER="${1#v}"; shift
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version must look like 5.0.1 (got '$VER')."
DASH=""; BETA=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dash) DASH="${2#v}"; shift 2; [[ "$DASH" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--dash needs a version like 3.0.1" ;;
        --beta) BETA="$2"; shift 2; [[ "$BETA" =~ ^[0-9]+$ ]] || die "--beta needs a number" ;;
        *) die "Unknown option: $1" ;;
    esac
done
[ -n "$DASH" ] || DASH=$(sed -n 's/^d=\([0-9.]*\)$/\1/p' "$SRC/version")
[ -n "$DASH" ] || DASH=$(sed -n 's/^const currentDashVersion = "v\{0,1\}\(.*\)";/\1/p' "$SRC/dash.html")

# --- write the version everywhere ---
sed -i "s/^PHLS_VERSION=\".*\"/PHLS_VERSION=\"$VER\"/" "$SRC/phls"
sed -i "s/^PHLS_BUILD=\".*\"/PHLS_BUILD=\"${BETA:+beta.$BETA}\"/" "$SRC/phls"
sed -i "0,/^VERSION=\".*\"/s//VERSION=\"v$VER\"/" "$SRC/pihole_stats.sh"
sed -i "s/^const currentDashVersion = \".*\";/const currentDashVersion = \"v$DASH\";/" "$SRC/dash.html"
printf 's=%s\nd=%s\n' "$VER" "$DASH" > "$SRC/version"

# --- check ---
bash -n "$SRC/phls" && bash -n "$SRC/pihole_stats.sh" && bash -n "$SRC/lib/settings.sh" && bash -n "$SRC/cgi/settings" && bash -n "$INST" \
    || die "A script has a syntax error - nothing was built."
[ "$(sed -n 's/^PHLS_VERSION="\(.*\)"/\1/p' "$SRC/phls")" = "$VER" ] || die "Could not set the version in phls."
[ "$(sed -n 's/^VERSION="v\(.*\)"/\1/p' "$SRC/pihole_stats.sh" | head -n 1)" = "$VER" ] || die "Could not set the version in pihole_stats.sh."

# --- build ---
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/phls_assets/lib" "$tmp/phls_assets/cgi"
cp "$SRC/pihole_stats.sh" "$SRC/phls" "$SRC/dash.html" "$SRC/favicon.png" "$SRC/version" "$tmp/phls_assets/"
cp "$SRC/lib/settings.sh" "$tmp/phls_assets/lib/"; cp "$SRC/cgi/settings" "$tmp/phls_assets/cgi/"
chmod 755 "$tmp/phls_assets/phls" "$tmp/phls_assets/pihole_stats.sh" "$tmp/phls_assets/cgi/settings"
chmod 644 "$tmp/phls_assets/dash.html" "$tmp/phls_assets/favicon.png" "$tmp/phls_assets/version" "$tmp/phls_assets/lib/settings.sh"
mkdir -p "$OUT"; rm -f "$OUT/phls_assets.tar.gz" "$OUT/phls_assets.tar.gz.sha256" "$OUT/install_phls.sh"
(cd "$tmp" && tar --owner=0 --group=0 -czf "$OUT/phls_assets.tar.gz" phls_assets)
(cd "$OUT" && sha256sum phls_assets.tar.gz > phls_assets.tar.gz.sha256)
cp "$INST" "$OUT/install_phls.sh"; chmod 755 "$OUT/install_phls.sh"

TAG="v$VER"; [ -n "$BETA" ] && TAG="v$VER-beta.$BETA"
echo "✔ Version $VER${BETA:+-beta.$BETA} written to:"; show
echo
echo "✔ Release files in $OUT:"
ls -l "$OUT" | sed -n '2,$p' | awk '{printf "  %-28s %8s bytes\n", $NF, $5}'
echo
echo "Next:"
echo "  1. Commit and push the changed files."
echo "  2. GitHub → Releases → Draft a new release → tag: $TAG"
echo "  3. Attach the 3 files from $OUT"
if [ -n "$BETA" ]; then echo "  4. Tick \"Set as a pre-release\" (users are not told about betas), then Publish."
else echo "  4. Leave \"Set as the latest release\" ticked, then Publish. Installs see it within a day."; fi
