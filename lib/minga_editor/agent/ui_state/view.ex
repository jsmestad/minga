defmodule MingaEditor.Agent.UIState.View do
  @moduledoc """
  Layout, search, preview, and toast state for the agent UI.

  Holds the data for the full-screen agentic view (focus, split sizing,
  preview pane, search, toasts, edit timeline, context estimate). This is the
  "view" half of the agent UI, separated from prompt editing concerns in
  `UIState.Panel`.

  Most callers interact through `UIState` functions rather than accessing
  this struct directly.
  """

  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.EditTimeline
  alias MingaEditor.Agent.Activity
  alias MingaEditor.Agent.UIState.Presentation
  alias MingaEditor.Agent.UIState.ReturnTarget
  alias MingaEditor.Agent.View.Preview
  alias Minga.Config
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows

  @typedoc "Which panel has keyboard focus inside the agentic view."
  @type focus :: Presentation.focus()

  @typedoc "Active prefix key awaiting a follow-up keystroke."
  @type prefix :: Presentation.prefix()

  @typedoc "A search match: message index, byte start, byte end."
  @type search_match ::
          {msg_index :: non_neg_integer(), col_start :: non_neg_integer(),
           col_end :: non_neg_integer()}

  @typedoc "Search state for the chat panel."
  @type search_state :: %{
          query: String.t(),
          matches: [search_match()],
          current: non_neg_integer(),
          saved_scroll: non_neg_integer(),
          input_active: boolean()
        }

  @typedoc "A notification toast."
  @type toast :: %{message: String.t(), icon: String.t(), level: :info | :warning | :error}

  @typedoc "Editor context to restore when leaving the agent view."
  @type return_target :: ReturnTarget.t()

  @typedoc "Layout, search, preview, and toast state."
  @type t :: %__MODULE__{
          presentation: Presentation.t(),
          preview: Preview.t(),
          chat_width_pct: non_neg_integer(),
          help_visible: boolean(),
          search: search_state() | nil,
          toast: toast() | nil,
          toast_queue: term(),
          edit_timeline: EditTimeline.t(),
          activity: Activity.t(),
          context_estimate: non_neg_integer(),
          compact_warned: boolean(),
          compact_triggered: boolean(),
          compact_pending_fill_pct: non_neg_integer() | nil,
          compaction_in_progress: boolean()
        }

  @min_chat_pct 30
  @max_chat_pct 80
  @resize_step 5

  defstruct presentation: %Presentation{},
            preview: Preview.new(),
            chat_width_pct: 65,
            help_visible: false,
            search: nil,
            toast: nil,
            toast_queue: :queue.new(),
            context_estimate: 0,
            compact_warned: false,
            compact_triggered: false,
            compact_pending_fill_pct: nil,
            compaction_in_progress: false,
            edit_timeline: EditTimeline.new(),
            activity: Activity.new()

  @doc "Creates a new view state with defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Marks compaction as no longer running."
  @spec finish_compaction(t()) :: t()
  def finish_compaction(%__MODULE__{} = view), do: %{view | compaction_in_progress: false}

  @doc "Installs the activity value produced by an Activity transition."
  @spec replace_activity(t(), Activity.t()) :: t()
  def replace_activity(%__MODULE__{} = view, %Activity{} = activity) do
    %{view | activity: activity}
  end

  @doc "Installs the edit timeline produced by an EditTimeline transition."
  @spec replace_edit_timeline(t(), EditTimeline.t()) :: t()
  def replace_edit_timeline(%__MODULE__{} = view, %EditTimeline{} = timeline) do
    %{view | edit_timeline: timeline}
  end

  # ── Layout ──────────────────────────────────────────────────────────────────

  @doc "Builds a return target from the current editor context."
  @spec return_target(
          pos_integer() | nil,
          pid() | nil,
          Windows.t(),
          FileTreeState.t(),
          Minga.Keymap.Scope.scope_name(),
          boolean()
        ) :: return_target()
  def return_target(
        active_tab_id,
        active_buffer,
        windows,
        file_tree,
        keymap_scope,
        prompt_focused
      ) do
    ReturnTarget.new(
      active_tab_id,
      active_buffer,
      windows,
      file_tree,
      keymap_scope,
      prompt_focused
    )
  end

  @doc "Activates the view, saving the current window layout."
  @spec activate(t(), Windows.t() | nil, FileTreeState.t() | nil) :: t()
  def activate(%__MODULE__{} = view, windows, file_tree) do
    activate(view, windows, file_tree, nil)
  end

  @doc "Activates the view with a recorded editor return target."
  @spec activate(
          t(),
          Windows.t() | nil,
          FileTreeState.t() | nil,
          return_target() | nil
        ) :: t()
  def activate(%__MODULE__{} = view, windows, file_tree, return_target),
    do: %{
      view
      | presentation: Presentation.activate(view.presentation, windows, file_tree, return_target)
    }

  @doc "Sets the editor return target."
  @spec set_return_target(t(), return_target() | nil) :: t()
  def set_return_target(%__MODULE__{} = view, return_target),
    do: %{
      view
      | presentation: Presentation.replace_return_target(view.presentation, return_target)
    }

  @doc "Clears the editor return target."
  @spec clear_return_target(t()) :: t()
  def clear_return_target(%__MODULE__{} = view), do: set_return_target(view, nil)

  @doc "Deactivates the view and returns the restored window layout."
  @spec deactivate(t()) :: {t(), Windows.t() | nil, FileTreeState.t() | nil}
  def deactivate(%__MODULE__{} = view) do
    {presentation, saved_windows, saved_file_tree} = Presentation.complete(view.presentation)
    {%{view | presentation: presentation}, saved_windows, saved_file_tree}
  end

  @doc "Returns whether the full-screen agent presentation is active."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{presentation: presentation}), do: Presentation.active?(presentation)

  @doc "Returns the focused agent panel."
  @spec focus(t()) :: focus()
  def focus(%__MODULE__{presentation: presentation}), do: Presentation.current_focus(presentation)

  @doc "Returns the editor target restored when presentation completes."
  @spec return_target(t()) :: return_target() | nil
  def return_target(%__MODULE__{presentation: presentation}),
    do: Presentation.return_target(presentation)

  @doc "Returns the pending multi-key prefix."
  @spec pending_prefix(t()) :: prefix()
  def pending_prefix(%__MODULE__{presentation: presentation}),
    do: Presentation.pending_prefix(presentation)

  @doc "Switches focus to the given panel."
  @spec set_focus(t(), focus()) :: t()
  def set_focus(%__MODULE__{} = view, focus) when focus in [:chat, :file_viewer],
    do: %{view | presentation: Presentation.focus(view.presentation, focus)}

  @doc "Sets the pending prefix for multi-key sequences."
  @spec set_prefix(t(), prefix()) :: t()
  def set_prefix(%__MODULE__{} = view, prefix),
    do: %{view | presentation: Presentation.install_prefix(view.presentation, prefix)}

  @doc "Clears any pending prefix."
  @spec clear_prefix(t()) :: t()
  def clear_prefix(%__MODULE__{} = view),
    do: %{view | presentation: Presentation.reset_prefix(view.presentation)}

  @doc "Toggles the help overlay visibility."
  @spec toggle_help(t()) :: t()
  def toggle_help(%__MODULE__{} = view), do: %{view | help_visible: !view.help_visible}

  @doc "Dismisses the help overlay."
  @spec dismiss_help(t()) :: t()
  def dismiss_help(%__MODULE__{} = view), do: %{view | help_visible: false}

  @doc "Grows the chat panel width by one step (clamped at max)."
  @spec grow_chat(t()) :: t()
  def grow_chat(%__MODULE__{} = view) do
    %{view | chat_width_pct: min(view.chat_width_pct + @resize_step, @max_chat_pct)}
  end

  @doc "Shrinks the chat panel width by one step (clamped at min)."
  @spec shrink_chat(t()) :: t()
  def shrink_chat(%__MODULE__{} = view) do
    %{view | chat_width_pct: max(view.chat_width_pct - @resize_step, @min_chat_pct)}
  end

  @doc "Resets the chat panel width to the configured default."
  @spec reset_split(t()) :: t()
  def reset_split(%__MODULE__{} = view) do
    default = Config.get(:agent_panel_split)
    pct = default |> max(@min_chat_pct) |> min(@max_chat_pct)
    %{view | chat_width_pct: pct}
  end

  # ── Preview ─────────────────────────────────────────────────────────────────

  @doc "Scrolls the preview pane down by the given number of lines."
  @spec scroll_viewer_down(t(), pos_integer()) :: t()
  def scroll_viewer_down(%__MODULE__{} = view, amount) do
    %{view | preview: Preview.scroll_down(view.preview, amount)}
  end

  @doc "Scrolls the preview pane up by the given number of lines, clamped at 0."
  @spec scroll_viewer_up(t(), pos_integer()) :: t()
  def scroll_viewer_up(%__MODULE__{} = view, amount) do
    %{view | preview: Preview.scroll_up(view.preview, amount)}
  end

  @doc "Scrolls the preview pane to the top (offset 0)."
  @spec scroll_viewer_to_top(t()) :: t()
  def scroll_viewer_to_top(%__MODULE__{} = view) do
    %{view | preview: Preview.scroll_to_top(view.preview)}
  end

  @doc "Scrolls the preview pane to a large offset (renderer clamps to actual content)."
  @spec scroll_viewer_to_bottom(t()) :: t()
  def scroll_viewer_to_bottom(%__MODULE__{} = view) do
    %{view | preview: Preview.scroll_to_bottom(view.preview)}
  end

  @doc "Installs the preview produced by a Preview transition."
  @spec replace_preview(t(), Preview.t()) :: t()
  def replace_preview(%__MODULE__{} = view, %Preview{} = preview) do
    %{view | preview: preview}
  end

  @type diff_resolution_action :: :accept_current | :reject_current | :accept_all | :reject_all
  @type diff_resolution_write :: :no_write | {:write_file, String.t(), String.t()}
  @type diff_resolution_result :: {:ok, t(), diff_resolution_write()} | :no_diff | :no_hunk

  @doc "Applies a diff-review resolution and reprojects the edit timeline authority atomically."
  @spec resolve_diff_review(t(), diff_resolution_action()) :: diff_resolution_result()
  def resolve_diff_review(%__MODULE__{} = view, action)
      when action in [:accept_current, :reject_current, :accept_all, :reject_all] do
    with %DiffReview{} = review <- Preview.diff_review(view.preview),
         {:ok, resolved_review} <- resolve_review_action(review, action) do
      original_lines = DiffReview.original_lines(review)
      materialized_lines = DiffReview.materialized_lines(resolved_review)

      timeline =
        EditTimeline.reproject(
          view.edit_timeline,
          resolved_review.path,
          original_lines,
          materialized_lines
        )

      updated_review =
        resolved_review
        |> DiffReview.update_after_lines(
          materialized_lines,
          EditTimeline.cumulative_hunks(timeline, resolved_review.path)
        )
        |> unresolved_review()

      updated_view = %{
        view
        | edit_timeline: timeline,
          preview: Preview.replace_diff(view.preview, updated_review)
      }

      {:ok, updated_view, write_request(action, resolved_review.path, materialized_lines)}
    else
      nil -> :no_diff
      :no_hunk -> :no_hunk
    end
  end

  # ── Search ──────────────────────────────────────────────────────────────────

  @doc "Starts a search, saving the current scroll position."
  @spec start_search(t(), non_neg_integer()) :: t()
  def start_search(%__MODULE__{} = view, current_scroll) do
    %{
      view
      | search: %{
          query: "",
          matches: [],
          current: 0,
          saved_scroll: current_scroll,
          input_active: true
        }
    }
  end

  @doc "Returns true if search is active (either inputting or confirmed with matches)."
  @spec searching?(t()) :: boolean()
  def searching?(%__MODULE__{search: nil}), do: false
  def searching?(%__MODULE__{search: %{}}), do: true

  @doc "Returns true if search input is being typed (vs confirmed)."
  @spec search_input_active?(t()) :: boolean()
  def search_input_active?(%__MODULE__{search: nil}), do: false
  def search_input_active?(%__MODULE__{search: %{input_active: active}}), do: active

  @doc "Updates the search query string."
  @spec update_search_query(t(), String.t()) :: t()
  def update_search_query(%__MODULE__{search: nil} = view, _query), do: view

  def update_search_query(%__MODULE__{search: search} = view, query) do
    %{view | search: %{search | query: query}}
  end

  @doc "Sets search matches and resets current to 0."
  @spec set_search_matches(t(), [search_match()]) :: t()
  def set_search_matches(%__MODULE__{search: nil} = view, _matches), do: view

  def set_search_matches(%__MODULE__{search: search} = view, matches) do
    %{view | search: %{search | matches: matches, current: 0}}
  end

  @doc "Moves to the next search match."
  @spec next_search_match(t()) :: t()
  def next_search_match(%__MODULE__{search: nil} = view), do: view
  def next_search_match(%__MODULE__{search: %{matches: []}} = view), do: view

  def next_search_match(%__MODULE__{search: search} = view) do
    next = rem(search.current + 1, Enum.count(search.matches))
    %{view | search: %{search | current: next}}
  end

  @doc "Moves to the previous search match."
  @spec prev_search_match(t()) :: t()
  def prev_search_match(%__MODULE__{search: nil} = view), do: view
  def prev_search_match(%__MODULE__{search: %{matches: []}} = view), do: view

  def prev_search_match(%__MODULE__{search: search} = view) do
    count = Enum.count(search.matches)
    prev = rem(search.current - 1 + count, count)
    %{view | search: %{search | current: prev}}
  end

  @doc "Cancels search and returns nil (caller restores scroll)."
  @spec cancel_search(t()) :: t()
  def cancel_search(%__MODULE__{} = view) do
    %{view | search: nil}
  end

  @doc "Confirms search (keeps matches for n/N navigation, disables input)."
  @spec confirm_search(t()) :: t()
  def confirm_search(%__MODULE__{search: nil} = view), do: view

  def confirm_search(%__MODULE__{search: %{matches: []}} = view) do
    cancel_search(view)
  end

  def confirm_search(%__MODULE__{search: search} = view) do
    %{view | search: %{search | input_active: false}}
  end

  @doc "Returns the saved scroll position from before search started."
  @spec search_saved_scroll(t()) :: non_neg_integer() | nil
  def search_saved_scroll(%__MODULE__{search: nil}), do: nil
  def search_saved_scroll(%__MODULE__{search: search}), do: search.saved_scroll

  @doc "Returns the search query, or nil if not searching."
  @spec search_query(t()) :: String.t() | nil
  def search_query(%__MODULE__{search: nil}), do: nil
  def search_query(%__MODULE__{search: search}), do: search.query

  # ── Toasts ──────────────────────────────────────────────────────────────────

  @doc "Pushes a toast. If no toast is showing, it becomes the current toast."
  @spec push_toast(t(), String.t(), :info | :warning | :error) :: t()
  def push_toast(%__MODULE__{toast: nil} = view, message, level) do
    toast = make_toast(message, level)
    %{view | toast: toast}
  end

  def push_toast(%__MODULE__{} = view, message, level) do
    toast = make_toast(message, level)
    %{view | toast_queue: :queue.in(toast, view.toast_queue)}
  end

  @doc "Dismisses the current toast. Shows the next one in the queue if any."
  @spec dismiss_toast(t()) :: t()
  def dismiss_toast(%__MODULE__{toast: nil} = view), do: view

  def dismiss_toast(%__MODULE__{} = view) do
    case :queue.out(view.toast_queue) do
      {{:value, next}, rest} ->
        %{view | toast: next, toast_queue: rest}

      {:empty, _} ->
        %{view | toast: nil}
    end
  end

  @doc "Returns true if a toast is currently visible."
  @spec toast_visible?(t()) :: boolean()
  def toast_visible?(%__MODULE__{toast: nil}), do: false
  def toast_visible?(%__MODULE__{}), do: true

  @doc "Clears all toasts."
  @spec clear_toasts(t()) :: t()
  def clear_toasts(%__MODULE__{} = view) do
    %{view | toast: nil, toast_queue: :queue.new()}
  end

  @spec resolve_review_action(DiffReview.t(), diff_resolution_action()) ::
          {:ok, DiffReview.t()} | :no_hunk
  defp resolve_review_action(%DiffReview{} = review, :accept_current) do
    if DiffReview.current_hunk(review),
      do: {:ok, DiffReview.accept_current(review)},
      else: :no_hunk
  end

  defp resolve_review_action(%DiffReview{} = review, :reject_current) do
    if DiffReview.current_hunk(review),
      do: {:ok, DiffReview.reject_current(review)},
      else: :no_hunk
  end

  defp resolve_review_action(%DiffReview{} = review, :accept_all),
    do: {:ok, DiffReview.accept_all(review)}

  defp resolve_review_action(%DiffReview{} = review, :reject_all),
    do: {:ok, DiffReview.reject_all(review)}

  @spec unresolved_review(DiffReview.t() | nil) :: DiffReview.t() | nil
  defp unresolved_review(nil), do: nil

  defp unresolved_review(%DiffReview{} = review),
    do: if(DiffReview.resolved?(review), do: nil, else: review)

  @spec write_request(diff_resolution_action(), String.t(), [String.t()]) ::
          diff_resolution_write()
  defp write_request(action, path, materialized_lines)
       when action in [:reject_current, :reject_all] do
    {:write_file, path, Enum.join(materialized_lines, "\n")}
  end

  defp write_request(_action, _path, _materialized_lines), do: :no_write

  @spec make_toast(String.t(), :info | :warning | :error) :: toast()
  defp make_toast(message, :info), do: %{message: message, icon: "✓", level: :info}
  defp make_toast(message, :warning), do: %{message: message, icon: "⚠", level: :warning}
  defp make_toast(message, :error), do: %{message: message, icon: "✗", level: :error}

  # ── Edit timeline ──────────────────────────────────────────────────────────

  @doc "Resets the edit timeline and cleans up file-backed entry snapshots."
  @spec reset_edit_timeline(t()) :: t()
  def reset_edit_timeline(%__MODULE__{} = view) do
    %{view | edit_timeline: EditTimeline.reset(view.edit_timeline)}
  end
end
