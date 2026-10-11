//! The API TeamTalk NG uses: registering an app install, its monitored
//! servers and their state, a WebSocket of events, sending messages, acting
//! on a server, and the install's push settings.
//!
//! Every route except `/v1/info` and `/v1/register` needs the install's
//! token: `Authorization: Bearer <token>`. Each install sees only its own
//! servers.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{ConnectInfo, FromRequestParts, Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

use crate::hub::{Action, Hub, HubError, MessageTarget};
use crate::push::Prefs;
use crate::store::{Device, ServerConfig};

pub const API_VERSION: i64 = 1;

#[derive(Clone)]
pub struct App {
    pub hub: Arc<Hub>,
    pub name: String,
}

pub fn router(app: App) -> Router {
    Router::new()
        .route("/v1/info", get(info))
        .route("/v1/register", post(register))
        .route("/v1/me", get(me).delete(unpair).patch(rename_me))
        .route("/v1/me/push", put(set_push))
        .route("/v1/me/merge", post(merge))
        .route("/v1/me/prefs", get(get_prefs).put(set_prefs))
        .route("/v1/servers", get(servers).post(add_server))
        .route("/v1/servers/{id}", get(server).put(update_server).delete(remove_server))
        .route("/v1/servers/{id}/config", get(server_config))
        .route("/v1/servers/{id}/messages", post(send_message))
        .route("/v1/servers/{id}/actions", post(act))
        .route("/v1/servers/{id}/pause", post(pause).delete(resume))
        .route("/v1/servers/{id}/admin", post(admin))
        .route("/v1/conversations", get(conversations))
        .route("/v1/servers/{id}/conversations/{conversation}", delete(delete_conversation))
        .route("/v1/servers/{id}/conversations/{conversation}/messages", get(conversation_messages))
        .route("/v1/servers/{id}/conversations/{conversation}/read", post(mark_read))
        .route("/v1/events", get(events))
        .route("/v1/ws", get(websocket))
        .layer(axum::extract::DefaultBodyLimit::max(64 * 1024))
        .with_state(app)
}

pub struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({ "error": self.1 }))).into_response()
    }
}

impl From<HubError> for ApiError {
    fn from(e: HubError) -> Self {
        let status = match &e {
            HubError::NotFound(_) => StatusCode::NOT_FOUND,
            HubError::Invalid(_) => StatusCode::BAD_REQUEST,
            HubError::Refused(_) => StatusCode::CONFLICT,
            HubError::Command(crate::tt::conn::CommandError::Server { .. }) => StatusCode::UNPROCESSABLE_ENTITY,
            HubError::Command(_) => StatusCode::SERVICE_UNAVAILABLE,
            HubError::Internal(e) => {
                tracing::error!("{e:#}");
                return ApiError(StatusCode::INTERNAL_SERVER_ERROR, "Something went wrong in the monitor".into());
            }
        };
        ApiError(status, e.to_string())
    }
}

type ApiResult<T> = Result<T, ApiError>;

/// The paired device making the request.
pub struct Authed(pub Device);

impl FromRequestParts<App> for Authed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &App) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get("authorization")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.strip_prefix("Bearer "))
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .ok_or_else(|| ApiError(StatusCode::UNAUTHORIZED, "This device is not paired with the monitor".into()))?;
        app.hub
            .authenticate(token)
            .map(Authed)
            .ok_or_else(|| ApiError(StatusCode::UNAUTHORIZED, "This device is no longer paired with the monitor".into()))
    }
}

async fn info(State(app): State<App>) -> Json<Value> {
    Json(json!({ "service": "ngmon", "name": app.name, "version": env!("CARGO_PKG_VERSION"), "api": API_VERSION }))
}

#[derive(Deserialize)]
struct RegisterRequest {
    #[serde(default)]
    device_name: String,
}

/// The address a request came from: nginx's `X-Real-IP` when the monitor
/// listens behind it on this machine, else the connection's own.
fn client_address(peer: SocketAddr, headers: &HeaderMap) -> String {
    if peer.ip().is_loopback()
        && let Some(ip) = headers.get("x-real-ip").and_then(|v| v.to_str().ok())
    {
        return ip.trim().to_owned();
    }
    peer.ip().to_string()
}

