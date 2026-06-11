pub mod intel_gossip;

use libp2p::futures::StreamExt;
use libp2p::{
    gossipsub, identity, mdns, noise, swarm::NetworkBehaviour, swarm::SwarmEvent, tcp, yamux,
};
use std::error::Error;
use std::time::Duration;
use tracing::info;

pub use intel_gossip::{ThreatDatabase, ThreatMessage};

#[derive(NetworkBehaviour)]
pub struct defenseBehaviour {
    pub gossipsub: gossipsub::Behaviour,
    pub mdns: mdns::tokio::Behaviour,
}

pub async fn start_node() -> Result<(), Box<dyn Error>> {
    let id_keys = identity::Keypair::generate_ed25519();
    let local_peer_id = id_keys.public().to_peer_id();
    info!("P2P Local Peer ID: {}", local_peer_id);

    let mut swarm = libp2p::SwarmBuilder::with_existing_identity(id_keys)
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_behaviour(|key| {
            let gossipsub_config = gossipsub::ConfigBuilder::default()
                .heartbeat_interval(Duration::from_secs(10))
                .validation_mode(gossipsub::ValidationMode::Strict)
                .build()
                .expect("Valid config");

            let mut gossipsub = gossipsub::Behaviour::new(
                gossipsub::MessageAuthenticity::Signed(key.clone()),
                gossipsub_config,
            )
            .expect("Valid gossipsub");

            let topic = gossipsub::IdentTopic::new("defense-global-threats");
            gossipsub.subscribe(&topic).unwrap();

            let mdns =
                mdns::tokio::Behaviour::new(mdns::Config::default(), key.public().to_peer_id())
                    .unwrap();

            defenseBehaviour { gossipsub, mdns }
        })?
        .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(60)))
        .build();

    swarm.listen_on("/ip4/0.0.0.0/tcp/0".parse()?)?;

    tokio::spawn(async move {
        loop {
            match swarm.select_next_some().await {
                SwarmEvent::NewListenAddr { address, .. } => {
                    info!("P2P Node Listening on: {}", address);
                }
                SwarmEvent::Behaviour(defenseBehaviourEvent::Mdns(mdns::Event::Discovered(
                    list,
                ))) => {
                    for (peer_id, multiaddr) in list {
                        info!("P2P mDNS Discovered: {} {:?}", peer_id, multiaddr);
                        swarm.behaviour_mut().gossipsub.add_explicit_peer(&peer_id);
                    }
                }
                SwarmEvent::Behaviour(defenseBehaviourEvent::Gossipsub(
                    gossipsub::Event::Message {
                        propagation_source: peer_id,
                        message_id: _,
                        message,
                    },
                )) => {
                    info!("Got Gossip Message from {}", peer_id);
                    if let Ok(ThreatMessage::NewBadIp { ip, reason }) =
                        serde_json::from_slice::<ThreatMessage>(&message.data)
                    {
                        info!("P2P ALERT: Learned new Bad IP {} ({})", ip, reason);
                        ThreatDatabase::global().add_ip(ip);
                    }
                }
                _ => {}
            }
        }
    });

    Ok(())
}
