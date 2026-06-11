use crate::collectors::network::{NetworkItem, SocketProtocol};
use crate::report::Evidence;

const MINER_PORTS: &[u16] = &[3333, 4444, 14444, 45560, 45700, 3334];

pub fn analyze_network_connection(item: &NetworkItem) -> Vec<Evidence> {
    let mut evidences = Vec::new();

    // Miner Havuz Portları
    if let Some(remote_port) = item.remote_port {
        if MINER_PORTS.contains(&remote_port) && item.protocol == SocketProtocol::Tcp {
            evidences.push(Evidence {
                kind: crate::report::EvidenceKind::Network,
                code: "network.miner_pool_port".to_string(),
                title: "Cryptocurrency Miner Pool Connection".to_string(),
                detail: format!(
                    "Process connected to typical miner pool port: {}",
                    remote_port
                ),
                weight: 70,
            });
        }
    }

    // Açık RDP / SSH Portları (İzinsiz Erişim Riski)
    if (item.local_port == 3389 || item.local_port == 22) && item.state.as_deref() == Some("LISTEN")
    {
        evidences.push(Evidence {
            kind: crate::report::EvidenceKind::Network,
            code: "network.exposed_admin_port".to_string(),
            title: "Admin Port Exposed".to_string(),
            detail: format!(
                "Port {} is open and listening to connections.",
                item.local_port
            ),
            weight: 20, // Bilgi amaçlı, kesin tehdit değil
        });
    }

    evidences
}
