#!/usr/bin/env bash
# Builds a signed apt repository from the newest GitHub releases of the apps listed in apps.txt.
#
# Per app: fetch the newest release -> download the .deb for each architecture ->
# verify it against the release's SHA256SUMS.txt -> check its metadata -> add it to reprepro.
# The repository is rebuilt from scratch on every run (stateless, newest version only).
# If anything fails, the script aborts: nothing is published and the previous
# repository stays online unchanged.
#
# Requires: bash, curl, jq, gpg, reprepro, dpkg-deb, sha256sum, awk
# Environment:
#   APT_GPG_PRIVATE_KEY  ASCII-armored private key WITHOUT a passphrase (imported at start)
#   GPG_FPR              optional: fingerprint of the signing key (default: first key in the keyring)
#   GH_TOKEN             optional but recommended (higher API rate limit); in Actions: ${{ github.token }}
#   BASE_URL             optional: public URL of the repo (default: https://<owner>.github.io/<repo>)
#   REQUIRED_ARCHS       architectures for which a missing .deb aborts the run (default: amd64)
#   OPTIONAL_ARCHS       architectures for which a missing .deb is only a warning (default: empty)
#   ALLOW_PRERELEASE     "1" = also use pre-releases (default: 0)
#   CODENAME             distribution name inside the repo (default: stable)
#   OUT                  output directory (default: public)
#   APPS_FILE            list of GitHub repositories (default: apps.txt)
#   API_BASE             GitHub API address (default: https://api.github.com; for tests/Enterprise only)

set -euo pipefail

CODENAME="${CODENAME:-stable}"
REQUIRED_ARCHS="${REQUIRED_ARCHS:-amd64}"
OPTIONAL_ARCHS="${OPTIONAL_ARCHS:-}"
ALLOW_PRERELEASE="${ALLOW_PRERELEASE:-0}"
OUT="${OUT:-public}"
APPS_FILE="${APPS_FILE:-apps.txt}"
API_BASE="${API_BASE:-https://api.github.com}"

die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }
log()  { echo "==> $*"; }

for tool in curl jq gpg reprepro dpkg-deb sha256sum awk; do
  command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[ -f "$APPS_FILE" ] || die "$APPS_FILE not found"

# Debian architecture -> file-name part of the upstream releases
upstream_arch() {
  case "$1" in
    amd64)   echo x86_64 ;;
    arm64)   echo aarch64 ;;
    riscv64) echo riscv64 ;;
    *) die "architecture '$1' is not supported" ;;
  esac
}

