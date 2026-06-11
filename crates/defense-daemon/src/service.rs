//! OS servis entegrasyonu — kurulum, kaldırma, başlatma, durdurma.
//!
//! `defense-daemon install`   → servisi OS'e kaydeder
//! `defense-daemon uninstall` → servisi OS'ten kaldırır
//! `defense-daemon start`     → servisi başlatır
//! `defense-daemon stop`      → servisi durdurur
//! `defense-daemon run`       → daemon loop'unu çalıştırır (servis tarafından çağrılır)

use anyhow::Result;

// ─── Windows ─────────────────────────────────────────────────────────────────

#[cfg(target_os = "windows")]
pub mod windows {
    use super::*;
    use std::ffi::OsString;
    use windows_service::{
        define_windows_service,
        service::{
            ServiceAccess, ServiceErrorControl, ServiceInfo, ServiceStartType, ServiceState,
            ServiceStatus, ServiceType,
        },
        service_control_handler::{self, ServiceControlHandlerResult},
        service_dispatcher,
        service_manager::{ServiceManager, ServiceManagerAccess},
    };

    const SERVICE_NAME: &str = "defenseDaemon";
    const SERVICE_DISPLAY: &str = "defense Real-Time Protection";

    /// Servisi Windows Service Control Manager'a kaydeder.
    pub fn install() -> Result<()> {
        let manager =
            ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CREATE_SERVICE)?;

        let exe_path = std::env::current_exe()?;

        let service_info = ServiceInfo {
            name: OsString::from(SERVICE_NAME),
            display_name: OsString::from(SERVICE_DISPLAY),
            service_type: ServiceType::OWN_PROCESS,
            start_type: ServiceStartType::AutoStart,
            error_control: ServiceErrorControl::Normal,
            executable_path: exe_path,
            launch_arguments: vec![OsString::from("run")],
            dependencies: vec![],
            account_name: None, // LocalSystem
            account_password: None,
        };

        let _service = manager.create_service(&service_info, ServiceAccess::CHANGE_CONFIG)?;

        // Açıklama ekle.
        // Windows API ile description set etmek için ChangeServiceConfig2 gerekir.
        // Şimdilik install yeterli.

        println!("✅ Servis kuruldu: {SERVICE_NAME}");
        println!("   Başlatmak için: defense-daemon start");
        Ok(())
    }

    /// Servisi Windows Service Control Manager'dan kaldırır.
    pub fn uninstall() -> Result<()> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;

        let service = manager.open_service(
            SERVICE_NAME,
            ServiceAccess::QUERY_STATUS | ServiceAccess::STOP | ServiceAccess::DELETE,
        )?;

        // Çalışıyorsa önce durdur.
        let status = service.query_status()?;
        if status.current_state != ServiceState::Stopped {
            service.stop()?;
        }

        service.delete()?;
        println!("🗑️  Servis kaldırıldı: {SERVICE_NAME}");
        Ok(())
    }

    /// Servisi başlatır.
    pub fn start() -> Result<()> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
        let service = manager.open_service(SERVICE_NAME, ServiceAccess::START)?;
        service.start::<&str>(&[])?;
        println!("▶️  Servis başlatıldı: {SERVICE_NAME}");
        Ok(())
    }

    /// Servisi durdurur.
    pub fn stop() -> Result<()> {
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)?;
        let service = manager.open_service(SERVICE_NAME, ServiceAccess::STOP)?;
        service.stop()?;
        println!("⏹️  Servis durduruldu: {SERVICE_NAME}");
        Ok(())
    }

    /// Windows SCM tarafından çağrılan servis giriş noktası.
    /// Bu fonksiyon `run` komutundan çağrılır.
    pub fn run_as_service() -> Result<()> {
        service_dispatcher::start(SERVICE_NAME, ffi_service_main)?;
        Ok(())
    }

    define_windows_service!(ffi_service_main, service_main);

    fn service_main(_args: Vec<OsString>) {
        if let Err(e) = run_service_main() {
            tracing::error!("Windows servis hatası: {e}");
        }
    }

    fn run_service_main() -> Result<()> {
        // SCM'e kontrol handler'ı bildir.
        let event_handler = move |control_event| -> ServiceControlHandlerResult {
            match control_event {
                windows_service::service::ServiceControl::Stop => {
                    // TODO: tokio runtime'ı gracefully shutdown et.
                    ServiceControlHandlerResult::NoError
                }
                _ => ServiceControlHandlerResult::NotImplemented,
            }
        };

        let status_handle = service_control_handler::register(SERVICE_NAME, event_handler)?;

        // SCM'e "Running" bildir.
        status_handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: ServiceState::Running,
            controls_accepted: windows_service::service::ServiceControlAccept::STOP,
            exit_code: windows_service::service::ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: std::time::Duration::default(),
            process_id: None,
        })?;

        // Gerçek daemon loop'unu başlat.
        let rt = tokio::runtime::Runtime::new()?;
        rt.block_on(crate::run_daemon_loop())?;

        Ok(())
    }
}

