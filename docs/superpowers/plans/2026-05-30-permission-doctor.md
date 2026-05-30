# Permission Doctor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a macOS permission + bundle-signature diagnosis to the existing `doctor` report so `openhuman-core doctor` and `openhuman.doctor_report` answer "what's broken and why."

**Architecture:** A new sibling module `src/openhuman/doctor/permissions.rs` exposes `check_permissions() -> Vec<DiagnosticItem>`, built from the already-existing `accessibility::detect_permissions()` plus a `codesign`-based bundle-signature probe. `core::run()` extends its item list with these. No new RPC method, no new schema — the report is already a flat `Vec<DiagnosticItem { severity, category, message }>` counted by `DoctorSummary`.

**Tech Stack:** Rust, `cargo test`, existing `accessibility` FFI (`AXIsProcessTrusted`, `CGPreflightScreenCaptureAccess`, `IOHIDCheckAccess`, CPAL), `codesign` CLI for signature inspection.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `src/openhuman/doctor/core.rs` (modify) | Make `DiagnosticItem::{ok,warn,error}` `pub(super)`; call `permissions::check_permissions()` in `run()`. |
| `src/openhuman/doctor/permissions.rs` (create) | All permission + bundle-signature diagnosis. Pure logic + thin probes; inline tests. |
| `src/openhuman/doctor/mod.rs` (modify) | `mod permissions;` declaration. |
| `src/openhuman/doctor/core_tests.rs` (modify) | Assert the report contains a `category == "permissions"` item. |

Design boundary: `permissions.rs` owns *severity mapping* and *message wording* as pure functions (testable without FFI), and isolates the two impure probes (`detect_permissions()`, `codesign`) behind small wrappers so tests never touch the OS.

---

### Task 1: Expose `DiagnosticItem` constructors to the doctor module tree

The constructors `ok`/`warn`/`error` are currently module-private to `core.rs`. A sibling `permissions.rs` must build `DiagnosticItem`s, so widen visibility to `pub(super)` (the `doctor` module, not the whole crate).

**Files:**
- Modify: `src/openhuman/doctor/core.rs:30-50`

- [ ] **Step 1: Widen the three constructors**

In `src/openhuman/doctor/core.rs`, change the `impl DiagnosticItem` block so each constructor is `pub(super)`:

```rust
impl DiagnosticItem {
    pub(super) fn ok(category: impl Into<String>, msg: impl Into<String>) -> Self {
        Self {
            severity: Severity::Ok,
            category: category.into(),
            message: msg.into(),
        }
    }
    pub(super) fn warn(category: impl Into<String>, msg: impl Into<String>) -> Self {
        Self {
            severity: Severity::Warn,
            category: category.into(),
            message: msg.into(),
        }
    }
    pub(super) fn error(category: impl Into<String>, msg: impl Into<String>) -> Self {
        Self {
            severity: Severity::Error,
            category: category.into(),
            message: msg.into(),
        }
    }
}
```

- [ ] **Step 2: Verify it still compiles**

Run: `cargo check --manifest-path Cargo.toml --bin openhuman-core`
Expected: PASS (no callers broke — `pub(super)` is strictly wider than private). A `dead_code` warning on `error` may appear if currently unused; that is pre-existing behavior, ignore.

- [ ] **Step 3: Commit**

```bash
git add src/openhuman/doctor/core.rs
git commit -m "refactor(doctor): pub(super) DiagnosticItem constructors for sibling modules"
```

---

### Task 2: Severity mapping (pure function, TDD)

Map `PermissionState` → `Severity` per the spec: `Granted`/`Unknown`/`Unsupported` → `Ok`, `Denied` → `Warn`. This is the one piece of branching logic worth isolating and testing directly.

**Files:**
- Create: `src/openhuman/doctor/permissions.rs`
- Modify: `src/openhuman/doctor/mod.rs:3-5`

- [ ] **Step 1: Declare the module**

In `src/openhuman/doctor/mod.rs`, add `mod permissions;` after the existing `mod core;` line:

```rust
mod core;
mod permissions;
pub mod ops;
mod schemas;
```

