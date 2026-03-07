defmodule Minga.Agent.View.State do
  @moduledoc """
  Agentic view layout state.

  Tracks whether the full-screen agentic view is active, which panel has
  focus, the file viewer scroll position, and the saved window layout to
  restore when the view is closed.

  Stored as a single sub-struct in `EditorState` so the top-level struct
  stays within Credo's 31-field limit.
  """

  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Windows

  @typedoc "Which panel has keyboard focus inside the agentic view."
  @type focus :: :chat | :file_viewer

  @typedoc "Agentic view sub-state."
  @type t :: %__MODULE__{
          active: boolean(),
          focus: focus(),
          file_viewer_scroll: non_neg_integer(),
          saved_windows: Windows.t() | nil,
          pending_g: boolean(),
          saved_file_tree: FileTreeState.t() | nil
        }

  @enforce_keys []
  defstruct active: false,
            focus: :chat,
            file_viewer_scroll: 0,
            saved_windows: nil,
            pending_g: false,
            saved_file_tree: nil

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
        pending_g: false
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
         pending_g: false
     }, saved_windows, saved_file_tree}
  end

  @doc "Switches focus to the given panel."
  @spec set_focus(t(), focus()) :: t()
  def set_focus(%__MODULE__{} = av, focus) when focus in [:chat, :file_viewer] do
    %{av | focus: focus}
  end

  @doc "Scrolls the file viewer down by the given number of lines."
  @spec scroll_viewer_down(t(), pos_integer()) :: t()
  def scroll_viewer_down(%__MODULE__{} = av, amount) do
    %{av | file_viewer_scroll: av.file_viewer_scroll + amount}
  end

  @doc "Scrolls the file viewer up by the given number of lines, clamped at 0."
  @spec scroll_viewer_up(t(), pos_integer()) :: t()
  def scroll_viewer_up(%__MODULE__{} = av, amount) do
    %{av | file_viewer_scroll: max(av.file_viewer_scroll - amount, 0)}
  end

  @doc "Scrolls the file viewer to the top (offset 0)."
  @spec scroll_viewer_to_top(t()) :: t()
  def scroll_viewer_to_top(%__MODULE__{} = av) do
    %{av | file_viewer_scroll: 0}
  end

  @doc "Scrolls the file viewer to a large offset (renderer clamps to actual content)."
  @spec scroll_viewer_to_bottom(t()) :: t()
  def scroll_viewer_to_bottom(%__MODULE__{} = av) do
    %{av | file_viewer_scroll: 999_999}
  end

  @doc "Sets the pending_g flag for tracking gg two-key sequences."
  @spec set_pending_g(t(), boolean()) :: t()
  def set_pending_g(%__MODULE__{} = av, pending) when is_boolean(pending) do
    %{av | pending_g: pending}
  end
end