async fn register(State(app): State<App>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Json(req): Json<RegisterRequest>) -> ApiResult<Json<Value>> {
    let r = app.hub.register(&req.device_name, &client_address(peer, &headers)).map_err(|e| match e {
        HubError::Refused(m) => ApiError(StatusCode::TOO_MANY_REQUESTS, m),
        e => e.into(),
    })?;
    Ok(Json(json!({ "device_id": r.device_id, "token": r.token, "push_key": r.push_key, "name": app.name, "api": API_VERSION })))
}

async fn me(Authed(d): Authed) -> Json<Device> {
    Json(d)
}

#[derive(Deserialize)]
struct Rename {
    name: String,
}

async fn rename_me(State(app): State<App>, Authed(d): Authed, Json(r): Json<Rename>) -> ApiResult<StatusCode> {
    app.hub.with_store(|s| s.rename_device(d.id, r.name.trim()))?;
    Ok(StatusCode::NO_CONTENT)
}

/// Forget this install and stop monitoring its servers.
async fn unpair(State(app): State<App>, Authed(d): Authed) -> ApiResult<StatusCode> {
    app.hub.remove_device(d.id)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct MergeRequest {
    /// The other sign-up's secret token.
    token: String,
}

/// Fold another sign-up of the same person into this one.
async fn merge(State(app): State<App>, Authed(d): Authed, Json(r): Json<MergeRequest>) -> ApiResult<StatusCode> {
    app.hub.merge(d.id, r.token.trim())?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct PushRegistration {
    /// The APNs device token in hex; null turns pushes off.
    apns_token: Option<String>,
    /// Development builds get their pushes from Apple's sandbox.
    #[serde(default)]
    sandbox: bool,
    /// The app's own name for this sign-up, returned in every push.
    #[serde(default)]
    app_ref: String,
    /// This installed copy of the app; each copy gets its own pushes.
    #[serde(default)]
    install_id: String,
}

async fn set_push(State(app): State<App>, Authed(d): Authed, Json(r): Json<PushRegistration>) -> ApiResult<StatusCode> {
    let token = r.apns_token.map(|t| t.trim().to_lowercase()).filter(|t| !t.is_empty());
    if let Some(t) = &token
        && (t.len() > 200 || !t.chars().all(|c| c.is_ascii_hexdigit())) {
            return Err(ApiError(StatusCode::BAD_REQUEST, "That is not an APNs device token".into()));
        }
    let clean = |v: &str| -> String { v.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(64).collect() };
    let app_ref = clean(&r.app_ref);
    let install_id = if r.install_id.is_empty() { app_ref.clone() } else { clean(&r.install_id) };
    app.hub.with_store(|s| s.set_push_target(d.id, &install_id, token.as_deref(), r.sandbox, &app_ref))?;
    Ok(StatusCode::NO_CONTENT)
}

async fn get_prefs(Authed(d): Authed) -> Json<Prefs> {
    Json(d.prefs)
}

async fn set_prefs(State(app): State<App>, Authed(d): Authed, Json(p): Json<Prefs>) -> ApiResult<Json<Prefs>> {
    app.hub.with_store(|s| s.set_device_prefs(d.id, &p))?;
    Ok(Json(p))
}

async fn servers(State(app): State<App>, Authed(d): Authed) -> Json<Value> {
    Json(json!({ "servers": app.hub.servers(d.id), "seq": app.hub.last_seq() }))
}

async fn server(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>) -> ApiResult<Json<Value>> {
    Ok(Json(serde_json::to_value(app.hub.server(d.id, id)?).map_err(|e| HubError::Internal(e.into()))?))
}

async fn server_config(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>) -> ApiResult<Json<ServerConfig>> {
    Ok(Json(app.hub.server_config(d.id, id)?))
}

/// A server's settings as the app sends them (`password` is accepted
/// here even though it is never sent back).
#[derive(Deserialize)]
struct ServerInput {
    name: String,
    host: String,
    #[serde(default = "default_port")]
    tcp_port: u16,
    #[serde(default)]
    encrypted: bool,
    #[serde(default)]
    nickname: String,
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: String,
    #[serde(default)]
    status_msg: String,
    #[serde(default)]
    status_mode: i64,
    #[serde(default)]
    channel: String,
    #[serde(default)]
    channel_password: String,
    #[serde(default = "yes")]
    enabled: bool,
}

use crate::tt::conn::GENDER_BITS;

fn default_port() -> u16 {
    10333
}

fn yes() -> bool {
    true
}

impl ServerInput {
    fn into_config(self, id: i64) -> ServerConfig {
        ServerConfig {
            id,
            owner: 0,
            name: self.name,
            host: self.host.trim().to_owned(),
            tcp_port: self.tcp_port,
            encrypted: self.encrypted,
            nickname: self.nickname,
            username: self.username,
            password: self.password,
            status_msg: self.status_msg,
            status_mode: self.status_mode & GENDER_BITS,
            channel: self.channel,
            channel_password: self.channel_password,
            enabled: self.enabled,
        }
    }
}

async fn add_server(State(app): State<App>, Authed(d): Authed, Json(s): Json<ServerInput>) -> ApiResult<(StatusCode, Json<Value>)> {
    let id = app.hub.add_server(d.id, s.into_config(0)).await?;
    Ok((StatusCode::CREATED, Json(json!({ "id": id }))))
}

async fn update_server(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>, Json(s): Json<ServerInput>) -> ApiResult<StatusCode> {
    app.hub.update_server(d.id, s.into_config(id)).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn remove_server(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>) -> ApiResult<StatusCode> {
    app.hub.remove_server(d.id, id)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SendMessage {
    #[serde(flatten)]
    target: MessageTarget,
    text: String,
}

async fn send_message(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>, Json(m): Json<SendMessage>) -> ApiResult<StatusCode> {
    app.hub.send_message(d.id, id, m.target, &m.text).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn act(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>, Json(a): Json<Action>) -> ApiResult<StatusCode> {
    app.hub.act(d.id, id, a).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct AdminRequest {
    command: String,
    #[serde(default)]
    params: serde_json::Map<String, Value>,
}

async fn admin(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>, Json(r): Json<AdminRequest>) -> ApiResult<Json<Value>> {
    let lines = app.hub.admin(d.id, id, &r.command, &r.params).await?;
    Ok(Json(json!({ "lines": lines })))
}

#[derive(Deserialize)]
struct Pause {
    /// How long at most; the app resumes sooner when it disconnects.
    #[serde(default = "default_pause")]
    minutes: i64,
}

fn default_pause() -> i64 {
    12 * 60
}

async fn pause(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>, body: Option<Json<Pause>>) -> ApiResult<StatusCode> {
    let minutes = body.map(|Json(p)| p.minutes).unwrap_or_else(default_pause);
    app.hub.pause(d.id, id, minutes)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn resume(State(app): State<App>, Authed(d): Authed, Path(id): Path<i64>) -> ApiResult<StatusCode> {
    app.hub.resume(d.id, id)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct ServerFilter {
    server_id: Option<i64>,
}

async fn conversations(State(app): State<App>, Authed(d): Authed, Query(q): Query<ServerFilter>) -> ApiResult<Json<Value>> {
    let c = app.hub.with_store(|s| s.conversations(d.id, q.server_id))?;
    Ok(Json(json!({ "conversations": c })))
}

#[derive(Deserialize)]
struct Page {
    before: Option<i64>,
    limit: Option<i64>,
}

/// A conversation on one of this install's servers.
fn conversation(app: &App, d: &Device, server_id: i64, conversation_id: i64) -> ApiResult<crate::store::Conversation> {
    owns(app, d, server_id)?;
    app.hub
        .with_store(|s| s.conversation(conversation_id))?
        .filter(|c| c.server_id == server_id)
        .ok_or_else(|| ApiError(StatusCode::NOT_FOUND, "No such conversation".into()))
}

async fn conversation_messages(State(app): State<App>, Authed(d): Authed, Path((id, conversation_id)): Path<(i64, i64)>, Query(p): Query<Page>) -> ApiResult<Json<Value>> {
    let c = conversation(&app, &d, id, conversation_id)?;
    let (m, seq) = app.hub.with_store_at(|s| s.messages(conversation_id, p.before, p.limit.unwrap_or(100).clamp(1, 500)))?;
    // `seq`: the history includes every event up to this one.
    Ok(Json(json!({ "conversation": c, "messages": m, "seq": seq })))
}

/// Delete a conversation and its messages.
async fn delete_conversation(State(app): State<App>, Authed(d): Authed, Path((id, conversation_id)): Path<(i64, i64)>) -> ApiResult<StatusCode> {
    conversation(&app, &d, id, conversation_id)?;
    app.hub.with_store(|s| s.delete_conversation(conversation_id))?;
    Ok(StatusCode::NO_CONTENT)
}

async fn mark_read(State(app): State<App>, Authed(d): Authed, Path((id, conversation_id)): Path<(i64, i64)>) -> ApiResult<StatusCode> {
    conversation(&app, &d, id, conversation_id)?;
    app.hub.with_store(|s| s.mark_read(conversation_id))?;
    Ok(StatusCode::NO_CONTENT)
}

fn owns(app: &App, d: &Device, server_id: i64) -> ApiResult<()> {
    if app.hub.owner_of(server_id) == Some(d.id) {
        Ok(())
    } else {
        Err(ApiError(StatusCode::NOT_FOUND, "No such server".into()))
    }
}

#[derive(Deserialize)]
struct EventQuery {
    /// Events after this number; leave out for the most recent ones.
    since: Option<i64>,
    server_id: Option<i64>,
    limit: Option<i64>,
}

async fn events(State(app): State<App>, Authed(d): Authed, Query(q): Query<EventQuery>) -> ApiResult<Json<Value>> {
    let limit = q.limit.unwrap_or(200).clamp(1, 1000);
    let (events, first) = app.hub.with_store(|s| {
        let events = match q.since {
            Some(since) => s.events_since(since, d.id, q.server_id, limit)?,
            None => s.recent_events(d.id, q.server_id, limit)?,
        };
        Ok((events, s.first_seq()?))
    })?;
    // Asking for events older than the log keeps means some were missed.
    let gap = q.since.is_some_and(|since| since > 0 && since + 1 < first);
    Ok(Json(json!({ "events": events, "last_seq": app.hub.last_seq(), "gap": gap })))
}

#[derive(Deserialize)]
struct WsQuery {
    since: Option<i64>,
}

/// Live events. With `since`, missed events are sent first; when too many
/// were missed, a `reset` message says to reload the servers instead.
async fn websocket(State(app): State<App>, Authed(d): Authed, Query(q): Query<WsQuery>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| follow(app.hub, socket, d.id, q.since))
}

async fn follow(hub: Arc<Hub>, mut socket: WebSocket, owner: i64, since: Option<i64>) {
    let mut live = hub.subscribe();
    let mut last = hub.last_seq();
    // A number past the end means the monitor's log was started over.
    if since.is_some_and(|s| s > last) && send(&mut socket, json!({ "type": "reset", "seq": last })).await.is_err() {
        return;
    }
    if let Some(since) = since.filter(|s| *s < last) {
        let first = hub.with_store(|s| s.first_seq()).unwrap_or(0);
        if since > 0 && since + 1 < first || last - since > 2000 {
            if send(&mut socket, json!({ "type": "reset", "seq": last })).await.is_err() {
                return;
            }
        } else {
            let mut from = since;
            loop {
                let Ok(batch) = hub.with_store(|s| s.events_since(from, owner, None, 500)) else { return };
                if batch.is_empty() {
                    break;
                }
                for e in batch {
                    from = e.seq;
                    if send(&mut socket, json!({ "type": "event", "event": e })).await.is_err() {
                        return;
                    }
                }
            }
            last = from.max(last);
        }
    }
    if send(&mut socket, json!({ "type": "ready", "seq": last })).await.is_err() {
        return;
    }
    let mut keepalive = tokio::time::interval(Duration::from_secs(25));
    loop {
        tokio::select! {
            ev = live.recv() => match ev {
                Ok(e) if e.seq <= last => {}
                // Other installs' servers.
                Ok(e) if hub.owner_of(e.server_id) != Some(owner) => {}
                Ok(e) => {
                    last = e.seq;
                    if send(&mut socket, json!({ "type": "event", "event": e })).await.is_err() {
                        return;
                    }
                }
                Err(RecvError::Lagged(_)) => {
                    if send(&mut socket, json!({ "type": "reset", "seq": hub.last_seq() })).await.is_err() {
                        return;
                    }
                }
                Err(RecvError::Closed) => return,
            },
            msg = socket.recv() => match msg {
                Some(Ok(Message::Text(t))) => {
                    if t.contains("\"ping\"") && send(&mut socket, json!({ "type": "pong", "seq": last })).await.is_err() {
                        return;
                    }
                }
                Some(Ok(_)) => {}
                _ => return,
            },
            _ = keepalive.tick() => {
                if socket.send(Message::Ping(Vec::new().into())).await.is_err() {
                    return;
                }
            }
        }
    }
}

async fn send(socket: &mut WebSocket, v: Value) -> Result<(), axum::Error> {
    socket.send(Message::Text(v.to_string().into())).await
}
