defmodule MingaEditor.Shell.Traditional.Layout do
  @moduledoc """
  Layout computation for the Traditional shell.

  Dispatches to `Layout.TUI` or `Layout.GUI` based on frontend capabilities.
  Shared layout operations (`get/1`, `put/1`, `invalidate/1`) delegate to
  `MingaEditor.Layout` since the `%Layout{}` struct and cache are shared infrastructure.
  """

  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState

  @doc """
  Computes the complete layout for the current frame.

  Uses TUI layout (with tab bar, file tree, modeline rows) for terminal
  frontends and GUI layout (Metal viewport only) for native GUI frontends.
  """
  @spec compute(EditorState.t()) :: Layout.t()
  def compute(state) do
    if MingaEditor.Frontend.gui?(state.capabilities) do
      Layout.GUI.compute(state)
    else
      MingaEditor.Shell.Traditional.Layout.TUI.compute(state)
    end
  end

  defdelegate get(state), to: Layout
  defdelegate put(state), to: Layout
  defdelegate invalidate(state), to: Layout
end
