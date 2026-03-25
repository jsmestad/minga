defmodule Minga.Workspace.State do
  @moduledoc """
  Core editing context that exists regardless of presentation.

  A workspace is the editing state that gets saved/restored when
  switching tabs. It works identically whether rendered as a tab in
  the traditional editor, a card on The Board, or running headless
  without any UI.

  This struct formalizes the `@per_tab_fields` boundary from
  `Minga.Editor.State`: every field here is snapshotted per tab and
  restored on tab switch.
  """

  alias Minga.Agent.UIState
  alias Minga.Completion
  alias Minga.Editor.CompletionTrigger
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.FileTree, as: FileTreeState
  alias Minga.Editor.State.Highlighting
  alias Minga.Editor.State.Mouse
  alias Minga.Editor.State.Search
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Keymap.Scope

  @typedoc "A document highlight range from the LSP server."
  @type document_highlight :: Minga.LSP.DocumentHighlight.t()

  @type t :: %__MODULE__{
          keymap_scope: Scope.scope_name(),
          buffers: Buffers.t(),
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          viewport: Viewport.t(),
          mouse: Mouse.t(),
          highlight: Highlighting.t(),
          lsp_pending: %{reference() => atom() | tuple()},
          completion: Completion.t() | nil,
          completion_trigger: CompletionTrigger.t(),
          injection_ranges: %{pid() => [Minga.UI.Highlight.InjectionRange.t()]},
          search: Search.t(),
          pending_conflict: {pid(), String.t()} | nil,
          vim: VimState.t(),
          document_highlights: [document_highlight()] | nil,
          agent_ui: UIState.t()
        }

  @enforce_keys [:viewport]
  defstruct keymap_scope: :editor,
            buffers: %Buffers{},
            windows: %Windows{},
            file_tree: %FileTreeState{},
            viewport: nil,
            mouse: %Mouse{},
            highlight: %Highlighting{},
            lsp_pending: %{},
            completion: nil,
            completion_trigger: CompletionTrigger.new(),
            injection_ranges: %{},
            search: %Search{},
            pending_conflict: nil,
            vim: VimState.new(),
            document_highlights: nil,
            agent_ui: UIState.new()

  @doc "Returns the list of field names (for snapshot/restore compatibility)."
  @spec field_names() :: [atom()]
  def field_names do
    %__MODULE__{viewport: %Viewport{top: 0, left: 0, rows: 1, cols: 1}}
    |> Map.keys()
    |> Enum.reject(&(&1 == :__struct__))
  end

  # ── Pure workspace operations ─────────────────────────────────────────────
  #
  # These are pure functions (no side effects) on WorkspaceState. The
  # Editor GenServer calls these through EditorState wrappers that handle
  # cross-cutting concerns (tab bar sync, process monitoring, etc.).

  alias Minga.Editor.Window
  alias Minga.Editor.Window.Content

  @doc "Returns the active window struct, or nil."
  @spec active_window_struct(t()) :: Window.t() | nil
  def active_window_struct(%__MODULE__{windows: ws}), do: Windows.active_struct(ws)

  @doc "Returns true if the workspace has more than one window."
  @spec split?(t()) :: boolean()
  def split?(%__MODULE__{windows: ws}), do: Windows.split?(ws)

  @doc "Updates the window struct for the given window id via a mapper function."
  @spec update_window(t(), Window.id(), (Window.t() -> Window.t())) :: t()
  def update_window(%__MODULE__{windows: ws} = wspace, id, fun) do
    %{wspace | windows: Windows.update(ws, id, fun)}
  end

  @doc """
  Invalidates render caches for all windows.

  Call when the screen layout changes (file tree toggle, agent panel toggle)
  because cached draws contain baked-in absolute coordinates that become
  wrong when column offsets shift.
  """
  @spec invalidate_all_windows(t()) :: t()
  def invalidate_all_windows(%__MODULE__{windows: ws} = wspace) do
    new_map =
      Map.new(ws.map, fn {id, window} -> {id, Window.invalidate(window)} end)

    %{wspace | windows: %{ws | map: new_map}}
  end

  @doc """
  Switches to the buffer at `idx`, making it active for the current window.

  Pure workspace operation: updates Buffers and syncs the active window.
  """
  @spec switch_buffer(t(), non_neg_integer()) :: t()
  def switch_buffer(%__MODULE__{buffers: bs} = wspace, idx) do
    %{wspace | buffers: Buffers.switch_to(bs, idx)}
    |> sync_active_window_buffer()
  end

  @doc """
  Syncs the active window's buffer reference with `buffers.active`.

  Call after any operation that changes `buffers.active` to keep the
  window tree consistent. No-op when windows aren't initialized.
  """
  @spec sync_active_window_buffer(t()) :: t()
  def sync_active_window_buffer(%__MODULE__{buffers: %{active: nil}} = wspace), do: wspace

  def sync_active_window_buffer(
        %__MODULE__{windows: %{map: windows, active: id} = ws, buffers: buffers} = wspace
      ) do
    case Map.fetch(windows, id) do
      {:ok, %Window{buffer: existing} = window} when existing != buffers.active ->
        window = %{
          Window.invalidate(window)
          | buffer: buffers.active,
            content: Content.buffer(buffers.active)
        }

        %{wspace | windows: %{ws | map: Map.put(windows, id, window)}}

      _ ->
        wspace
    end
  end

  @doc "Transitions the editing model to a new mode."
  @spec transition_mode(t(), atom(), term()) :: t()
  def transition_mode(%__MODULE__{vim: vim} = wspace, mode, mode_state \\ nil) do
    %{wspace | vim: VimState.transition(vim, mode, mode_state)}
  end

  @doc """
  Derives the keymap scope from a window's content type.

  Agent chat windows always use `:agent` scope. Buffer windows use
  `:editor` when coming from `:agent` scope, and preserve the current
  scope otherwise.
  """
  @spec scope_for_content(Content.t(), Scope.scope_name()) :: Scope.scope_name()
  def scope_for_content({:agent_chat, _pid}, _current_scope), do: :agent
  def scope_for_content({:buffer, _pid}, :agent), do: :editor
  def scope_for_content({:buffer, _pid}, current_scope), do: current_scope

  @doc """
  Returns the appropriate keymap scope for the active window's content type.
  """
  @spec scope_for_active_window(t()) :: atom()
  def scope_for_active_window(%__MODULE__{windows: %{map: map, active: active_id}}) do
    case Map.get(map, active_id) do
      %{content: content} -> scope_for_content(content, :editor)
      nil -> :editor
    end
  end
end
