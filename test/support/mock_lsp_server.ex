defmodule Minga.Test.MockLSPServer do
  @moduledoc """
  A minimal LSP server for testing, implemented as an Elixir script.

  Speaks JSON-RPC 2.0 over stdin/stdout with Content-Length framing.
  Responds to `initialize` with basic capabilities, accepts document
  sync notifications, and can be told to publish diagnostics.

  Used by `LSP.Client` tests to verify the full protocol flow without
  requiring a real language server.

  ## Usage

  Start via `Port.open/2` pointing at `elixir` with this script as arg.
  The mock server reads from stdin and writes responses to stdout.
  """

  @doc """
  Returns the path to the mock server script.
  """
  @spec script_path() :: String.t()
  def script_path do
    Path.join([__DIR__, "mock_lsp_server_script.exs"])
  end

  @doc """
  Returns a server_config map suitable for `LSP.Client.start_link/1`.

  Uses `elixir` as the command with the mock script as the argument.
  """
  @spec server_config() :: map()
  def server_config do
    %{
      name: :mock_lsp,
      command: "elixir",
      args: [script_path()],
      root_markers: [],
      init_options: %{}
    }
  end
end