- [ ] **Step 2: Write the failing test (and minimal module skeleton so it compiles)**

Create `src/openhuman/doctor/permissions.rs`:

```rust
//! Doctor checks for OS-level permissions (macOS TCC) and bundle-signature
//! stability. Read-only and fail-soft: never panics, never returns `Error`
//! for a merely-missing permission — a denied grant restricts a feature, it
//! does not constitute a broken system.

use super::core::{DiagnosticItem, Severity};
use crate::openhuman::accessibility::PermissionState;

/// Severity for a single permission. Denied is a warning (feature restricted);
/// everything else (granted / unknown / unsupported) is Ok.
fn severity_for(state: &PermissionState) -> Severity {
    match state {
        PermissionState::Denied => Severity::Warn,
        PermissionState::Granted
        | PermissionState::Unknown
        | PermissionState::Unsupported => Severity::Ok,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn severity_maps_denied_to_warn_else_ok() {
        assert_eq!(severity_for(&PermissionState::Denied), Severity::Warn);
        assert_eq!(severity_for(&PermissionState::Granted), Severity::Ok);
        assert_eq!(severity_for(&PermissionState::Unknown), Severity::Ok);
        assert_eq!(severity_for(&PermissionState::Unsupported), Severity::Ok);
    }
}
```

Note: `Severity` derives `PartialEq, Eq` already (verified in `core.rs:15`), so `assert_eq!` works.

- [ ] **Step 3: Run the test, confirm it passes**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::severity_maps`
Expected: PASS. (This is a pure mapping; it passes immediately — the value of the test is locking the contract before the message/probe logic stacks on top.)

- [ ] **Step 4: Commit**

```bash
git add src/openhuman/doctor/mod.rs src/openhuman/doctor/permissions.rs
git commit -m "feat(doctor): permission severity mapping"
```

---

### Task 3: Per-permission diagnostic items with fix hints (TDD)

Build one `DiagnosticItem` per permission, with a denied-state message that names the affected feature and the macOS privacy pane to open.

**Files:**
- Modify: `src/openhuman/doctor/permissions.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module in `permissions.rs`:

```rust
    #[test]
    fn item_for_denied_names_feature_and_pane() {
        let item = permission_item(
            "accessibility",
            &PermissionState::Denied,
            "Accessibility",
            "controlling the keyboard/mouse and reading focused text",
            "Privacy_Accessibility",
        );
        assert_eq!(item.severity, Severity::Warn);
        assert_eq!(item.category, "permissions");
        assert!(item.message.contains("Accessibility"));
        assert!(item.message.contains("denied"));
        assert!(item.message.contains("Privacy_Accessibility"));
    }

    #[test]
    fn item_for_granted_is_ok_and_terse() {
        let item = permission_item(
            "accessibility",
            &PermissionState::Granted,
            "Accessibility",
            "unused-when-granted",
            "Privacy_Accessibility",
        );
        assert_eq!(item.severity, Severity::Ok);
        assert!(item.message.contains("granted"));
    }

    #[test]
    fn item_for_unsupported_notes_platform() {
        let item = permission_item(
            "screen_recording",
            &PermissionState::Unsupported,
            "Screen Recording",
            "x",
            "Privacy_ScreenCapture",
        );
        assert_eq!(item.severity, Severity::Ok);
        assert!(item.message.to_lowercase().contains("not applicable"));
    }
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::item_for`
Expected: FAIL — `permission_item` not found / does not compile.

- [ ] **Step 3: Implement `permission_item`**

Add to `permissions.rs` (above the `#[cfg(test)]` block):

