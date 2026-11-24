defmodule MingaAgent.MCP.GenerationTransport do
  @moduledoc false

  # A transport double whose value changes on every call.
  # Each request reports the generation it received, so a test can prove the client installs every returned value.

  @behaviour MingaAgent.MCP.Transport

  alias MingaAgent.MCP.ServerConfig

  @enforce_keys [:test_pid, :generation]
  defstruct [:test_pid, :generation]

  @type t :: %__MODULE__{test_pid: pid(), generation: non_neg_integer()}

  @impl MingaAgent.MCP.Transport
  @spec start(ServerConfig.t(), pid(), keyword()) :: {:ok, t()}
  def start(%ServerConfig{}, _owner, opts),
    do: {:ok, %__MODULE__{test_pid: Keyword.fetch!(opts, :test_pid), generation: 0}}

  @impl MingaAgent.MCP.Transport
  @spec request(t(), map(), timeout()) :: MingaAgent.MCP.Transport.request_result()
  def request(%__MODULE__{} = transport, %{"method" => method}, _timeout) do
    send(transport.test_pid, {:generation_transport_request, method, transport.generation})
    next = advance(transport)

    case method do
      "initialize" -> {:ok, %{}, next}
      "tools/list" -> {:ok, %{"tools" => []}, next}
      "tools/call" -> {:error, :timeout, next}
    end
  end

  @impl MingaAgent.MCP.Transport
  @spec notify(t(), map()) :: :ok
  def notify(%__MODULE__{}, _message), do: :ok

  @impl MingaAgent.MCP.Transport
  @spec stop(t()) :: :ok
  def stop(%__MODULE__{}), do: :ok

  @impl MingaAgent.MCP.Transport
  @spec handle_transport_info(term(), t()) :: {:ok, t()}
  def handle_transport_info(:generation_transport_data, %__MODULE__{} = transport),
    do: {:ok, advance(transport)}

  def handle_transport_info(_message, %__MODULE__{} = transport), do: {:ok, transport}

  @spec advance(t()) :: t()
  defp advance(%__MODULE__{generation: generation} = transport),
    do: %{transport | generation: generation + 1}
end
