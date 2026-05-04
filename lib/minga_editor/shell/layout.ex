defmodule MingaEditor.Shell.Layout do
  @moduledoc """
  Behaviour: how a shell computes spatial layout for the current state.

  Carved out of `MingaEditor.Shell` so a shell that only contributes
  layout (e.g., a hypothetical pane-only test fixture) can implement
  this contract alone without the full shell surface.
  """

  @doc """
  Returns a layout struct with named rectangles for each UI region.
  The shell decides what regions exist (tab bar, modeline, file tree,
  editor panes, agent panel, bottom panel, etc.).
  """
  @callback compute_layout(editor_state :: term()) :: MingaEditor.Layout.t()
end
