//! TeamTalk NG's own services, on ttmonitor.mad-gamer.com (the `ngmon`
//! server): NG Account (making and signing in to accounts, and syncing
//! saved servers between the person's devices). Blocking calls: run them
//! off the main thread.

mod account;
mod error;
mod server_record;
mod sync;

pub use account::{Account, AccountInfo, NgAccount, Session, SyncApplied, SyncChange, SyncPull, SyncRecord};
pub use error::ServiceError;
pub use server_record::SyncedServer;
pub use sync::{LocalServer, SyncOutcome, SyncState, content_hash, sync};

/// The live service.
pub const DEFAULT_BASE_URL: &str = "https://ttmonitor.mad-gamer.com";
