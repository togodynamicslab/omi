const COMMANDS: &[&str] = &[
    "list_devices",
    "start_recording",
    "stop_recording",
    "get_capture_state",
    "probe_system_audio",
    "probe_live_capture",
    "request_system_audio_permission",
    "list_local_sessions",
    "get_local_segments",
    "retry_sync_now",
    "retry_all_failed",
    "delete_local_session",
    "delete_all_unsynced",
];

fn main() {
    tauri_plugin::Builder::new(COMMANDS).build();
}
