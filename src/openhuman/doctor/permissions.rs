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
}
