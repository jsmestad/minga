defmodule Mix.Tasks.Native.Build.Support do
  @moduledoc """
  Builds native support binaries required by BEAM tests and GUI packaging.

  This builds the Zig parser and hook runner. It is the explicit replacement for the old implicit native build hidden inside `mix compile`.
  """

  use Mix.Task

  @shortdoc "Builds native parser and hook-runner support binaries"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(_args) do
    Mix.Tasks.Native.Build.Result.raise_on_error(
      Mix.Tasks.Compile.MingaZig.run([]),
      "native support build failed"
    )
  end
end
