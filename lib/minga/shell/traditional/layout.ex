defmodule Minga.Shell.Traditional.Layout do
  @moduledoc """
  Layout computation for the Traditional shell.

  Delegates to `Minga.Editor.Layout` which contains the actual layout
  computation logic. As the shell independence refactor progresses,
  the implementation will move here from `editor/layout.ex`.

  This module exists to establish the correct dependency direction:
  the Traditional shell owns its own layout decisions, the Editor
  GenServer just calls them through the Shell behaviour.
  """

  defdelegate compute(state), to: Minga.Editor.Layout
  defdelegate get(state), to: Minga.Editor.Layout
  defdelegate put(state), to: Minga.Editor.Layout
  defdelegate invalidate(state), to: Minga.Editor.Layout
end
