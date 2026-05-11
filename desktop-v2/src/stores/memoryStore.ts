import { create } from "zustand";
import { listen } from "@tauri-apps/api/event";
import { useAuthStore } from "./authStore";
import { api } from "../services/api";

export interface Memory {
  id: string;
  content: string;
  category?: string;
  created_at: string;
  updated_at?: string;
  structured?: {
    title?: string;
    emoji?: string;
    category?: string;
  };
}

interface MemoryState {
  memories: Memory[];
  isLoading: boolean;
  query: string;
  categoryFilter: string | null;
  loadMemories: () => Promise<void>;
  deleteMemory: (id: string) => Promise<void>;
  setQuery: (q: string) => void;
  setCategoryFilter: (c: string | null) => void;
  filteredMemories: () => Memory[];
}

export const useMemoryStore = create<MemoryState>((set, get) => ({
  memories: [],
  isLoading: false,
  query: "",
  categoryFilter: null,

  setQuery: (q: string) => set({ query: q }),

  setCategoryFilter: (c: string | null) => set({ categoryFilter: c }),

  filteredMemories: () => {
    const { memories, query, categoryFilter } = get();
    const normalizedQuery = query.trim().toLowerCase();
    return memories.filter((memory) => {
      if (normalizedQuery.length > 0) {
        const content = memory.content?.toLowerCase() ?? "";
        const title = memory.structured?.title?.toLowerCase() ?? "";
        if (
          !content.includes(normalizedQuery) &&
          !title.includes(normalizedQuery)
        ) {
          return false;
        }
      }
      if (categoryFilter !== null) {
        const category = memory.structured?.category ?? memory.category;
        if (category !== categoryFilter) {
          return false;
        }
      }
      return true;
    });
  },

  loadMemories: async () => {
    const token = useAuthStore.getState().idToken;
    if (!token) return;

    set({ isLoading: true });

    try {
      const data = await api.get<Memory[]>(
        "/v3/memories?limit=50&offset=0",
      );
      const memories = Array.isArray(data) ? data : [];
      console.info(
        `[Memories] loaded ${memories.length} memories${
          memories.length > 0
            ? ` (sample: "${memories[0].content?.slice(0, 60) ?? ""}…")`
            : ""
        }`,
      );
      set({
        memories,
        isLoading: false,
      });
    } catch (error) {
      console.error("[Memories] failed to load:", error);
      set({ isLoading: false });
    }
  },

  deleteMemory: async (id: string) => {
    const token = useAuthStore.getState().idToken;
    if (!token) return;

    // Optimistic removal
    const prev = get().memories;
    set({ memories: prev.filter((m) => m.id !== id) });

    try {
      await api.delete(`/v3/memories/${id}`);
    } catch (error) {
      console.error("Failed to delete memory:", error);
      set({ memories: prev });
    }
  },
}));

// Auto-reload memories whenever a meeting finishes syncing or the backend
// finishes async post-processing on a conversation. Backend memory extraction
// runs server-side during `/from-segments` (and the integration trigger task
// after), so memories appear after these events fire — without this, the user
// has to navigate away and back to see new ones. The 1.5s delay gives Firestore
// a moment to commit before we re-query.
listen("meeting:synced", () => {
  setTimeout(() => {
    void useMemoryStore.getState().loadMemories();
  }, 1500);
})
  .then(() => console.log("[Memories] subscribed to meeting:synced"))
  .catch((err) =>
    console.error("[Memories] failed to subscribe to meeting:synced:", err),
  );

listen("conversation:updated", () => {
  setTimeout(() => {
    void useMemoryStore.getState().loadMemories();
  }, 1500);
})
  .then(() => console.log("[Memories] subscribed to conversation:updated"))
  .catch((err) =>
    console.error(
      "[Memories] failed to subscribe to conversation:updated:",
      err,
    ),
  );
