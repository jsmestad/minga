defmodule Mix.Tasks.Protocol.Gen do
  @moduledoc """
  Generates protocol opcode artifacts from `docs/protocol_schema.toml`.

  The schema is the source of truth. Commit refreshed Elixir and Go outputs; Swift and Zig outputs are local build inputs.
  """

  use Mix.Task

  @shortdoc "Generates protocol opcode artifacts"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    Minga.Mix.ProtocolGenerator.run(args)
  end
end
