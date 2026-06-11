//! IPC sunucusu — `defense-cli`'ın bağlanacağı dinleyici.
//!
//! Platform seçimi:
//!   Windows : Named Pipe  (`\\.\pipe\defense-daemon`)
//!   Linux   : Unix Socket (`/run/defense/daemon.sock`)
//!   macOS   : Unix Socket (`/tmp/defense-daemon.sock`)
//!
//! Protokol: newline-delimited JSON — her satır bir `IpcRequest` veya
//! `IpcResponse`. Basit, insan-okunabilir, debug kolaylığı sağlar.

use std::sync::Arc;

use anyhow::Result;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tracing::{debug, info, warn};

use crate::ipc_types::{IpcRequest, IpcResponse};
use crate::state::DaemonState;

// ─── Platform-specific socket yolu ──────────────────────────────────────────

/// IPC socket / pipe yolunu döndürür.
pub fn socket_path() -> String {
    #[cfg(target_os = "windows")]
    {
        r"\\.\pipe\defense-daemon".to_string()
    }

    #[cfg(target_os = "macos")]
    {
        "/tmp/defense-daemon.sock".to_string()
    }

    #[cfg(all(not(target_os = "windows"), not(target_os = "macos")))]
    {
        // Linux: /run/defense/daemon.sock (root) veya /tmp (kullanıcı testi)
        let run_dir = std::path::Path::new("/run/defense");
        if run_dir.exists() {
            "/run/defense/daemon.sock".to_string()
        } else {
            "/tmp/defense-daemon.sock".to_string()
        }
    }
}

// ─── Unix socket sunucusu (Linux + macOS) ───────────────────────────────────

#[cfg(unix)]
pub async fn run_ipc_server(state: Arc<DaemonState>) -> Result<()> {
    use tokio::net::UnixListener;

    let path = socket_path();

    // Önceki çalıştırmadan kalan socket dosyasını temizle.
    if std::path::Path::new(&path).exists() {
        std::fs::remove_file(&path)?;
    }

    // Socket dizinini oluştur (gerekirse).
    if let Some(parent) = std::path::Path::new(&path).parent() {
        std::fs::create_dir_all(parent)?;
    }

    let listener = UnixListener::bind(&path)?;
    info!("IPC sunucusu dinliyor: {path}");

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let state = Arc::clone(&state);
                tokio::spawn(async move {
                    if let Err(e) = handle_unix_connection(stream, state).await {
                        warn!("IPC bağlantı hatası: {e}");
                    }
                });
            }
            Err(e) => {
                warn!("IPC accept hatası: {e}");
            }
        }
    }
}

#[cfg(unix)]
async fn handle_unix_connection(
    stream: tokio::net::UnixStream,
    state: Arc<DaemonState>,
) -> Result<()> {
    let (read_half, write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    let mut writer = write_half;

    handle_connection(&mut reader, &mut writer, state).await
}

// ─── Windows Named Pipe sunucusu ─────────────────────────────────────────────

#[cfg(windows)]
pub async fn run_ipc_server(state: Arc<DaemonState>) -> Result<()> {
    use tokio::net::windows::named_pipe::ServerOptions;

    let pipe_name = socket_path();
    info!("IPC sunucusu dinliyor: {pipe_name}");

    loop {
        // Windows Named Pipe: her bağlantı için yeni bir örnek oluştur.
        let server = ServerOptions::new()
            .first_pipe_instance(false)
            .create(&pipe_name)?;

        // Bağlantı bekle.
        server.connect().await?;

        let state = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(e) = handle_windows_pipe(server, state).await {
                warn!("IPC bağlantı hatası: {e}");
            }
        });
    }
}

#[cfg(windows)]
async fn handle_windows_pipe(
    pipe: tokio::net::windows::named_pipe::NamedPipeServer,
    state: Arc<DaemonState>,
) -> Result<()> {
    let (read_half, write_half) = tokio::io::split(pipe);
    let mut reader = BufReader::new(read_half);
    let mut writer = write_half;
    handle_connection(&mut reader, &mut writer, state).await
}

