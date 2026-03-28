defmodule Minga.Shell.Traditional.Renderer do
  @moduledoc """
  Render pipeline for the Traditional shell.

  Orchestrates the full render cycle: invalidation, layout, scroll,
  content, chrome, compose, and emit. This is the Traditional shell's
  implementation of the Shell.render callback.

  Delegates to `Minga.Editor.Renderer` which contains the actual render
  logic. As the shell independence refactor progresses, the implementation
  will move here.
  """

  @spec render(term()) :: term()
  def render(%{workspace: %{buffers: %{active: nil}}} = state) do
    Minga.Editor.Renderer.render_dashboard(state)
  end

  def render(state) do
    Minga.Editor.Renderer.render_buffer(state)
  end
end
