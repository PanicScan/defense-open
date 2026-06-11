//! Dosya sistemi olay izleyicisi — Hafta 3-4 implementasyonu.
//!
//! Platform desteği:
//!   Windows  → ReadDirectoryChangesW  (notify crate aracılığıyla)
//!   Linux    → inotify                (notify crate aracılığıyla)
//!   macOS    → FSEvents               (notify crate aracılığıyla)
//!
//! Mimari:
//!   - `notify` crate olayları bir `std::sync::mpsc` kanalına gönderir.
//!   - `FsWatcherTask` bu kanalı tokio ile async olarak dinler.
//!   - Her olay uzantı filtresi + cooldown kontrolünden geçer.
//!   - Geçen dosyalar `defense-core` ile taranır (blocking thread'de).
//!   - Yüksek tehditler `events.jsonl`'e yazılır ve sistem bildirimi tetiklenir.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use anyhow::Result;
use notify::{
    event::{CreateKind, ModifyKind},
    recommended_watcher, EventKind, RecursiveMode, Watcher,
};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::state::DaemonState;

// ─── Sabitler ────────────────────────────────────────────────────────────────

/// İzlenecek dosya uzantıları (büyük harf ile karşılaştırılır).
const WATCHED_EXTENSIONS: &[&str] = &[
    "EXE", "DLL", "SYS", "DRV", "PS1", "PSM1", "PSD1", "BAT", "CMD", "VBS", "VBE", "JS", "JSE",
    "WSF", "WSH", "JAR", "CLASS", "PY", "PYC", "SH", "BASH", "ELF", "MSI", "HTA", "SCR", "CPL",
    "LNK", "INF",
];

/// Aynı dosyanın tekrar taranmaması için bekleme süresi (saniye).
const RESCAN_COOLDOWN_SECS: u64 = 60;

/// Paralel tarama limiti — CPU spike'ını önler.
const MAX_CONCURRENT_SCANS: usize = 4;

// ─── Olay yapısı ─────────────────────────────────────────────────────────────

/// Bir tarama olayının kalıcı kaydı.
#[derive(Debug, serde::Serialize)]
pub struct ScanEvent {
    pub event_id: String,
    pub path: String,
    pub detected_at: chrono::DateTime<chrono::Utc>,
    pub trigger: EventTrigger,
    pub finding_count: usize,
    pub highest_severity: String,
    pub ml_verdict: Option<String>,
    pub duration_ms: u64,
}

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EventTrigger {
    FileCreated,
    FileModified,
    ManualRequest,
}

// ─── İzleyici görevi ─────────────────────────────────────────────────────────

/// `FsWatcherTask` — daemon'ın arka planında çalışan dosya izleme görevi.
pub struct FsWatcherTask {
    state: Arc<DaemonState>,
    event_log_path: PathBuf,
    last_scan: HashMap<PathBuf, Instant>,
    semaphore: Arc<tokio::sync::Semaphore>,
}

