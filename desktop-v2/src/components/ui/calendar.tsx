import * as React from "react"
import { ChevronLeftIcon, ChevronRightIcon, ChevronDownIcon } from "lucide-react"
import { DayPicker, getDefaultClassNames } from "react-day-picker"

import { cn } from "@/lib/utils"
import { buttonVariants } from "@/components/ui/button"

type ButtonVariant =
  | "default"
  | "destructive"
  | "outline"
  | "secondary"
  | "ghost"
  | "link"

/**
 * Themed react-day-picker calendar.
 *
 * Layout follows the shadcn-ui v9 reference: a single CSS variable
 * `--cell-size` drives both the day-cell square and the chevron buttons, so
 * the nav row sits flush with the grid edges. The chevrons are absolutely
 * positioned over the caption row via `nav`, with the caption itself padded
 * by `px-(--cell-size)` so the title never collides with the buttons.
 *
 * Earlier revisions used a `pointer-events: none` overlay nav with
 * `pointer-events: auto` children — that worked geometrically but the
 * click events failed to register on the right chevron in WebView2 (the
 * keyboard path still routed through the inner `<button>`). Dropping the
 * pointer-events hack and relying on the default stacking context fixes
 * the click target without losing the visual layout.
 */
function Calendar({
  className,
  classNames,
  showOutsideDays = true,
  buttonVariant = "ghost",
  components,
  ...props
}: React.ComponentProps<typeof DayPicker> & {
  buttonVariant?: ButtonVariant
}) {
  const defaults = getDefaultClassNames()

  return (
    <DayPicker
      showOutsideDays={showOutsideDays}
      className={cn(
        "bg-popover text-popover-foreground p-3 [--cell-size:2.25rem]",
        className,
      )}
      classNames={{
        root: cn("w-fit", defaults.root),
        months: cn(
          "flex gap-4 flex-col md:flex-row relative",
          defaults.months,
        ),
        month: cn("flex flex-col w-full gap-4", defaults.month),
        nav: cn(
          "flex items-center justify-between absolute top-0 inset-x-0 z-10 w-full px-1",
          defaults.nav,
        ),
        button_previous: cn(
          buttonVariants({ variant: buttonVariant }),
          "size-[var(--cell-size)] p-0 select-none text-muted-foreground hover:text-foreground aria-disabled:opacity-50",
          defaults.button_previous,
        ),
        button_next: cn(
          buttonVariants({ variant: buttonVariant }),
          "size-[var(--cell-size)] p-0 select-none text-muted-foreground hover:text-foreground aria-disabled:opacity-50",
          defaults.button_next,
        ),
        month_caption: cn(
          "flex items-center justify-center h-[var(--cell-size)] w-full px-[var(--cell-size)]",
          defaults.month_caption,
        ),
        caption_label: cn("text-sm font-medium select-none", defaults.caption_label),
        weekdays: cn("flex", defaults.weekdays),
        weekday: cn(
          "text-muted-foreground rounded-md flex-1 font-normal text-[0.75rem] select-none",
          defaults.weekday,
        ),
        month_grid: cn("w-full border-collapse", defaults.month_grid),
        week: cn("flex w-full mt-1", defaults.week),
        day: cn(
          "relative w-full h-full p-0 text-center group/day aspect-square select-none",
          defaults.day,
        ),
        day_button: cn(
          "size-[var(--cell-size)] mx-auto flex items-center justify-center rounded-md text-sm font-normal transition-colors hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
          defaults.day_button,
        ),
        selected: cn(
          "bg-primary text-primary-foreground hover:bg-primary hover:text-primary-foreground focus-visible:bg-primary [&>button]:bg-primary [&>button]:text-primary-foreground [&>button]:hover:bg-primary",
          defaults.selected,
        ),
        today: cn(
          "rounded-md font-semibold [&>button]:ring-1 [&>button]:ring-inset [&>button]:ring-primary/60",
          defaults.today,
        ),
        outside: cn(
          "text-muted-foreground/60 aria-selected:text-muted-foreground",
          defaults.outside,
        ),
        disabled: cn("text-muted-foreground/40 opacity-50", defaults.disabled),
        hidden: cn("invisible", defaults.hidden),
        range_start: cn(
          "rounded-l-md bg-primary text-primary-foreground",
          defaults.range_start,
        ),
        range_middle: cn(
          "bg-accent text-accent-foreground",
          defaults.range_middle,
        ),
        range_end: cn(
          "rounded-r-md bg-primary text-primary-foreground",
          defaults.range_end,
        ),
        ...classNames,
      }}
      components={{
        Chevron: ({ orientation, className: chevronClass, ...rest }) => {
          if (orientation === "left") {
            return (
              <ChevronLeftIcon
                className={cn("size-4", chevronClass)}
                {...rest}
              />
            )
          }
          if (orientation === "right") {
            return (
              <ChevronRightIcon
                className={cn("size-4", chevronClass)}
                {...rest}
              />
            )
          }
          return (
            <ChevronDownIcon
              className={cn("size-4", chevronClass)}
              {...rest}
            />
          )
        },
        ...components,
      }}
      {...props}
    />
  )
}

export { Calendar }
