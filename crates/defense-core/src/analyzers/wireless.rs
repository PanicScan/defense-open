use crate::collectors::wireless::WirelessItem;
use crate::report::Evidence;
use std::collections::HashMap;

pub fn analyze_wireless_networks(items: &[WirelessItem]) -> Vec<Evidence> {
    let mut evidences = Vec::new();
    let mut ssid_map: HashMap<String, Vec<&WirelessItem>> = HashMap::new();

    // Ağları SSID (Ağ İsmi) bazında grupla
    for item in items {
        ssid_map.entry(item.ssid.clone()).or_default().push(item);
    }

    for (ssid, networks) in ssid_map {
        // Eğer aynı isimli birden fazla ağ varsa ve gizli değilse
        if networks.len() > 1 && !ssid.is_empty() {
            let has_secure = networks.iter().any(|n| {
                n.security.to_lowercase() != "open"
                    && n.security.to_lowercase() != "none"
                    && !n.security.is_empty()
            });
            let open_networks: Vec<_> = networks
                .iter()
                .filter(|n| {
                    n.security.to_lowercase() == "open"
                        || n.security.to_lowercase() == "none"
                        || n.security.is_empty()
                })
                .collect();

            // Orijinal güvenli ağ var ama açık/şifresiz sahtesi de varsa -> Evil Twin
            if has_secure && !open_networks.is_empty() {
                for spoof in open_networks {
                    evidences.push(Evidence {
                        kind: crate::report::EvidenceKind::Network,
                        code: "wireless.evil_twin".to_string(),
                        title: "Potential Evil Twin Detected".to_string(),
                        detail: format!("Network '{}' (MAC: {}) is Open, but secure networks with the same name exist. This could be a Rogue AP / Karma Attack.", ssid, spoof.mac),
                        weight: 90, // Yüksek risk
                    });
                }
            }
        }
    }

    evidences
}
