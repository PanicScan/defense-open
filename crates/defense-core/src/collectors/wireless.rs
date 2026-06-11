#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WirelessItem {
    pub mac: String,
    pub ssid: String,
    pub channel: String,
    pub signal_level: String,
    pub security: String,
}

#[derive(Debug, Default)]
pub struct WirelessCollector;

impl WirelessCollector {
    /// Çevredeki Wi-Fi ağlarını tarar ve SSID, MAC (BSSID) ve Güvenlik bilgilerini döner.
    pub fn collect(&self) -> Vec<WirelessItem> {
        let mut items = Vec::new();
        // wifiscanner, işletim sisteminin native araçlarını kullanır (örn: netsh wlan show networks mode=bssid)
        // Mac ortamında donanım olmadığında panic atabildiği için catch_unwind ile yakalıyoruz.
        let scan_result = std::panic::catch_unwind(wifiscanner::scan);

        if let Ok(Ok(networks)) = scan_result {
            for network in networks {
                items.push(WirelessItem {
                    mac: network.mac,
                    ssid: network.ssid,
                    channel: network.channel,
                    signal_level: network.signal_level,
                    security: network.security,
                });
            }
        }
        items
    }
}
