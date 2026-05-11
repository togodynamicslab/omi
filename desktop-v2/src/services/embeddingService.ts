/**
 * Gemini embedding service — TypeScript port of
 * `desktop/Desktop/Sources/ProactiveAssistants/Services/EmbeddingService.swift`.
 *
 * Calls `gemini-embedding-001` (3072-dim) directly against
 * `generativelanguage.googleapis.com` using the locally-stored Gemini API
 * key — same path `sendChatViaGemini` and `companionAssistant` already use.
 * The previous backend proxy (`/v1/proxy/gemini/...`) returned 404 on
 * Coolify; it was a leftover from the GCP backend that never ported.
 *
 * Vectors are L2-normalized on the way out so cosine similarity reduces to
 * a dot product downstream.
 *
 * Persistence lives in Rust (see `staged_tasks_db.rs::save_staged_task_embedding`)
 * — this file is pure transport + a tiny in-memory cache for query embeddings.
 */

import { invoke } from "@tauri-apps/api/core";
import { getGeminiApiKey } from "@/services/api";

export const EMBEDDING_DIMENSION = 3072;
const MODEL = "gemini-embedding-001";
const GEMINI_EMBED_URL = `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:embedContent`;

/** Cache the last few query embeddings so the tool-loop doesn't pay for the
 *  same text twice in one TaskAssistant run. */
const queryCache = new Map<string, Float32Array>();
const QUERY_CACHE_MAX = 32;

/**
 * Circuit breaker: when the embedding endpoint fails repeatedly (network
 * down, API key missing/invalid, Gemini outage), stop issuing calls so we
 * don't spam the console and burn CPU. Trips after 3 consecutive failures
 * and auto-resets after a cooldown so the app self-heals when the endpoint
 * comes back.
 */
const CIRCUIT_FAIL_THRESHOLD = 3;
const CIRCUIT_COOLDOWN_MS = 5 * 60 * 1000; // 5 min
let consecutiveFails = 0;
let circuitOpenedAt: number | null = null;

function circuitIsOpen(): boolean {
  if (circuitOpenedAt == null) return false;
  if (Date.now() - circuitOpenedAt >= CIRCUIT_COOLDOWN_MS) {
    // Cooldown elapsed — reset and retry once.
    circuitOpenedAt = null;
    consecutiveFails = 0;
    console.info("[embedding] circuit-breaker cooldown elapsed, retrying");
    return false;
  }
  return true;
}

class EmbeddingUnavailableError extends Error {
  constructor() {
    super("embedding endpoint unavailable (circuit breaker open)");
    this.name = "EmbeddingUnavailableError";
  }
}

export function isEmbeddingUnavailable(err: unknown): boolean {
  return err instanceof EmbeddingUnavailableError;
}

interface EmbedResponse {
  embedding?: { values?: number[] };
}

function normalize(values: number[]): Float32Array {
  let norm = 0;
  for (const v of values) norm += v * v;
  norm = Math.sqrt(norm);
  const out = new Float32Array(values.length);
  if (norm === 0) return out;
  for (let i = 0; i < values.length; i++) out[i] = values[i] / norm;
  return out;
}

/**
 * Embed a single text. `taskType` should be `RETRIEVAL_DOCUMENT` for items
 * stored in the index and `RETRIEVAL_QUERY` for search queries (matches
 * Gemini's recommendation for asymmetric retrieval).
 */
export async function embedText(
  text: string,
  taskType: "RETRIEVAL_DOCUMENT" | "RETRIEVAL_QUERY" = "RETRIEVAL_DOCUMENT",
): Promise<Float32Array> {
  const trimmed = text.trim();
  if (!trimmed) return new Float32Array(EMBEDDING_DIMENSION);

  if (taskType === "RETRIEVAL_QUERY") {
    const cached = queryCache.get(trimmed);
    if (cached) return cached;
  }

  if (circuitIsOpen()) {
    throw new EmbeddingUnavailableError();
  }

  const apiKey = await getGeminiApiKey();

  const body = {
    model: `models/${MODEL}`,
    content: { parts: [{ text: trimmed }] },
    taskType,
  };

  let resp: EmbedResponse;
  try {
    const httpResp = await fetch(`${GEMINI_EMBED_URL}?key=${encodeURIComponent(apiKey)}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!httpResp.ok) {
      const text = await httpResp.text().catch(() => "");
      throw new Error(`Gemini embed HTTP ${httpResp.status}: ${text.slice(0, 200)}`);
    }
    resp = (await httpResp.json()) as EmbedResponse;
  } catch (err) {
    consecutiveFails++;
    if (consecutiveFails >= CIRCUIT_FAIL_THRESHOLD && circuitOpenedAt == null) {
      circuitOpenedAt = Date.now();
      console.warn(
        `[embedding] circuit-breaker opened after ${consecutiveFails} consecutive failures — ` +
          `suppressing further calls for ${CIRCUIT_COOLDOWN_MS / 60000} min`,
      );
    }
    throw err;
  }
  // Success — reset the failure counter.
  consecutiveFails = 0;

  const values = resp?.embedding?.values;
  if (!values || !Array.isArray(values)) {
    throw new Error("[embedding] response missing embedding values");
  }
  const normalized = normalize(values);

  if (taskType === "RETRIEVAL_QUERY") {
    if (queryCache.size >= QUERY_CACHE_MAX) {
      const firstKey = queryCache.keys().next().value;
      if (firstKey !== undefined) queryCache.delete(firstKey);
    }
    queryCache.set(trimmed, normalized);
  }
  return normalized;
}

/**
 * Backfill embeddings for any staged task missing one. Runs in batches of
 * ~25 to keep within sane proxy rate limits (Swift uses 100 with a 200ms
 * delay between calls; we're more conservative because this runs from the
 * renderer process).
 */
export async function backfillMissingEmbeddings(maxItems = 100): Promise<number> {
  interface BacklogItem {
    kind: string;
    id: string;
    text: string;
  }
  const items = await invoke<BacklogItem[]>("items_missing_embeddings", {
    limit: maxItems,
  });
  if (items.length === 0) return 0;

  let done = 0;
  for (const item of items) {
    try {
      const vec = await embedText(item.text, "RETRIEVAL_DOCUMENT");
      await invoke("save_staged_task_embedding", {
        id: item.id,
        embedding: Array.from(vec),
      });
      done++;
      // Tiny delay so we don't hammer the proxy.
      await new Promise((r) => setTimeout(r, 80));
    } catch (err) {
      if (isEmbeddingUnavailable(err)) {
        // Circuit opened; stop trying the rest of the batch.
        break;
      }
      console.warn("[embedding] backfill failed for", item.id, err);
    }
  }
  if (done > 0) console.info(`[embedding] backfilled ${done} item(s)`);
  return done;
}
