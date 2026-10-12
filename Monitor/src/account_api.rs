//! The NG Account part of the API: making and signing in to accounts,
//! the account's devices, syncing servers and settings, and sound packs.
//!
//! Signing up, signing in and resetting a password need no token, and
//! neither do the sound pack catalog and published sounds. Everything else
//! here needs an NG Account session's token.

use std::net::SocketAddr;

use axum::body::Bytes;
use axum::extract::{ConnectInfo, FromRequestParts, Path, Query, State};
use axum::http::request::Parts;
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::IntoResponse;
use axum::routing::{get, post, put};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::accounts::{Install, Session, SignedIn};
use crate::api::{ApiError, ApiResult, App, client_address};
use crate::packs::PackChange;
use crate::store::Device;
use crate::sync::Change;

pub fn routes() -> Router<App> {
    Router::new()
        .route("/v1/account/signup", post(sign_up))
        .route("/v1/account/verify", post(verify))
        .route("/v1/account/signin", post(sign_in))
        .route("/v1/account/forgot", post(forgot))
        .route("/v1/account/reset", post(reset))
        .route("/v1/account", get(account))
        .route("/v1/account/password", post(change_password))
        .route("/v1/account/signout", post(sign_out))
        .route("/v1/account/delete", post(delete_account))
        .route("/v1/account/sessions", get(sessions))
        .route("/v1/account/sessions/{id}", axum::routing::delete(end_session))
        .route("/v1/account/export", get(export))
        .route("/v1/sync", get(pull).post(push_changes).layer(axum::extract::DefaultBodyLimit::max(8 * 1024 * 1024)))
        .route("/v1/packs", get(my_packs).post(backup_pack))
        .route("/v1/packs/{id}", axum::routing::patch(change_pack).delete(delete_pack))
        .route(
            "/v1/packs/{id}/files/{name}",
            put(upload).delete(remove_file).get(download).layer(axum::extract::DefaultBodyLimit::max(26 * 1024 * 1024)),
        )
        .route("/v1/packs/{id}/pack.zip", get(download_zip))
        .route("/v1/catalog", get(catalog))
        .route("/v1/catalog/{id}/installed", post(installed))
        .route("/v1/catalog/{id}/report", post(report))
}

/// An NG Account session and its account's sign-up.
pub struct Signed(pub Session, pub Device);

fn bearer(parts: &Parts) -> Option<&str> {
    parts
        .headers
        .get("authorization")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .map(str::trim)
        .filter(|t| !t.is_empty())
}

impl FromRequestParts<App> for Signed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &App) -> Result<Self, Self::Rejection> {
        let token = bearer(parts).ok_or_else(|| ApiError(StatusCode::UNAUTHORIZED, "Sign in to your NG Account".into()))?;
        app.accounts
            .authenticate(token)
            .map(|(s, d)| Signed(s, d))
            .ok_or_else(|| ApiError(StatusCode::UNAUTHORIZED, "You're signed out of your NG Account. Sign in again.".into()))
    }
}

/// A session if there is one; nobody otherwise.
pub struct MaybeSigned(pub Option<Session>);

impl FromRequestParts<App> for MaybeSigned {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, app: &App) -> Result<Self, Self::Rejection> {
        Ok(MaybeSigned(bearer(parts).and_then(|t| app.accounts.authenticate(t)).map(|(s, _)| s)))
    }
}

#[derive(Deserialize)]
struct InstallFields {
    #[serde(default)]
    install_id: String,
    #[serde(default)]
    device_name: String,
    /// The sign-up this install used before NG Account.
    #[serde(default)]
    claim_token: Option<String>,
}

