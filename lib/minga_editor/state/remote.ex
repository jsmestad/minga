defmodule MingaEditor.State.Remote do
  @moduledoc "State for remote agent sessions and read-only remote file buffers."

  @type session_metadata :: MingaAgent.SessionMetadata.t() | map()
  @type session_entry :: {String.t(), pid(), session_metadata()}
  @type connection_status :: :connected | :disconnected | :ended | :unavailable
  @type remote_file_key :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          sessions: %{String.t() => [session_entry()]},
          server_status: %{String.t() => connection_status()},
          buffers: %{remote_file_key() => pid()}
        }

  defstruct sessions: %{},
            server_status: %{},
            buffers: %{}

  @doc "Stores the latest discovered remote sessions for a server."
  @spec put_sessions(t(), String.t(), [session_entry()]) :: t()
  def put_sessions(%__MODULE__{} = remote, server_name, sessions)
      when is_binary(server_name) and is_list(sessions) do
    %{remote | sessions: Map.put(remote.sessions, server_name, sessions)}
  end

  @doc "Returns all discovered remote sessions grouped by server name."
  @spec sessions(t()) :: %{String.t() => [session_entry()]}
  def sessions(%__MODULE__{} = remote), do: remote.sessions

  @doc "Marks a server's connection status."
  @spec put_server_status(t(), String.t(), connection_status()) :: t()
  def put_server_status(%__MODULE__{} = remote, server_name, status)
      when is_binary(server_name) and status in [:connected, :disconnected, :ended, :unavailable] do
    %{remote | server_status: Map.put(remote.server_status, server_name, status)}
  end

  @doc "Returns a server's known connection status."
  @spec server_status(t(), String.t()) :: connection_status()
  def server_status(%__MODULE__{} = remote, server_name) when is_binary(server_name) do
    Map.get(remote.server_status, server_name, :disconnected)
  end

  @doc "Tracks the buffer pid used to display a remote file."
  @spec put_buffer(t(), String.t(), String.t(), pid()) :: t()
  def put_buffer(%__MODULE__{} = remote, server_name, path, buffer)
      when is_binary(server_name) and is_binary(path) and is_pid(buffer) do
    %{remote | buffers: Map.put(remote.buffers, {server_name, path}, buffer)}
  end

  @doc "Finds an open buffer for a remote file."
  @spec buffer(t(), String.t(), String.t()) :: pid() | nil
  def buffer(%__MODULE__{} = remote, server_name, path)
      when is_binary(server_name) and is_binary(path) do
    Map.get(remote.buffers, {server_name, path})
  end
end
