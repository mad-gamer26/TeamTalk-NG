//! TeamTalk NG's own services, on ttmonitor.mad-gamer.com: NG Account (for
//! publishing sound packs) and the Monitor (watching servers while the app
//! isn't connected: TeamTalk NG's hosted one, or your own through the
//! relay). Blocking calls: run them
//! off the main thread.

mod account;
mod error;
mod monitor;
mod stream;
mod tunnel;

pub use account::{Account, AccountInfo, NgAccount, OwnPack, OwnPackFile, PackChange, Session};
pub use error::ServiceError;
pub use monitor::{
    Conversation, Monitor, MonitorAction, MonitorChannel, MonitorEvent, MonitorEvents, MonitorServer,
    MonitorServerConfig, MonitorServerInput, MonitorTarget, MonitorUser, MonitorView, PrivateMessage, Registration,
};
pub use stream::{EventStream, StreamItem};
pub use tunnel::{PairedMonitor, Tunnel, new_phone_key, pair as pair_own_monitor};

/// The live service.
pub const DEFAULT_BASE_URL: &str = "https://ttmonitor.mad-gamer.com";
