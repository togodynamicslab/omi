import type { HTMLAttributes } from "react";
import { cn } from "@/lib/utils";

/**
 * Skeleton primitive — a subtle animated placeholder used while the real data
 * is loading. Compose it into shapes that mirror the eventual content so the
 * layout doesn't shift when data arrives.
 */
export function Skeleton({
  className,
  ...props
}: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cn(
        "animate-pulse rounded-md bg-muted-foreground/15",
        className,
      )}
      {...props}
    />
  );
}
