defmodule MingaAgent.Gateway.Server do
  @moduledoc """
  Starts and owns the Bandit HTTP/WebSocket listener.

  Does not start by default. Started on-demand when the headless runtime
  boots with `gateway: true` or when `MingaAgent.Runtime.start_gateway/1`
  is called. The Editor never starts this.

  ## Port selection

  Default port is 4820. Pass `port: 0` to let the OS pick an available
  port (useful for tests). Retrieve the actual port with `port/1`.
  """

  use GenServer

  @default_port 4820
  @default_ip {127, 0, 0, 1}

  @type state :: %{
          bandit: pid(),
          port: non_neg_integer(),
          ip: :inet.ip_address(),
          auth_token?: boolean()
        }

  @doc "Starts the gateway server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the port the gateway is listening on."
  @spec port(GenServer.server()) :: non_neg_integer()
  def port(server \\ __MODULE__) do
    GenServer.call(server, :port)
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()} | {:stop, term()}
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    ip = Keyword.get(opts, :ip, @default_ip)
    auth_token = Keyword.get(opts, :auth_token, System.get_env("MINGA_GATEWAY_TOKEN"))
    Application.put_env(:minga, :gateway_auth_token, auth_token)

    case Bandit.start_link(
           plug: MingaAgent.Gateway.Router,
           ip: ip,
           port: port,
           scheme: :http,
           thousand_island_options: [num_acceptors: 2]
         ) do
      {:ok, bandit_pid} ->
        actual_port = resolve_port(bandit_pid, port)
        log_started(actual_port, ip, auth_token)

        {:ok,
         %{
           bandit: bandit_pid,
           port: actual_port,
           ip: ip,
           auth_token?: token_configured?(auth_token)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl GenServer
  def terminate(_reason, %{bandit: pid}) do
    Application.delete_env(:minga, :gateway_auth_token)
    if Process.alive?(pid), do: Supervisor.stop(pid)
    :ok
  end

  # When port 0 is requested, Bandit picks a random port. We extract
  # the actual port from the ThousandIsland listener via its info API.
  @spec resolve_port(pid(), non_neg_integer()) :: non_neg_integer()
  defp resolve_port(_bandit_pid, port) when port > 0, do: port

  defp resolve_port(bandit_pid, 0) do
    case ThousandIsland.listener_info(bandit_pid) do
      {:ok, {_address, actual_port}} -> actual_port
      _ -> 0
    end
  end

  @spec log_started(non_neg_integer(), :inet.ip_address(), String.t() | nil) :: :ok
  defp log_started(port, ip, auth_token) do
    auth_text =
      if token_configured?(auth_token),
        do: "auth enabled",
        else: "WebSocket disabled until MINGA_GATEWAY_TOKEN is set"

    Minga.Log.info(:agent, "[Gateway] listening on #{:inet.ntoa(ip)}:#{port} (#{auth_text})")
  end

  @spec token_configured?(String.t() | nil) :: boolean()
  defp token_configured?(token) when is_binary(token), do: token != ""
  defp token_configured?(_token), do: false
end
