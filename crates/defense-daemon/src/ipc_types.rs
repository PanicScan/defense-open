//! defense Daemon — IPC message protocol
//!
//! Her mesaj newline-delimited JSON. Tek bir TCP veya Unix socket bağlantısı
//! üzerinden seri olarak gönderilir.
//!
//! İstemci (CLI) → Daemon: `IpcRequest`
//! Daemon → İstemci (CLI): `IpcResponse`

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// CLI'dan daemon'a gönderilen komutlar.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum IpcRequest {
    /// Daemon'ın durumunu sorgula.
    Status,
    /// Daemon'ı durdur (yalnızca yetkili kullanıcı).
    Shutdown,
    /// Son N tarama olayını listele.
    ListEvents { limit: usize },
    /// Belirli bir dosyayı anında tara.
    ScanFile { path: String },
}

/// Daemon'dan CLI'ya dönen cevaplar.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum IpcResponse {
    /// `Status` isteğine cevap.
    Status(DaemonStatus),
    /// `ListEvents` isteğine cevap.
    Events(Vec<ScanEventSummary>),
    /// `ScanFile` isteğine cevap.
    ScanResult(ScanResultSummary),
    /// Daemon'a gönderilen komut başarıyla alındı ve işlendi.
    Ok { message: String },
    /// Hata cevabı.
    Error { code: String, message: String },
}

/// Daemon'ın anlık durum özeti.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonStatus {
    /// Daemon'ın çalıştığını gösterir — her zaman `true`.
    pub running: bool,
    /// Daemon'ın başladığı zaman.
    pub started_at: DateTime<Utc>,
    /// Şimdiye kadar taranan toplam dosya sayısı.
    pub total_scans: u64,
    /// Şimdiye kadar üretilen uyarı sayısı (severity >= HIGH).
    pub total_alerts: u64,
    /// Daemon'ın izlediği klasör sayısı.
    pub watched_dirs: usize,
    /// Daemon versiyonu.
    pub version: String,
    /// Koruma modu.
    pub protection_mode: ProtectionMode,
}

/// Aktif koruma modunu gösterir.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProtectionMode {
    /// P2P 70B model aktif — tam koruma.
    FullP2P,
    /// Yerel 13B model aktif — güçlendirilmiş koruma.
    Enhanced13B,
    /// Yerel 8B/ONNX model aktif — temel koruma.
    BasicOffline,
    /// Yalnızca kural motoru — hızlı koruma.
    RulesOnly,
}

impl std::fmt::Display for ProtectionMode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::FullP2P => write!(f, "🟢 Tam Koruma (P2P 70B aktif)"),
            Self::Enhanced13B => write!(f, "🟡 Güçlendirilmiş Koruma (Yerel 13B aktif)"),
            Self::BasicOffline => write!(f, "🟠 Temel Koruma (Çevrimdışı 8B aktif)"),
            Self::RulesOnly => write!(f, "🔴 Hızlı Koruma (Kural motoru aktif)"),
        }
    }
}

/// Tek bir tarama olayının özeti.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanEventSummary {
    pub event_id: String,
    pub path: String,
    pub detected_at: DateTime<Utc>,
    pub severity: String,
    pub finding_count: usize,
    pub ml_verdict: Option<String>,
}

/// `ScanFile` isteğine dönen tarama sonucu özeti.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanResultSummary {
    pub path: String,
    pub scanned_at: DateTime<Utc>,
    pub finding_count: usize,
    pub highest_severity: String,
    pub ml_verdict: Option<String>,
    pub duration_ms: u64,
}
