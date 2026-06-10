defmodule MingaEditor.Shell.Traditional.Layout do
  @moduledoc """
  Layout computation for the Traditional shell.

  Dispatches to `Layout.TUI` or `Layout.GUI` based on the frontend's semantic
  capability. Every live frontend (macOS GUI and the Go TUI) advertises
  `semantic_ui` and uses `Layout.GUI` (the frontend renders chrome natively, so
  the BEAM reserves no rows/columns); only the legacy Zig cell-grid frontend
  uses `Layout.TUI`. Shared layout operations (`get/1`, `put/1`, `invalidate/1`)
  delegate to `MingaEditor.Layout` since the `%Layout{}` struct and cache are
  shared infrastructure.
  """

  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState

  @doc """
  Computes the complete layout for the current frame.

  Uses GUI layout (Metal/native viewport only, no reserved chrome rows) for
  semantic frontends and TUI layout (with tab bar, file tree, modeline rows)
  for the legacy Zig cell-grid frontend.
  """
  @spec compute(EditorState.t() | map()) :: Layout.t()
  def compute(state) do
    if MingaEditor.Frontend.semantic_ui?(state.capabilities) do
      Layout.GUI.compute(state)
    else
      MingaEditor.Shell.Traditional.Layout.TUI.compute(state)
    end
  end

  defdelegate get(state), to: Layout
  defdelegate put(state), to: Layout
  defdelegate invalidate(state), to: Layout
end
