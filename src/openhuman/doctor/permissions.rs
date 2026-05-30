//! Doctor checks for OS-level permissions (macOS TCC) and bundle-signature
//! stability. Read-only and fail-soft: never panics, never returns `Error`
//! for a merely-missing permission — a denied grant restricts a feature, it
//! does not constitute a broken system.

use super::core::{DiagnosticItem, Severity};
use crate::openhuman::accessibility::PermissionState;
use std::path::{Path, PathBuf};

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
        assert!(item.category.starts_with("permissions"));
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
}
