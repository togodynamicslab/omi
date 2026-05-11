import { useEffect, useRef, useState } from "react";
import { Check, Loader2, Monitor } from "lucide-react";
import { takeScreenshot, type MonitorInfo } from "@/services/rewind";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * Discord/OBS-style picker: a thumbnail-per-monitor grid plus an "Auto" card
 * that defers to the primary display. Thumbnails are captured once on mount
 * via `take_screenshot` (no DB persistence on that path), and can be refreshed
 * manually so the user sees what's actually on each screen right now.
 *
 * Used in two places:
 * - Settings → Rewind → Display (persistent picker).
 * - The first-time MonitorPickerDialog that opens when the user enables Rewind
 *   on a multi-monitor setup.
 */
export interface MonitorPickerGridProps {
  monitors: MonitorInfo[];
  selectedIndex: number | null;
  onSelect: (index: number | null) => void;
  /** Hide the count + refresh footer (used in modals where the dialog has its own actions). */
  hideFooter?: boolean;
}

export function MonitorPickerGrid({
  monitors,
  selectedIndex,
  onSelect,
  hideFooter = false,
}: MonitorPickerGridProps) {
  const [thumbs, setThumbs] = useState<Map<number, string>>(new Map());
  const [refreshing, setRefreshing] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);
  const [justSaved, setJustSaved] = useState(false);
  const savedTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    return () => {
      if (savedTimeoutRef.current) clearTimeout(savedTimeoutRef.current);
    };
  }, []);

  const onSave = () => {
    // Re-grab thumbnails (so the user sees the live state of each display)
    // and flash "Saved" — the actual persist already happened on card click
    // via updateConfig; this is the explicit "your pick is locked in" beat
    // the user expects.
    setRefreshKey((k) => k + 1);
    if (savedTimeoutRef.current) clearTimeout(savedTimeoutRef.current);
    setJustSaved(true);
    savedTimeoutRef.current = setTimeout(() => setJustSaved(false), 1600);
  };

  useEffect(() => {
    if (monitors.length === 0) return;
    let cancelled = false;
    setRefreshing(true);
    Promise.all(
      monitors.map(async (m) => {
        try {
          const data = await takeScreenshot({
            monitor_index: m.index,
            max_width: 320,
            quality: 55,
          });
          return [m.index, data] as const;
        } catch (e) {
          console.warn(`[MonitorPicker] capture #${m.index} failed:`, e);
          return [m.index, ""] as const;
        }
      }),
    ).then((results) => {
      if (cancelled) return;
      setThumbs(new Map(results));
      setRefreshing(false);
    });
    return () => {
      cancelled = true;
    };
  }, [monitors, refreshKey]);

  const isAuto = selectedIndex == null;

  return (
    <div className="flex flex-col gap-3">
      <div className="grid grid-cols-2 gap-3 sm:grid-cols-3">
        {/* Auto card — same outer/inner structure as monitor cards so the
            heights match exactly. The "thumbnail" slot just shows a Monitor
            icon centered. */}
        <button
          type="button"
          onClick={() => onSelect(null)}
          className={cn(
            "relative flex flex-col gap-1.5 rounded-lg border bg-card/60 p-2 text-left transition-colors",
            isAuto
              ? "border-primary ring-2 ring-primary/40"
              : "border-border/60 hover:border-border",
          )}
        >
          <div className="relative grid aspect-video w-full place-items-center overflow-hidden rounded-md bg-muted">
            <Monitor className="size-8 text-muted-foreground/60" />
            {isAuto && (
              <div className="absolute right-1.5 top-1.5 grid size-5 place-items-center rounded-full bg-primary text-primary-foreground">
                <Check className="size-3" />
              </div>
            )}
          </div>
          <div className="flex items-baseline justify-between gap-2 px-1">
            <div className="text-[12px] font-medium">Auto</div>
            <div className="shrink-0 text-[10px] text-muted-foreground">
              Primary
            </div>
          </div>
        </button>

        {monitors.map((m) => {
          const selected = selectedIndex === m.index;
          const thumb = thumbs.get(m.index);
          return (
            <button
              key={m.index}
              type="button"
              onClick={() => onSelect(m.index)}
              className={cn(
                "relative flex flex-col gap-1.5 rounded-lg border bg-card/60 p-2 text-left transition-colors",
                selected
                  ? "border-primary ring-2 ring-primary/40"
                  : "border-border/60 hover:border-border",
              )}
            >
              <div className="relative aspect-video w-full overflow-hidden rounded-md bg-muted">
                {thumb ? (
                  <img
                    src={`data:image/jpeg;base64,${thumb}`}
                    alt={`Display ${m.index + 1}`}
                    className="size-full object-cover"
                  />
                ) : (
                  <div className="grid size-full place-items-center">
                    {refreshing ? (
                      <Loader2 className="size-4 animate-spin text-muted-foreground" />
                    ) : (
                      <Monitor className="size-5 text-muted-foreground/50" />
                    )}
                  </div>
                )}
                {selected && (
                  <div className="absolute right-1.5 top-1.5 grid size-5 place-items-center rounded-full bg-primary text-primary-foreground">
                    <Check className="size-3" />
                  </div>
                )}
                <div className="absolute left-1.5 top-1.5 rounded bg-black/60 px-1.5 py-0.5 text-[10px] font-medium text-white">
                  {m.index + 1}
                </div>
                {m.is_primary && (
                  <div className="absolute bottom-1.5 left-1.5 rounded bg-primary/80 px-1.5 py-0.5 text-[10px] font-medium text-primary-foreground">
                    Primary
                  </div>
                )}
              </div>
              <div className="flex items-baseline justify-between gap-2 px-1">
                <div
                  className="truncate text-[12px] font-medium"
                  title={m.name}
                >
                  Display {m.index + 1}
                </div>
                <div className="shrink-0 text-[10px] tabular-nums text-muted-foreground">
                  {m.width}×{m.height}
                </div>
              </div>
            </button>
          );
        })}
      </div>

      {!hideFooter && monitors.length > 0 && (
        <div className="flex items-center justify-between">
          <div className="text-[11px] text-muted-foreground">
            {monitors.length === 1
              ? "Only one display detected."
              : `${monitors.length} displays detected.`}
          </div>
          <Button
            type="button"
            size="sm"
            disabled={refreshing}
            onClick={onSave}
            className="h-7 text-[11px]"
          >
            {refreshing ? (
              <>
                <Loader2 className="size-3.5 animate-spin" />
                Saving…
              </>
            ) : justSaved ? (
              <>
                <Check className="size-3.5" />
                Saved
              </>
            ) : (
              "Save"
            )}
          </Button>
        </div>
      )}

      {!hideFooter && monitors.length === 0 && (
        <div className="rounded-md border border-dashed border-border/50 p-4 text-center text-[11.5px] text-muted-foreground">
          No displays detected. The picker will populate when monitors are
          enumerated.
        </div>
      )}
    </div>
  );
}