impl InstallFields {
    fn install(&self) -> Install {
        let clean = |v: &str, n: usize| -> String { v.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').take(n).collect() };
        let name: String = self.device_name.trim().chars().take(100).collect();
        Install {
            install_id: if self.install_id.is_empty() { "unknown".into() } else { clean(&self.install_id, 64) },
            name: if name.is_empty() { "iPhone".into() } else { name },
            claim_token: self.claim_token.clone(),
        }
    }
}

fn signed_in(r: SignedIn) -> Json<Value> {
    Json(json!({
        "token": r.token,
        "session_id": r.session_id,
        "account": r.account,
        "device_id": r.device_id,
        "push_key": r.push_key,
    }))
}

#[derive(Deserialize)]
struct SignUp {
    email: String,
    password: String,
}

async fn sign_up(State(app): State<App>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Json(r): Json<SignUp>) -> ApiResult<StatusCode> {
    app.accounts.sign_up(&r.email, &r.password, &client_address(peer, &headers)).await?;
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize)]
struct Verify {
    email: String,
    code: String,
    #[serde(flatten)]
    install: InstallFields,
}

async fn verify(State(app): State<App>, Json(r): Json<Verify>) -> ApiResult<Json<Value>> {
    Ok(signed_in(app.accounts.verify_sign_up(&r.email, &r.code, &r.install.install()).await?))
}

#[derive(Deserialize)]
struct SignIn {
    email: String,
    password: String,
    #[serde(flatten)]
    install: InstallFields,
}

async fn sign_in(State(app): State<App>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Json(r): Json<SignIn>) -> ApiResult<Json<Value>> {
    Ok(signed_in(app.accounts.sign_in(&r.email, &r.password, &r.install.install(), &client_address(peer, &headers)).await?))
}

#[derive(Deserialize)]
struct Forgot {
    email: String,
}

async fn forgot(State(app): State<App>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Json(r): Json<Forgot>) -> ApiResult<StatusCode> {
    app.accounts.forgot_password(&r.email, &client_address(peer, &headers)).await?;
    Ok(StatusCode::ACCEPTED)
}

#[derive(Deserialize)]
struct Reset {
    email: String,
    code: String,
    password: String,
    #[serde(flatten)]
    install: InstallFields,
}

async fn reset(State(app): State<App>, Json(r): Json<Reset>) -> ApiResult<Json<Value>> {
    Ok(signed_in(app.accounts.reset_password(&r.email, &r.code, &r.password, &r.install.install()).await?))
}

async fn account(State(app): State<App>, Signed(s, d): Signed) -> ApiResult<Json<Value>> {
    let account = app.accounts.account(s.account)?;
    let ((used, limit), rev) = app.hub.with_store(|st| Ok((st.pack_usage(s.account)?, st.sync_rev(s.account)?)))?;
    Ok(Json(json!({
        "account": account,
        "session_id": s.id,
        "device_id": d.id,
        "sync_rev": rev,
        "packs": { "used_bytes": used, "limit_bytes": limit },
    })))
}

#[derive(Deserialize)]
struct ChangePassword {
    current: String,
    new: String,
}

