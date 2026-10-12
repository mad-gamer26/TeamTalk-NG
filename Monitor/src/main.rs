//! TeamTalk NG Monitor (`ngmon`): the central service that stays logged in
//! to TeamTalk servers for TeamTalk NG users, so the app can show what is
//! happening on them, send push notifications, and reply and act from the
//! phone.

mod account_api;
mod accounts;
mod api;
mod config;
mod hub;
mod mail;
mod packs;
mod push;
mod store;
mod sync;
mod tt;
mod zip;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, bail};
use clap::{Parser, Subcommand};

use config::Config;

#[derive(Parser)]
#[command(name = "ngmon", version, about = "TeamTalk NG Monitor: watches TeamTalk servers for TeamTalk NG users")]
struct Cli {
    /// Settings file.
    #[arg(short, long, global = true, default_value = config::DEFAULT_CONFIG)]
    config: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Write a settings file to start from.
    Init,
    /// Run the monitor.
    Serve,
    /// How many installs and servers use the monitor.
    Stats,
    /// List monitored servers (all installs').
    Servers,
    /// List or remove app installs.
    #[command(subcommand)]
    Device(DeviceCommand),
    /// NG Accounts.
    #[command(subcommand)]
    Account(AccountCommand),
    /// Sound packs: the catalog, reports, and Official packs.
    #[command(subcommand)]
    Pack(PackCommand),
    /// Put abandoned sign-ups to sleep and delete long-abandoned ones now
    /// (the running monitor also does this every hour).
    Sweep,
    /// Send every phone the silent check that the app is still installed
    /// now (the running monitor does this daily per phone).
    CheckPhones,
    /// Send a test notification to an install (or to a raw APNs token).
    PushTest {
        /// The install to notify, from `ngmon device list`.
        #[arg(long, conflicts_with = "token")]
        device: Option<i64>,
        /// An APNs device token in hex.
        #[arg(long)]
        token: Option<String>,
        /// Use Apple's sandbox (development builds) with --token.
        #[arg(long)]
        sandbox: bool,
    },
}

#[derive(Subcommand)]
enum DeviceCommand {
    List,
    /// Forget an install and stop monitoring its servers (takes effect
    /// when the monitor next starts, or within seconds while it runs).
    Remove { id: i64 },
}

#[derive(Subcommand)]
enum AccountCommand {
    List,
    /// Stop an account from publishing sound packs (unpublishes its packs).
    Block { id: i64 },
    Unblock { id: i64 },
}

#[derive(Subcommand)]
enum PackCommand {
    /// Every pack, private ones included.
    List,
    /// Packs people reported.
    Reports,
    /// Take a published pack out of the catalog.
    Hide { id: String },
    /// Put a hidden pack back.
    Show { id: String },
    /// Give a pack to an NG Account, which can then update or unpublish it.
    Assign { id: String, email: String },
    /// Mark a pack Official (or not, with --off).
    Official {
        id: String,
        #[arg(long)]
        off: bool,
    },
    /// Make or replace an Official pack from a zip of sounds. Keep the ID
    /// of a pack people already installed, so it updates for them.
    ImportOfficial {
        id: String,
        name: String,
        author: String,
        /// The pack's version; installed copies of a lower one update.
        version: i64,
        zip: PathBuf,
    },
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_env("NGMON_LOG").unwrap_or_else(|_| "ngmon=info".into()))
        .with_writer(std::io::stderr)
        .init();
    let _ = rustls::crypto::ring::default_provider().install_default();
    if let Err(e) = run(Cli::parse()).await {
        eprintln!("ngmon: {e:#}");
        std::process::exit(1);
    }
}

