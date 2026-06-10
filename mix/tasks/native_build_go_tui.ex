defmodule Mix.Tasks.Native.Build.GoTui do
  @moduledoc """
  Builds the Go TUI renderer (the default terminal frontend).
  """

  use Mix.Task

  @shortdoc "Builds the Go TUI renderer (default terminal frontend)"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaGoTui.run([]),
      "Go TUI build failed"
    )
  end
end
