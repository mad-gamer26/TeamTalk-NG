//! TeamTalk NG Monitor (`ngmon`): the central service that stays logged in
//! to TeamTalk servers for TeamTalk NG users, so the app can show what is
//! happening on them, send push notifications, and reply and act from the
//! phone.

mod api;
mod config;
mod hub;
mod push;
mod store;
mod tt;

use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, bail};
use clap::{Parser, Subcommand};

use config::Config;
use store::Store;

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
            let store = Store::open(&cfg.database())?;
            println!("{} installs, {} servers", store.count_devices()?, store.count_servers(None)?);
            Ok(())
        }
        Command::Servers => {
            let store = Store::open(&cfg.database())?;
            for s in store.servers()? {
                println!("{}: {} ({}:{}) for install {}{}", s.id, s.name, s.host, s.tcp_port, s.owner, if s.enabled { "" } else { " [off]" });
            }
            Ok(())
        }
        Command::Device(DeviceCommand::List) => {
            let store = Store::open(&cfg.database())?;
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
        Command::CheckPhones => {
            let apns = push::Apns::new(cfg.push.apns.as_ref().context("[push.apns] is not set up")?)?;
            let store = Store::open(&cfg.database())?;
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
            let store = Store::open(&cfg.database())?;
            let r = store.sweep(store::now_ms(), store::Retention::default())?;
            println!("{} put to sleep, {} deleted", r.dormant.len(), r.deleted.len());
            Ok(())
        }
        Command::PushTest { device, token, sandbox } => {
            let apns = push::Apns::new(cfg.push.apns.as_ref().context("[push.apns] is not set up")?)?;
            let store = Store::open(&cfg.database())?;
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
            let store = Store::open(&cfg.database())?;
            if !store.remove_device(id)? {
                bail!("There is no install {id}");
            }
            println!("Removed install {id} and its servers.");
            Ok(())
        }
    }
}

async fn serve(cfg: Config) -> anyhow::Result<()> {
    let store = Store::open(&cfg.database())?;
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
    let app = api::App { hub: hub.clone(), name: cfg.client_name.clone() };
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
