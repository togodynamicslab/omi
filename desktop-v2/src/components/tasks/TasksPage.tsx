import { useEffect, useMemo, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { Plus } from "lucide-react";
import { Skeleton } from "@/components/ui/skeleton";
import { useTaskStore } from "../../stores/taskStore";
import type { Task } from "../../stores/taskStore";
import { BUCKET_META, bucketFor, type DueBucket } from "./taskDates";
import { TaskRow } from "./TaskRow";
import { TaskSection } from "./TaskSection";
import { TasksHeader, type FilterKey, type SourceKey } from "./TasksHeader";
import { TaskDetailPanel } from "./TaskDetailPanel";

const VALID_FILTERS: FilterKey[] = [
  "all",
  "overdue",
  "today",
  "nodate",
  "done",
];

const BUCKET_ORDER: DueBucket[] = [
  "overdue",
  "today",
  "tomorrow",
  "thisWeek",
  "later",
  "noDate",
];

export function TasksPage() {
  const {
    tasks,
    isLoading: isLoadingStore,
    loadTasks,
    toggleTask,
    createTask,
    deleteTask,
  } = useTaskStore();
  // Only skeleton on the first fetch — silent background refreshes keep the
  // already-rendered list visible instead of flashing placeholders.
  const isLoading = tasks.length === 0 && isLoadingStore;
  const [newTaskText, setNewTaskText] = useState("");
  // Inline detail panel — clicking a row opens a side pane to its right
  // instead of editing or popping the source ticket. Track the id rather
  // than the object so it stays in sync as `tasks` re-fetches.
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [searchParams, setSearchParams] = useSearchParams();
  const paramFilter = searchParams.get("filter") as FilterKey | null;
  const filter: FilterKey =
    paramFilter && VALID_FILTERS.includes(paramFilter) ? paramFilter : "all";

  // Independent of `filter` — pick a tracker (Nooto / Jira / Linear / …) to
  // scope the open-task list. Stored in its own URL param so the date filter
  // and source filter compose ("Today + Jira" is a real query).
  const sourceFilter: SourceKey = (searchParams.get("source") as SourceKey | null) ?? "all";

  const setFilter = (next: FilterKey) => {
    const params = new URLSearchParams(searchParams);
    if (next === "all") {
      params.delete("filter");
    } else {
      params.set("filter", next);
    }
    setSearchParams(params, { replace: true });
  };

  const setSourceFilter = (next: SourceKey) => {
    const params = new URLSearchParams(searchParams);
    if (next === "all") {
      params.delete("source");
    } else {
      params.set("source", next);
    }
    setSearchParams(params, { replace: true });
  };

  useEffect(() => {
    loadTasks();
  }, [loadTasks]);

  // If the user lands on `?filter=done` but every task is open (e.g. they
  // just unchecked the last completed task), the "Completed" chip is hidden
  // because its count is 0 and the page becomes a dead end with a
  // "No completed tasks." message. Bounce back to `all` so the open list
  // takes over.
  useEffect(() => {
    if (
      filter === "done" &&
      tasks.length > 0 &&
      tasks.every((t) => !t.completed)
    ) {
      setFilter("all");
    }
    // setFilter is stable enough to skip from deps — the effect only needs
    // to react to `filter` and the task list shape changing.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter, tasks]);

  const handleCreate = async () => {
    const text = newTaskText.trim();
    if (!text) return;
    setNewTaskText("");
    await createTask(text);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter") {
      e.preventDefault();
      handleCreate();
    }
  };

  const filtered = useMemo(() => {
    const matchesSource = (t: Task) => {
      if (sourceFilter === "all") return true;
      const src = t.source && t.source !== "native" ? t.source : "native";
      return src === sourceFilter;
    };
    if (filter === "done") return tasks.filter((t) => t.completed && matchesSource(t));
    const open = tasks.filter((t) => !t.completed && matchesSource(t));
    if (filter === "all") return open;
    return open.filter((t) => {
      const b = bucketFor(t);
      if (filter === "overdue") return b === "overdue";
      if (filter === "today") return b === "today";
      if (filter === "nodate") return b === "noDate";
      return true;
    });
  }, [tasks, filter, sourceFilter]);

  const buckets = useMemo(() => {
    const map: Record<DueBucket, Task[]> = {
      overdue: [],
      today: [],
      tomorrow: [],
      thisWeek: [],
      later: [],
      noDate: [],
    };
    for (const t of filtered) {
      map[bucketFor(t)].push(t);
    }
    return map;
  }, [filtered]);

  const empty = !isLoading && tasks.length === 0;
  // Resolve the selected task each render so the panel stays consistent when
  // `tasks` re-loads from the backend mid-view.
  const selectedTask = selectedTaskId ? tasks.find((t) => t.id === selectedTaskId) ?? null : null;

  return (
    <div className="tasks-page">
      <TasksHeader
        tasks={tasks}
        stagedCount={0}
        filter={filter}
        onFilter={setFilter}
        sourceFilter={sourceFilter}
        onSourceFilter={setSourceFilter}
      />

      <div className="tasks-split">
        <div className="tasks-content">
        <div className="tasks-create-bar">
          <Plus size={14} className="tasks-create-icon" />
          <input
            type="text"
            className="tasks-create-input"
            placeholder="Add a task..."
            value={newTaskText}
            onChange={(e) => setNewTaskText(e.target.value)}
            onKeyDown={handleKeyDown}
          />
          <button
            className="tasks-create-submit"
            onClick={handleCreate}
            disabled={!newTaskText.trim()}
          >
            Add
          </button>
        </div>

        {isLoading ? (
          <>
            {/* Expanded section — header + ~5 task rows. */}
            <div className="task-section">
              <div className="task-section-head">
                <Skeleton className="size-3.5" />
                <Skeleton className="size-4" />
                <Skeleton className="h-3.5 w-20" />
                <Skeleton className="ml-auto h-4 w-7 rounded-full" />
              </div>
              <div className="task-section-body">
                {Array.from({ length: 5 }).map((_, i) => (
                  <div key={i} className="task-row">
                    <Skeleton className="mt-0.5 size-4 shrink-0 rounded-full" />
                    <Skeleton
                      className="h-3.5"
                      style={{
                        flex: 1,
                        maxWidth: `${80 - i * 9}%`,
                      }}
                    />
                    <Skeleton className="h-4 w-12 shrink-0 rounded-md" />
                  </div>
                ))}
              </div>
            </div>
            {/* Collapsed section — header only. */}
            <div className="task-section">
              <div className="task-section-head">
                <Skeleton className="size-3.5" />
                <Skeleton className="size-4" />
                <Skeleton className="h-3.5 w-24" />
                <Skeleton className="ml-auto h-4 w-7 rounded-full" />
              </div>
            </div>
          </>
        ) : null}

        {empty && (
          <div className="page-empty">
            No tasks yet. Add one above, or Nooto will extract them from your
            meetings.
          </div>
        )}

        {!isLoading && (filter === "done" ? (
          filtered.length === 0 ? (
            <div className="page-empty">No completed tasks.</div>
          ) : (
            <div className="task-list">
              {filtered.map((task) => (
                <TaskRow
                  key={task.id}
                  task={task}
                  selected={task.id === selectedTaskId}
                  onSelect={() => setSelectedTaskId(task.id)}
                  onToggle={() => toggleTask(task.id)}
                  onUpdate={() => {}}
                  onDelete={() => deleteTask(task.id)}
                />
              ))}
            </div>
          )
        ) : (
          BUCKET_ORDER.map((bucket) => {
            const items = buckets[bucket];
            if (items.length === 0) return null;
            const meta = BUCKET_META[bucket];
            return (
              <TaskSection
                key={bucket}
                bucket={bucket}
                label={meta.label}
                hint={meta.hint}
                count={items.length}
                defaultOpen={bucket === "overdue" || bucket === "today" || items.length <= 5}
              >
                {items.map((task) => (
                  <TaskRow
                    key={task.id}
                    task={task}
                    selected={task.id === selectedTaskId}
                    onSelect={() => setSelectedTaskId(task.id)}
                    onToggle={() => toggleTask(task.id)}
                    onUpdate={() => {}}
                    onDelete={() => deleteTask(task.id)}
                  />
                ))}
              </TaskSection>
            );
          })
        ))}
        </div>
        {selectedTask && (
          <TaskDetailPanel
            key={selectedTask.id}
            task={selectedTask}
            onClose={() => setSelectedTaskId(null)}
            onToggle={() => toggleTask(selectedTask.id)}
          />
        )}
      </div>
    </div>
  );
}
