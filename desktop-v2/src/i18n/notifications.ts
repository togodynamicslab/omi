// Lightweight string-key translator for OS notification titles / bodies.
//
// Source of truth for the active language is the same localStorage key the
// audio dropdown writes — keeps this in sync with the visible "language"
// setting without standing up a full i18n framework. Only covers the
// notification surface; expand if more strings need translating.

const STORAGE_KEY = "nooto.audio.language";

export type NotifLang = "en" | "pt-BR";

function readLang(): NotifLang {
  if (typeof window === "undefined") return "pt-BR";
  try {
    const v = window.localStorage.getItem(STORAGE_KEY);
    if (v === "en" || v === "pt-BR") return v;
  } catch {
    /* localStorage blocked — fall through to default */
  }
  return "pt-BR";
}

type Catalog = Record<string, string>;

const STRINGS: Record<NotifLang, Catalog> = {
  en: {
    focus_title: "Focus",
    focus_back_default: "Great, you're back on track!",
    distraction_default: "Time to refocus!",
    distraction_fallback: "You seem distracted on {app}",
    memory_saved: "Memory saved",
    wisdom_captured: "Wisdom captured",
    rate_limit_title: "Rate limit",
    rate_limit_body: "Too many {key} calls. Try again later.",
  },
  "pt-BR": {
    focus_title: "Foco",
    focus_back_default: "Ótimo, você voltou pro foco!",
    distraction_default: "Hora de focar de novo!",
    distraction_fallback: "Você parece distraído no {app}",
    memory_saved: "Memória salva",
    wisdom_captured: "Sabedoria capturada",
    rate_limit_title: "Limite de uso",
    rate_limit_body: "Muitas chamadas de {key}. Tente novamente mais tarde.",
  },
};

/** Look up a notification string in the user's selected language, falling
 *  back to English if the key is missing. `{name}`-style placeholders in the
 *  template are replaced with values from `params`. */
export function tNotif(key: string, params?: Record<string, string>): string {
  const lang = readLang();
  let out = STRINGS[lang][key] ?? STRINGS.en[key] ?? key;
  if (params) {
    for (const [k, v] of Object.entries(params)) {
      out = out.replace(`{${k}}`, v);
    }
  }
  return out;
}

/** Public so non-notification callers (LLM prompts, transcription configs)
 *  can read the same language preference without duplicating the storage
 *  key. Returns "pt-BR" or "en". */
export function getUserLang(): NotifLang {
  return readLang();
}

/** Drop-in instruction for LLM system prompts that produce user-facing
 *  text. Tells the model to write its human-readable output in the user's
 *  selected language while keeping machine-parsed fields (status,
 *  category, …) in English. Empty string for English so the prompt stays
 *  unchanged. */
export function llmLanguageInstruction(opts?: {
  /** Names of fields the model should localise. Defaults to "message". */
  humanFields?: string[];
}): string {
  const lang = readLang();
  if (lang === "en") return "";
  const fields =
    (opts?.humanFields ?? ["message"])
      .map((f) => `\`${f}\``)
      .join(", ") || "`message`";
  return `\n\nRESPONSE LANGUAGE: Write ${fields} in Brazilian Portuguese (pt-BR), natural and friendly. Keep all other fields in English so the app can parse them.`;
}
