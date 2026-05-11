import { create } from "zustand";
import { invoke } from "@tauri-apps/api/core";

interface AuthState {
  isSignedIn: boolean;
  isLoading: boolean;
  isSigningIn: boolean;
  error: string | null;
  userId: string | null;
  userEmail: string | null;
  idToken: string | null;
  signIn: (provider: "google" | "apple") => Promise<void>;
  signOut: () => Promise<void>;
  restoreSession: () => Promise<void>;
  /** Ask the Rust side to refresh the Firebase ID token and update in-memory state. */
  refreshToken: () => Promise<boolean>;
}

// Firebase ID tokens expire after 1h. Refresh at 50min so the cached token
// stays valid during long sessions — without this, the Rust retry loop in
// `tauri-plugin-audio-capture/src/retry.rs` reads an expired token from the
// auth store and meeting uploads fail with 401 ExpiredSignature for ~30min
// before backoff exhausts. The Rust side also retries once on 401 as a safety
// net, but proactive refresh prevents the user-visible "Sync failed" flicker.
const TOKEN_REFRESH_INTERVAL_MS = 50 * 60 * 1000;
let tokenRefreshTimer: ReturnType<typeof setInterval> | null = null;

function startTokenRefreshTimer(refresh: () => Promise<boolean>): void {
  if (tokenRefreshTimer != null) return;
  tokenRefreshTimer = setInterval(() => {
    void refresh().catch((err) => {
      console.warn("[auth] periodic token refresh failed:", err);
    });
  }, TOKEN_REFRESH_INTERVAL_MS);
}

function stopTokenRefreshTimer(): void {
  if (tokenRefreshTimer != null) {
    clearInterval(tokenRefreshTimer);
    tokenRefreshTimer = null;
  }
}

export const useAuthStore = create<AuthState>((set, get) => ({
  isSignedIn: false,
  isLoading: true,
  isSigningIn: false,
  error: null,
  userId: null,
  userEmail: null,
  idToken: null,

  signIn: async (provider: "google" | "apple") => {
    set({ isSigningIn: true, error: null });
    try {
      const result = await invoke<{
        user_id: string;
        email: string;
        id_token: string;
      }>("sign_in", { provider });

      set({
        isSignedIn: true,
        isSigningIn: false,
        userId: result.user_id,
        userEmail: result.email,
        idToken: result.id_token,
      });
      startTokenRefreshTimer(() => get().refreshToken());
    } catch (error) {
      console.error("Sign in failed:", error);
      set({
        isSigningIn: false,
        error: typeof error === "string" ? error : "Sign in failed",
      });
    }
  },

  signOut: async () => {
    stopTokenRefreshTimer();
    try {
      await invoke("sign_out");
    } catch {
      // best-effort
    }
    set({
      isSignedIn: false,
      userId: null,
      userEmail: null,
      idToken: null,
    });
  },

  restoreSession: async () => {
    try {
      const result = await invoke<{
        user_id: string;
        email: string;
        id_token: string;
      } | null>("restore_session");

      if (result) {
        set({
          isSignedIn: true,
          userId: result.user_id,
          userEmail: result.email,
          idToken: result.id_token,
          isLoading: false,
        });
        startTokenRefreshTimer(() => get().refreshToken());
      } else {
        set({ isLoading: false });
      }
    } catch {
      set({ isLoading: false });
    }
  },

  refreshToken: async () => {
    try {
      const result = await invoke<{
        user_id: string;
        email: string;
        id_token: string;
      } | null>("force_refresh_token");
      if (result) {
        set({
          isSignedIn: true,
          userId: result.user_id,
          userEmail: result.email,
          idToken: result.id_token,
        });
        return true;
      }
      return false;
    } catch (err) {
      console.warn("[auth] force_refresh_token failed:", err);
      return false;
    }
  },
}));
