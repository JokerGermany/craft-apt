# craft-apt

Inoffizielles, signiertes apt-Repository für die Craft-Apps (z. B. **LightCraft**).
Ein GitHub-Actions-Workflow holt täglich das neueste Release aus den GitHub-Repos in `apps.txt`,
prüft das `.deb` gegen `SHA256SUMS.txt`, baut mit `reprepro` ein signiertes Repo und
veröffentlicht es über **GitHub Pages**. Danach laufen Updates ganz normal über `apt upgrade`
bzw. die Aktualisierungsverwaltung von Linux Mint – der ArtCraft Launcher muss nicht geöffnet werden.

Läuft komplett bei GitHub, unabhängig von deinem Proxmox-Server.

## Einrichtung (einmalig)

1. **Neues öffentliches Repository** auf GitHub anlegen (z. B. `craft-apt`) und den Inhalt dieses
   Ordners hineinlegen (inkl. `.github/`). Standard-Branch: `main`.
   *Nach GitHubs Doku gibt es Pages bei GitHub Free nur für öffentliche Repositories.*

2. **Signaturschlüssel erzeugen** (eigener Schlüssel nur für dieses Repo, ohne Passphrase):

   ```bash
   export GNUPGHOME="$(mktemp -d)"
   gpg --batch --passphrase '' --quick-generate-key "craft-apt <deine@mail.example>" rsa4096 sign never
   gpg --list-secret-keys --keyid-format long          # Fingerprint ansehen
   gpg --armor --export-secret-keys <FINGERPRINT> > craft-apt-private.asc
   ```

3. **Secret anlegen:** Repo → *Settings → Secrets and variables → Actions → New repository secret*
   Name `APT_GPG_PRIVATE_KEY`, Wert = kompletter Inhalt von `craft-apt-private.asc`
   (inkl. der `BEGIN`/`END`-Zeilen). Die Datei danach sicher aufbewahren (z. B. Passwortmanager) und
   vom Rechner löschen. Geht der Schlüssel verloren, erzeugst du einen neuen – dann müssen alle
   Clients den neuen öffentlichen Schlüssel einmal neu laden.

4. **Pages aktivieren:** *Settings → Pages → Build and deployment → Source: GitHub Actions*.

5. **Ersten Lauf starten:** Reiter *Actions → Update APT repo → Run workflow*.
   Im Log siehst du pro App die Release-Version, die Prüfsummen-Kontrolle und am Ende die
   enthaltenen Pakete (auch in der Zusammenfassung des Laufs).

6. **Auf dem Rechner einbinden** (ersetze `DEIN-NAME` und `craft-apt`; die fertige Anleitung mit
   den richtigen Adressen steht auch auf der Startseite der Pages-Seite):

   ```bash
   sudo install -d -m 0755 /etc/apt/keyrings
   sudo curl -fsSL https://DEIN-NAME.github.io/craft-apt/craft-apt.gpg -o /etc/apt/keyrings/craft-apt.gpg
   echo "deb [signed-by=/etc/apt/keyrings/craft-apt.gpg] https://DEIN-NAME.github.io/craft-apt stable main" \
     | sudo tee /etc/apt/sources.list.d/craft-apt.list
   sudo apt update
   sudo apt install lightcraft
   ```

   Wenn du LightCraft schon per `.deb` oder über den Launcher installiert hast, übernimmt apt
   die Updates ab dann (gleicher Paketname `lightcraft`).

## Weitere Apps hinzufügen

Zeile in `apps.txt` ergänzen (`owner/repo`), committen – fertig. Voraussetzung: Das Release enthält
`<name>-<version>-linux-<x86_64|aarch64>.deb` und eine `SHA256SUMS.txt`. Prüfe den genauen
Repo-Namen vorher auf GitHub.

## Einstellungen

Über Umgebungsvariablen im Workflow (siehe Kopf von `scripts/build-repo.sh`):

| Variable | Standard | Bedeutung |
|---|---|---|
| `REQUIRED_ARCHS` | `amd64` | fehlt hier ein `.deb`, bricht der Lauf ab (nichts wird veröffentlicht) |
| `OPTIONAL_ARCHS` | leer | z. B. `arm64`: fehlt das `.deb`, nur eine Warnung |
| `ALLOW_PRERELEASE` | `0` | `1` = auch Pre-Releases verwenden |
| `BASE_URL` | `https://<owner>.github.io/<repo>` | als *Repository variable* setzen, wenn das Repo `<owner>.github.io` heißt oder du eine eigene Domain nutzt |

## Wichtige Hinweise

- **Größe:** Ein LightCraft-`.deb` ist rund 120 MB groß. GitHub nennt für veröffentlichte Pages-Seiten
  1 GB als Obergrenze und ein weiches Limit von 100 GB Traffic pro Monat. Deshalb ist standardmäßig nur
  `amd64` aktiv; jede zusätzliche Architektur vervielfacht die Größe.
  Ein eigenes Größenlimit pro Datei ist für Pages nicht dokumentiert – ob eine ~120-MB-Datei beim
  Deployment durchgeht, zeigt der erste Lauf.
- **Nur die neueste Version:** Das Repo wird bei jedem Lauf neu aufgebaut und enthält pro App nur das
  aktuelle Release. Ältere Versionen lassen sich darüber nicht installieren.
- **Vertrauen:** `SHA256SUMS.txt` stammt aus demselben Release wie das `.deb`. Die Prüfung schützt vor
  beschädigten oder unvollständigen Downloads, **nicht** vor einem kompromittierten Upstream-Release.
  Dein Schlüssel signiert, was Upstream veröffentlicht – das Vertrauen entspricht dem direkten Download
  von GitHub.
- **Lizenz:** Nach den READMEs der Apps stehen sie unter MIT bzw. Apache-2.0. Das erlaubt grundsätzlich
  die Weitergabe; ich bin kein Jurist – bei einem breit beworbenen öffentlichen Repo die Lizenztexte lesen.
- **Zeitplan:** GitHub kann geplante Workflows in öffentlichen Repos nach 60 Tagen ohne Aktivität
  deaktivieren. Fällt der tägliche Lauf aus, im Actions-Tab wieder aktivieren oder einen Commit machen.
- **Action-Versionen:** `actions/checkout@v4`, `upload-pages-artifact@v3`, `deploy-pages@v4` stammen aus
  meinem Wissensstand. `dependabot.yml` schlägt neuere Versionen automatisch vor.
- **Inoffiziell:** Das Repo hat nichts mit dem ArtCraft-Team zu tun.
