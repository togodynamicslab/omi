import { useEffect, useState } from "react";
import { Check, Loader2 } from "lucide-react";
import { useRewindStore } from "@/stores/rewindStore";
import { listMonitors, type MonitorInfo } from "@/services/rewind";
import { MonitorPickerGrid } from "./MonitorPickerGrid";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";

/**
 * First-run "Choose a screen" dialog. Mounted at app root and listens to
 * `rewindStore.showMonitorPicker`. Opens when the user enables Rewind for the
 * first time on a multi-monitor setup; lets them pick a display, optionally
 * tick "Don't show this again", then flips Rewind on with the chosen index.
 *
 * Cancel = leave Rewind off. Setting can always be revisited at
 * Settings → Rewind → Display.
 */
export function MonitorPickerDialog() {
  const showMonitorPicker = useRewindStore((s) => s.showMonitorPicker);
  const cancelMonitorPicker = useRewindStore((s) => s.cancelMonitorPicker);
  const confirmMonitorAndStart = useRewindStore(
    (s) => s.confirmMonitorAndStart,
  );
  const currentMonitorIndex = useRewindStore(
    (s) => s.captureConfig.monitor_index ?? null,
  );

  const [monitors, setMonitors] = useState<MonitorInfo[]>([]);
  const [selected, setSelected] = useState<number | null>(currentMonitorIndex);
  const [dontShowAgain, setDontShowAgain] = useState(false);
  const [loading, setLoading] = useState(false);
  const [confirming, setConfirming] = useState(false);

  // Reload monitors + reset local state every time the dialog opens.
  useEffect(() => {
    if (!showMonitorPicker) return;
    let cancelled = false;
    setLoading(true);
    setSelected(currentMonitorIndex);
    setDontShowAgain(false);
    listMonitors()
      .then((m) => {
        if (cancelled) return;
        setMonitors(m);
        // Default to the saved index if it still exists, otherwise the first
        // non-primary monitor (typical multi-monitor "I want the external
        // screen" intent), otherwise primary.
        if (currentMonitorIndex != null && m.some((x) => x.index === currentMonitorIndex)) {
          setSelected(currentMonitorIndex);
        } else {
          setSelected(null); // Auto / primary
        }
      })
      .catch((e) => {
        console.warn("[MonitorPickerDialog] listMonitors failed:", e);
        if (!cancelled) setMonitors([]);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [showMonitorPicker, currentMonitorIndex]);

  const onConfirm = async () => {
    setConfirming(true);
    try {
      await confirmMonitorAndStart(selected, dontShowAgain);
    } finally {
      setConfirming(false);
    }
  };

  return (
    <Dialog
      open={showMonitorPicker}
      onOpenChange={(open) => {
        if (!open) cancelMonitorPicker();
      }}
    >
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>Choose a screen</DialogTitle>
          <DialogDescription>
            Pick which display Nooto should capture for Rewind. You can change
            this anytime in Settings → Rewind → Display.
          </DialogDescription>
        </DialogHeader>

        {loading ? (
          <div className="grid place-items-center py-12">
            <Loader2 className="size-6 animate-spin text-muted-foreground" />
          </div>
        ) : (
          <MonitorPickerGrid
            monitors={monitors}
            selectedIndex={selected}
            onSelect={setSelected}
            hideFooter
          />
        )}

        <button
          type="button"
          onClick={() => setDontShowAgain((v) => !v)}
          className="-mx-1 flex items-center gap-2 self-start rounded px-1 py-1 text-[12px] text-muted-foreground transition-colors hover:text-foreground"
        >
          <span
            role="checkbox"
            aria-checked={dontShowAgain}
            className={cn(
              "grid size-4 shrink-0 place-items-center rounded border transition-colors",
              dontShowAgain
                ? "border-primary bg-primary text-primary-foreground"
                : "border-border bg-transparent",
            )}
          >
            {dontShowAgain && <Check className="size-3" />}
          </span>
          Don't show this again
        </button>

        <DialogFooter showCloseButton={false}>
          <Button
            variant="outline"
            onClick={cancelMonitorPicker}
            disabled={confirming}
          >
            Cancel
          </Button>
          <Button onClick={() => void onConfirm()} disabled={confirming || loading}>
            {confirming && <Loader2 className="size-3.5 animate-spin" />}
            Start capturing
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
