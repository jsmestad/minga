defmodule Mix.Tasks.Protocol.Gen do
  @moduledoc """
  Generates protocol opcode artifacts from `docs/protocol_schema.toml`.

  The schema is the source of truth. Generated protocol artifacts are written under `.generated/protocol/`, which is ignored by Git and consumed by local build steps.
  """

  use Mix.Task

  @shortdoc "Generates protocol opcode artifacts"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Minga.Mix.ProtocolGenerator.run(args)
  end
end