async fn change_password(State(app): State<App>, Signed(s, _): Signed, Json(r): Json<ChangePassword>) -> ApiResult<StatusCode> {
    app.accounts.change_password(&s, &r.current, &r.new).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn sign_out(State(app): State<App>, Signed(s, _): Signed) -> ApiResult<StatusCode> {
    app.accounts.end_session(s.account, s.id)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct DeleteAccount {
    password: String,
}

async fn delete_account(State(app): State<App>, Signed(s, _): Signed, Json(r): Json<DeleteAccount>) -> ApiResult<StatusCode> {
    app.accounts.delete(&s, &r.password).await?;
    if let Err(e) = app.packs.collect_garbage() {
        tracing::warn!("could not clear unused sound files: {e:#}");
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn sessions(State(app): State<App>, Signed(s, _): Signed) -> ApiResult<Json<Value>> {
    let list: Vec<Value> = app
        .accounts
        .sessions(s.account)?
        .into_iter()
        .map(|x| {
            let current = x.id == s.id;
            let mut v = json!(x);
            v["current"] = json!(current);
            v
        })
        .collect();
    Ok(Json(json!({ "sessions": list })))
}

async fn end_session(State(app): State<App>, Signed(s, _): Signed, Path(id): Path<i64>) -> ApiResult<StatusCode> {
    app.accounts.end_session(s.account, id)?;
    Ok(StatusCode::NO_CONTENT)
}

/// Everything the account holds, as one JSON file (passwords left out).
async fn export(State(app): State<App>, Signed(s, d): Signed) -> ApiResult<impl IntoResponse> {
    let account = app.accounts.account(s.account)?;
    let (monitors, mut synced, packs, sessions) = app.hub.with_store(|st| {
        Ok((st.servers_of(d.id)?, st.sync_changes(s.account, 0)?, st.packs_of(s.account)?, st.sessions(s.account)?))
    })?;
    for r in &mut synced {
        if let Some(obj) = r.data.as_mut().and_then(Value::as_object_mut) {
            for f in ["password", "chanpasswd", "certprivkeydata"] {
                obj.remove(f);
            }
        }
    }
    let body = json!({
        "exported": crate::store::now_ms(),
        "account": account,
        "devices": sessions,
        "monitored_servers": monitors,
        "synced": synced,
        "sound_packs": packs,
        "note": "Passwords are left out of this file.",
    });
    Ok((
        [(header::CONTENT_DISPOSITION, "attachment; filename=\"NG Account.json\"")],
        Json(body),
    ))
}

#[derive(Deserialize)]
struct PullQuery {
    #[serde(default)]
    since: i64,
}

async fn pull(State(app): State<App>, Signed(s, _): Signed, Query(q): Query<PullQuery>) -> ApiResult<Json<Value>> {
    let (rev, records) = app.hub.with_store(|st| Ok((st.sync_rev(s.account)?, st.sync_changes(s.account, q.since.max(0))?)))?;
    // A revision past the account's: its data was started over.
    let reset = q.since > rev;
    let records = if reset { app.hub.with_store(|st| st.sync_changes(s.account, 0))? } else { records };
    Ok(Json(json!({ "rev": rev, "reset": reset, "records": records })))
}

#[derive(Deserialize)]
struct Push {
    changes: Vec<Change>,
}

async fn push_changes(State(app): State<App>, Signed(s, d): Signed, Json(p): Json<Push>) -> ApiResult<Json<Value>> {
    if p.changes.len() > 500 {
        return Err(ApiError(StatusCode::BAD_REQUEST, "Send at most 500 changes at a time".into()));
    }
    let applied = app.hub.with_store(|st| Ok(st.apply_sync(s.account, &p.changes)))??;
    if !applied.applied.is_empty() {
        app.hub.sync_changed(d.id, applied.rev, &s.install_id);
    }
    Ok(Json(json!(applied)))
}

async fn my_packs(State(app): State<App>, Signed(s, _): Signed) -> ApiResult<Json<Value>> {
    let (packs, (used, limit)) = app.hub.with_store(|st| Ok((st.packs_of(s.account)?, st.pack_usage(s.account)?)))?;
    Ok(Json(json!({ "packs": packs, "used_bytes": used, "limit_bytes": limit })))
}

#[derive(Deserialize)]
struct Backup {
    local_id: String,
    name: String,
}

async fn backup_pack(State(app): State<App>, Signed(s, _): Signed, Json(b): Json<Backup>) -> ApiResult<Json<Value>> {
    let local_id: String = b.local_id.trim().chars().take(100).collect();
    if local_id.is_empty() {
        return Err(ApiError(StatusCode::BAD_REQUEST, "Say which of your packs this is".into()));
    }
    let pack = app.hub.with_store(|st| Ok(st.backup_pack(s.account, &local_id, &b.name)))??;
    Ok(Json(json!(pack)))
}

async fn change_pack(State(app): State<App>, Signed(s, d): Signed, Path(id): Path<String>, Json(c): Json<PackChange>) -> ApiResult<Json<Value>> {
    let pack = app.hub.with_store(|st| Ok(st.change_pack(s.account, &id, &c)))??;
    app.hub.sync_changed(d.id, 0, &s.install_id);
    Ok(Json(json!(pack)))
}

async fn delete_pack(State(app): State<App>, Signed(s, d): Signed, Path(id): Path<String>) -> ApiResult<StatusCode> {
    app.hub.with_store(|st| Ok(st.delete_pack(s.account, &id)))??;
    let _ = app.packs.collect_garbage();
    app.hub.sync_changed(d.id, 0, &s.install_id);
    Ok(StatusCode::NO_CONTENT)
}

async fn upload(State(app): State<App>, Signed(s, d): Signed, Path((id, name)): Path<(String, String)>, body: Bytes) -> ApiResult<Json<Value>> {
    let pack = app.packs.upload(s.account, &id, &name, &body)?;
    app.hub.sync_changed(d.id, 0, &s.install_id);
    Ok(Json(json!(pack)))
}

async fn remove_file(State(app): State<App>, Signed(s, d): Signed, Path((id, name)): Path<(String, String)>) -> ApiResult<Json<Value>> {
    let pack = app.hub.with_store(|st| Ok(st.remove_pack_file(s.account, &id, &name)))??;
    let _ = app.packs.collect_garbage();
    app.hub.sync_changed(d.id, 0, &s.install_id);
    Ok(Json(json!(pack)))
}

async fn download(State(app): State<App>, MaybeSigned(s): MaybeSigned, Path((id, name)): Path<(String, String)>) -> ApiResult<impl IntoResponse> {
    let (name, data) = app.packs.file(s.map(|s| s.account), &id, &name)?;
    let kind = match name.rsplit_once('.').map(|(_, e)| e) {
        Some("wav") => "audio/wav",
        Some("mp3") => "audio/mpeg",
        Some("caf") => "audio/x-caf",
        Some("aiff" | "aif") => "audio/aiff",
        Some("m4a") => "audio/mp4",
        Some("aac") => "audio/aac",
        _ => "application/octet-stream",
    };
    Ok(([(header::CONTENT_TYPE, kind), (header::CACHE_CONTROL, "private, max-age=3600")], data))
}

async fn download_zip(State(app): State<App>, MaybeSigned(s): MaybeSigned, Path(id): Path<String>) -> ApiResult<impl IntoResponse> {
    let (name, zip) = app.packs.zip(s.map(|s| s.account), &id)?;
    let file: String = name.chars().filter(|c| c.is_alphanumeric() || " -_".contains(*c)).collect();
    let file = if file.trim().is_empty() { "Sound Pack".to_owned() } else { file };
    Ok((
        [
            (header::CONTENT_TYPE, "application/zip".to_owned()),
            (header::CONTENT_DISPOSITION, format!("attachment; filename=\"{file}.zip\"")),
        ],
        zip,
    ))
}

#[derive(Deserialize)]
struct CatalogQuery {
    #[serde(default)]
    q: String,
    /// `new` (the default) or `popular`.
    #[serde(default)]
    sort: String,
}

async fn catalog(State(app): State<App>, Query(q): Query<CatalogQuery>) -> ApiResult<Json<Value>> {
    let packs = app.hub.with_store(|st| st.catalog(&q.q, q.sort == "popular"))?;
    let packs: Vec<Value> = packs
        .into_iter()
        .map(|p| {
            json!({
                "id": p.id, "name": p.name, "author": p.author, "description": p.description,
                "version": p.version, "official": p.official, "installs": p.installs,
                "updated": p.updated, "size": p.size, "files": p.files,
                "download_path": format!("/v1/packs/{}/pack.zip", p.id),
            })
        })
        .collect();
    Ok(Json(json!({ "packs": packs })))
}

async fn installed(State(app): State<App>, ConnectInfo(peer): ConnectInfo<SocketAddr>, headers: HeaderMap, Path(id): Path<String>) -> ApiResult<StatusCode> {
    app.packs.count_install(&id, &client_address(peer, &headers))?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct Report {
    reason: String,
}

async fn report(State(app): State<App>, Signed(s, _): Signed, Path(id): Path<String>, Json(r): Json<Report>) -> ApiResult<StatusCode> {
    app.hub.with_store(|st| Ok(st.report_pack(s.account, &id, &r.reason)))??;
    Ok(StatusCode::NO_CONTENT)
}
