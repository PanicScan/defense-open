use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;
use std::time::Duration;
use tokio::time;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BluetoothItem {
    pub mac: String,
    pub name: Option<String>,
    pub rssi: Option<i16>,
}

#[derive(Debug, Default)]
pub struct BluetoothCollector;

impl BluetoothCollector {
    /// Çevredeki BLE (Bluetooth Low Energy) cihazları 3 saniye boyunca tarar.
    pub async fn collect(&self) -> Vec<BluetoothItem> {
        let mut items = Vec::new();

        if let Ok(manager) = Manager::new().await {
            if let Ok(adapters) = manager.adapters().await {
                if let Some(central) = adapters.into_iter().next() {
                    if central.start_scan(ScanFilter::default()).await.is_ok() {
                        // Bluetooth radyo sinyallerinin toplanması için asenkron bekleme
                        time::sleep(Duration::from_secs(3)).await;

                        if let Ok(peripherals) = central.peripherals().await {
                            for peripheral in peripherals {
                                if let Ok(Some(props)) = peripheral.properties().await {
                                    items.push(BluetoothItem {
                                        mac: peripheral.id().to_string(),
                                        name: props.local_name,
                                        rssi: props.rssi,
                                    });
                                }
                            }
                        }
                        let _ = central.stop_scan().await;
                    }
                }
            }
        }
        items
    }
}
