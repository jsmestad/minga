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
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Windows

  @typedoc "Which panel has keyboard focus inside the agentic view."
  @type focus :: :chat | :file_viewer

  @typedoc "Active prefix key awaiting a follow-up keystroke."
  @type prefix :: nil | :g | :z | :bracket_next | :bracket_prev

  @typedoc "Agentic view sub-state."
  @type t :: %__MODULE__{
          active: boolean(),
          focus: focus(),
          preview: Preview.t(),
          saved_windows: Windows.t() | nil,
          pending_prefix: prefix(),
          chat_width_pct: non_neg_integer(),
          saved_file_tree: FileTreeState.t() | nil,
          help_visible: boolean()
        }

  @enforce_keys []
  defstruct active: false,
            focus: :chat,
            preview: Preview.new(),
            saved_windows: nil,
            pending_prefix: nil,
            chat_width_pct: 65,
            saved_file_tree: nil,
            help_visible: false

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

  @doc "Resets the chat panel width to the default."
  @spec reset_split(t()) :: t()
  def reset_split(%__MODULE__{} = av) do
    %{av | chat_width_pct: 65}
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
end
