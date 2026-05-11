import { useEffect, useRef } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { useAudioStore } from "@/stores/audioStore";
import { useWhisprStore } from "@/stores/whisprStore";

/**
 * Generation counter shared across every mount of the PTT hook. Each
 * useEffect run bumps it and snapshots the new value as `myToken`. Inside
 * every listener body we early-return when `myToken !== activeToken` —
 * leftover handlers from a previous mount (StrictMode double-render or
 * HMR replacing the module before the async cleanup finishes) become
 * no-ops automatically, so partials never get processed twice and the
 * transcript stops duplicating ("Adiciona 1 na Adiciona 1 na").
 */
let activeToken = 0;

interface TranscriptPartial {
  text: string;
  is_final: boolean;
}

/**
 * Global PTT orchestration. Runs in the main window so it still works
 * even if the floating bar window hasn't been shown yet (its webview
 * doesn't mount until first reveal on some platforms).
 *
 * On ptt:start — start audio capture.
 * On transcript:partial — accumulate.
 * On ptt:stop — stop capture, assemble final text, write to clipboard,
 *   attempt auto-paste, push to Whispr history.
 */
export function usePttSession(): void {
  const finalSegmentsRef = useRef<string[]>([]);
  const interimRef = useRef<string>("");
  const startedAtRef = useRef<number | null>(null);
  const activeRef = useRef(false);
  const partialCountRef = useRef(0);

  useEffect(() => {
    // Capture listen() promises synchronously. The previous version pushed
    // unlisteners via `.then(...)`, which leaked listeners under React
    // StrictMode + Vite HMR: if the effect's cleanup ran before the listen
    // promise resolved, the unlistener never made it into the array, the OLD
    // listener stayed alive, and the next mount registered another. After N
    // HMR cycles, every ptt:start fired N times — start_recording / Whispr
    // ran in parallel pipelines and the first one terminated empty (44-byte
    // WAV → 422 from /v1/conversations/from-audio). Same fix as the
    // companion + TTS leaks: store the promises and await them in cleanup.
    const myToken = ++activeToken;
    const listenPromises: Array<Promise<UnlistenFn>> = [];

    listenPromises.push(listen("ptt:start", () => {
      if (myToken !== activeToken) return;
      console.info("[PTT] ptt:start received");
      finalSegmentsRef.current = [];
      interimRef.current = "";
      startedAtRef.current = Date.now();
      activeRef.current = true;
      partialCountRef.current = 0;
      // Show the dedicated Whispr HUD (its own window, bottom-center).
      // We don't reuse the chat floating bar — separate surface, separate
      // concerns.
      invoke("show_whispr_hud").catch((err) => {
        console.warn("[PTT] show_whispr_hud failed:", err);
      });
      // Build the config from the audio store so the recording inherits the
      // user's language / VAD / device choices. Without this, `start_recording`
      // gets no config and the Rust side falls back to `language="en"`,
      // making Deepgram transcribe Portuguese speech as garbled English ("oi"
      // becomes silence or random tokens).
      const audio = useAudioStore.getState();
      const pttConfig = {
        sample_rate: 16000,
        channels: 1,
        device_id: audio.selectedInputId,
        language: audio.language || "pt-BR",
        mode: "ptt" as const,
        capture_system_audio: false,
        vad_mode: audio.vadMode,
        // PTT is short-form, the live WS is what feeds the HUD partials —
        // keep it on. (skip_live_transcription would defeat the purpose.)
        skip_live_transcription: false,
      };
      invoke("plugin:audio-capture|start_recording", { config: pttConfig }).catch(
        (err) => {
          console.warn("[PTT] start_recording failed:", err);
        },
      );
    }));

    listenPromises.push(listen<TranscriptPartial>("transcript:partial", (e) => {
      if (myToken !== activeToken) return;
      if (!activeRef.current) return;
      const p = e.payload;
      partialCountRef.current += 1;
      if (p.is_final) {
        if (p.text.trim()) finalSegmentsRef.current.push(p.text.trim());
        interimRef.current = "";
      } else {
        interimRef.current = p.text;
      }
      // Push the rolling transcript through Rust so `app.emit` broadcasts
      // it to every window, including the Whispr HUD. `emitTo` from JS
      // didn't reliably deliver to the freshly-shown HUD.
      const combined = [
        ...finalSegmentsRef.current,
        interimRef.current,
      ]
        .filter((s) => s && s.trim().length > 0)
        .join(" ");
      void invoke("whispr_push_live", {
        text: combined,
        isFinal: p.is_final,
      });
    }));

    listenPromises.push(listen("ptt:stop", () => {
      if (myToken !== activeToken) return;
      console.info("[PTT] ptt:stop received");
      const startedAt = startedAtRef.current;
      startedAtRef.current = null;

      (async () => {
        // Phase 1: keep capturing AFTER the user releases the key. People
        // naturally finish the last syllable a beat after lifting the key
        // — without this, the tail of the sentence ("...no final") gets
        // chopped, sometimes leaving just a single character. We stay
        // `active` so transcript:partial events for that tail audio still
        // update finalSegments/interim.
        const TAIL_CAPTURE_MS = 300;
        await new Promise((resolve) => setTimeout(resolve, TAIL_CAPTURE_MS));

        activeRef.current = false;

        // Now stop the recording. Fire-and-forget: the consumer task closes
        // the Deepgram WS and POSTs the conversation to the backend before
        // returning — multi-second round-trip we do NOT need to block on.
        // The state mutations (handle=None, cancel, take consumer) happen
        // synchronously inside the command's lock, so the next
        // start_recording is unblocked immediately.
        invoke("plugin:audio-capture|stop_recording").catch((err) => {
          console.warn("[PTT] stop_recording failed:", err);
        });
        // Phase 2: wait for Deepgram's closing partials. The WS sees the
        // finish frame from the background task above and emits its tail
        // is_final segments. 400ms covers the round-trip on real-world
        // connections without the user feeling stuck.
        await new Promise((resolve) => setTimeout(resolve, 400));

        const finalSegments = finalSegmentsRef.current;
        const interim = interimRef.current;
        const finals = [...finalSegments, interim]
          .filter((s) => s && s.trim().length > 0)
          .join(" ")
          .trim();

        console.info(
          `[PTT] ptt:stop transcript: ${partialCountRef.current} partial events` +
            ` → ${finalSegments.length} final segments + interim ${interim.length} chars` +
            ` → "${finals.slice(0, 80)}${finals.length > 80 ? "…" : ""}"`,
        );

        finalSegmentsRef.current = [];
        interimRef.current = "";

        // Hide the Whispr HUD before attempting keystroke injection so
        // the simulated Ctrl+V goes to the previously focused app, not
        // the HUD window.
        invoke("hide_whispr_hud").catch(() => {});

        if (!finals) {
          console.info("[PTT] no transcript text — nothing to paste");
          return;
        }

        const durationMs = startedAt ? Date.now() - startedAt : undefined;

        // `paste_transcript` snapshots the current clipboard, writes the
        // transcript, simulates Ctrl+V, then restores the original
        // clipboard. The user's previous clipboard survives.
        let autoPasted = false;
        try {
          await invoke("paste_transcript", { text: finals });
          autoPasted = true;
          console.info("[PTT] pasted + clipboard restored");
        } catch (err) {
          console.warn("[PTT] paste_transcript failed:", err);
          // Fallback: if simulated paste errored, leave the transcript on
          // the clipboard so the user can at least Ctrl+V manually. They
          // lose their previous clipboard in this branch, but that's the
          // same behaviour as before.
          try {
            await invoke("copy_to_clipboard", { text: finals });
          } catch (err2) {
            console.warn("[PTT] copy_to_clipboard fallback failed:", err2);
          }
        }

        // Whispr history always captures the transcript so the user can
        // recopy it later even though the clipboard has been restored.
        useWhisprStore.getState().record({
          text: finals,
          durationMs,
          autoPasted,
        });
      })();
    }));

    return () => {
      // Async cleanup: await every listen() promise, then call its
      // unlistener. Has to be fire-and-forget because React's useEffect
      // cleanup is synchronous, but allSettled below means we never miss
      // a slow promise — even if HMR replaces this module before resolution.
      void (async () => {
        const results = await Promise.allSettled(listenPromises);
        for (const r of results) {
          if (r.status === "fulfilled") {
            try {
              r.value();
            } catch {
              /* already unsubscribed */
            }
          }
        }
      })();
    };
  }, []);
}
