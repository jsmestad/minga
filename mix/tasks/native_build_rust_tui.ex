defmodule Mix.Tasks.Native.Build.RustTui do
  @moduledoc """
  Builds the experimental Rust TUI renderer.
  """

  use Mix.Task

  @shortdoc "Builds the experimental Rust TUI renderer"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaRustTui.run([]),
      "Rust TUI build failed"
    )
  end
end
