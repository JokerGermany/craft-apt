#!/usr/bin/env bash
# Baut ein signiertes apt-Repository aus den neuesten GitHub-Releases der Apps in apps.txt.
#
# Ablauf pro App: neuestes Release holen -> .deb je Architektur herunterladen ->
# gegen SHA256SUMS.txt des Releases prüfen -> Metadaten kontrollieren -> in reprepro aufnehmen.
# Das Repo wird bei jedem Lauf komplett neu aufgebaut (zustandslos, nur die neueste Version).
# Schlägt irgendetwas fehl, bricht das Script ab -> es wird nichts veröffentlicht und
# das bisherige Repo bleibt unverändert online.
#
# Benötigt: bash, curl, jq, gpg, reprepro, dpkg-deb, sha256sum, awk
# Umgebung:
#   APT_GPG_PRIVATE_KEY  ASCII-armored privater Schlüssel OHNE Passphrase (wird importiert)
#   GPG_FPR              optional: Fingerprint des Signaturschlüssels (sonst der erste im Schlüsselbund)
#   GH_TOKEN             optional, aber empfohlen (höheres API-Limit); in Actions: ${{ github.token }}
#   BASE_URL             optional: öffentliche URL des Repos (Standard: https://<owner>.github.io/<repo>)
#   REQUIRED_ARCHS       Architekturen, bei denen ein fehlendes .deb zum Abbruch führt (Standard: amd64)
#   OPTIONAL_ARCHS       Architekturen, bei denen ein fehlendes .deb nur eine Warnung ist (Standard: leer)
#   ALLOW_PRERELEASE     "1" = auch Pre-Releases verwenden (Standard: 0)
#   CODENAME             Name der Distribution im Repo (Standard: stable)
#   OUT                  Ausgabeverzeichnis (Standard: public)
#   APPS_FILE            Liste der GitHub-Repos (Standard: apps.txt)
#   API_BASE             GitHub-API-Adresse (Standard: https://api.github.com; nur für Tests/Enterprise)

set -euo pipefail

CODENAME="${CODENAME:-stable}"
REQUIRED_ARCHS="${REQUIRED_ARCHS:-amd64}"
OPTIONAL_ARCHS="${OPTIONAL_ARCHS:-}"
ALLOW_PRERELEASE="${ALLOW_PRERELEASE:-0}"
OUT="${OUT:-public}"
APPS_FILE="${APPS_FILE:-apps.txt}"
API_BASE="${API_BASE:-https://api.github.com}"

die()  { echo "FEHLER: $*" >&2; exit 1; }
warn() { echo "WARNUNG: $*" >&2; }
log()  { echo "==> $*"; }

for tool in curl jq gpg reprepro dpkg-deb sha256sum awk; do
  command -v "$tool" >/dev/null 2>&1 || die "Werkzeug fehlt: $tool"
done
[ -f "$APPS_FILE" ] || die "$APPS_FILE nicht gefunden"

# Debian-Architektur -> Dateiname-Teil der Upstream-Releases
upstream_arch() {
  case "$1" in
    amd64)   echo x86_64 ;;
    arm64)   echo aarch64 ;;
    riscv64) echo riscv64 ;;
    *) die "Architektur '$1' wird nicht unterstützt" ;;
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

# ---------------------------------------------------------------- Signaturschlüssel
[ -n "${APT_GPG_PRIVATE_KEY:-}" ] || die "APT_GPG_PRIVATE_KEY ist leer (GitHub-Secret anlegen, siehe README)"
printf '%s\n' "$APT_GPG_PRIVATE_KEY" | gpg --batch --quiet --import
FPR="${GPG_FPR:-$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')}"
[ -n "$FPR" ] || die "Kein privater Schlüssel im Schlüsselbund gefunden"
log "Signiere mit Schlüssel $FPR"

# ---------------------------------------------------------------- reprepro-Konfiguration
ARCHS="$(echo "$REQUIRED_ARCHS $OPTIONAL_ARCHS" | xargs)"
cat > "$REPO/conf/distributions" <<CONF
Origin: craft-apt
Label: craft-apt
Codename: $CODENAME
Suite: $CODENAME
Architectures: $ARCHS
Components: main
Description: Inoffizielles apt-Repository mit den neuesten Releases der Craft-Apps
SignWith: $FPR
CONF

