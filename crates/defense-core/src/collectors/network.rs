use netstat2::{get_sockets_info, AddressFamilyFlags, ProtocolFlags, ProtocolSocketInfo};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SocketProtocol {
    Tcp,
    Udp,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkItem {
    pub pid: Option<u32>,
    pub local_ip: String,
    pub local_port: u16,
    pub remote_ip: Option<String>,
    pub remote_port: Option<u16>,
    pub protocol: SocketProtocol,
    pub state: Option<String>,
}

#[derive(Debug, Default)]
pub struct NetworkCollector;

impl NetworkCollector {
    /// Sistemdeki mevcut TCP ve UDP soketlerini toplar ve ilişikli PID'leri döndürür.
    pub fn collect(&self) -> Vec<NetworkItem> {
        let mut items = Vec::new();
        let af_flags = AddressFamilyFlags::IPV4 | AddressFamilyFlags::IPV6;
        let proto_flags = ProtocolFlags::TCP | ProtocolFlags::UDP;

        if let Ok(sockets) = get_sockets_info(af_flags, proto_flags) {
            for socket in sockets {
                let pid = socket.associated_pids.first().copied();
                let (protocol, local_ip, local_port, remote_ip, remote_port, state) =
                    match socket.protocol_socket_info {
                        ProtocolSocketInfo::Tcp(tcp) => (
                            SocketProtocol::Tcp,
                            tcp.local_addr.to_string(),
                            tcp.local_port,
                            Some(tcp.remote_addr.to_string()),
                            Some(tcp.remote_port),
                            Some(tcp.state.to_string()),
                        ),
                        ProtocolSocketInfo::Udp(udp) => (
                            SocketProtocol::Udp,
                            udp.local_addr.to_string(),
                            udp.local_port,
                            None,
                            None,
                            None,
                        ),
                    };

                items.push(NetworkItem {
                    pid,
                    local_ip,
                    local_port,
                    remote_ip,
                    remote_port,
                    protocol,
                    state,
                });
            }
        }
        items
    }
}