async fn run(cli: Cli) -> anyhow::Result<()> {
    if let Command::Init = cli.command {
        if cli.config.exists() {
            bail!("{} already exists", cli.config.display());
        }
        std::fs::write(&cli.config, config::SAMPLE)?;
        println!("Wrote {}.", cli.config.display());
        return Ok(());
    }
    let cfg = Config::load(&cli.config)?;
    match cli.command {
        Command::Init => unreachable!(),
        Command::Serve => serve(cfg).await,
        Command::Stats => {
            let store = cfg.open_store()?;
            println!("{} installs, {} servers", store.count_devices()?, store.count_servers(None)?);
            Ok(())
        }
        Command::Servers => {
            let store = cfg.open_store()?;
            for s in store.servers()? {
                println!("{}: {} ({}:{}) for install {}{}", s.id, s.name, s.host, s.tcp_port, s.owner, if s.enabled { "" } else { " [off]" });
            }
            Ok(())
        }
        Command::Device(DeviceCommand::List) => {
            let store = cfg.open_store()?;
            for d in store.devices()? {
                println!(
                    "{}: {}, {} servers, {} phones with notifications{}",
                    d.id,
                    d.name,
                    store.count_servers(Some(d.id))?,
                    store.push_targets(d.id)?.len(),
                    if d.dormant { ", asleep" } else { "" }
                );
            }
            Ok(())
        }
        Command::Account(AccountCommand::List) => {
            let store = cfg.open_store()?;
            for a in store.accounts()? {
                let (bytes, _) = store.pack_usage(a.id)?;
                println!(
                    "{}: {}, {} devices signed in, {} monitored servers, {} KB of sound packs",
                    a.id,
                    a.email,
                    store.sessions(a.id)?.len(),
                    store.servers_of(a.owner)?.len(),
                    bytes / 1024
                );
            }
            Ok(())
        }
        Command::Account(AccountCommand::Block { id }) | Command::Account(AccountCommand::Unblock { id }) => {
            let block = matches!(cli.command, Command::Account(AccountCommand::Block { .. }));
            if !cfg.open_store()?.set_publishing_blocked(id, block)? {
                bail!("There is no account {id}");
            }
            println!("Account {id} {}", if block { "can no longer publish; its packs were unpublished" } else { "can publish again" });
            Ok(())
        }
        Command::Pack(PackCommand::List) => {
            for p in cfg.open_store()?.all_packs()? {
                let state = match (p.public, p.hidden, p.official) {
                    (_, true, _) => "hidden",
                    (true, _, true) => "official",
                    (true, _, false) => "public",
                    _ => "private",
                };
                let owner = p.owner.map_or("nobody".to_owned(), |o| format!("account {o}"));
                println!("{}: {} by {:?} ({state}, {owner}, version {}, {} sounds, {} KB, {} installs)", p.id, p.name, p.author, p.version, p.files.len(), p.size / 1024, p.installs);
            }
            Ok(())
        }
        Command::Pack(PackCommand::Reports) => {
            for (pack, account, reason, _) in cfg.open_store()?.pack_reports()? {
                println!("{pack} reported by account {account}: {reason}");
            }
            Ok(())
        }
        Command::Pack(PackCommand::Hide { ref id }) | Command::Pack(PackCommand::Show { ref id }) => {
            let hide = matches!(cli.command, Command::Pack(PackCommand::Hide { .. }));
            if !cfg.open_store()?.set_pack_hidden(id, hide)? {
                bail!("There is no pack {id}");
            }
            Ok(())
        }
        Command::Pack(PackCommand::Assign { ref id, ref email }) => {
            let store = cfg.open_store()?;
            let email = accounts::normalize_email(email).map_err(|e| anyhow::anyhow!("{e}"))?;
            let account = store.account_by_email(&email)?.with_context(|| format!("There is no NG Account {email}"))?;
            if !store.assign_pack(id, account.id)? {
                bail!("There is no pack {id}");
            }
            println!("{id} now belongs to {email} (account {})", account.id);
            Ok(())
        }
        Command::Pack(PackCommand::Official { ref id, off }) => {
            if !cfg.open_store()?.set_pack_official(id, !off)? {
                bail!("There is no pack {id}");
            }
            Ok(())
        }
        Command::Pack(PackCommand::ImportOfficial { ref id, ref name, ref author, version, ref zip }) => {
            let hub = hub::Hub::new(cfg.open_store()?, hub::Options {
                client_name: cfg.client_name.clone(),
                seal: false,
                allow_private_hosts: false,
                limits: cfg.limits.clone(),
            })?;
            let packs = packs::Packs::new(hub, cfg.packs_dir.clone())?;
            let n = packs.import_official(id, name, author, version, zip)?;
            println!("{name} ({id}) is an Official pack, version {version}, with {n} sounds");
            Ok(())
        }
        Command::CheckPhones => {
            let apns = push::Apns::new(cfg.push.apns.as_ref().context("[push.apns] is not set up")?)?;
            let store = cfg.open_store()?;
            let due = store.push_targets_due(store::now_ms(), 0)?;
            let mut gone = 0;
            for t in &due {
                let job = push::PushJob { apns_token: t.apns_token.clone(), sandbox: t.sandbox, payload: push::silent_payload(), background: true };
                if let Err(push::PushError::Unregistered) = apns.send(&job).await {
                    store.drop_apns_token(&t.apns_token)?;
                    gone += 1;
                }
            }
            println!("{} phones checked, {} no longer have the app", due.len(), gone);
            Ok(())
        }
        Command::Sweep => {
            let store = cfg.open_store()?;
            let r = store.sweep(store::now_ms(), store::Retention::default())?;
            println!("{} put to sleep, {} deleted", r.dormant.len(), r.deleted.len());
            Ok(())
        }
        Command::PushTest { device, token, sandbox } => {
            let apns = push::Apns::new(cfg.push.apns.as_ref().context("[push.apns] is not set up")?)?;
            let store = cfg.open_store()?;
            let (token, sandbox, key, app_ref) = match (device, token) {
                (Some(id), _) => {
                    let d = store.device(id)?.into_iter().next().with_context(|| format!("There is no install {id}"))?;
                    let t = store.push_targets(id)?.into_iter().last().context("That install has not turned on notifications")?;
                    (t.apns_token, t.sandbox, Some(d.push_key), t.app_ref)
                }
                (None, Some(t)) => (t, sandbox, None, String::new()),
                (None, None) => bail!("Say --device or --token"),
            };
            let n = push::Notification {
                title: "TeamTalk NG Monitor".into(),
                subtitle: String::new(),
                body: "Test notification: the monitor can reach this phone.".into(),
                thread: "test".into(),
                category: push::CATEGORY_CONNECTION,
                sound: "logged_on.wav",
                data: serde_json::json!({ "event": "test" }),
            };
            let payload = push::payload(&n, key.as_deref().filter(|_| cfg.push.encrypt), &app_ref)?;
            match apns.send(&push::PushJob { apns_token: token, sandbox, payload, background: false }).await {
                Ok(()) => println!("Apple accepted the notification."),
                Err(push::PushError::Unregistered) => println!("Apple accepted the key but says that device token is not valid."),
                Err(e) => bail!("{e}"),
            }
            Ok(())
        }
        Command::Device(DeviceCommand::Remove { id }) => {
            let store = cfg.open_store()?;
            if !store.remove_device(id)? {
                bail!("There is no install {id}");
            }
            println!("Removed install {id} and its servers.");
            Ok(())
        }
    }
}

