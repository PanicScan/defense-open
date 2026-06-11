use crate::collectors::bluetooth::BluetoothItem;
use crate::report::Evidence;

pub fn analyze_bluetooth_devices(items: &[BluetoothItem]) -> Vec<Evidence> {
    let mut evidences = Vec::new();

    let mut nameless_count = 0;

    for item in items {
        if let Some(name) = &item.name {
            let lower_name = name.to_lowercase();
            // Flipper Zero veya Pwnagotchi gibi ofansif siber güvenlik donanımları tespit et
            if lower_name.contains("flipper")
                || lower_name.contains("pwnagotchi")
                || lower_name.contains("hak5")
            {
                evidences.push(Evidence {
                    kind: crate::report::EvidenceKind::Network,
                    code: "bluetooth.offensive_device".to_string(),
                    title: "Offensive Hardware Detected".to_string(),
                    detail: format!(
                        "Detected potential offensive cyber hardware nearby: {} (MAC: {})",
                        name, item.mac
                    ),
                    weight: 85, // Yüksek risk
                });
            }
        } else {
            nameless_count += 1;
        }
    }

    // BLE Spam / Apple Crash Flood tarzı saldırıları yakalama
    if nameless_count > 25 {
        evidences.push(Evidence {
            kind: crate::report::EvidenceKind::Network,
            code: "bluetooth.ble_flood".to_string(),
            title: "BLE Beacon Flood Detected".to_string(),
            detail: format!("Unusually high number of nameless BLE devices ({}) detected. Possible spoofing or beacon flood attack (e.g. Apple crash flood).", nameless_count),
            weight: 75,
        });
    }

    evidences
}