// ─── Ortak bağlantı işleyicisi ───────────────────────────────────────────────

/// Her bağlantı için JSON satırlarını okur, işler ve cevap yazar.
async fn handle_connection<R, W>(
    reader: &mut BufReader<R>,
    writer: &mut W,
    state: Arc<DaemonState>,
) -> Result<()>
where
    R: tokio::io::AsyncRead + Unpin,
    W: AsyncWriteExt + Unpin,
{
    let mut line = String::new();

    loop {
        line.clear();
        let bytes_read = reader.read_line(&mut line).await?;

        // Bağlantı kapandı.
        if bytes_read == 0 {
            debug!("IPC istemcisi bağlantıyı kapattı.");
            break;
        }

        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        let response = match serde_json::from_str::<IpcRequest>(trimmed) {
            Ok(request) => {
                debug!("IPC isteği alındı: {request:?}");
                dispatch(request, Arc::clone(&state)).await
            }
            Err(e) => {
                warn!("Geçersiz IPC isteği: {e}");
                IpcResponse::Error {
                    code: "INVALID_REQUEST".to_string(),
                    message: format!("JSON parse hatası: {e}"),
                }
            }
        };

        // Cevabı JSON satırı olarak yaz.
        let mut json = serde_json::to_string(&response)?;
        json.push('\n');
        writer.write_all(json.as_bytes()).await?;
        writer.flush().await?;
    }

    Ok(())
}

// ─── İstek işleyici ──────────────────────────────────────────────────────────

async fn dispatch(request: IpcRequest, state: Arc<DaemonState>) -> IpcResponse {
    match request {
        IpcRequest::Status => IpcResponse::Status(state.to_status().await),

        IpcRequest::Shutdown => {
            info!("Shutdown isteği alındı, daemon kapatılıyor...");
            // Gerçek shutdown sinyali ileride tokio::signal ile entegre edilecek.
            IpcResponse::Ok {
                message: "Shutdown sinyali alındı.".to_string(),
            }
        }

        IpcRequest::ListEvents { limit } => {
            // Faz 1'de event log henüz yok — boş liste döndür.
            let _ = limit;
            IpcResponse::Events(vec![])
        }

        IpcRequest::ScanFile { path } => {
            info!("Manuel tarama isteği: {path}");
            // Faz 1'de doğrudan defense-core'u çağır.
            // İleride bu da daemon event loop'una gidecek.
            use crate::ipc_types::ScanResultSummary;
            use chrono::Utc;
            use defense_core::{ScanMode, ScanRequest, ScanRunner};
            use std::time::Instant;

            let t = Instant::now();
            let req = ScanRequest::new(ScanMode::Quick).with_root(path.clone());

            match ScanRunner::default().run(req) {
                Ok(report) => {
                    let highest = report
                        .findings
                        .iter()
                        .map(|f| match f.severity {
                            defense_core::report::FindingSeverity::Critical => 4u8,
                            defense_core::report::FindingSeverity::High => 3,
                            defense_core::report::FindingSeverity::Medium => 2,
                            defense_core::report::FindingSeverity::Low => 1,
                            defense_core::report::FindingSeverity::Info => 0,
                        })
                        .max()
                        .unwrap_or(0);

                    let highest_label = match highest {
                        4 => "critical",
                        3 => "high",
                        2 => "medium",
                        1 => "low",
                        _ => "none",
                    };

                    let produced_alert = highest >= 3;
                    state.record_scan(produced_alert);

                    IpcResponse::ScanResult(ScanResultSummary {
                        path,
                        scanned_at: Utc::now(),
                        finding_count: report.findings.len(),
                        highest_severity: highest_label.to_string(),
                        ml_verdict: None,
                        duration_ms: t.elapsed().as_millis() as u64,
                    })
                }
                Err(e) => IpcResponse::Error {
                    code: "SCAN_FAILED".to_string(),
                    message: e.to_string(),
                },
            }
        }
    }
}
