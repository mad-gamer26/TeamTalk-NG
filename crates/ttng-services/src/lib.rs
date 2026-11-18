//! TeamTalk NG's own services, on ttmonitor.mad-gamer.com (the `ngmon`
//! server): NG Account (making and signing in to accounts, and syncing
//! saved servers between the person's devices) and the Monitor (watching
//! servers while the app isn't connected). Blocking calls: run them
//! off the main thread.

mod account;
mod error;
mod monitor;
mod server_record;
mod sync;
mod tunnel;

pub use account::{
    Account, AccountInfo, NgAccount, OwnPack, OwnPackFile, PackChange, Session, SyncApplied, SyncChange, SyncPull,
    SyncRecord,
};
pub use error::ServiceError;
pub use monitor::{
    Conversation, Monitor, MonitorAction, MonitorChannel, MonitorEvent, MonitorEvents, MonitorServer,
    MonitorServerConfig, MonitorServerInput, MonitorTarget, MonitorUser, MonitorView, PrivateMessage, Registration,
};
pub use server_record::SyncedServer;
pub use sync::{LocalServer, SyncOutcome, SyncState, content_hash, sync, sync_with_settings};
pub use tunnel::{PairedMonitor, Tunnel, new_phone_key, pair as pair_own_monitor};

/// The live service.
pub const DEFAULT_BASE_URL: &str = "https://ttmonitor.mad-gamer.com";
