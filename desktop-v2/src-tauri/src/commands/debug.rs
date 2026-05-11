use serde::{Deserialize, Serialize};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use tauri::{command, AppHandle, Emitter, Runtime};

fn http_client() -> &'static reqwest::Client {
    static CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .expect("failed to build reqwest client")
    })
}

#[derive(Serialize)]
pub struct BackendPingResult {
    pub status: Option<u16>,
    pub body_preview: String,
    pub elapsed_ms: u128,
    pub error: Option<String>,
}

#[command]
pub async fn debug_backend_ping(url: String, token: Option<String>) -> Result<BackendPingResult, String> {
    let start = Instant::now();
    tracing::info!("[debug_backend_ping] GET {}", url);

    let mut req = http_client().get(&url);
    if let Some(t) = token {
        req = req.header("Authorization", format!("Bearer {t}"));
    }

    match req.send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let body = resp.text().await.unwrap_or_default();
            let preview: String = body.chars().take(300).collect();
            tracing::info!("[debug_backend_ping] {} → {} in {}ms", url, status, start.elapsed().as_millis());
            Ok(BackendPingResult {
                status: Some(status),
                body_preview: preview,
                elapsed_ms: start.elapsed().as_millis(),
                error: None,
            })
        }
        Err(e) => {
            tracing::error!("[debug_backend_ping] {} failed: {}", url, e);
            Ok(BackendPingResult {
                status: None,
                body_preview: String::new(),
                elapsed_ms: start.elapsed().as_millis(),
                error: Some(e.to_string()),
            })
        }
    }
}

#[derive(Deserialize)]
pub struct BackendRequestArgs {
    pub method: String,
    pub url: String,
    pub token: Option<String>,
    pub body: Option<String>,
}

#[derive(Serialize)]
pub struct BackendResponse {
    pub status: u16,
    pub body: String,
}

#[command]
pub async fn backend_request(args: BackendRequestArgs) -> Result<BackendResponse, String> {
    let start = Instant::now();
    let method = reqwest::Method::from_bytes(args.method.as_bytes())
        .map_err(|e| format!("invalid method: {e}"))?;

    let mut req = http_client()
        .request(method.clone(), &args.url)
        .header("Content-Type", "application/json");

    if let Some(t) = args.token {
        req = req.header("Authorization", format!("Bearer {t}"));
    }

    if let Some(body) = args.body {
        req = req.body(body);
    }

    let resp = req.send().await.map_err(|e| {
        tracing::error!("[backend_request] {} {} failed: {}", method, args.url, e);
        format!("request failed: {e}")
    })?;

    let status = resp.status().as_u16();
    let body = resp.text().await.unwrap_or_default();
    tracing::info!("[backend_request] {} {} → {} in {}ms", method, args.url, status, start.elapsed().as_millis());

    Ok(BackendResponse { status, body })
}

#[derive(Deserialize)]
pub struct BackendChatStreamArgs {
    pub url: String,
    pub token: Option<String>,
    pub body: String,
    pub request_id: String,
}

#[derive(Serialize)]
pub struct BackendChatStreamResult {
    pub status: u16,
    pub error_body: Option<String>,
}

#[command]
pub async fn backend_chat_stream<R: Runtime>(
    app: AppHandle<R>,
    args: BackendChatStreamArgs,
) -> Result<BackendChatStreamResult, String> {
    let start = Instant::now();
    let mut req = http_client()
        .post(&args.url)
        .header("Content-Type", "application/json");
    if let Some(t) = &args.token {
        req = req.header("Authorization", format!("Bearer {t}"));
    }
    req = req.body(args.body);

    let resp = req.send().await.map_err(|e| {
        tracing::error!("[backend_chat_stream] {} failed: {}", args.url, e);
        format!("request failed: {e}")
    })?;

    let status = resp.status().as_u16();

    if !resp.status().is_success() {
        let body = resp.text().await.unwrap_or_default();
        tracing::warn!("[backend_chat_stream] {} → {} in {}ms (error body len={})", args.url, status, start.elapsed().as_millis(), body.len());
        let _ = app.emit("chat:stream:done", serde_json::json!({ "request_id": args.request_id }));
        return Ok(BackendChatStreamResult { status, error_body: Some(body) });
    }

    let body = resp.text().await.map_err(|e| format!("read body failed: {e}"))?;
    for line in body.split('\n') {
        let trimmed = line.trim_end_matches('\r');
        if trimmed.is_empty() {
            continue;
        }
        let _ = app.emit(
            "chat:stream",
            serde_json::json!({ "request_id": args.request_id, "line": trimmed }),
        );
    }
    let _ = app.emit("chat:stream:done", serde_json::json!({ "request_id": args.request_id }));

    tracing::info!("[backend_chat_stream] {} → {} in {}ms (body len={})", args.url, status, start.elapsed().as_millis(), body.len());
    Ok(BackendChatStreamResult { status, error_body: None })
}
