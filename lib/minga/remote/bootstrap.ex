defmodule Minga.Remote.Bootstrap do
  @moduledoc "Bootstraps and controls remote agent sessions over SSH plus the existing RemoteAPI broker."

  alias Minga.Remote.SessionURL

  @enforce_keys [:server_name, :remote_node, :session_id, :pid, :token, :workdir]
  defstruct [:server_name, :remote_node, :session_id, :pid, :token, :workdir]

  @type attach_result :: %__MODULE__{
          server_name: String.t(),
          remote_node: node(),
          session_id: String.t(),
          pid: pid(),
          token: String.t(),
          workdir: String.t()
        }

  @type session_row :: %{
          session_id: String.t(),
          workdir: String.t() | nil,
          status: atom(),
          recent: String.t() | nil
        }

  @doc "Creates or reuses the session for an SSH URL's server-side working directory."
  @spec attach(SessionURL.t()) :: {:ok, attach_result()} | {:error, term()}
  def attach(%SessionURL{} = url) do
    with :ok <- ensure_daemon(url),
         {:ok, remote_node} <- connect_remote_node(url),
         {:ok, info} <-
           erpc(remote_node, MingaAgent.RemoteAPI, :start_or_get_for_workdir, [url.path]) do
      {:ok,
       %__MODULE__{
         server_name: SessionURL.server_name(url),
         remote_node: remote_node,
         session_id: info.session_id,
         pid: info.pid,
         token: info.token,
         workdir: url.path
       }}
    end
  end

  @doc "Lists remote sessions for a host URL."
  @spec sessions(SessionURL.t()) :: {:ok, [session_row()]} | {:error, term()}
  def sessions(%SessionURL{} = url) do
    with :ok <- ensure_daemon(url),
         {:ok, remote_node} <- connect_remote_node(url),
         {:ok, sessions} <- erpc(remote_node, MingaAgent.RemoteAPI, :list_sessions, []) do
      {:ok, Enum.map(sessions, &session_row/1)}
    end
  end

  @doc "Stops the stable session for an SSH URL's server-side working directory."
  @spec kill_session(SessionURL.t()) :: :ok | {:error, term()}
  def kill_session(%SessionURL{} = url) do
    with {:ok, result} <- attach(url) do
      erpc_result(result.remote_node, MingaAgent.RemoteAPI, :stop_session, [
        result.session_id,
        result.token
      ])
    end
  end

  @doc "Ensures the user daemon is running through SSH."
  @spec ensure_daemon(SessionURL.t()) :: :ok | {:error, term()}
  def ensure_daemon(%SessionURL{} = url) do
    if Application.get_env(:minga, :remote_skip_ssh_bootstrap, false) do
      :ok
    else
      command =
        "systemctl --user start minga-headless.service || launchctl kickstart -k gui/$(id -u)/com.minga.headless"

      args = ssh_args(url) ++ [command]

      case System.cmd("ssh", args, stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:ssh_bootstrap_failed, status, String.trim(output)}}
      end
    end
  end

  @doc "Connects to the conventional distributed node for a remote host."
  @spec connect_remote_node(SessionURL.t()) :: {:ok, node()} | {:error, term()}
  def connect_remote_node(%SessionURL{host: host}) do
    node_name = Application.get_env(:minga, :remote_node_name, "minga_server@#{host}")
    remote_node = String.to_atom(node_name)

    case Node.connect(remote_node) do
      true -> {:ok, remote_node}
      false -> {:error, {:node_connect_failed, remote_node}}
      :ignored -> {:error, :distribution_not_started}
    end
  end

  @spec erpc(node(), module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp erpc(remote_node, module, function, args) do
    {:ok, :erpc.call(remote_node, module, function, args, 10_000)}
  catch
    :exit, reason -> {:error, reason}
  end

  @spec erpc_result(node(), module(), atom(), [term()]) :: :ok | {:error, term()}
  defp erpc_result(remote_node, module, function, args) do
    case erpc(remote_node, module, function, args) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_result, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ssh_args(SessionURL.t()) :: [String.t()]
  defp ssh_args(%SessionURL{port: nil} = url), do: ssh_destination_args(url)

  defp ssh_args(%SessionURL{port: port} = url) do
    ["-p", Integer.to_string(port)] ++ ssh_destination_args(url)
  end

  @spec ssh_destination_args(SessionURL.t()) :: [String.t()]
  defp ssh_destination_args(%SessionURL{user: nil, host: host}), do: ["--", host]
  defp ssh_destination_args(%SessionURL{user: user, host: host}), do: ["-l", user, "--", host]

  @spec session_row(MingaAgent.RemoteAPI.session_info()) :: session_row()
  defp session_row(info) do
    meta = info.metadata

    %{
      session_id: info.session_id,
      workdir: Map.get(meta, :workdir),
      status: Map.get(meta, :status, :unknown),
      recent: Map.get(meta, :first_prompt)
    }
  end
end
