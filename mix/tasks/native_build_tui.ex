defmodule Mix.Tasks.Native.Build.Tui do
  @moduledoc """
  Builds native binaries required by the default TUI release.

  The default packaged TUI uses the Zig renderer, parser, and hook runner. The experimental Go renderer has its own opt-in task.
  """

  use Mix.Task

  @shortdoc "Builds native binaries for the default TUI release"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaZig.run(profile: :full),
      "native TUI build failed"
    )
  end
end
