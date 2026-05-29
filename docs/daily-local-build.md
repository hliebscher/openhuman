# Täglicher lokaler macOS-Build (Fork-Workflow)

Anleitung für einen **persönlichen Build-Rechner**, der OpenHuman aus **deinem GitHub-Fork** baut — nicht aus dem upstream-Repo direkt.

| Einstellung | Wert (Standard bei dir) |
|-------------|-------------------------|
| Fork-Remote | `origin` → `github.com/hliebscher/openhuman` |
| Branch | `daily-local-build` |
| Upstream-Merge | ja (`upstream/main` von tinyhumansai/openhuman) |
| Automatik | launchd, täglich 06:00 |
| macOS-Architektur | **nur Apple Silicon** (`aarch64-apple-darwin` / `arm64`) — kein Intel |
| Launcher | `~/Applications/OpenHuman (Daily).app` |

---

## 1. Voraussetzungen (einmalig)

### Software

```bash
# Node / pnpm (Repo-Pin beachten)
node -v    # >= 24
pnpm -v

# Rust (wird via rust-toolchain.toml auf 1.93.0 gepinnt)
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# CEF-Cache (wird beim ersten Tauri-Build befüllt)
ls ~/Library/Caches/tauri-cef
```

**Wichtig:** Beim Bauen muss **rustup-Rust vor Homebrew-Rust** in der `PATH` stehen. Das erledigt das Skript automatisch. Wenn du manuell baust:

```bash
export PATH="$HOME/.rustup/toolchains/1.93.0-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$PWD/.cache/cargo-install/bin:/opt/homebrew/bin:$PATH"
export CEF_PATH="$HOME/Library/Caches/tauri-cef"
```

### Repository klonen & Remotes

```bash
git clone https://github.com/hliebscher/openhuman.git
cd openhuman

git remote add upstream https://github.com/tinyhumansai/openhuman.git   # falls noch nicht da
git fetch --all

git checkout daily-local-build
git submodule update --init --recursive
pnpm install
```

Optional `.env` aus `.env.example` anlegen (Backend-URL etc.) — das Skript lädt `.env` beim Build.

---

## 2. Automatischen Tages-Build installieren

Vom **Repo-Root**:

```bash
pnpm daily:build:install
```

Das legt einen launchd-Job an:

| | |
|---|---|
| Plist | `~/Library/LaunchAgents/com.openhuman.daily-build.plist` |
| Zeitplan | täglich **06:00** (lokal) |
| Logs | `target/daily-build/logs/` |

**Andere Uhrzeit:**

```bash
bash scripts/install-daily-build-launchd.sh --hour 7 --minute 30
```

**Deinstallieren:**

```bash
bash scripts/install-daily-build-launchd.sh --unload
```

### Was der Job jeden Tag macht

1. `git fetch origin` (+ `upstream`)
2. Branch `daily-local-build` mit `origin/daily-local-build` abgleichen
3. `upstream/main` mergen und zurück zu `origin` pushen (falls neue Commits)
4. **Nur bei neuen Commits:** Submodule, `pnpm install`, Release-Build, DMG
5. Symlink: `~/Applications/OpenHuman (Daily).app`

Status der letzten Ausführung:

```bash
cat target/daily-build/last-build.json
tail -f target/daily-build/logs/latest.log
```

---

## 3. Manuell bauen (sofort nach Änderungen)

### Befehle im Überblick

| Ziel | Befehl |
|------|--------|
| Remote holen + bauen, **nur bei neuen Commits** | `pnpm daily:build` |
| **Sofort neu kompilieren** (auch ohne neue Commits) | `pnpm daily:build -- --force` |
| **Lokal bauen** mit uncommitteten Änderungen | `pnpm daily:build -- --force` oder `--no-sync` |
| Nur prüfen, nicht bauen | `pnpm daily:build -- --dry-run` |
| Schneller Debug-Build | `pnpm daily:build -- --debug` |
| Ohne upstream-Merge | `OPENHUMAN_MERGE_UPSTREAM=0 pnpm daily:build` |

**Ohne pnpm** (direkt, kein `--` nötig):

```bash
bash scripts/daily-local-build.sh --force
bash scripts/daily-local-build.sh --no-sync
bash scripts/daily-local-build.sh --dry-run
```

### pnpm und das `--`-Trennzeichen

Bei `pnpm` trennt `--` pnpm-Argumente von Skript-Argumenten:

```bash
pnpm daily:build -- --force    # richtig
pnpm daily:build --force       # falsch — pnpm frisst das Flag
```

Das Skript akzeptiert `--` und leitet die Flags danach weiter.

### Standard-Lauf (mit Git-Sync)

```bash
cd /pfad/zu/openhuman
pnpm daily:build
```

Ablauf:

1. `git fetch origin` (+ optional `upstream`)
2. Branch `daily-local-build` mit dem Fork abgleichen
3. `upstream/main` mergen und zu `origin` pushen
4. **Build nur**, wenn sich der Commit danach geändert hat

### Sofort bauen (`--force`)

```bash
pnpm daily:build -- --force
```

Zwei Fälle:

| Working Tree | Verhalten |
|--------------|-----------|
| **Sauber** (keine uncommitteten tracked Änderungen) | Normaler Git-Sync, danach **immer** bauen — auch wenn kein neuer Commit |
| **Dirty** (lokale Änderungen an getrackten Dateien) | Git-Sync wird **übersprungen**, aktueller Stand wird kompiliert (Warnung + Liste der Dateien im Log) |

Typisch bei lokalen Skript-/Config-Änderungen, die du noch nicht committen willst.

