defmodule MingaAgent.RemoteAPI do
  @moduledoc """
  Brokered control boundary for remote agent sessions.

  Remote clients may use Erlang distribution as the transport for the MVP, but they should call only this module across the node boundary. The public contract is the verb set here, not arbitrary `:erpc` into `SessionManager`, `Session`, or other internals.

  The trust model is deliberately explicit. The Erlang cookie gates trusted node membership and is all-or-nothing: any cookie holder can bypass this broker with raw distribution. The per-session token checked here is defense in depth for Minga's own clients and the seam for a future socket transport; it is not isolation from an untrusted cookie holder.
  """

  alias MingaAgent.EventLog
  alias MingaAgent.OAuth.Flow, as: OAuthFlow
  alias MingaAgent.RemoteAPI.AttachResult
  alias MingaAgent.RemoteAPI.SessionInfo
  alias MingaAgent.Session
  alias MingaAgent.Session.{ConnectionTarget, Transcript}
  alias MingaAgent.SessionListing
  alias MingaAgent.SessionManager
  alias MingaAgent.SessionStore
  alias MingaAgent.ArtifactStore.Fetched
  alias MingaAgent.Tool.Output.{Range, Reference}

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
    normalized_workdir = normalize_workdir(workdir)
    session_id = SessionManager.stable_session_id_for_workdir(normalized_workdir)

    opts =
      opts |> Keyword.put(:session_id, session_id) |> Keyword.put(:workdir, normalized_workdir)

    with {:ok, ^session_id, pid} <- SessionManager.start_or_get_session(session_id, opts),
         {:ok, token} <- SessionManager.session_token(session_id) do
      {:ok, session_info(session_id, pid, token)}
    end
  end

  @doc "Lists live registrations with session metadata or a safe unavailable reason."
  @spec list_sessions() :: [session_info()]
  def list_sessions do
    SessionManager.list_sessions()
    |> Enum.flat_map(&session_info_if_live/1)
  end

  @doc "Attaches a client. A capable driver receives its private question receipt directly on the subscriber PID."
  @spec attach(String.t(), String.t(), pid(), keyword()) ::
          {:ok, attach_result()} | {:error, term()}
  def attach(session_id, token, subscriber_pid, opts \\ [])
      when is_binary(session_id) and is_binary(token) and is_pid(subscriber_pid) do
    role = Keyword.get(opts, :role, :viewer)
    last_seen_event_id = Keyword.get(opts, :last_seen_event_id, 0)
    questions? = Keyword.get(opts, :questions?, false) == true

    with :ok <- validate_attach_role(role),
         :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id),
         {:ok, attachment} <- Session.broker_attach(pid, subscriber_pid, role, questions?) do
      attach_after_subscribe(
        pid,
        session_id,
        token,
        subscriber_pid,
        last_seen_event_id,
        attachment
      )
    end
  end

  @spec validate_attach_role(term()) :: :ok | {:error, :invalid_role}
  defp validate_attach_role(role) when role in [:driver, :viewer], do: :ok
  defp validate_attach_role(_role), do: {:error, :invalid_role}

  @doc "Detaches a client. A protected driver must provide its current private receipt."
  @spec detach(String.t(), String.t(), pid() | {pid(), binary()}) :: :ok | {:error, term()}
  def detach(session_id, token, authority)
      when is_binary(session_id) and is_binary(token) do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      Session.broker_detach(pid, authority)
    end
  end

  @doc "Reads a bounded retained transcript page for a token-authorized session."
  @spec transcript_history_before(
          ConnectionTarget.t(),
          String.t(),
          ConnectionTarget.t() | Transcript.Cursor.t(),
          pos_integer() | :tail,
          1..64
        ) :: Transcript.history_result() | {:error, term()}
  def transcript_history_before(
        %ConnectionTarget{session_id: id, session: pid},
        token,
        source,
        anchor,
        limit
      ) do
    with :ok <- authorize(id, token),
         {:ok, ^pid} <- SessionManager.get_session(id) do
      Session.transcript_history_before(pid, source, anchor, limit)
    else
      {:ok, _other_pid} -> {:error, :stale_target}
      {:error, _reason} = error -> error
    end
  end

  @doc "Begins a server-side manual OAuth flow through the broker."
  @spec begin_oauth(String.t(), String.t(), pid()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def begin_oauth(session_id, token, client_pid)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) do
    with :ok <- authorize_driver(session_id, token, client_pid) do
      OAuthFlow.begin_manual(session_id: session_id, client_pid: client_pid)
    end
  end

  @doc "Completes a server-side manual OAuth flow through the broker."
  @spec complete_oauth(String.t(), String.t(), pid(), String.t(), String.t()) ::
          {:ok, :openai} | {:error, term()}
  def complete_oauth(session_id, token, client_pid, ref, pasted)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) and is_binary(ref) and
             is_binary(pasted) do
    with :ok <- authorize_driver(session_id, token, client_pid) do
      complete_authorized_oauth(session_id, client_pid, ref, pasted)
    end
  end

  @doc "Adds a system message to a session through the broker."
  @spec add_system_message(String.t(), String.t(), pid(), String.t(), :info | :error) ::
          :ok | {:error, term()}
  def add_system_message(session_id, token, client_pid, message, level \\ :info)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) and
             is_binary(message) and
             level in [:info, :error] do
    with :ok <- authorize_driver(session_id, token, client_pid),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      Session.add_system_message(pid, message, level)
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

  @doc "Continues an exact interrupted request only as the driver attached to the original Session."
  @spec continue_stopped(pid(), String.t(), {pid(), binary()}, {String.t(), String.t()}) ::
          :ok | {:error, term()}
  def continue_stopped(session, token, {driver, receipt} = authority, {id, request} = target)
      when is_pid(session) and is_binary(token) and is_pid(driver) and is_binary(receipt) and
             is_binary(id) and is_binary(request) do
    with :ok <- authorize(id, token),
         {:ok, ^session} <- SessionManager.get_session(id) do
      Session.continue_stopped_as(session, authority, target)
    else
      {:ok, _replacement} -> {:error, :stale_turn}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolves the exact displayed approval as an authorized attached driver."
  @spec approve(
          String.t(),
          String.t(),
          pid(),
          Session.approval_target(),
          Session.approval_decision()
        ) ::
          :ok | {:error, term()}
  def approve(session_id, token, client_pid, %MingaAgent.ToolApproval.Target{} = target, decision)
      when is_binary(session_id) and is_binary(token) and is_pid(client_pid) and
             decision in [:approve, :approve_session, :approve_turn, :reject] do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      Session.respond_to_approval_as(pid, client_pid, target, decision)
    end
  end

  @doc "Reads a clarification after authorizing access to the remote session."
  @spec pending_question(String.t(), String.t()) ::
          {:ok, {MingaAgent.Question.Target.t(), MingaAgent.Question.t()} | nil}
          | {:error, term()}
  def pending_question(session_id, token) when is_binary(session_id) and is_binary(token) do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      {:ok, Session.pending_question(pid)}
    end
  end

  @doc "Answers or cancels the displayed clarification using the private current attachment receipt."
  @spec respond_to_question(
          String.t(),
          String.t(),
          {pid(), binary()} | pid(),
          MingaAgent.Question.Target.t(),
          MingaAgent.Question.response()
        ) :: :ok | {:error, term()}
  def respond_to_question(
        session_id,
        token,
        {client, receipt} = authority,
        %MingaAgent.Question.Target{} = target,
        response
      )
      when is_binary(session_id) and is_binary(token) and is_pid(client) and is_binary(receipt) do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id) do
      Session.respond_to_question_as(pid, authority, target, response)
    end
  end

  def respond_to_question(_session_id, _token, _without_receipt, _target, _response),
    do: {:error, :not_driver}

  @doc "Executes a saved-composer operation only for the authenticated original Session."
  @spec composer(
          String.t(),
          String.t(),
          pid(),
          {pid(), binary()},
          Session.remote_composer_operation()
        ) :: Session.composer_result()
  def composer(session_id, token, session, {driver, receipt} = authority, operation)
      when is_binary(session_id) and is_binary(token) and is_pid(session) and
             is_pid(driver) and is_binary(receipt) do
    with :ok <- authorize(session_id, token),
         {:ok, ^session} <- SessionManager.get_session(session_id) do
      Session.remote_composer(session, session_id, authority, operation)
    else
      {:ok, _replacement} -> {:error, :stale_target}
      {:error, _reason} = error -> error
    end
  end

  @doc "Stops a session through the broker."
  @spec stop_session(String.t(), String.t()) :: :ok | {:error, term()}
  def stop_session(session_id, token) when is_binary(session_id) and is_binary(token) do
    with :ok <- authorize(session_id, token) do
      SessionManager.stop_session(session_id)
    end
  end

  @doc "Stops the existing stable session for a workdir through the broker."
  @spec stop_workdir_session(String.t()) :: :ok | {:error, term()}
  def stop_workdir_session(workdir) when is_binary(workdir) do
    session_id = workdir |> normalize_workdir() |> SessionManager.stable_session_id_for_workdir()

    case SessionManager.session_token(session_id) do
      {:ok, token} -> stop_session(session_id, token)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Loads persisted session data through the broker for an ended session."
  @spec session_data(String.t()) :: {:ok, SessionStore.session_data()} | {:error, term()}
  def session_data(session_id) when is_binary(session_id) do
    SessionStore.load(session_id)
  end

  @doc "Loads persisted session data through the broker for a live token-authorized session."
  @spec session_data(String.t(), String.t()) ::
          {:ok, SessionStore.session_data()} | {:error, term()}
  def session_data(session_id, token) when is_binary(session_id) and is_binary(token) do
    with :ok <- authorize(session_id, token) do
      SessionStore.load(session_id)
    end
  end

  @doc "Reads original retained tool output for the exact token-authorized live session."
  @spec read_retained_output(
          ConnectionTarget.t(),
          String.t(),
          pos_integer(),
          Reference.t(),
          Range.t()
        ) ::
          {:ok, Fetched.t()} | {:error, term()}
  def read_retained_output(
        %ConnectionTarget{session_id: session_id, session: expected_pid} = target,
        token,
        id,
        reference,
        range
      ) do
    with :ok <- authorize(session_id, token),
         {:ok, ^expected_pid} <- SessionManager.get_session(session_id) do
      Session.read_retained_output(target, id, reference, range)
    else
      {:ok, _replacement_pid} -> {:error, :not_found}
      {:error, _reason} = error -> error
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

  @spec attach_after_subscribe(
          pid(),
          String.t(),
          String.t(),
          pid(),
          non_neg_integer(),
          Session.broker_attachment()
        ) :: {:ok, attach_result()} | {:error, term()}
  defp attach_after_subscribe(
         pid,
         session_id,
         token,
         subscriber_pid,
         last_seen_event_id,
         attachment
       ) do
    case event_catchup(session_id, last_seen_event_id) do
      {:ok, events, latest_event_id} ->
        info = session_info(session_id, pid, token)
        role = Session.subscriber_role(pid, subscriber_pid) || :viewer

        {:ok,
         AttachResult.new(info, role, Session.messages(pid), Session.editor_snapshot(pid),
           events: events,
           latest_event_id: latest_event_id
         )}

      {:error, _reason} = error ->
        Session.rollback_broker_attach(pid, attachment)
        error
    end
  end

  @spec authorize_driver(String.t(), String.t(), pid()) ::
          :ok | {:error, :unauthorized | :not_found | :not_driver}
  defp authorize_driver(session_id, token, client_pid) do
    with :ok <- authorize(session_id, token),
         {:ok, pid} <- SessionManager.get_session(session_id),
         :driver <- Session.subscriber_role(pid, client_pid) do
      :ok
    else
      nil -> {:error, :not_driver}
      :viewer -> {:error, :not_driver}
      {:error, _reason} = error -> error
    end
  end

  @spec complete_authorized_oauth(String.t(), pid(), String.t(), String.t()) ::
          {:ok, :openai} | {:error, String.t()}
  defp complete_authorized_oauth(session_id, client_pid, ref, pasted) do
    case OAuthFlow.complete_manual(ref, pasted, session_id: session_id, client_pid: client_pid) do
      {:ok, :openai} ->
        refresh_all_session_credentials()
        {:ok, :openai}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec event_catchup(String.t(), non_neg_integer()) ::
          {:ok, [EventLog.EventRecord.t()], non_neg_integer()} | {:error, term()}
  defp event_catchup(session_id, last_seen_event_id)
       when is_integer(last_seen_event_id) and last_seen_event_id >= 0 do
    case EventLog.open_read_connection() do
      {:ok, db} ->
        result =
          with {:ok, events} <- EventLog.events_after(db, session_id, last_seen_event_id, 10_000),
               {:ok, latest_event_id} <- EventLog.latest_id(db, session_id) do
            {:ok, events, safe_latest_event_id(events, latest_event_id)}
          end

        MingaAgent.EventLog.Store.close(db)
        result

      {:error, :database_not_found} ->
        {:ok, [], 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp event_catchup(_session_id, _last_seen_event_id), do: {:error, :invalid_event_cursor}

  @spec safe_latest_event_id([EventLog.EventRecord.t()], non_neg_integer()) :: non_neg_integer()
  defp safe_latest_event_id([], latest_event_id), do: latest_event_id

  defp safe_latest_event_id(events, latest_event_id) do
    delivered_latest_id = events |> Enum.at(-1) |> Map.fetch!(:id)
    min(delivered_latest_id, latest_event_id)
  end

  @spec normalize_workdir(String.t()) :: String.t()
  defp normalize_workdir(workdir) when is_binary(workdir), do: Path.expand(workdir)

  @spec session_info_if_live(SessionListing.t()) :: [session_info()]
  defp session_info_if_live(%SessionListing{id: session_id} = listing) do
    case SessionManager.session_token(session_id) do
      {:ok, token} -> [SessionInfo.from_listing(listing, token)]
      {:error, _reason} -> []
    end
  catch
    :exit, _reason -> []
  end

  @spec refresh_all_session_credentials() :: :ok
  defp refresh_all_session_credentials do
    SessionManager.list_sessions()
    |> Enum.each(fn %SessionListing{pid: pid} -> Session.refresh_credentials(pid) end)
  end

  @spec session_info(String.t(), pid(), String.t()) :: session_info()
  defp session_info(session_id, pid, token) do
    SessionInfo.new(session_id, pid, token, Session.metadata(pid))
  end
end
