defmodule Minga.Test.StateFactory do
  @moduledoc """
  Builds minimal valid `EditorState` structs for tests.

  Use this instead of constructing bare maps. The compiler verifies
  struct field names at compile time, so typos and stale field references
  are caught immediately rather than silently failing to match at runtime.

  ## Usage

      state = StateFactory.build()
      state = StateFactory.build(vim: %VimState{mode: :insert})
      state = StateFactory.build(buffers: %Buffers{active: buf, list: [buf]})
  """

  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Workspace.State, as: WorkspaceState

  @doc """
  Builds a minimal EditorState with sensible defaults.

  Accepts keyword options to override workspace fields or top-level fields.

  ## Workspace field overrides

  Any field that belongs to `Workspace.State` (vim, buffers, windows,
  viewport, keymap_scope, etc.) is routed into the workspace automatically.

  ## Top-level field overrides

  Fields that belong to `EditorState` directly (theme, tab_bar, agent,
  picker_ui, status_msg, etc.) are set at the top level.

  ## Examples

      # Minimal state (no buffer, normal mode)
      state = StateFactory.build()

      # With a specific buffer
      state = StateFactory.build(buffers: %Buffers{active: buf, list: [buf]})

      # With vim mode
      state = StateFactory.build(vim: %VimState{mode: :insert})

      # With both workspace and top-level overrides
      state = StateFactory.build(
        buffers: %Buffers{active: buf},
        theme: Minga.Theme.get!(:doom_one),
        tab_bar: some_tab_bar
      )
  """
  @spec build(keyword()) :: EditorState.t()
  def build(opts \\ []) do
    ws_fields = WorkspaceState.fields()

    {ws_overrides, top_overrides} =
      Enum.split_with(opts, fn {k, _v} -> k in ws_fields end)

    workspace =
      struct!(
        %WorkspaceState{viewport: Viewport.new(24, 80)},
        ws_overrides
      )

    struct!(
      %EditorState{port_manager: nil, workspace: workspace},
      top_overrides
    )
  end
end