### Nur bauen, kein Git (`--no-sync`)

```bash
pnpm daily:build -- --no-sync
```

Überspringt `git fetch`, Merge und Push komplett. Baut den **aktuellen Working Tree** — auch mit uncommitteten Änderungen. Sinnvoll, wenn du genau den lokalen Stand testen willst.

### Erst prüfen, nicht bauen

```bash
pnpm daily:build -- --dry-run
```

### Debug-Build (schneller, größere Binary)

```bash
pnpm daily:build -- --debug
```

### Nur Fork, ohne upstream-Merge

```bash
OPENHUMAN_MERGE_UPSTREAM=0 pnpm daily:build
```

---

## 4. Build-Artefakte

Nach erfolgreichem Release-Build (**Apple Silicon only**):

| Artefakt | Pfad |
|----------|------|
| App | `app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/OpenHuman.app` |
| Core in der App (MCP/CLI) | `…/OpenHuman.app/Contents/MacOS/openhuman-core` |
| Core für Skripte | `target/release/openhuman-core` (Kopie aus dem arm64-Build) |
| CLI im Terminal | `~/.local/bin/openhuman-core` (Symlink auf die Staging-Binary) |
| DMG | `…/bundle/dmg/OpenHuman_<version>_arm64.dmg` |
| Launcher | `~/Applications/OpenHuman (Daily).app` |

Das Skript baut `openhuman-core` separat und kopiert die Binary nach:

1. **`Contents/MacOS/openhuman-core`** neben `OpenHuman` (Release-MCP-Pfad in der App)
2. **`target/release/openhuman-core`** im Repo-Root (für `serve`, Tests, Skripte)
3. **`~/.local/bin/openhuman-core`** — Symlink für Terminal-CLI (`openhuman-core serve`, `openhuman-core mcp`, …)

Falls `~/.local/bin` noch nicht in der `PATH` steht, wird es einmalig in `.zshrc` / `.bashrc` ergänzt.

### CLI ohne vollen App-Build

Wenn nur die Core-Binary fehlt (z. B. MCP-Einstellungen in der App zeigen „Binary not found“):

```bash
pnpm daily:cli
# oder nach einem Daily-Build automatisch mit dabei
```

Prüfen:

```bash
openhuman-core --help
openhuman-core serve   # JSON-RPC auf :7788 (eigenes Terminal)
```

Es gibt **keine** Intel- (`x86_64`) oder Universal-Builds in diesem Workflow.

App starten:

```bash
open ~/Applications/OpenHuman\ \(Daily\).app
# oder DMG mounten und App in Programme ziehen
```

---

## 5. Typische Probleme

### „working tree has uncommitted tracked changes“

**Symptom** (ohne `--force`):

```
[daily-build] working tree has uncommitted tracked changes; refusing to sync/build
[daily-build] dirty files:
[daily-build]   M scripts/daily-local-build.sh
```

**Ursache:** Getrackte Dateien sind lokal geändert. Ohne Flag bricht das Skript ab — Git-Sync soll nichts überschreiben.

**Betroffene Dateien anzeigen:**

```bash
git status --porcelain
```

**Lösung A — lokal bauen, Änderungen behalten (empfohlen beim Entwickeln):**

```bash
pnpm daily:build -- --force
# oder explizit ohne Git:
pnpm daily:build -- --no-sync
```

**Lösung B — Working Tree säubern, dann normaler Sync-Build:**

```bash
git stash push -m "vor daily build"
pnpm daily:build
git stash pop
```

**Lösung C — Änderungen committen und pushen:**

```bash
git add -A && git commit -m "…"
git push origin daily-local-build
pnpm daily:build
```

> Untracked Dateien (z. B. neue Docs) blockieren **nicht**. Nur **getrackte** Änderungen (`M`, `D` in `git status`).

### Build schlägt bei `tauri:ensure` / CEF-Helper fehl

Meist falsche Rust-Version in der PATH (Homebrew statt rustup). Immer `pnpm daily:build` nutzen — nicht rohes `cargo tauri` ohne PATH-Setup.

### launchd-Job läuft nicht

```bash
launchctl print "gui/$(id -u)/com.openhuman.daily-build"
cat target/daily-build/logs/launchd.stderr.log
```

Job neu laden:

```bash
pnpm daily:build:install
```

### Merge-Konflikt mit upstream/main

Der Job stoppt mit Fehler. Manuell lösen:

```bash
git checkout daily-local-build
git fetch upstream origin
git merge upstream/main
# Konflikte lösen
git push origin daily-local-build
pnpm daily:build -- --force
```

---

## 6. Kurzreferenz

```bash
# ── Einmalig ──
git checkout daily-local-build && pnpm install
pnpm daily:build:install

# ── Manuell bauen ──
pnpm daily:build                    # sync + bauen (nur bei neuen Commits)
pnpm daily:build -- --force         # immer bauen; bei dirty tree → lokal ohne sync
pnpm daily:build -- --no-sync       # kein git, nur aktuellen Stand kompilieren
pnpm daily:build -- --dry-run       # nur anzeigen, was passieren würde

# Direkt (ohne pnpm --):
bash scripts/daily-local-build.sh --force
bash scripts/daily-local-build.sh --no-sync

# ── Logs & Status ──
tail -f target/daily-build/logs/latest.log
cat target/daily-build/last-build.json

# ── CLI (Terminal / MCP-Snippets) ──
pnpm daily:cli
openhuman-core --help

# ── App starten ──
open ~/Applications/OpenHuman\ \(Daily\).app
```
