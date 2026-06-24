defmodule MingaEditor.Shell.Traditional.Layout do
  @moduledoc """
  Layout computation for the Traditional shell.

  Computes layout via `Layout.GUI`. Every live frontend (macOS GUI and the Go
  TUI) advertises `semantic_ui` and renders chrome natively, so the BEAM
  reserves no rows/columns; the legacy Zig cell-grid frontend has been retired
  (#2223), so `Layout.GUI` is the only path. Shared layout operations
  (`get/1`, `put/1`, `invalidate/1`) delegate to `MingaEditor.Layout` since the
  `%Layout{}` struct and cache are shared infrastructure.
  """

  alias MingaEditor.Layout
  alias MingaEditor.State, as: EditorState

  @doc """
  Computes the complete layout for the current frame via `Layout.GUI`
  (Metal/native viewport only, no reserved chrome rows).
  """
  @spec compute(EditorState.t() | map()) :: Layout.t()
  def compute(state) do
    Layout.GUI.compute(state)
  end

  @spec get(term()) :: term()
  def get(state), do: Layout.get(state)
  @spec put(term()) :: term()
  def put(state), do: Layout.put(state)
  @spec invalidate(term()) :: term()
  def invalidate(state), do: Layout.invalidate(state)
end
