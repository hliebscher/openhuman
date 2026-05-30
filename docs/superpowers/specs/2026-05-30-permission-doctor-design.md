# Permission Doctor — Design (Phase A: CLI / doctor)

**Date:** 2026-05-30
**Branch context:** `daily-local-build` (fork-based daily local macOS build)
**Status:** Approved design, pre-implementation

## Problem

On the local `daily-local-build` workflow, features intermittently stop working "because of permissions," and there is no single place that tells the user *what* is missing and *why*. Investigation confirmed:

- macOS permission detection already exists and works (`src/openhuman/accessibility/permissions.rs`): `detect_accessibility_permission` (`AXIsProcessTrusted`), `detect_screen_recording_permission` (`CGPreflightScreenCaptureAccess`), `detect_input_monitoring_permission` (`IOHIDCheckAccess`), `detect_microphone_permission` (CPAL probe), plus `request_*` and `open_macos_privacy_pane`.
- The central diagnostic command (`openhuman.doctor_report` → `src/openhuman/doctor/core.rs`) checks models, DB, network, embeddings, workspace, scheduler — **but not a single OS permission**.
- The likely root cause of the *recurring* loss: the daily build produces an ad-hoc / unsigned `.app` bundle (`daily-local-build.sh` runs `xattr -dr com.apple.quarantine` but no stable codesign). macOS TCC grants are keyed to bundle identity, so a fresh build can read as "new" and reset Accessibility / Screen Recording grants. Nothing surfaces this as the cause.

## Scope

**Phase A (this spec):** Wire a permission + bundle-signature diagnosis into the existing `doctor` report so `openhuman-core doctor` (via the installed CLI shim) and the `openhuman.doctor_report` RPC immediately answer "what's broken and why."

**Phase B (planned next, separate spec):** A Settings UI panel with per-permission green/red status and buttons that open the correct macOS privacy pane. Phase B reuses Phase A's logic. **Not in this spec.**

## Architecture

A new blocking check function appends its findings as `DiagnosticItem`s to the existing `DoctorReport`. No new RPC method, no new schema, no new domain — the report is already a flat `Vec<DiagnosticItem { severity, category, message }>` with a counting `DoctorSummary`.

Data flow:

```
openhuman-core doctor  (CLI shim)        UI → openhuman.doctor_report
            \                              /
             → ops::doctor_report (spawn_blocking)
                       → core::run(config)
                            → items.extend(permissions::check_permissions())   // NEW
                       → DoctorSummary counts permissions items too
```

Immediately usable headless via the CLI shim, no UI required.

## Components

### 1. `src/openhuman/doctor/permissions.rs` (new file)

Sharp single responsibility; keeps `core.rs` lean. Public entry:

```rust
pub fn check_permissions() -> Vec<DiagnosticItem>
```

- Calls the existing `accessibility::detect_*` functions (does not reimplement FFI).
- Severity mapping:
  - `PermissionState::Granted` → `Severity::Ok`
  - `PermissionState::Denied`  → `Severity::Warn` (missing perms restrict features; they do not constitute a broken system → not `Error`)
  - `PermissionState::Unknown` → `Severity::Ok` with a neutral note (macOS `IOHIDCheckAccess` legitimately returns unknown)
- Each `denied` message names the affected feature (e.g. "Screen Intelligence needs Screen Recording") and the exact macOS privacy pane path to open (same pane identifiers `open_macos_privacy_pane` already uses).
- `category` for these items: `"permissions"`.

### 2. Bundle-signature diagnosis (A2 core) — same file

```rust
fn check_bundle_signature() -> DiagnosticItem   // category: "bundle"
```

- Resolve `std::env::current_exe()`, walk up to the enclosing `.app` (`…/Contents/MacOS/<bin>` → `….app`).
- If a `.app` is found: run `codesign -dvv <bundle>` and inspect the output for ad-hoc / unsigned status.
  - **ad-hoc / unsigned** → `Severity::Warn`: explains that macOS may reset TCC grants after each daily build; points at `scripts/setup-dev-codesign.sh` as the fix.
  - **stably signed** → `Severity::Ok`.
  - **no bundle found** (cargo run / tests / CLI shim outside the bundle) → `Severity::Ok`, note "not launched from a .app bundle".
- Read-only and fail-soft: if `codesign` is missing or errors, emit an `Ok`/neutral note — never an `Error`, never a panic.

### 3. Platform gating

- `#[cfg(not(target_os = "macos"))]`: `check_permissions()` returns a single `Severity::Ok` item, `category: "permissions"`, message "not applicable on this platform". Keeps the schema stable and tests deterministic on CI (Linux).

### 4. Wiring

- `src/openhuman/doctor/mod.rs`: add `mod permissions;`.
- `src/openhuman/doctor/core.rs` `run()`: `items.extend(permissions::check_permissions());` before the summary is computed (so counts include them).

## Error handling

Entirely read-only and fail-soft. The doctor must never crash or block on permission/codesign probing. Any probe failure degrades to a neutral/Ok note.

## Testing

Per project rule "tests before the next layer":

- `permissions.rs` inline `#[cfg(test)] mod tests`:
  - `PermissionState → Severity` mapping for all four permissions.
  - Bundle-path derivation from a synthetic `…/Contents/MacOS/<bin>` path → `….app`.
  - "no bundle" path (a plain `/usr/local/bin/foo`-style path) → Ok/neutral.
  - Non-macOS branch returns exactly one `permissions` Ok item.
  - No real FFI/TCC/codesign calls in tests (deterministic on all platforms).
- `src/openhuman/doctor/core_tests.rs`: assert the report now contains at least one item with `category == "permissions"`.

## Explicitly out of scope (YAGNI / Phase B)

- No UI panel, no "Repair" buttons, no automatic permission requests.
- No change to the daily build script's signing behavior (that is a separate Build-Robustness track the user deferred).

Phase A delivers diagnosis only.
