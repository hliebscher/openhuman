//! Doctor checks for OS-level permissions (macOS TCC) and bundle-signature
//! stability. Read-only and fail-soft: never panics, never returns `Error`
//! for a merely-missing permission — a denied grant restricts a feature, it
//! does not constitute a broken system.

use super::core::Severity;
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
