//! Firebase ID token refresh for the retry service.
//!
//! Mirrors the logic in the main app crate's `commands/auth.rs`. Duplicated
//! here so the retry loop (which runs entirely inside this plugin) can recover
//! from 401s without invoking a Tauri command. Both modules read/write the
//! same `auth.json` store, so a refresh from either side is visible to the
//! other on the next read.

use serde::Deserialize;
use tauri::{AppHandle, Runtime};
use tauri_plugin_store::StoreExt;

use crate::AUTH_STORE_PATH;

const FIREBASE_API_KEY: &str = "AIzaSyAPDdy9ZUCMQOPvcbjkB-dQn6WPcPY5nng";

#[derive(Debug, Deserialize)]
struct RefreshTokenResponse {
    id_token: String,
    refresh_token: String,
}

/// Force-refresh the Firebase ID token using the stored refresh token and
/// persist the new pair back to `auth.json`. Returns the fresh id_token.
///
/// Returns `Err` if the store has no refresh_token or the Firebase call fails.
pub async fn force_refresh_id_token<R: Runtime>(app: &AppHandle<R>) -> Result<String, String> {
    let store = app
        .get_store(AUTH_STORE_PATH)
        .or_else(|| app.store(AUTH_STORE_PATH).ok())
        .ok_or_else(|| "auth store unavailable".to_string())?;

    let refresh_token = store
        .get("refresh_token")
        .and_then(|v| v.as_str().map(|s| s.to_string()))
        .unwrap_or_default();

    if refresh_token.is_empty() {
        return Err("no refresh_token in store".into());
    }

    let url = format!(
        "https://securetoken.googleapis.com/v1/token?key={}",
        FIREBASE_API_KEY,
    );

    let client = reqwest::Client::new();
    let resp = client
        .post(&url)
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.as_str()),
        ])
        .send()
        .await
        .map_err(|e| format!("token refresh request failed: {}", e))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(format!("token refresh {}: {}", status, body));
    }

    let parsed: RefreshTokenResponse = resp
        .json()
        .await
        .map_err(|e| format!("parse refresh response: {}", e))?;

    store.set("id_token", serde_json::json!(&parsed.id_token));
    store.set("refresh_token", serde_json::json!(&parsed.refresh_token));
    store
        .save()
        .map_err(|e| format!("save refreshed tokens: {}", e))?;

    tracing::info!("[auth] Firebase ID token refreshed (audio-capture plugin)");
    Ok(parsed.id_token)
}

/// True if the error string emitted by `post_conversation` indicates an
/// expired/invalid Firebase token. We match on the prefix produced by
/// `format!("conversation create {}: ...", status)` — `status` is a
/// `reqwest::StatusCode` which renders 401 as "401 Unauthorized".
pub fn is_auth_error(err: &str) -> bool {
    err.contains("conversation create 401")
}
