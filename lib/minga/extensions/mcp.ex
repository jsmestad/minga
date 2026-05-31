defmodule Minga.Extensions.MCP do
  @moduledoc """
  Optional MCP extension marker and lifecycle hook.

  MCP support is intentionally opt-in. User config enables this extension with `extension Minga.Extensions.MCP`, then declares stdio servers with `mcp_server/2`. The native agent provider only exposes the lightweight MCP meta-tools while this extension is running, so users who do not enable MCP get no extra tools, no extra prompt text, and no server processes.
  """

  use Minga.Extension.Editor

  @impl true
  @spec name() :: atom()
  def name, do: :minga_mcp

  @impl true
  @spec description() :: String.t()
  def description, do: "MCP tool server integration"

  @impl true
  @spec version() :: String.t()
  def version, do: "0.1.0"

  @impl true
  @spec init(keyword()) :: {:ok, map()} | {:error, term()}
  def init(_config), do: {:ok, %{}}

  @impl true
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_config) do
    %{
      id: __MODULE__.Supervisor,
      start: {__MODULE__.Supervisor, :start_link, [[]]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @doc "Returns true when the optional MCP extension is currently running."
  @spec enabled?() :: boolean()
  def enabled? do
    case Minga.Extension.Registry.get(name()) do
      {:ok, %{status: :running}} -> true
      _other -> false
    end
  catch
    :exit, reason ->
      Minga.Log.warning(:agent, "MCP extension status unavailable: #{inspect(reason)}")
      false
  end
end
