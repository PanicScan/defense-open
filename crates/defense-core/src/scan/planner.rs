use std::env;
use std::path::{Path, PathBuf};

use crate::scan::target::ScanTarget;
use crate::scan::{ScanMode, ScanRequest};

#[derive(Debug, Default)]
pub struct ScanPlanner;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PlatformFamily {
    Windows,
    Macos,
    Linux,
    Other,
}

impl PlatformFamily {
    fn current() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else if cfg!(target_os = "macos") {
            Self::Macos
        } else if cfg!(target_os = "linux") {
            Self::Linux
        } else {
            Self::Other
        }
    }
}

impl ScanPlanner {
    pub fn plan(&self, request: &ScanRequest) -> Vec<ScanTarget> {
        match request.mode {
            ScanMode::Quick => quick_targets_for(PlatformFamily::current(), user_home().as_deref()),
            ScanMode::Usb => request
                .roots
                .iter()
                .map(|root| ScanTarget::directory(root, "removable drive"))
                .collect(),
            ScanMode::Full => {
                let home = user_home();
                let system_drive = env::var_os("SystemDrive").map(PathBuf::from);
                full_targets_for(
                    PlatformFamily::current(),
                    home.as_deref(),
                    system_drive.as_deref(),
                )
            }
        }
    }
}

fn quick_targets_for(platform: PlatformFamily, home: Option<&Path>) -> Vec<ScanTarget> {
    let mut targets = Vec::new();
    if let Some(home) = home {
        targets.push(ScanTarget::directory(home.join("Downloads"), "downloads"));
        targets.push(ScanTarget::directory(home.join("Desktop"), "desktop"));
        targets.extend(platform_user_targets(platform, home));
    }
    targets
}

fn full_targets_for(
    platform: PlatformFamily,
    home: Option<&Path>,
    system_drive: Option<&Path>,
) -> Vec<ScanTarget> {
    let mut targets = quick_targets_for(platform, home);
    match platform {
        PlatformFamily::Windows => {
            if let Some(system_drive) = system_drive {
                targets.push(ScanTarget::directory(system_drive, "system drive"));
            }
        }
        PlatformFamily::Macos | PlatformFamily::Linux => {
            targets.push(ScanTarget::directory(PathBuf::from("/"), "root filesystem"));
        }
        PlatformFamily::Other => {}
    }
    targets
}

fn user_home() -> Option<PathBuf> {
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
}

fn platform_user_targets(platform: PlatformFamily, home: &Path) -> Vec<ScanTarget> {
    let mut targets = Vec::new();

    match platform {
        PlatformFamily::Windows => {
            targets.push(ScanTarget::directory(
                home.join("AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"),
                "windows startup folder",
            ));
            targets.push(ScanTarget::directory(
                home.join("AppData\\Local\\Temp"),
                "windows user temp",
            ));
        }
        PlatformFamily::Macos => {
            targets.push(ScanTarget::directory(
                home.join("Library/LaunchAgents"),
                "macos launch agents",
            ));
        }
        PlatformFamily::Linux => {
            targets.push(ScanTarget::directory(
                home.join(".config/autostart"),
                "linux desktop autostart",
            ));
            targets.push(ScanTarget::directory(
                home.join(".config/systemd/user"),
                "linux systemd user units",
            ));
            targets.push(ScanTarget::directory(PathBuf::from("/tmp"), "linux temp"));
        }
        PlatformFamily::Other => {}
    }

    targets
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usb_mode_uses_requested_root() {
        let request = ScanRequest::new(ScanMode::Usb).with_root("E:\\".to_string());
        let targets = ScanPlanner.plan(&request);
        assert_eq!(targets.len(), 1);
        assert_eq!(targets[0].label, "removable drive");
    }

    #[test]
    fn unknown_platform_quick_scan_keeps_basic_user_targets() {
        let home = PathBuf::from("/Users/future");
        let targets = quick_targets_for(PlatformFamily::Other, Some(&home));
        let labels = target_labels(&targets);

        assert_eq!(labels, vec!["downloads", "desktop"]);
    }

    #[test]
    fn unknown_platform_full_scan_does_not_assume_posix_root() {
        let home = PathBuf::from("/Users/future");
        let targets = full_targets_for(PlatformFamily::Other, Some(&home), None);
        let labels = target_labels(&targets);

        assert_eq!(labels, vec!["downloads", "desktop"]);
    }

    #[test]
    fn windows_targets_can_be_planned_without_windows_host() {
        let home = PathBuf::from("C:\\Users\\defense");
        let targets = quick_targets_for(PlatformFamily::Windows, Some(&home));
        let labels = target_labels(&targets);

        assert!(labels.contains(&"windows startup folder"));
        assert!(labels.contains(&"windows user temp"));
    }

    fn target_labels(targets: &[ScanTarget]) -> Vec<&str> {
        targets.iter().map(|target| target.label.as_str()).collect()
    }
}
