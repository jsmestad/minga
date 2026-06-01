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
    with :ok <- ensure_daemon(url),
         {:ok, remote_node} <- connect_remote_node(url) do
      erpc_result(remote_node, MingaAgent.RemoteAPI, :stop_workdir_session, [url.path])
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

    with {:ok, remote_node} <- distribution_atom(node_name) do
      connect_remote_node(remote_node, node_connect_attempts(), node_connect_retry_interval_ms())
    end
  end

  @spec connect_remote_node(node(), pos_integer(), non_neg_integer()) ::
          {:ok, node()} | {:error, term()}
  defp connect_remote_node(remote_node, attempts_left, interval_ms) do
    case Node.connect(remote_node) do
      true ->
        {:ok, remote_node}

      false when attempts_left > 1 ->
        wait_for_retry(interval_ms)
        connect_remote_node(remote_node, attempts_left - 1, interval_ms)

      false ->
        {:error, {:node_connect_failed, remote_node}}

      :ignored ->
        {:error, :distribution_not_started}
    end
  end

  @spec wait_for_retry(non_neg_integer()) :: :ok
  defp wait_for_retry(0), do: :ok

  defp wait_for_retry(interval_ms) do
    receive do
    after
      interval_ms -> :ok
    end
  end

  @spec node_connect_attempts() :: pos_integer()
  defp node_connect_attempts do
    :minga
    |> Application.get_env(:remote_node_connect_attempts, 20)
    |> positive_integer_or_default(20)
  end

  @spec node_connect_retry_interval_ms() :: non_neg_integer()
  defp node_connect_retry_interval_ms do
    :minga
    |> Application.get_env(:remote_node_connect_retry_interval_ms, 100)
    |> non_negative_integer_or_default(100)
  end

  @spec positive_integer_or_default(term(), pos_integer()) :: pos_integer()
  defp positive_integer_or_default(value, _default) when is_integer(value) and value > 0,
    do: value

  defp positive_integer_or_default(_value, default), do: default

  @spec non_negative_integer_or_default(term(), non_neg_integer()) :: non_neg_integer()
  defp non_negative_integer_or_default(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp non_negative_integer_or_default(_value, default), do: default

  @spec erpc(node(), module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp erpc(remote_node, module, function, args) do
    remote_node
    |> :erpc.call(module, function, args, 10_000)
    |> normalize_erpc_result()
  catch
    :exit, reason -> {:error, reason}
  end

  @spec normalize_erpc_result(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_erpc_result({:ok, value}), do: {:ok, value}
  defp normalize_erpc_result({:error, reason}), do: {:error, reason}
  defp normalize_erpc_result(value), do: {:ok, value}

  @spec erpc_result(node(), module(), atom(), [term()]) :: :ok | {:error, term()}
  defp erpc_result(remote_node, module, function, args) do
    case erpc(remote_node, module, function, args) do
      {:ok, :ok} -> :ok
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

  @spec distribution_atom(String.t()) :: {:ok, node()} | {:error, :invalid_node_name}
  defp distribution_atom(node_name) when is_binary(node_name) do
    if valid_node_name?(node_name) do
      {:ok, :erlang.binary_to_atom(node_name, :utf8)}
    else
      {:error, :invalid_node_name}
    end
  end

  @spec valid_node_name?(String.t()) :: boolean()
  defp valid_node_name?(node_name) do
    byte_size(node_name) <= 255 and Regex.match?(~r/^[A-Za-z0-9_.@-]+$/, node_name)
  end
end
