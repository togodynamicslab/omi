import { invoke } from "@tauri-apps/api/core";
import { tNotif } from "@/i18n/notifications";
import { useRewindStore } from "@/stores/rewindStore";

/** Fires an OS-native notification via the Rust command, which uses the
 *  installed Nooto.app bundle when available and falls back to `osascript`
 *  on macOS. No separate in-app window — see
 *  `src-tauri/src/commands/notifications.rs`. */
async function deliver(title: string, body: string): Promise<void> {
  try {
    await invoke("show_notification_alert", { title, body });
  } catch (err) {
    console.error("[notifications] show_notification_alert failed", err);
  }
}

/**
 * True when no Focus/Rewind notification should be delivered because the user
 * has Rewind turned off. Catches in-flight callbacks that fire after the user
 * toggles off but before listener teardown completes.
 */
function rewindGateClosed(): boolean {
  return !useRewindStore.getState().rewindEnabled;
}

export async function notify(title: string, body: string): Promise<void> {
  await deliver(title, body);
}

export async function sendFocusNotification(title: string, body: string): Promise<void> {
  if (rewindGateClosed()) {
    console.info("[notifications] focus alert suppressed: Rewind is off");
    return;
  }
  await deliver(title, body);
}

export async function sendDistractionAlert(appOrSite: string, message: string): Promise<void> {
  if (rewindGateClosed()) {
    console.info("[notifications] distraction alert suppressed: Rewind is off");
    return;
  }
  await deliver(
    tNotif("focus_title"),
    message || tNotif("distraction_fallback", { app: appOrSite }),
  );
}
