defmodule Mix.Tasks.Native.Build.Tui do
  @moduledoc """
  Builds native binaries required by the default TUI release.

  The packaged TUI ships:

    - the Go/Bubble Tea renderer (`minga-renderer-go`), the default terminal frontend;
    - the Zig renderer (`minga-renderer`), the `MINGA_FRONTEND=zig` escape hatch;
    - the Zig parser (`minga-parser`) and hook runner (`minga-hook-runner`).

  Both renderers ship so the escape hatch keeps working from a single binary.
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

    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaGoTui.run([]),
      "Go TUI build failed"
    )
  end
end