impl FsWatcherTask {
    pub fn new(state: Arc<DaemonState>) -> Self {
        // Olay log dosyasının yolu.
        let log_dir = defense_dir();
        let _ = std::fs::create_dir_all(&log_dir);
        let event_log_path = log_dir.join("events.jsonl");

        Self {
            state,
            event_log_path,
            last_scan: HashMap::new(),
            semaphore: Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_SCANS)),
        }
    }

    /// Ana izleme döngüsü. Klasörleri izlemeye başlar ve olayları işler.
    pub async fn run(mut self, watch_dirs: Vec<String>) -> Result<()> {
        // tokio mpsc kanalı — notify thread → async runtime.
        let (tx, mut rx) = mpsc::channel::<notify::Event>(256);

        // notify watcher: OS olaylarını kanalımıza gönderir.
        let mut watcher = recommended_watcher(move |res: notify::Result<notify::Event>| {
            match res {
                Ok(event) => {
                    if let Err(e) = tx.blocking_send(event) {
                        // Kanal doldu veya kapandı — kritik değil.
                        debug!("FS event drop: {e}");
                    }
                }
                Err(e) => warn!("FS watch hatası: {e}"),
            }
        })?;

        // İzlenecek klasörleri ekle.
        let mut watched_count = 0;
        for dir in &watch_dirs {
            let path = Path::new(dir);
            if path.exists() {
                match watcher.watch(path, RecursiveMode::Recursive) {
                    Ok(()) => {
                        info!("📂 İzleniyor: {dir}");
                        watched_count += 1;
                    }
                    Err(e) => warn!("İzleme başarısız ({dir}): {e}"),
                }
            } else {
                debug!("Klasör mevcut değil, atlandı: {dir}");
            }
        }

        info!(
            "✅ Dosya sistemi izleyici hazır ({watched_count}/{} klasör aktif)",
            watch_dirs.len()
        );

        // Olay döngüsü.
        while let Some(event) = rx.recv().await {
            self.handle_notify_event(event).await;
        }

        Ok(())
    }

    // ─── Olay işleyici ───────────────────────────────────────────────────────

    async fn handle_notify_event(&mut self, event: notify::Event) {
        // Sadece Create ve Modify olaylarını işle.
        let trigger = match &event.kind {
            EventKind::Create(CreateKind::File) | EventKind::Create(CreateKind::Any) => {
                EventTrigger::FileCreated
            }

            EventKind::Modify(ModifyKind::Data(_))
            | EventKind::Modify(ModifyKind::Name(_))
            | EventKind::Modify(ModifyKind::Any) => EventTrigger::FileModified,

            _ => return, // Diğer olaylar (Remove, Access, vb.) görmezden gel.
        };

        for path in event.paths {
            if path.is_file() {
                self.process_file(&path, &trigger).await;
            }
        }
    }

    async fn process_file(&mut self, path: &Path, trigger: &EventTrigger) {
        // 1. Uzantı filtresi.
        let ext = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_uppercase();

        if !WATCHED_EXTENSIONS.contains(&ext.as_str()) {
            return;
        }

        // 2. Cooldown filtresi — aynı dosyayı çok sık tarama.
        let now = Instant::now();
        if let Some(&last) = self.last_scan.get(path) {
            if last.elapsed().as_secs() < RESCAN_COOLDOWN_SECS {
                debug!("Cooldown: {}", path.display());
                return;
            }
        }
        self.last_scan.insert(path.to_path_buf(), now);

        // 3. Dosyayı tara.
        let path_str = path.to_string_lossy().to_string();
        let trigger_str = match trigger {
            EventTrigger::FileCreated => "oluşturuldu",
            EventTrigger::FileModified => "değiştirildi",
            EventTrigger::ManualRequest => "manuel",
        };
        info!("🔍 Taranıyor [{trigger_str}]: {path_str}");

        let state = Arc::clone(&self.state);
        let sem = Arc::clone(&self.semaphore);
        let event_log = self.event_log_path.clone();

        // CPU-yoğun taramayı blocking thread'e taşı, semaphore ile limitle.
        tokio::spawn(async move {
            let _permit = sem.acquire_owned().await.expect("semaphore dropped");
            scan_and_log(path_str, state, event_log).await;
        });
    }
}

// ─── Tarama + log ────────────────────────────────────────────────────────────

async fn scan_and_log(path: String, state: Arc<DaemonState>, event_log: PathBuf) {
    use defense_core::report::FindingSeverity;
    use defense_core::{ScanMode, ScanRequest, ScanRunner};
    use std::time::Instant;

    let t = Instant::now();
    let req = ScanRequest::new(ScanMode::Quick).with_root(path.clone());
    let path_clone = path.clone();

    let result = tokio::task::spawn_blocking(move || ScanRunner::default().run(req)).await;

    match result {
        Ok(Ok(report)) => {
            let severity_score = report
                .findings
                .iter()
                .map(|f| match f.severity {
                    FindingSeverity::Critical => 4u8,
                    FindingSeverity::High => 3,
                    FindingSeverity::Medium => 2,
                    FindingSeverity::Low => 1,
                    FindingSeverity::Info => 0,
                })
                .max()
                .unwrap_or(0);

            let highest = match severity_score {
                4 => "critical",
                3 => "high",
                2 => "medium",
                1 => "low",
                _ => "none",
            };

            let produced_alert = severity_score >= 3;
            state.record_scan(produced_alert);

            let event = ScanEvent {
                event_id: uuid::Uuid::new_v4().to_string(),
                path: path.clone(),
                detected_at: chrono::Utc::now(),
                trigger: EventTrigger::FileCreated,
                finding_count: report.findings.len(),
                highest_severity: highest.to_string(),
                ml_verdict: None,
                duration_ms: t.elapsed().as_millis() as u64,
            };

            // events.jsonl'e yaz (append).
            append_event_log(&event_log, &event);

            if produced_alert {
                warn!(
                    "🚨 TEHDİT TESPİT EDİLDİ ▶ {} | {} bulgu | en yüksek: {}",
                    path,
                    report.findings.len(),
                    highest
                );
                // Sistem bildirimi — platform-specific.
                send_system_notification(&path, highest, report.findings.len());
            } else {
                info!(
                    "✅ Temiz ▶ {} | {} düşük öncelikli bulgu | {}ms",
                    path,
                    report.findings.len(),
                    event.duration_ms
                );
            }
        }
        Ok(Err(e)) => {
            warn!("Tarama başarısız ▶ {} — {e}", path_clone);
            state.record_scan(false);
        }
        Err(e) => {
            warn!("Spawn hatası: {e}");
        }
    }
}

