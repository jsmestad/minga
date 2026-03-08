defmodule Minga.Agent.View.State do
  @moduledoc """
  Agentic view layout state.

  Tracks whether the full-screen agentic view is active, which panel has
  focus, the file viewer scroll position, and the saved window layout to
  restore when the view is closed.

  ## Prefix state machine

  Multi-key sequences (gg, za, ]m, gf, etc.) use a generalized prefix
  system. When a prefix key is pressed, `pending_prefix` is set and the
  next keypress completes or cancels the sequence. This replaces the
  old `pending_g: boolean()` flag.

  Stored as a single sub-struct in `EditorState` so the top-level struct
  stays within Credo's 31-field limit.
  """

  alias Minga.Agent.View.Preview
  alias Minga.Config.Options
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Windows

  @typedoc "Which panel has keyboard focus inside the agentic view."
  @type focus :: :chat | :file_viewer

  @typedoc "Active prefix key awaiting a follow-up keystroke."
  @type prefix :: nil | :g | :z | :bracket_next | :bracket_prev

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

  @typedoc "Agentic view sub-state."
  @type t :: %__MODULE__{
          active: boolean(),
          focus: focus(),
          preview: Preview.t(),
          saved_windows: Windows.t() | nil,
          pending_prefix: prefix(),
          chat_width_pct: non_neg_integer(),
          saved_file_tree: FileTreeState.t() | nil,
          help_visible: boolean(),
          search: search_state() | nil,
          toast: toast() | nil,
          toast_queue: term()
        }

  @enforce_keys []
  defstruct active: false,
            focus: :chat,
            preview: Preview.new(),
            saved_windows: nil,
            pending_prefix: nil,
            chat_width_pct: 65,
            saved_file_tree: nil,
            help_visible: false,
            search: nil,
            toast: nil,
            toast_queue: :queue.new()

  @min_chat_pct 30
  @max_chat_pct 80
  @resize_step 5

  @doc "Returns a new agentic view state with all defaults."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Activates the view, saving the current window layout."
  @spec activate(t(), Windows.t(), FileTreeState.t()) :: t()
  def activate(%__MODULE__{} = av, windows, file_tree) do
    %{
      av
      | active: true,
        focus: :chat,
        saved_windows: windows,
        saved_file_tree: file_tree,
        pending_prefix: nil
    }
  end

  @doc "Deactivates the view and returns the restored window layout."
  @spec deactivate(t()) :: {t(), Windows.t() | nil, FileTreeState.t() | nil}
  def deactivate(%__MODULE__{saved_windows: saved_windows, saved_file_tree: saved_file_tree} = av) do
    {%{
       av
       | active: false,
         focus: :chat,
         saved_windows: nil,
         saved_file_tree: nil,
         pending_prefix: nil
     }, saved_windows, saved_file_tree}
  end

  @doc "Switches focus to the given panel."
  @spec set_focus(t(), focus()) :: t()
  def set_focus(%__MODULE__{} = av, focus) when focus in [:chat, :file_viewer] do
    %{av | focus: focus}
  end

  @doc "Scrolls the preview pane down by the given number of lines."
  @spec scroll_viewer_down(t(), pos_integer()) :: t()
  def scroll_viewer_down(%__MODULE__{} = av, amount) do
    %{av | preview: Preview.scroll_down(av.preview, amount)}
  end

  @doc "Scrolls the preview pane up by the given number of lines, clamped at 0."
  @spec scroll_viewer_up(t(), pos_integer()) :: t()
  def scroll_viewer_up(%__MODULE__{} = av, amount) do
    %{av | preview: Preview.scroll_up(av.preview, amount)}
  end

  @doc "Scrolls the preview pane to the top (offset 0)."
  @spec scroll_viewer_to_top(t()) :: t()
  def scroll_viewer_to_top(%__MODULE__{} = av) do
    %{av | preview: Preview.scroll_to_top(av.preview)}
  end

  @doc "Scrolls the preview pane to a large offset (renderer clamps to actual content)."
  @spec scroll_viewer_to_bottom(t()) :: t()
  def scroll_viewer_to_bottom(%__MODULE__{} = av) do
    %{av | preview: Preview.scroll_to_bottom(av.preview)}
  end

  # ── Preview management ──────────────────────────────────────────────────────

  @doc "Updates the preview state with the given function."
  @spec update_preview(t(), (Preview.t() -> Preview.t())) :: t()
  def update_preview(%__MODULE__{} = av, fun) when is_function(fun, 1) do
    %{av | preview: fun.(av.preview)}
  end

  @doc "Sets the pending prefix for multi-key sequences."
  @spec set_prefix(t(), prefix()) :: t()
  def set_prefix(%__MODULE__{} = av, prefix)
      when prefix in [nil, :g, :z, :bracket_next, :bracket_prev] do
    %{av | pending_prefix: prefix}
  end

  @doc "Clears any pending prefix."
  @spec clear_prefix(t()) :: t()
  def clear_prefix(%__MODULE__{} = av), do: %{av | pending_prefix: nil}

  @doc "Toggles the help overlay visibility."
  @spec toggle_help(t()) :: t()
  def toggle_help(%__MODULE__{} = av), do: %{av | help_visible: !av.help_visible}

  @doc "Dismisses the help overlay."
  @spec dismiss_help(t()) :: t()
  def dismiss_help(%__MODULE__{} = av), do: %{av | help_visible: false}

  @doc "Grows the chat panel width by one step (clamped at max)."
  @spec grow_chat(t()) :: t()
  def grow_chat(%__MODULE__{} = av) do
    %{av | chat_width_pct: min(av.chat_width_pct + @resize_step, @max_chat_pct)}
  end

  @doc "Shrinks the chat panel width by one step (clamped at min)."
  @spec shrink_chat(t()) :: t()
  def shrink_chat(%__MODULE__{} = av) do
    %{av | chat_width_pct: max(av.chat_width_pct - @resize_step, @min_chat_pct)}
  end

  @doc "Resets the chat panel width to the configured default."
  @spec reset_split(t()) :: t()
  def reset_split(%__MODULE__{} = av) do
    default = Options.get(:agent_panel_split)
    pct = default |> max(@min_chat_pct) |> min(@max_chat_pct)
    %{av | chat_width_pct: pct}
  end

  # ── Backward compatibility ──────────────────────────────────────────────────

  @doc false
  @doc deprecated: "Use set_prefix/2 and clear_prefix/1 instead"
  @spec set_pending_g(t(), boolean()) :: t()
  def set_pending_g(%__MODULE__{} = av, true), do: set_prefix(av, :g)
  def set_pending_g(%__MODULE__{} = av, false), do: clear_prefix(av)

  @doc false
  @doc deprecated: "Use pending_prefix == :g instead"
  @spec pending_g(t()) :: boolean()
  def pending_g(%__MODULE__{pending_prefix: :g}), do: true
  def pending_g(%__MODULE__{}), do: false

  # ── Search ──────────────────────────────────────────────────────────────────

  @doc "Starts a search, saving the current scroll position."
  @spec start_search(t(), non_neg_integer()) :: t()
  def start_search(%__MODULE__{} = av, current_scroll) do
    %{
      av
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
  def update_search_query(%__MODULE__{search: nil} = av, _query), do: av

  def update_search_query(%__MODULE__{search: search} = av, query) do
    %{av | search: %{search | query: query}}
  end

  @doc "Sets search matches and resets current to 0."
  @spec set_search_matches(t(), [search_match()]) :: t()
  def set_search_matches(%__MODULE__{search: nil} = av, _matches), do: av

  def set_search_matches(%__MODULE__{search: search} = av, matches) do
    %{av | search: %{search | matches: matches, current: 0}}
  end

  @doc "Moves to the next search match."
  @spec next_search_match(t()) :: t()
  def next_search_match(%__MODULE__{search: nil} = av), do: av

  def next_search_match(%__MODULE__{search: %{matches: []}} = av), do: av

  def next_search_match(%__MODULE__{search: search} = av) do
    next = rem(search.current + 1, length(search.matches))
    %{av | search: %{search | current: next}}
  end

  @doc "Moves to the previous search match."
  @spec prev_search_match(t()) :: t()
  def prev_search_match(%__MODULE__{search: nil} = av), do: av

  def prev_search_match(%__MODULE__{search: %{matches: []}} = av), do: av

  def prev_search_match(%__MODULE__{search: search} = av) do
    count = length(search.matches)
    prev = rem(search.current - 1 + count, count)
    %{av | search: %{search | current: prev}}
  end

  @doc "Cancels search and returns nil (caller restores scroll)."
  @spec cancel_search(t()) :: t()
  def cancel_search(%__MODULE__{} = av) do
    %{av | search: nil}
  end

  @doc "Confirms search (keeps matches for n/N navigation, disables input)."
  @spec confirm_search(t()) :: t()
  def confirm_search(%__MODULE__{search: nil} = av), do: av

  def confirm_search(%__MODULE__{search: %{matches: []}} = av) do
    # No matches found, cancel instead
    cancel_search(av)
  end

  def confirm_search(%__MODULE__{search: search} = av) do
    %{av | search: %{search | input_active: false}}
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
  def push_toast(%__MODULE__{toast: nil} = av, message, level) do
    toast = make_toast(message, level)
    %{av | toast: toast}
  end

  def push_toast(%__MODULE__{} = av, message, level) do
    toast = make_toast(message, level)
    %{av | toast_queue: :queue.in(toast, av.toast_queue)}
  end

  @doc "Dismisses the current toast. Shows the next one in the queue if any."
  @spec dismiss_toast(t()) :: t()
  def dismiss_toast(%__MODULE__{toast: nil} = av), do: av

  def dismiss_toast(%__MODULE__{} = av) do
    case :queue.out(av.toast_queue) do
      {{:value, next}, rest} ->
        %{av | toast: next, toast_queue: rest}

      {:empty, _} ->
        %{av | toast: nil}
    end
  end

  @doc "Returns true if a toast is currently visible."
  @spec toast_visible?(t()) :: boolean()
  def toast_visible?(%__MODULE__{toast: nil}), do: false
  def toast_visible?(%__MODULE__{}), do: true

  @doc "Clears all toasts."
  @spec clear_toasts(t()) :: t()
  def clear_toasts(%__MODULE__{} = av) do
    %{av | toast: nil, toast_queue: :queue.new()}
  end

  @spec make_toast(String.t(), :info | :warning | :error) :: toast()
  defp make_toast(message, :info), do: %{message: message, icon: "✓", level: :info}
  defp make_toast(message, :warning), do: %{message: message, icon: "⚠", level: :warning}
  defp make_toast(message, :error), do: %{message: message, icon: "✗", level: :error}
end