```rust
/// Build a diagnostic item for one permission.
///
/// `label` is the human name ("Accessibility"); `needed_for` describes what
/// breaks without it; `pane` is the macOS privacy-pane identifier the user
/// opens to grant it (the same identifiers `accessibility::open_macos_privacy_pane`
/// expects, e.g. "Privacy_Accessibility", "Privacy_ScreenCapture",
/// "Privacy_ListenEvent", "Privacy_Microphone").
fn permission_item(
    category_key: &str,
    state: &PermissionState,
    label: &str,
    needed_for: &str,
    pane: &str,
) -> DiagnosticItem {
    let severity = severity_for(state);
    let message = match state {
        PermissionState::Granted => format!("{label}: granted"),
        PermissionState::Denied => format!(
            "{label}: denied — needed for {needed_for}. \
             Grant it in System Settings → Privacy & Security → {label} \
             (pane: {pane}), then restart OpenHuman."
        ),
        PermissionState::Unknown => format!(
            "{label}: status unknown — the OS did not report a definitive state. \
             If a feature depending on it misbehaves, re-check System Settings → \
             Privacy & Security → {label} (pane: {pane})."
        ),
        PermissionState::Unsupported => {
            format!("{label}: not applicable on this platform")
        }
    };
    match severity {
        Severity::Ok => DiagnosticItem::ok(format!("permissions:{category_key}"), message),
        Severity::Warn => DiagnosticItem::warn(format!("permissions:{category_key}"), message),
        Severity::Error => DiagnosticItem::error(format!("permissions:{category_key}"), message),
    }
}
```

Note: the test asserts `item.category == "permissions"` but this sets `"permissions:accessibility"`. Fix the test in Step 1 to assert `item.category.starts_with("permissions")` instead of equality. Update the first test's assertion line to:

```rust
        assert!(item.category.starts_with("permissions"));
```

(Rationale: a per-permission sub-category like `permissions:accessibility` is more useful in output than a flat `permissions`, while still satisfying the Task 6 "contains a permissions item" contract via `starts_with`.)

- [ ] **Step 4: Run the test, confirm it passes**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::item_for`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/openhuman/doctor/permissions.rs
git commit -m "feat(doctor): per-permission diagnostic items with fix hints"
```

---

### Task 4: Bundle-signature path derivation (pure function, TDD)

Derive the enclosing `.app` bundle path from the running executable path. Pure string/path logic — no FS, no `codesign` — so it is fully testable.

**Files:**
- Modify: `src/openhuman/doctor/permissions.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module:

```rust
    use std::path::PathBuf;

    #[test]
    fn bundle_path_from_macos_exe() {
        let exe = PathBuf::from("/Applications/OpenHuman.app/Contents/MacOS/OpenHuman");
        assert_eq!(
            enclosing_app_bundle(&exe),
            Some(PathBuf::from("/Applications/OpenHuman.app"))
        );
    }

    #[test]
    fn bundle_path_none_for_plain_binary() {
        let exe = PathBuf::from("/Users/me/.local/bin/openhuman-core");
        assert_eq!(enclosing_app_bundle(&exe), None);
    }

    #[test]
    fn bundle_path_none_for_target_debug() {
        let exe = PathBuf::from("/repo/target/debug/openhuman-core");
        assert_eq!(enclosing_app_bundle(&exe), None);
    }
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::bundle_path`
Expected: FAIL — `enclosing_app_bundle` not found.

- [ ] **Step 3: Implement `enclosing_app_bundle`**

Add to `permissions.rs`:

```rust
use std::path::{Path, PathBuf};

