defmodule Mix.Tasks.Native.Build.Tui do
  @moduledoc """
  Builds native binaries required by the default TUI release.

  The packaged TUI ships:

    - the Go/Bubble Tea renderer (`minga-renderer-go`), the terminal frontend;
    - the Zig parser (`minga-parser`), hook runner (`minga-hook-runner`),
      demand-driven shell output reader (`minga-shell-output-reader`), and
      overlay clone helper (`minga-clone-tree`).
  """

  use Mix.Task

  @shortdoc "Builds native binaries for the default TUI release"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaZig.run([]),
      "native TUI build failed"
    )

    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaGoTui.run([]),
      "Go TUI build failed"
    )

    Mix.Task.run("native.build.apple")
  end
end
