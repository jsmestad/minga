defmodule MingaAgent.RemoteAPI do
  @moduledoc """
  Brokered control boundary for remote agent sessions.

  Remote clients may use Erlang distribution as the transport for the MVP, but they should call only this module across the node boundary. The public contract is the verb set here, not arbitrary `:erpc` into `SessionManager`, `Session`, or other internals.

  The trust model is deliberately explicit. The Erlang cookie gates trusted node membership and is all-or-nothing: any cookie holder can bypass this broker with raw distribution. The per-session token checked here is defense in depth for Minga's own clients and the seam for a future socket transport; it is not isolation from an untrusted cookie holder.
  """

  alias MingaAgent.RemoteAPI.AttachResult
  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.Session
  alias MingaAgent.SessionManager

  @typedoc "Remote attachment role."
  @type role :: :driver | :viewer

  @typedoc "Public session record returned by the broker."
  @type session_info :: SessionInfo.t()

  @typedoc "Attach result returned by the broker."
  @type attach_result :: AttachResult.t()

  @doc "Starts a new session through the broker."
  @spec start_session(keyword()) :: {:ok, session_info()} | {:error, term()}
  def start_session(opts \\ []) do
    with {:ok, session_id, pid} <- SessionManager.start_session(opts),
         {:ok, token} <- SessionManager.session_token(session_id) do
      {:ok, session_info(session_id, pid, token)}
    end
  end

  @doc "Starts or returns the stable session for a server-side working directory."
  @spec start_or_get_for_workdir(String.t(), keyword()) ::
          {:ok, session_info()} | {:error, term()}
  def start_or_get_for_workdir(workdir, opts \\ []) when is_binary(workdir) do
    session_id = SessionManager.stable_session_id_for_workdir(workdir)
    opts = Keyword.put(opts, :session_id, session_id)

    with {:ok, ^session_id, pid} <- SessionManager.start_or_get_session(session_id, opts),
         {:ok, token} <- SessionManager.session_token(session_id) do
      {:ok, session_info(session_id, pid, token)}
    end
  end

  @doc "Lists live sessions through the broker."
  @spec list_sessions() :: [session_info()]
  def list_sessions do
    SessionManager.list_sessions()
    |> Enum.map(fn {session_id, pid, _metadata} ->
      {:ok, token} = SessionManager.session_token(session_id)
      session_info(session_id, pid, token)
    end)
  end

  @doc "Attaches a client process to a session as driver or viewer."
  @spec attach(String.t(), String.t(), pid(), keyword()) ::
          {:ok, attach_result()} | {:error, term()}
  def attach(session_id, token, subscriber_pid, opts \\ [])
      when is_binary(session_id) and is_binary(token) and is_pid(subscriber_pid) do
    role = Keyword.get(opts, :role, :viewer)

    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id),
         :ok <- Session.subscribe(pid, subscriber_pid, role: role) do
      info = session_info(session_id, pid, token)
      role = Session.subscriber_role(pid, subscriber_pid) || :viewer
      {:ok, AttachResult.new(info, role, Session.messages(pid), Session.editor_snapshot(pid))}
    end
  end

  @doc "Sends a prompt as an attached driver."
  @spec send_prompt(String.t(), String.t(), pid(), String.t() | [ReqLLM.Message.ContentPart.t()]) ::
          :ok | {:queued, :steering} | {:error, term()}
  def send_prompt(session_id, token, client_pid, prompt)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) and
             (is_binary(prompt) or is_list(prompt)) do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      Session.send_prompt_as(pid, client_pid, prompt)
    end
  end

  @doc "Responds to a tool approval as an attached driver."
  @spec approve(String.t(), String.t(), pid(), Session.approval_decision()) ::
          :ok | {:error, term()}
  def approve(session_id, token, client_pid, decision)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) and
             decision in [:approve, :approve_session, :approve_turn, :reject] do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      Session.respond_to_approval_as(pid, client_pid, decision)
    end
  end

  @doc "Stops a session through the broker."
  @spec stop_session(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_session(session_id, token) when is_binary(session_id) and is_binary(token) do
    with :ok <- authorize(session_id, token) do
      SessionManager.stop_session(session_id)
    end
  end

  @doc "Authorizes a broker call with the per-session token."
  @spec authorize(String.t(), String.t()) :: :ok | {:error, :unauthorized | :not_found}
  def authorize(session_id, token) when is_binary(session_id) and is_binary(token) do
    case SessionManager.session_token(session_id) do
      {:ok, ^token} -> :ok
      {:ok, _other} -> {:error, :unauthorized}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @spec session_info(String.t(), pid(), String.t()) :: session_info()
  defp session_info(session_id, pid, token) do
    SessionInfo.new(session_id, pid, token, Session.metadata(pid))
  end
end