/// Walk up from an executable path to the enclosing `.app` bundle, if any.
///
/// macOS app binaries live at `<Name>.app/Contents/MacOS/<bin>`. Returns the
/// `<Name>.app` directory when that layout is present, else `None` (plain CLI
/// binary, `cargo run`, tests, the `~/.local/bin` shim, etc.).
fn enclosing_app_bundle(exe: &Path) -> Option<PathBuf> {
    let macos_dir = exe.parent()?; // .../Contents/MacOS
    if macos_dir.file_name()?.to_str()? != "MacOS" {
        return None;
    }
    let contents_dir = macos_dir.parent()?; // .../Contents
    if contents_dir.file_name()?.to_str()? != "Contents" {
        return None;
    }
    let app_dir = contents_dir.parent()?; // .../<Name>.app
    if app_dir.extension()?.to_str()? == "app" {
        Some(app_dir.to_path_buf())
    } else {
        None
    }
}
```

- [ ] **Step 4: Run the test, confirm it passes**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::bundle_path`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/openhuman/doctor/permissions.rs
git commit -m "feat(doctor): derive enclosing .app bundle from exe path"
```

---

### Task 5: Bundle-signature classification + item (TDD on the pure classifier)

Classify `codesign -dvv` output into a signature state, and build a `DiagnosticItem` from it. The `codesign` invocation itself is an impure wrapper (not unit-tested); the *parsing* and *item building* are pure and tested.

**Files:**
- Modify: `src/openhuman/doctor/permissions.rs`

- [ ] **Step 1: Write the failing test**

Add to the `tests` module:

```rust
    #[test]
    fn classify_adhoc_signature_warns() {
        // codesign -dvv prints to stderr; ad-hoc shows "Signature=adhoc".
        let out = "Executable=/Applications/OpenHuman.app/Contents/MacOS/OpenHuman\n\
                   Identifier=ai.openhuman\nFormat=app bundle\nSignature=adhoc\n";
        let item = bundle_signature_item_from_codesign(Some(out));
        assert_eq!(item.severity, Severity::Warn);
        assert!(item.message.contains("ad-hoc"));
        assert!(item.message.contains("setup-dev-codesign.sh"));
    }

    #[test]
    fn classify_real_signature_is_ok() {
        let out = "Executable=/Applications/OpenHuman.app/Contents/MacOS/OpenHuman\n\
                   Authority=Developer ID Application: Example (TEAMID)\n\
                   TeamIdentifier=TEAMID\n";
        let item = bundle_signature_item_from_codesign(Some(out));
        assert_eq!(item.severity, Severity::Ok);
    }

    #[test]
    fn classify_no_bundle_is_ok_neutral() {
        let item = bundle_signature_item_from_codesign(None);
        assert_eq!(item.severity, Severity::Ok);
        assert!(item.message.to_lowercase().contains("not launched from"));
    }
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::classify`
Expected: FAIL — `bundle_signature_item_from_codesign` not found.

- [ ] **Step 3: Implement the classifier + item builder**

Add to `permissions.rs`:

```rust
/// Build the bundle-signature diagnostic from raw `codesign -dvv` output.
///
/// `None` means we never ran codesign (no enclosing `.app` — plain binary,
/// `cargo run`, tests, the CLI shim). That is a neutral Ok, not a problem.
///
/// Ad-hoc / unsigned bundles produce `Signature=adhoc` (or no Authority line)
/// and are flagged Warn because macOS keys TCC grants to bundle identity, so a
/// freshly rebuilt ad-hoc bundle can lose Accessibility / Screen Recording
/// grants after each daily build.
fn bundle_signature_item_from_codesign(codesign_stderr: Option<&str>) -> DiagnosticItem {
    let Some(out) = codesign_stderr else {
        return DiagnosticItem::ok(
            "bundle",
            "Bundle signature: not launched from a .app bundle (plain binary, \
             dev run, or CLI shim) — TCC stability check skipped.",
        );
    };
    let is_adhoc = out.contains("Signature=adhoc");
    let has_authority = out.contains("Authority=");
    if is_adhoc || !has_authority {
        DiagnosticItem::warn(
            "bundle",
            "Bundle signature: ad-hoc / unsigned. macOS keys permission (TCC) \
             grants to bundle identity, so Accessibility / Screen Recording / \
             Input Monitoring can reset after each daily rebuild. Fix: give the \
             bundle a stable ad-hoc identity — see scripts/setup-dev-codesign.sh.",
        )
    } else {
        DiagnosticItem::ok(
            "bundle",
            "Bundle signature: stably signed — permission grants should persist \
             across rebuilds.",
        )
    }
}
```

- [ ] **Step 4: Run the test, confirm it passes**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions::tests::classify`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/openhuman/doctor/permissions.rs
git commit -m "feat(doctor): classify bundle signature for TCC stability"
```

---

### Task 6: Public `check_permissions()` orchestrator + impure probes

Wire the pure pieces together behind the public entry point, calling the real `accessibility::detect_permissions()` and the real `codesign`. This function is the only impure surface; it is integration-checked in Task 7, not unit-tested here.

**Files:**
- Modify: `src/openhuman/doctor/permissions.rs`

- [ ] **Step 1: Implement the orchestrator + codesign probe**

Add to `permissions.rs` (above the test module):

```rust
use crate::openhuman::accessibility::detect_permissions;

