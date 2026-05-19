defmodule MingaEditor.Agent.UIState.ReturnTarget do
  @moduledoc """
  Editor context to restore when leaving the agent view.

  The agent view is a zoom surface inside a workspace. This struct records the editor context that was active before zooming in so `q` and `Esc` can return to the same workspace instead of guessing from tab order alone.
  """

  alias Minga.Keymap.Scope
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.Windows

  @type t :: %__MODULE__{
          active_tab_id: pos_integer() | nil,
          active_buffer: pid() | nil,
          windows: Windows.t(),
          file_tree: FileTreeState.t(),
          keymap_scope: Scope.scope_name(),
          prompt_focused: boolean()
        }

  @enforce_keys [:windows, :file_tree, :keymap_scope, :prompt_focused]
  defstruct active_tab_id: nil,
            active_buffer: nil,
            windows: nil,
            file_tree: nil,
            keymap_scope: :editor,
            prompt_focused: false

  @doc "Builds a return target from the current editor context."
  @spec new(
          pos_integer() | nil,
          pid() | nil,
          Windows.t(),
          FileTreeState.t(),
          Scope.scope_name(),
          boolean()
        ) :: t()
  def new(active_tab_id, active_buffer, windows, file_tree, keymap_scope, prompt_focused)
      when (is_integer(active_tab_id) and active_tab_id > 0) or is_nil(active_tab_id) do
    %__MODULE__{
      active_tab_id: active_tab_id,
      active_buffer: active_buffer,
      windows: windows,
      file_tree: file_tree,
      keymap_scope: keymap_scope,
      prompt_focused: prompt_focused
    }
  end
end
