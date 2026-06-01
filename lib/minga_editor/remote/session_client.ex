defmodule MingaEditor.Remote.SessionClient do
  @moduledoc "Editor-side client for brokered remote agent session calls."

  alias MingaAgent.RemoteAPI
  alias MingaAgent.RemoteAPI.AttachResult
  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.Session
  alias MingaAgent.SessionStore

  @type remote_node :: node()
  @type session_id :: String.t()
  @type token :: String.t()

  @doc "Lists live sessions on a remote node."
  @spec list_sessions(remote_node()) :: {:ok, [RemoteAPI.session_info()]} | {:error, term()}
  def list_sessions(remote_node) when is_atom(remote_node) do
    case erpc(remote_node, :list_sessions, [], 5_000) do
      sessions when is_list(sessions) -> {:ok, sessions}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @doc "Starts a new session on a remote node."
  @spec start_session(remote_node(), keyword()) :: {:ok, SessionInfo.t()} | {:error, term()}
  def start_session(remote_node, opts) when is_atom(remote_node) and is_list(opts) do
    case erpc(remote_node, :start_session, [opts], 10_000) do
      {:ok, %SessionInfo{} = info} -> {:ok, info}
      {:ok, %{session_id: _session_id, pid: _pid, token: _token} = info} -> {:ok, info}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @doc "Attaches as the driver to a remote session by id."
  @spec attach_driver(remote_node(), session_id(), non_neg_integer(), pid()) ::
          {:ok, AttachResult.t()} | {:error, term()}
  def attach_driver(remote_node, session_id, last_seen_event_id, client_pid \\ self())
      when is_atom(remote_node) and is_binary(session_id) and is_integer(last_seen_event_id) and
             last_seen_event_id >= 0 and is_pid(client_pid) do
    with {:ok, token} <- session_token(remote_node, session_id) do
      attach_driver(remote_node, session_id, token, last_seen_event_id, client_pid)
    end
  end

  @doc "Attaches as the driver to a remote session with a known token."
  @spec attach_driver(remote_node(), session_id(), token(), non_neg_integer(), pid()) ::
          {:ok, AttachResult.t()} | {:error, term()}
  def attach_driver(remote_node, session_id, token, last_seen_event_id, client_pid)
      when is_atom(remote_node) and is_binary(session_id) and is_binary(token) and
             is_integer(last_seen_event_id) and last_seen_event_id >= 0 and is_pid(client_pid) do
    opts = [role: :driver, last_seen_event_id: last_seen_event_id]

    case erpc(remote_node, :attach, [session_id, token, client_pid, opts], 10_000) do
      {:ok, %AttachResult{role: :driver} = result} -> {:ok, result}
      {:ok, %{role: :driver} = result} -> {:ok, result}
      {:ok, %{role: :viewer}} -> {:error, :not_driver}
      {:error, _reason} = error -> error
      other -> {:error, other}
    end
  end

  @doc "Sends a prompt through the remote broker as the attached driver."
  @spec send_prompt(pid(), String.t() | [ReqLLM.Message.ContentPart.t()], pid()) ::
          :ok | {:queued, :steering} | {:error, term()}
  def send_prompt(remote_pid, prompt, client_pid \\ self())
      when is_pid(remote_pid) and is_pid(client_pid) and (is_binary(prompt) or is_list(prompt)) do
    with {:ok, session_id, token} <- credentials_for_pid(remote_pid) do
      erpc(node(remote_pid), :send_prompt, [session_id, token, client_pid, prompt], 10_000)
    end
  end

  @doc "Responds to a remote tool approval as the attached driver."
  @spec approve(pid(), String.t() | nil, Session.approval_decision(), pid()) ::
          :ok | {:error, term()}
  def approve(remote_pid, approval_id, decision, client_pid \\ self())
      when is_pid(remote_pid) and (is_binary(approval_id) or is_nil(approval_id)) and
             decision in [:approve, :approve_session, :approve_turn, :reject] and
             is_pid(client_pid) do
    with {:ok, session_id, token} <- credentials_for_pid(remote_pid) do
      erpc(
        node(remote_pid),
        :approve,
        [session_id, token, client_pid, approval_id, decision],
        10_000
      )
    end
  end

  @doc "Detaches a client from a remote session by id."
  @spec detach(remote_node(), session_id(), pid()) :: :ok | {:error, term()}
  def detach(remote_node, session_id, client_pid \\ self())
      when is_atom(remote_node) and is_binary(session_id) and is_pid(client_pid) do
    with {:ok, token} <- session_token(remote_node, session_id) do
      erpc(remote_node, :detach, [session_id, token, client_pid], 5_000)
    end
  end

  @doc "Stops a remote session by pid."
  @spec stop_session_pid(pid()) :: :ok | {:error, term()}
  def stop_session_pid(remote_pid) when is_pid(remote_pid) do
    with {:ok, session_id} <- session_id_for_pid(node(remote_pid), remote_pid) do
      stop_session(node(remote_pid), session_id)
    end
  end

  @doc "Stops a remote session by id."
  @spec stop_session(remote_node(), session_id()) :: :ok | {:error, term()}
  def stop_session(remote_node, session_id) when is_atom(remote_node) and is_binary(session_id) do
    with {:ok, token} <- session_token(remote_node, session_id) do
      erpc(remote_node, :stop_session, [session_id, token], 5_000)
    end
  end

  @doc "Begins a server-side manual OAuth flow for a remote attached driver."
  @spec begin_oauth(pid(), pid()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def begin_oauth(remote_pid, client_pid \\ self())
      when is_pid(remote_pid) and is_pid(client_pid) do
    with {:ok, session_id, token} <- credentials_for_pid(remote_pid) do
      erpc(node(remote_pid), :begin_oauth, [session_id, token, client_pid], 10_000)
    end
  end

  @doc "Completes a server-side manual OAuth flow for a remote attached driver."
  @spec complete_oauth(pid(), String.t(), String.t(), pid()) ::
          {:ok, :openai} | {:error, term()}
  def complete_oauth(remote_pid, ref, pasted, client_pid \\ self())
      when is_pid(remote_pid) and is_binary(ref) and is_binary(pasted) and is_pid(client_pid) do
    with {:ok, session_id, token} <- credentials_for_pid(remote_pid) do
      erpc(
        node(remote_pid),
        :complete_oauth,
        [session_id, token, client_pid, ref, pasted],
        15_000
      )
    end
  end

  @doc "Adds a system message through the broker for a remote attached driver."
  @spec add_system_message(pid(), String.t(), :info | :error, pid()) :: :ok | {:error, term()}
  def add_system_message(remote_pid, message, level, client_pid \\ self())
      when is_pid(remote_pid) and is_binary(message) and level in [:info, :error] and
             is_pid(client_pid) do
    with {:ok, session_id, token} <- credentials_for_pid(remote_pid) do
      erpc(
        node(remote_pid),
        :add_system_message,
        [session_id, token, client_pid, message, level],
        5_000
      )
    end
  end

  @doc "Loads persisted session data, using a token when the session is still live."
  @spec session_data(remote_node(), session_id()) ::
          {:ok, SessionStore.session_data()} | {:error, term()}
  def session_data(remote_node, session_id) when is_atom(remote_node) and is_binary(session_id) do
    case session_token(remote_node, session_id) do
      {:ok, token} -> erpc(remote_node, :session_data, [session_id, token], 5_000)
      {:error, :not_found} -> erpc(remote_node, :session_data, [session_id], 5_000)
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the session id for a remote session pid."
  @spec session_id_for_pid(remote_node(), pid()) :: {:ok, session_id()} | {:error, term()}
  def session_id_for_pid(remote_node, remote_pid)
      when is_atom(remote_node) and is_pid(remote_pid) do
    with {:ok, sessions} <- list_sessions(remote_node) do
      Enum.find_value(sessions, {:error, :not_found}, fn
        %{session_id: session_id, pid: ^remote_pid} -> {:ok, session_id}
        _session -> nil
      end)
    end
  end

  @doc "Returns the session pid for a remote session id."
  @spec session_pid(remote_node(), session_id()) :: {:ok, pid()} | {:error, term()}
  def session_pid(remote_node, session_id) when is_atom(remote_node) and is_binary(session_id) do
    with {:ok, sessions} <- list_sessions(remote_node) do
      Enum.find_value(sessions, {:error, :not_found}, fn
        %{session_id: ^session_id, pid: pid} -> {:ok, pid}
        _session -> nil
      end)
    end
  end

  @doc "Returns the broker token for a live remote session."
  @spec session_token(remote_node(), session_id()) :: {:ok, token()} | {:error, term()}
  def session_token(remote_node, session_id)
      when is_atom(remote_node) and is_binary(session_id) do
    with {:ok, sessions} <- list_sessions(remote_node) do
      Enum.find_value(sessions, {:error, :not_found}, fn
        %{session_id: ^session_id, token: token} -> {:ok, token}
        _session -> nil
      end)
    end
  end

  @doc "Returns id and token for a remote session pid."
  @spec credentials_for_pid(pid()) :: {:ok, session_id(), token()} | {:error, term()}
  def credentials_for_pid(remote_pid) when is_pid(remote_pid) do
    remote_node = node(remote_pid)

    with {:ok, sessions} <- list_sessions(remote_node) do
      Enum.find_value(sessions, {:error, :not_found}, fn
        %{session_id: session_id, token: token, pid: ^remote_pid} -> {:ok, session_id, token}
        _session -> nil
      end)
    end
  end

  @spec erpc(remote_node(), atom(), [term()], pos_integer()) :: term() | {:error, term()}
  defp erpc(remote_node, function, args, timeout)
       when is_atom(remote_node) and is_atom(function) and is_list(args) and is_integer(timeout) do
    :erpc.call(remote_node, RemoteAPI, function, args, timeout)
  catch
    :exit, reason -> {:error, {:remote_unavailable, reason}}
  end
end