/// Run `codesign -dvv` against a bundle and return its combined output, or
/// `None` if codesign is unavailable or fails. Read-only, fail-soft.
#[cfg(target_os = "macos")]
fn run_codesign(bundle: &Path) -> Option<String> {
    let output = std::process::Command::new("codesign")
        .arg("-dvv")
        .arg(bundle)
        .output()
        .ok()?;
    // codesign writes its description to stderr.
    Some(String::from_utf8_lossy(&output.stderr).into_owned())
}

/// Full permission + bundle-signature diagnosis, appended to the doctor report.
pub(super) fn check_permissions() -> Vec<DiagnosticItem> {
    let mut items = Vec::new();
    let perms = detect_permissions();

    items.push(permission_item(
        "accessibility",
        &perms.accessibility,
        "Accessibility",
        "controlling keyboard/mouse and reading focused text (autocomplete, overlay)",
        "Privacy_Accessibility",
    ));
    items.push(permission_item(
        "screen_recording",
        &perms.screen_recording,
        "Screen Recording",
        "Screen Intelligence capture",
        "Privacy_ScreenCapture",
    ));
    items.push(permission_item(
        "input_monitoring",
        &perms.input_monitoring,
        "Input Monitoring",
        "Tab/Escape and Globe-key detection",
        "Privacy_ListenEvent",
    ));
    items.push(permission_item(
        "microphone",
        &perms.microphone,
        "Microphone",
        "voice capture",
        "Privacy_Microphone",
    ));

    items.push(bundle_signature_check());
    items
}

/// Bundle-signature check: macOS resolves the `.app` and runs codesign;
/// other platforms report not-applicable.
#[cfg(target_os = "macos")]
fn bundle_signature_check() -> DiagnosticItem {
    let bundle = std::env::current_exe()
        .ok()
        .and_then(|exe| enclosing_app_bundle(&exe));
    match bundle {
        Some(app) => bundle_signature_item_from_codesign(run_codesign(&app).as_deref()),
        None => bundle_signature_item_from_codesign(None),
    }
}

#[cfg(not(target_os = "macos"))]
fn bundle_signature_check() -> DiagnosticItem {
    DiagnosticItem::ok(
        "bundle",
        "Bundle signature: not applicable on this platform.",
    )
}
```

- [ ] **Step 2: Verify it compiles on this host**

Run: `cargo check --manifest-path Cargo.toml --bin openhuman-core`
Expected: PASS. (On macOS the `#[cfg(target_os = "macos")]` branches compile; the non-macOS `bundle_signature_check` is cfg'd out. `enclosing_app_bundle`, `run_codesign` are only referenced on macOS — if building on Linux they'd be unused; that's fine because they're inside macOS-only call paths. If a Linux `dead_code` warning appears for `enclosing_app_bundle`, add `#[cfg_attr(not(target_os = "macos"), allow(dead_code))]` above it.)

- [ ] **Step 3: Run the whole permissions test module**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::permissions`
Expected: PASS (all tests from Tasks 2–5).

- [ ] **Step 4: Commit**

```bash
git add src/openhuman/doctor/permissions.rs
git commit -m "feat(doctor): check_permissions orchestrator with codesign probe"
```

---

### Task 7: Wire into `core::run()` + integration test

Extend the report and assert the permissions block appears.

**Files:**
- Modify: `src/openhuman/doctor/core.rs` (inside `run()`, before the summary is computed)
- Modify: `src/openhuman/doctor/core_tests.rs`

- [ ] **Step 1: Find the summary-construction point in `run()`**

Run: `grep -n "DoctorSummary\|summary\|Ok(DoctorReport\|items.push\|fn run" src/openhuman/doctor/core.rs | head -20`
Expected: shows where `items` is finalized and `DoctorSummary`/`DoctorReport` is built. The new line goes *after* the last `items.push(...)` / extend and *before* the summary counts the items.

- [ ] **Step 2: Add the extend call**

In `src/openhuman/doctor/core.rs`, immediately before the code that computes `DoctorSummary` from `items`, insert:

```rust
    items.extend(super::permissions::check_permissions());