# ---------------------------------------------------------------- Apps verarbeiten
included=0
while IFS= read -r line || [ -n "$line" ]; do
  gh_repo="$(printf '%s' "${line%%#*}" | xargs)"
  [ -n "$gh_repo" ] || continue
  [[ "$gh_repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "Ungültiger Repo-Name in $APPS_FILE: '$gh_repo'"

  log "$gh_repo: suche neuestes Release"
  releases_json="$(api "$API_BASE/repos/$gh_repo/releases?per_page=20")" \
    || die "$gh_repo: GitHub-API-Abfrage fehlgeschlagen (Repo-Name falsch oder Rate-Limit? GH_TOKEN setzen)"
  release="$(jq -c --arg pre "$ALLOW_PRERELEASE" \
    '[.[] | select(.draft==false) | select($pre=="1" or .prerelease==false)] | first // empty' \
    <<<"$releases_json")"
  [ -n "$release" ] || die "$gh_repo: kein veröffentlichtes Release gefunden"
  tag="$(jq -r '.tag_name' <<<"$release")"
  log "$gh_repo: Release $tag"

  dl="$WORK/dl/${gh_repo//\//__}"
  mkdir -p "$dl"

  asset_url() { jq -r --arg re "$1" '.assets[] | select(.name|test($re)) | .browser_download_url' <<<"$release"; }

  # Prüfsummen-Datei ist Pflicht: sie wird erst am Ende des Release-Workflows erzeugt
  # und schützt so auch vor unvollständig hochgeladenen Releases.
  sums_url="$(asset_url '^SHA256SUMS\.txt$' | head -n1)"
  [ -n "$sums_url" ] || die "$gh_repo $tag: SHA256SUMS.txt fehlt (Release evtl. noch nicht fertig)"
  curl -fsSL -o "$dl/SHA256SUMS.txt" "$sums_url"

  for arch in $REQUIRED_ARCHS $OPTIONAL_ARCHS; do
    up="$(upstream_arch "$arch")"
    urls="$(asset_url "-linux-${up}\\.deb\$")"
    if [ -z "$urls" ]; then
      case " $REQUIRED_ARCHS " in
        *" $arch "*) die "$gh_repo $tag: kein .deb für $arch gefunden" ;;
        *) warn "$gh_repo $tag: kein .deb für $arch – übersprungen"; continue ;;
      esac
    fi
    while IFS= read -r url; do
      name="$(basename "$url")"
      log "Lade $name"
      curl -fsSL -o "$dl/$name" "$url"

      expected="$(awk -v f="$name" '{n=$2; sub(/^\*/,"",n); if (n==f) print $1}' "$dl/SHA256SUMS.txt")"
      actual="$(sha256sum "$dl/$name" | awk '{print $1}')"
      [ -n "$expected" ] || die "$name steht nicht in SHA256SUMS.txt"
      [ "$expected" = "$actual" ] || die "Prüfsumme von $name stimmt nicht (erwartet $expected, erhalten $actual)"

      pkg="$(dpkg-deb -f "$dl/$name" Package)"
      ver="$(dpkg-deb -f "$dl/$name" Version)"
      darch="$(dpkg-deb -f "$dl/$name" Architecture)"
      [ "$darch" = "$arch" ] || die "$name: Architektur im Paket ist '$darch', erwartet '$arch'"
      log "OK: $pkg $ver ($darch)"

      reprepro -b "$REPO" includedeb "$CODENAME" "$dl/$name"
      included=$((included + 1))
    done <<<"$urls"
  done
done < "$APPS_FILE"

[ "$included" -gt 0 ] || die "Kein Paket aufgenommen"

# ---------------------------------------------------------------- Ausgabe zusammenstellen
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$REPO/dists" "$REPO/pool" "$OUT/"
gpg --export "$FPR"           > "$OUT/craft-apt.gpg"   # binäres Schlüsselbund, für signed-by
gpg --armor --export "$FPR"   > "$OUT/craft-apt.asc"   # ASCII-Variante zum Ansehen/Prüfen
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
<html lang="de"><meta charset="utf-8"><title>craft-apt</title>
<body style="font-family:system-ui,sans-serif;max-width:50rem;margin:2rem auto;padding:0 1rem">
<h1>craft-apt</h1>
<p>Inoffizielles apt-Repository für Craft-Apps (automatisch aus den GitHub-Releases gebaut).</p>
<h2>Einbinden</h2>
<pre>sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSL $BASE_URL/craft-apt.gpg -o /etc/apt/keyrings/craft-apt.gpg
echo "deb [signed-by=/etc/apt/keyrings/craft-apt.gpg] $BASE_URL $CODENAME main" \\
  | sudo tee /etc/apt/sources.list.d/craft-apt.list
sudo apt update</pre>
<p>Schlüssel-Fingerprint: <code>$FPR_SHORT</code></p>
<h2>Enthaltene Pakete</h2>
<pre>$PKG_LIST</pre>
<p>Stand: $(date -u '+%Y-%m-%d %H:%M UTC')</p>
</body></html>
HTML

log "Fertig. Pakete im Repo:"
reprepro -b "$REPO" list "$CODENAME"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo "### Pakete im Repo"; echo '```'; reprepro -b "$REPO" list "$CODENAME"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
