# craft-apt

Unofficial, signed apt repository for the Craft apps (e.g. **LightCraft**).

A GitHub Actions workflow checks the newest release of every GitHub repository listed in `apps.txt` once a day,
verifies the `.deb` against the release's `SHA256SUMS.txt`, builds a signed repository with `reprepro` and
publishes it via **GitHub Pages**. After that, updates arrive through the normal `apt upgrade` or Linux Mint's
Update Manager. ArtCraft Launcher does not need to be opened.

It runs entirely on GitHub and does not depend on any server of your own.

> **Status:** proof of concept, not affiliated with the ArtCraft/Storyteller team. A repository run by the project
> itself, signed with the project's key, would be the better long-term solution (see the notes on size below).

## Setup (one time)

1. **Create a new public repository** on GitHub (e.g. `craft-apt`) and put the contents of this folder into it
   (including `.github/`). Default branch: `main`.
   *According to GitHub's documentation, Pages is only available for public repositories on GitHub Free.*

2. **Create a signing key** (a dedicated key just for this repository, without a passphrase):

   ```bash
   export GNUPGHOME="$(mktemp -d)"
   gpg --batch --passphrase '' --quick-generate-key "craft-apt <you@example.com>" rsa4096 sign never
   gpg --list-secret-keys --keyid-format long          # shows the fingerprint
   gpg --armor --export-secret-keys <FINGERPRINT> > craft-apt-private.asc
   ```

3. **Add the secret:** repository → *Settings → Secrets and variables → Actions → New repository secret*.
   Name: `APT_GPG_PRIVATE_KEY`, value: the complete content of `craft-apt-private.asc`
   (including the `BEGIN`/`END` lines). Keep the file somewhere safe (e.g. a password manager) and delete it from
   your machine. If the key is lost you can create a new one, but every client then has to fetch the new public key once.

4. **Enable Pages:** *Settings → Pages → Build and deployment → Source: GitHub Actions*.

5. **Start the first run:** *Actions → Update APT repo → Run workflow*.
   The log shows the release version of each app, the checksum verification and, at the end, the packages in the
   repository (also in the run's summary).

6. **Add the repository on your machine** (replace `YOUR-NAME`; the finished instructions with the correct
   addresses are also shown on the start page of the Pages site):

   ```bash
   sudo install -d -m 0755 /etc/apt/keyrings
   sudo curl -fsSL https://YOUR-NAME.github.io/craft-apt/craft-apt.gpg -o /etc/apt/keyrings/craft-apt.gpg
   echo "deb [signed-by=/etc/apt/keyrings/craft-apt.gpg] https://YOUR-NAME.github.io/craft-apt stable main" \
     | sudo tee /etc/apt/sources.list.d/craft-apt.list
   sudo apt update
   sudo apt install lightcraft
   ```

   If you already installed LightCraft from a `.deb` or through the launcher, apt takes over the updates from
   then on (same package name, `lightcraft`).

## Adding more apps

Add a line to `apps.txt` (`owner/repo`) and commit. Requirement: the release contains
`<name>-<version>-linux-<x86_64|aarch64>.deb` and a `SHA256SUMS.txt`. Check the exact repository name on GitHub first.

## Settings

Environment variables in the workflow (see the header of `scripts/build-repo.sh`):

| Variable | Default | Meaning |
|---|---|---|
| `REQUIRED_ARCHS` | `amd64` | if a `.deb` is missing for one of these, the run aborts (nothing is published) |
| `OPTIONAL_ARCHS` | empty | e.g. `arm64`: if the `.deb` is missing, only a warning is printed |
| `ALLOW_PRERELEASE` | `0` | `1` = also use pre-releases |
| `BASE_URL` | `https://<owner>.github.io/<repo>` | set as a *repository variable* if the repository is named `<owner>.github.io` or you use a custom domain |

## Notes

- **Size:** a LightCraft `.deb` is about 120 MB. GitHub gives 1 GB as the upper limit for a published Pages site and a
  soft limit of 100 GB of traffic per month. That is why only `amd64` is enabled by default; every additional
  architecture multiplies the size. As of November 2026 the x86_64 packages of all 15 Craft apps add up to roughly
  1.35 GB, so the whole suite does not fit on GitHub Pages. For a single app or a handful of apps it works fine.
  GitHub documents no per-file size limit for Pages; whether a ~120 MB file passes the deployment is shown by the
  first run.
- **Newest version only:** the repository is rebuilt from scratch on every run and contains only the current release
  of each app. Older versions cannot be installed from it.
- **Trust:** `SHA256SUMS.txt` comes from the same release as the `.deb`. The check protects against corrupted or
  incompletely uploaded downloads, **not** against a compromised upstream release. Your key signs whatever upstream
  publishes, so the trust is the same as downloading directly from GitHub.
- **License:** according to the apps' READMEs they are licensed under MIT or Apache-2.0, which generally allows
  redistribution. I am not a lawyer; read the license texts before promoting a public repository widely.
- **Schedule:** GitHub may disable scheduled workflows in public repositories after 60 days without repository
  activity. If the daily run stops, re-enable it in the Actions tab or push a commit.
- **Action versions:** `actions/checkout@v4`, `upload-pages-artifact@v3` and `deploy-pages@v4` are from my own
  knowledge. `dependabot.yml` proposes newer versions automatically.
- **Unofficial:** this repository has nothing to do with the ArtCraft team.