async fn serve(cfg: Config) -> anyhow::Result<()> {
    let store = cfg.open_store()?;
    let hub = hub::Hub::new(
        store,
        hub::Options {
            client_name: cfg.client_name.clone(),
            seal: push::seals(&cfg.push),
            allow_private_hosts: cfg.allow_private_hosts,
            limits: cfg.limits.clone(),
        },
    )?;
    let weak = std::sync::Arc::downgrade(&hub);
    let tx = push::start(&cfg.push, move |token| {
        if let Some(hub) = weak.upgrade() {
            tracing::info!("forgetting a device token Apple no longer accepts");
            hub.forget_apns_token(&token);
        }
    })?;
    hub.set_push(tx);
    hub.check_phones();
    hub.sweep(store::Retention::default());
    hub.reconcile(true);
    // Pick up servers removed from the command line, and sweep for
    // abandoned sign-ups every hour.
    let watcher = {
        let hub = hub.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_secs(3));
            let mut last_sweep = std::time::Instant::now();
            loop {
                tick.tick().await;
                hub.expire_pauses();
                if last_sweep.elapsed() >= Duration::from_secs(60 * 60) {
                    last_sweep = std::time::Instant::now();
                    hub.check_phones();
                    hub.sweep(store::Retention::default());
                }
                hub.reconcile(false);
            }
        })
    };
    let listener = tokio::net::TcpListener::bind(&cfg.listen).await.with_context(|| format!("Could not listen on {}", cfg.listen))?;
    tracing::info!("monitor listening on {}", cfg.listen);
    if cfg.push.mode == config::PushMode::None {
        tracing::info!("push notifications are off ([push] mode = \"none\")");
    }
    if cfg.allow_private_hosts {
        tracing::warn!("private and local server addresses are allowed (allow_private_hosts); never on a public service");
    }
    let mailer = mail::Mailer::new(&cfg.mail)?;
    if !mailer.enabled() {
        tracing::warn!("[mail] is not set up: nobody can make an NG Account or reset a password");
    }
    let accounts = std::sync::Arc::new(accounts::Accounts::new(hub.clone(), mailer));
    let packs = std::sync::Arc::new(packs::Packs::new(hub.clone(), cfg.packs_dir.clone())?);
    match packs.collect_garbage() {
        Ok(0) => {}
        Ok(n) => tracing::info!(files = n, "cleared unused sound files"),
        Err(e) => tracing::warn!("could not clear unused sound files: {e:#}"),
    }
    let app = api::App { hub: hub.clone(), accounts, packs, name: cfg.client_name.clone() };
    axum::serve(listener, api::router(app).into_make_service_with_connect_info::<SocketAddr>()).with_graceful_shutdown(shutdown()).await?;
    watcher.abort();
    hub.stop_all();
    // Let sessions send their quit.
    tokio::time::sleep(Duration::from_millis(300)).await;
    Ok(())
}

async fn shutdown() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    {
        let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("signal handler");
        tokio::select! {
            _ = ctrl_c => {}
            _ = term.recv() => {}
        }
    }
    #[cfg(not(unix))]
    let _ = ctrl_c.await;
    tracing::info!("shutting down");
}