```

(If `run()` references items via a different binding name, use that name. The call must precede the `ok`/`warnings`/`errors` counting so permission items are included in the summary.)

- [ ] **Step 3: Write the failing integration test**

In `src/openhuman/doctor/core_tests.rs`, add:

```rust
#[test]
fn report_includes_permission_diagnostics() {
    let config = crate::openhuman::config::Config::default();
    let report = super::core::run(&config).expect("doctor report");
    assert!(
        report
            .items
            .iter()
            .any(|i| i.category.starts_with("permissions")),
        "doctor report should include at least one permissions item"
    );
    assert!(
        report.items.iter().any(|i| i.category == "bundle"),
        "doctor report should include a bundle-signature item"
    );
}
```

Note: verify the module path to `run` and `Config`. Run `grep -n "core::run\|super::\|use crate" src/openhuman/doctor/core_tests.rs | head` first; match the existing tests' import style in that file (they already call into `core`). If `Config::default()` is not the constructor used elsewhere in this test file, copy the construction the existing tests use.

- [ ] **Step 4: Run the test**

Run: `cargo test --manifest-path Cargo.toml --lib doctor::core_tests::report_includes_permission_diagnostics`
Expected: PASS. (If the test harness runs in an environment where `current_exe()` is the test binary, `enclosing_app_bundle` returns `None` → neutral `bundle` Ok item, and `detect_permissions()` returns real states or `Unsupported` on Linux CI → permission items still present. Both assertions hold regardless of platform.)

- [ ] **Step 5: Run the full doctor test module to check for regressions**

Run: `cargo test --manifest-path Cargo.toml --lib doctor`
Expected: PASS (all doctor tests, including the existing ones).

- [ ] **Step 6: Commit**

```bash
git add src/openhuman/doctor/core.rs src/openhuman/doctor/core_tests.rs
git commit -m "feat(doctor): surface permissions + bundle signature in report"
```

---

### Task 8: Manual end-to-end verification via the CLI shim

Confirm the real, user-facing path works — the whole point is that `openhuman-core doctor` now answers "what's broken and why."

**Files:** none (verification only)

- [ ] **Step 1: Build and run doctor**

Run: `cargo run --manifest-path Cargo.toml --bin openhuman-core -- doctor`
Expected: output now contains permission lines (e.g. `Accessibility: ...`, `Screen Recording: ...`, `Input Monitoring: ...`, `Microphone: ...`) and a bundle-signature line. Under `cargo run` the bundle line should read "not launched from a .app bundle".

- [ ] **Step 2: Confirm format/lint**

Run: `cargo fmt --manifest-path Cargo.toml && cargo fmt --manifest-path Cargo.toml -- --check`
Expected: clean (no diff).

- [ ] **Step 3: Final commit if fmt changed anything**

```bash
git add -A src/openhuman/doctor/
git commit -m "style(doctor): cargo fmt" || echo "nothing to format"
```

---

## Notes for the implementer

- **Do not** reimplement permission FFI — call `accessibility::detect_permissions()`, which already exists and is re-exported from `crate::openhuman::accessibility`.
- **Do not** add a new RPC method or schema. The report is a flat `Vec<DiagnosticItem>`; appending items is the entire integration.
- Keep `permissions.rs` read-only and fail-soft: no `panic!`, no `unwrap()` on probe results, no `Severity::Error` for a merely-missing permission.
- The user's uncommitted change to `scripts/daily-local-build.sh` is unrelated — do not touch it, do not stage it.
- Pane identifiers (`Privacy_Accessibility`, `Privacy_ScreenCapture`, `Privacy_ListenEvent`, `Privacy_Microphone`) match what `accessibility::open_macos_privacy_pane` consumes; reuse them so Phase B's UI buttons line up with the doctor's advice.