// ─── Yardımcı fonksiyonlar ────────────────────────────────────────────────────

/// Olayı `events.jsonl` dosyasına ekler.
fn append_event_log(log_path: &Path, event: &ScanEvent) {
    use std::io::Write;
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)
    {
        Ok(mut file) => {
            if let Ok(json) = serde_json::to_string(event) {
                let _ = writeln!(file, "{json}");
            }
        }
        Err(e) => warn!("Log yazma hatası: {e}"),
    }
}

/// Platform-specific sistem bildirimi gönderir.
fn send_system_notification(path: &str, severity: &str, count: usize) {
    let title = format!("defense 🚨 {}", severity.to_uppercase());
    let body = format!(
        "{count} tehdit bulgusu\n{}",
        // Çok uzun path'leri kısalt.
        if path.len() > 60 {
            &path[path.len() - 60..]
        } else {
            path
        }
    );

    // Platform-specific bildirim çağrıları.
    // Faz 2'de notify-rust crate'i ile değiştirilecek.
    // Şimdilik OS komutlarıyla çalışan basit bir implementasyon.

    #[cfg(target_os = "windows")]
    {
        // PowerShell toast notification.
        let script = format!(
            r#"[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null;
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02);
$text = $xml.GetElementsByTagName('text');
$text[0].AppendChild($xml.CreateTextNode('{title}')) | Out-Null;
$text[1].AppendChild($xml.CreateTextNode('{body}')) | Out-Null;
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml);
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('defense').Show($toast);"#
        );
        let _ = std::process::Command::new("powershell")
            .args(["-WindowStyle", "Hidden", "-Command", &script])
            .spawn();
    }

    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("notify-send")
            .args(["-u", "critical", &title, &body])
            .spawn();
    }

    #[cfg(target_os = "macos")]
    {
        let script =
            format!(r#"display notification "{body}" with title "{title}" sound name "Basso""#);
        let _ = std::process::Command::new("osascript")
            .args(["-e", &script])
            .spawn();
    }
}

/// defense veri klasörü yolunu döndürür.
pub fn defense_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        let appdata = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(appdata).join("defense")
    }
    #[cfg(not(target_os = "windows"))]
    {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(home).join(".defense")
    }
}

/// İzlenecek varsayılan klasörleri döndürür (platforma özgü).
pub fn default_watch_dirs() -> Vec<String> {
    let mut dirs = Vec::new();

    #[cfg(target_os = "windows")]
    {
        if let Ok(profile) = std::env::var("USERPROFILE") {
            dirs.push(format!("{profile}\\Downloads"));
            dirs.push(format!("{profile}\\AppData\\Roaming"));
            dirs.push(format!("{profile}\\AppData\\Local\\Temp"));
        }
        if let Ok(temp) = std::env::var("TEMP") {
            dirs.push(temp);
        }
        dirs.push(r"C:\Windows\Temp".to_string());
        dirs.push(r"C:\Users\Public\Downloads".to_string());
        // Startup klasörleri.
        if let Ok(appdata) = std::env::var("APPDATA") {
            dirs.push(format!(
                r"{appdata}\Microsoft\Windows\Start Menu\Programs\Startup"
            ));
        }
    }

    #[cfg(target_os = "linux")]
    {
        if let Ok(home) = std::env::var("HOME") {
            dirs.push(format!("{home}/Downloads"));
            dirs.push(format!("{home}/.local/share"));
            dirs.push(format!("{home}/.config"));
        }
        dirs.push("/tmp".to_string());
        dirs.push("/var/tmp".to_string());
        dirs.push("/opt".to_string());
        // systemd user service dirs.
        if let Ok(home) = std::env::var("HOME") {
            dirs.push(format!("{home}/.config/systemd/user"));
        }
    }

    #[cfg(target_os = "macos")]
    {
        if let Ok(home) = std::env::var("HOME") {
            dirs.push(format!("{home}/Downloads"));
            dirs.push(format!("{home}/Library/LaunchAgents"));
        }
        dirs.push("/tmp".to_string());
        dirs.push("/private/tmp".to_string());
        dirs.push("/Applications".to_string());
        dirs.push("/Library/LaunchDaemons".to_string());
        dirs.push("/Library/LaunchAgents".to_string());
    }

    dirs
}
