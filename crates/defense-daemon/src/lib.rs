pub mod fs_watcher;
pub mod ipc;
pub mod ipc_types;
pub mod service;
pub mod state;

use anyhow::Result;
use std::sync::Arc;
use tracing::info;

// ─── Ana daemon döngüsü ───────────────────────────────────────────────────────

/// Daemon'ın asıl çalışma döngüsü.
/// Windows Service, systemd ve launchd bu fonksiyonu çalıştırır.
/// Manuel test için `defense-daemon run` ile de çağrılabilir.
pub async fn run_daemon_loop() -> Result<()> {
    info!(
        "🛡️  defense Daemon v{} başlatılıyor...",
        env!("CARGO_PKG_VERSION")
    );

    // 1. Varsayılan izleme klasörlerini al.
    let watch_dirs = fs_watcher::default_watch_dirs();
    info!("İzlenecek {} klasör bulundu.", watch_dirs.len());
    for dir in &watch_dirs {
        info!("  📂 {dir}");
    }

    // 2. Daemon durumunu oluştur.
    let state = state::DaemonState::new(watch_dirs.clone());

    // 3. IPC sunucusunu arka planda başlat.
    let ipc_state = Arc::clone(&state);
    let ipc_handle = tokio::spawn(async move {
        if let Err(e) = ipc::run_ipc_server(ipc_state).await {
            tracing::error!("IPC sunucu hatası: {e}");
        }
    });

    info!("✅ Daemon hazır. IPC kanalı açık: {}", ipc::socket_path());
    info!("   Durumu görmek için: defense-daemon status");
    info!("   Durdurmak için:     defense-daemon stop");

    // 4. Dosya sistemi izleyiciyi arka planda başlat.
    let watcher_dirs = watch_dirs.clone();
    let watcher_state = Arc::clone(&state);
    let watcher_handle = tokio::spawn(async move {
        let task = fs_watcher::FsWatcherTask::new(watcher_state);
        if let Err(e) = task.run(watcher_dirs).await {
            tracing::error!("FS watcher hatası: {e}");
        }
    });

    info!("📁 Dosya sistemi izleyici başlatıldı.");

    // 4.5 P2P Tehdit İstihbaratı Düğümünü Başlat
    let _p2p_handle = tokio::spawn(async move {
        if let Err(e) = defense_core::p2p::start_node().await {
            tracing::error!("P2P Node hatası: {e}");
        }
    });
    info!("🌍 P2P Tehdit İstihbarat Düğümü başlatıldı.");
    // 5. Graceful shutdown sinyallerini bekle.
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let mut sigterm = signal(SignalKind::terminate())?;
        let mut sigint = signal(SignalKind::interrupt())?;

        tokio::select! {
            _ = sigterm.recv() => info!("SIGTERM alındı, kapatılıyor..."),
            _ = sigint.recv()  => info!("SIGINT alındı, kapatılıyor..."),
            _ = ipc_handle     => info!("IPC görev sona erdi."),
            _ = watcher_handle => info!("FS watcher görevi sona erdi."),
        }
    }

    #[cfg(windows)]
    {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => info!("Ctrl+C alındı, kapatılıyor..."),
            _ = ipc_handle              => info!("IPC görev sona erdi."),
            _ = watcher_handle          => info!("FS watcher görevi sona erdi."),
        }
    }

    info!("🛑 defense Daemon kapatıldı.");
    Ok(())
}
