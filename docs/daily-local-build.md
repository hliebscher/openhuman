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
| **Sofort neu kompilieren** (auch ohne neue Commits) | `pnpm daily:build --force` |
| **Lokal bauen** mit uncommitteten Änderungen | `pnpm daily:build --force` oder `--no-sync` |
| Nur prüfen, nicht bauen | `pnpm daily:build --dry-run` |
| Schneller Debug-Build | `pnpm daily:build --debug` |
| Ohne upstream-Merge | `OPENHUMAN_MERGE_UPSTREAM=0 pnpm daily:build` |

> `--` vor den Flags ist mit pnpm ≥ 10 optional (siehe [Abschnitt unten](#pnpm-und-das----trennzeichen)). Beide Schreibweisen funktionieren.

**Ohne pnpm** (direkt, kein `--` nötig):

```bash
bash scripts/daily-local-build.sh --force
bash scripts/daily-local-build.sh --no-sync
bash scripts/daily-local-build.sh --dry-run
```

### pnpm und das `--`-Trennzeichen

**Mit pnpm ≥ 10 reichst du Flags direkt durch — `--` ist optional:**

```bash
pnpm daily:build --force       # funktioniert (pnpm 10.10.0, verifiziert 2026-06-12)
pnpm daily:build -- --force    # funktioniert ebenfalls
```

Verifizierung:

```bash
pnpm daily:build --dry-run     # → bash scripts/daily-local-build.sh --dry-run
pnpm daily:build -- --dry-run  # → bash scripts/daily-local-build.sh -- --dry-run
```

Das Skript akzeptiert ein führendes `--` und überspringt es, daher ist die Variante mit `--` als Gewohnheit unschädlich. Ältere pnpm-Versionen (< 7) benötigten das `--` zwingend — wer unsicher ist, schreibt es einfach immer hin.

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

> **Wichtig — „skipped_up_to_date":** Wenn der lokale Branch bereits den
> kompletten `upstream/main` enthält (z. B. weil ein früherer Lauf heute Nacht
> schon gemergt hat), findet Schritt 4 **keinen neuen Commit** und überspringt
> den Build:
>
> ```
> [daily-build] fast-forwarded with upstream/main
> [daily-build] fork remote already at HEAD; no push needed
> [daily-build] no new commits since last sync; skipping build
> ```
>
> `last-build.json` zeigt dann `"status": "skipped_up_to_date"`. Das ist **kein
> Fehler** — Main ist synchron, es gibt schlicht nichts Neues zu bauen. Willst du
> trotzdem eine frische `.app`, nimm `--force` (siehe unten).
>
> Prüfen, ob wirklich alles drin ist:
>
> ```bash
> git fetch upstream
> git rev-list --count HEAD..upstream/main   # 0 = vollständig synchron
> ```

### Sofort bauen (`--force`)

```bash
pnpm daily:build --force
```

Zwei Fälle:

| Working Tree | Verhalten |
|--------------|-----------|
| **Sauber** (keine uncommitteten tracked Änderungen) | Normaler Git-Sync, danach **immer** bauen — auch wenn kein neuer Commit |
| **Dirty** (lokale Änderungen an getrackten Dateien) | Git-Sync wird **übersprungen**, aktueller Stand wird kompiliert (Warnung + Liste der Dateien im Log) |

Typisch bei lokalen Skript-/Config-Änderungen, die du noch nicht committen willst.

### Nur bauen, kein Git (`--no-sync`)

```bash
pnpm daily:build --no-sync
```

Überspringt `git fetch`, Merge und Push komplett. Baut den **aktuellen Working Tree** — auch mit uncommitteten Änderungen. Sinnvoll, wenn du genau den lokalen Stand testen willst.

### Erst prüfen, nicht bauen

```bash
pnpm daily:build --dry-run
```

### Debug-Build (schneller, größere Binary)

```bash
pnpm daily:build --debug
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
pnpm daily:build --force
# oder explizit ohne Git:
pnpm daily:build --no-sync
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
pnpm daily:build --force
```

---

## 6. Kurzreferenz

```bash
# ── Einmalig ──
git checkout daily-local-build && pnpm install
pnpm daily:build:install

# ── Manuell bauen ── (pnpm ≥ 10: -- vor den Flags ist optional)
pnpm daily:build                    # sync + bauen (nur bei neuen Commits)
pnpm daily:build --force            # immer bauen; bei dirty tree → lokal ohne sync
pnpm daily:build --no-sync          # kein git, nur aktuellen Stand kompilieren
pnpm daily:build --dry-run          # nur anzeigen, was passieren würde

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

---

## 7. Verifizierter Ablauf (Worked Example, 2026-06-12)

Konkreter Mitschnitt einer echten Session auf einem **Apple M5 Max** — zeigt
Build-Dauer, Versionssprünge und das `skipped_up_to_date`-Verhalten in der Praxis.

| # | Befehl | Ergebnis | Dauer |
|---|--------|----------|-------|
| 1 | `pnpm daily:build --no-sync` (≙ `bash scripts/daily-local-build.sh --no-sync`) | Build aus aktuellem Tree → **OpenHuman 0.57.33** (`33592058`) | ~7 min |
| 2 | `pnpm daily:build` | Fetch + Merge `upstream/main` (246 Dateien), Push zu `origin/daily-local-build` (`1ca81b1e`) → **0.57.37** | ~11 min |
| 3 | `pnpm daily:build` | `upstream/main` schon eingemergt → `no new commits` → **`status: skipped_up_to_date`**, kein Build | ~2 s |
| 4 | `pnpm daily:build --force` | Sync (nichts Neues) + erzwungener Build → **0.57.37** (`db0c6be4`) | ~3 min |

**Erkenntnisse aus dieser Session:**

- `pnpm daily:build --force` **ohne** `--` reicht das Flag in pnpm 10.10.0 korrekt
  durch — die frühere Doku-Behauptung („pnpm frisst das Flag") traf für diese
  Version nicht zu.
- Lauf #3 war **kein Fehler**: Ein vorheriger (nächtlicher) Lauf hatte
  `upstream/main` bereits gemergt, deshalb gab es nichts Neues. Verifiziert mit
  `git rev-list --count HEAD..upstream/main` → `0`.
- Build-Zeiten: erster Voll-Build ~7–11 min (inkl. CEF-aware `cargo-tauri` ggf.
  neu installieren); reiner Re-Build bei warmem Cache ~3 min.
- ESLint-Schritt gibt aus dem Upstream-Code viele
  `react-hooks/set-state-in-effect`-**Warnings** aus — das sind Warnungen, keine
  Errors, und blockieren den Build nicht.

**Artefakte nach Lauf #4:**

```
app/src-tauri/target/aarch64-apple-darwin/release/bundle/macos/OpenHuman.app
app/src-tauri/target/aarch64-apple-darwin/release/bundle/dmg/OpenHuman_0.57.37_arm64.dmg
~/Applications/OpenHuman (Daily).app   (Symlink)
~/.local/bin/openhuman-core            (CLI-Symlink)
```