// ─── Linux systemd ───────────────────────────────────────────────────────────

#[cfg(target_os = "linux")]
pub mod linux {
    use super::*;
    use tracing::info;

    const SERVICE_FILE: &str = "/etc/systemd/system/defense.service";

    /// systemd unit dosyasını /etc/systemd/system/ altına yazar ve `enable` eder.
    pub fn install() -> Result<()> {
        let exe = std::env::current_exe()?;
        let unit = format!(
            r#"[Unit]
Description=defense Real-Time Protection Daemon
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
ExecStart={exe} run
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=defense-daemon

[Install]
WantedBy=multi-user.target
"#,
            exe = exe.display()
        );

        std::fs::write(SERVICE_FILE, unit)?;
        info!("systemd unit dosyası yazıldı: {SERVICE_FILE}");

        let status = std::process::Command::new("systemctl")
            .args(["daemon-reload"])
            .status()?;
        if !status.success() {
            anyhow::bail!("systemctl daemon-reload başarısız");
        }

        let status = std::process::Command::new("systemctl")
            .args(["enable", "defense"])
            .status()?;
        if !status.success() {
            anyhow::bail!("systemctl enable defense başarısız");
        }

        println!("✅ defense servisi kuruldu ve etkinleştirildi.");
        println!("   Başlatmak için: sudo systemctl start defense");
        Ok(())
    }

    pub fn uninstall() -> Result<()> {
        let _ = std::process::Command::new("systemctl")
            .args(["disable", "--now", "defense"])
            .status();
        let _ = std::fs::remove_file(SERVICE_FILE);
        let _ = std::process::Command::new("systemctl")
            .args(["daemon-reload"])
            .status();
        println!("🗑️  defense servisi kaldırıldı.");
        Ok(())
    }

    pub fn start() -> Result<()> {
        std::process::Command::new("systemctl")
            .args(["start", "defense"])
            .status()?;
        println!("▶️  defense başlatıldı.");
        Ok(())
    }

    pub fn stop() -> Result<()> {
        std::process::Command::new("systemctl")
            .args(["stop", "defense"])
            .status()?;
        println!("⏹️  defense durduruldu.");
        Ok(())
    }
}

// ─── macOS launchd ───────────────────────────────────────────────────────────

#[cfg(target_os = "macos")]
pub mod macos {
    use super::*;

    const PLIST_LABEL: &str = "com.defense.daemon";
    const PLIST_PATH: &str = "/Library/LaunchDaemons/com.defense.daemon.plist";

    pub fn install() -> Result<()> {
        let exe = std::env::current_exe()?;
        let log_dir = "/var/log/defense";
        std::fs::create_dir_all(log_dir)?;

        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>{label}</string>
    <key>ProgramArguments</key>
    <array>
        <string>{exe}</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{log_dir}/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>{log_dir}/daemon-error.log</string>
</dict>
</plist>
"#,
            label = PLIST_LABEL,
            exe = exe.display(),
            log_dir = log_dir,
        );

        std::fs::write(PLIST_PATH, plist)?;

        let status = std::process::Command::new("launchctl")
            .args(["load", "-w", PLIST_PATH])
            .status()?;

        if status.success() {
            println!("✅ defense launchd daemon kuruldu: {PLIST_PATH}");
        } else {
            anyhow::bail!("launchctl load başarısız");
        }

        Ok(())
    }

    pub fn uninstall() -> Result<()> {
        let _ = std::process::Command::new("launchctl")
            .args(["unload", "-w", PLIST_PATH])
            .status();
        let _ = std::fs::remove_file(PLIST_PATH);
        println!("🗑️  defense launchd daemon kaldırıldı.");
        Ok(())
    }

    pub fn start() -> Result<()> {
        std::process::Command::new("launchctl")
            .args(["start", PLIST_LABEL])
            .status()?;
        println!("▶️  defense başlatıldı.");
        Ok(())
    }

    pub fn stop() -> Result<()> {
        std::process::Command::new("launchctl")
            .args(["stop", PLIST_LABEL])
            .status()?;
        println!("⏹️  defense durduruldu.");
        Ok(())
    }
}