api() {
  local args=(-fsSL -H "Accept: application/vnd.github+json")
  [ -n "${GH_TOKEN:-}" ] && args+=(-H "Authorization: Bearer $GH_TOKEN")
  curl "${args[@]}" "$1"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GNUPGHOME="$WORK/gnupg"
mkdir -m 700 "$GNUPGHOME"
REPO="$WORK/repo"
mkdir -p "$REPO/conf" "$WORK/dl"

# ---------------------------------------------------------------- signing key
[ -n "${APT_GPG_PRIVATE_KEY:-}" ] || die "APT_GPG_PRIVATE_KEY is empty (create the GitHub secret, see README)"
printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
FPR="${GPG_FPR:-$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')}"
[ -n "$FPR" ] || die "no private key found in the keyring"
log "Signing with key $FPR"

# ---------------------------------------------------------------- reprepro configuration
ARCHS="$(echo "$REQUIRED_ARCHS $OPTIONAL_ARCHS" | xargs)"
cat > "$REPO/conf/distributions" <<CONF
Origin: craft-apt
Label: craft-apt
Codename: $CODENAME
Suite: $CODENAME
Architectures: $ARCHS
Components: main
Description: Unofficial apt repository with the newest releases of the Craft apps
SignWith: $FPR
CONF

# ---------------------------------------------------------------- process the apps
included=0
while IFS= read -r line || [ -n "$line" ]; do
  gh_repo="$(printf '%s' "${line%%#*}" | xargs)"
  [ -n "$gh_repo" ] || continue
  [[ "$gh_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "invalid repository name in $APPS_FILE: '$gh_repo'"

  log "$gh_repo: looking for the newest release"
  releases_json="$(api "$API_BASE/repos/$gh_repo/releases?per_page=20")" \
    || die "$gh_repo: GitHub API request failed (wrong repository name or rate limit? set GH_TOKEN)"
  release="$(jq -c --arg pre "$ALLOW_PRERELEASE" \
    '[.[] | select(.draft==false) | select($pre=="1" or .prerelease==false)] | first // empty' \
    <<<"$releases_json")"
  [ -n "$release" ] || die "$gh_repo: no published release found"
  tag="$(jq -r '.tag_name' <<<"$release")"
  log "$gh_repo: release $tag"

  dl="$WORK/dl/${gh_repo//\//__}"
  mkdir -p "$dl"

  asset_url() { jq -r --arg re "$1" '.assets[] | select(.name|test($re)) | .browser_download_url' <<<"$release"; }

  # The checksum file is mandatory: it is only created at the end of the release
  # workflow, so requiring it also protects against incompletely uploaded releases.
  sums_url="$(asset_url '^SHA256SUMS\.txt$' | head -n1)"
  [ -n "$sums_url" ] || die "$gh_repo $tag: SHA256SUMS.txt is missing (release may not be finished yet)"
  curl -fsSL -o "$dl/SHA256SUMS.txt" "$sums_url"

  for arch in $REQUIRED_ARCHS $OPTIONAL_ARCHS; do
    up="$(upstream_arch "$arch")"
    urls="$(asset_url "-linux-${up}\\.deb\$")"
    if [ -z "$urls" ]; then
      case " $REQUIRED_ARCHS " in
        *" $arch "*) die "$gh_repo $tag: no .deb found for $arch" ;;
        *) warn "$gh_repo $tag: no .deb for $arch - skipped"; continue ;;
      esac
    fi
    while IFS= read -r url; do
      name="$(basename "$url")"
      log "Downloading $name"
      curl -fsSL -o "$dl/$name" "$url"

      expected="$(awk -v f="$name" '{n=$2; sub(/^\*/,"",n); if (n==f) print $1}' "$dl/SHA256SUMS.txt")"
      actual="$(sha256sum "$dl/$name" | awk '{print $1}')"
      [ -n "$expected" ] || die "$name is not listed in SHA256SUMS.txt"
      [ "$expected" = "$actual" ] || die "checksum of $name does not match (expected $expected, got $actual)"

      pkg="$(dpkg-deb -f "$dl/$name" Package)"
      ver="$(dpkg-deb -f "$dl/$name" Version)"
      darch="$(dpkg-deb -f "$dl/$name" Architecture)"
      [ "$darch" = "$arch" ] || die "$name: architecture in the package is '$darch', expected '$arch'"
      log "OK: $pkg $ver ($darch)"

      reprepro -b "$REPO" includedeb "$CODENAME" "$dl/$name"
      included=$((included + 1))
    done <<<"$urls"
  done
done < "$APPS_FILE"

[ "$included" -gt 0 ] || die "no package was added"

# ---------------------------------------------------------------- assemble the output
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$REPO/dists" "$REPO/pool" "$OUT/"
gpg --export "$FPR"           > "$OUT/craft-apt.gpg"   # binary keyring, for signed-by
gpg --armor --export "$FPR"   > "$OUT/craft-apt.asc"   # ASCII version for viewing/checking
touch "$OUT/.nojekyll"

if [ -z "${BASE_URL:-}" ]; then
  owner="${GITHUB_REPOSITORY%%/*}"; name="${GITHUB_REPOSITORY#*/}"
  BASE_URL="https://${owner:-OWNER}.github.io/${name:-REPO}"
fi
BASE_URL="${BASE_URL%/}"

PKG_LIST="$(reprepro -b "$REPO" list "$CODENAME" | sed 's/&/\&amp;/g; s/</\&lt;/g')"
FPR_SHORT="$(printf '%s' "$FPR" | fold -w4 | paste -sd' ' -)"
cat > "$OUT/index.html" <<HTML
<!doctype html>
<html lang="en"><meta charset="utf-8"><title>craft-apt</title>
<body style="font-family:system-ui,sans-serif;max-width:50rem;margin:2rem auto;padding:0 1rem">
<h1>craft-apt</h1>
<p>Unofficial apt repository for the Craft apps (built automatically from their GitHub releases).</p>
<h2>Setup</h2>
<pre>sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL $BASE_URL/craft-apt.gpg -o /etc/apt/keyrings/craft-apt.gpg
echo "deb [signed-by=/etc/apt/keyrings/craft-apt.gpg] $BASE_URL $CODENAME main" \\
  | sudo tee /etc/apt/sources.list.d/craft-apt.list
sudo apt update</pre>
<p>Key fingerprint: <code>$FPR_SHORT</code></p>
<h2>Packages in this repository</h2>
<pre>$PKG_LIST</pre>
<p>Last updated: $(date -u '+%Y-%m-%d %H:%M UTC')</p>
</body></html>
HTML

log "Done. Packages in the repository:"
reprepro -b "$REPO" list "$CODENAME"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Packages in the repository"; echo '```'; reprepro -b "$REPO" list "$CODENAME"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
