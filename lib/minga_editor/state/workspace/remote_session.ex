defmodule MingaEditor.State.Workspace.RemoteSession do
  @moduledoc """
  Durable remote session identity for an agent workspace.

  Workspaces own remote identity. Tabs may project this data for display, but lifecycle code should read the workspace copy so reconnect and teardown still work when a file tab is active or the agent tab has been closed.
  """

  @typedoc "Remote connection status."
  @type connection_status :: :connected | :disconnected | :ended | :unavailable

  @typedoc "Durable remote session metadata for a workspace."
  @type t :: %__MODULE__{
          server_name: String.t(),
          session_id: String.t(),
          connection_status: connection_status()
        }

  @enforce_keys [:server_name, :session_id, :connection_status]
  defstruct [:server_name, :session_id, :connection_status]

  @doc "Creates durable remote metadata."
  @spec new(String.t(), String.t(), connection_status()) :: t()
  def new(server_name, session_id, status \\ :connected)
      when is_binary(server_name) and is_binary(session_id) and
             status in [:connected, :disconnected, :ended, :unavailable] do
    %__MODULE__{server_name: server_name, session_id: session_id, connection_status: status}
  end

  @doc "Updates the connection status."
  @spec set_connection_status(t(), connection_status()) :: t()
  def set_connection_status(%__MODULE__{} = remote_session, status)
      when status in [:connected, :disconnected, :ended, :unavailable] do
    %{remote_session | connection_status: status}
  end

  @doc "Returns true when the remote metadata points at the server/session pair."
  @spec matches?(t(), String.t(), String.t()) :: boolean()
  def matches?(
        %__MODULE__{server_name: server_name, session_id: session_id},
        server_name,
        session_id
      ),
      do: true

  def matches?(%__MODULE__{}, _server_name, _session_id), do: false

  @doc "Returns true when the remote metadata belongs to the server."
  @spec server?(t(), String.t()) :: boolean()
  def server?(%__MODULE__{server_name: server_name}, server_name), do: true
  def server?(%__MODULE__{}, _server_name), do: false
end
