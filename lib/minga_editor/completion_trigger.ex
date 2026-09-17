defmodule MingaEditor.CompletionTrigger do
  @moduledoc """
  Manages LSP completion request lifecycle.
  """

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.LSP.Client
  alias Minga.LSP.PositionEncoding
  alias Minga.LSP.SyncServer
  alias Minga.Editing.Completion
  alias Minga.Editing.Completion.Item
  alias Minga.Editing.Completion.ProviderBatch
  alias Minga.Editing.Completion.Session

  @debounce_ms 100

  @typedoc "Cursor position captured when completion was triggered."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Role assigned to a completion request reference within a batch."
  @type response_role :: :primary | :secondary

  @typedoc "Request tracking fact returned to the Editor-global LSP owner."
  @type tracking_fact ::
          {reference(), response_role(), Item.provider_id(), pid(), pid(), non_neg_integer(),
           reference(), non_neg_integer(), position()}

  @typedoc "Exclusive completion trigger phase tracked in the Editor."
  @type phase ::
          :idle
          | {:debounced, reference(), [pid()], pid(), non_neg_integer(), position()}
          | {:pending, position()}

  defstruct phase: :idle, gen: 0, session: nil

  @typedoc "Completion bridge state tracked in the Editor."
  @type t :: %__MODULE__{phase: phase(), gen: non_neg_integer(), session: Session.t() | nil}

  @doc "Returns initial completion bridge state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the latest-wins request generation."
  @spec generation(t()) :: non_neg_integer()
  def generation(%__MODULE__{gen: gen}), do: gen

  @doc "Returns the stable completion session, when one is active."
  @spec session(t()) :: Session.t() | nil
  def session(%__MODULE__{session: session}), do: session

  @doc "Installs an updated pure session transition."
  @spec put_session(t(), Session.t()) :: t()
  def put_session(%__MODULE__{} = bridge, %Session{} = session),
    do: %__MODULE__{bridge | session: session, gen: session.generation}

  @doc "Checks whether the given character should trigger completion."
  @spec maybe_trigger(t(), String.t(), pid(), CursorContext.t()) :: {t(), [tracking_fact()]}
  def maybe_trigger(%__MODULE__{} = bridge, char, buffer_pid, %CursorContext{} = context) do
    clients = SyncServer.clients_for_buffer(buffer_pid)

    case clients do
      [] ->
        {bridge, []}

      _ ->
        trigger_chars = clients |> Enum.flat_map(&get_trigger_characters/1) |> Enum.uniq()
        [first_client | _] = clients
        handle_char_type(bridge, char, trigger_chars, clients, first_client, buffer_pid, context)
    end
  end

  @doc "Continues an active session, refreshing only incomplete providers for identifier input."
  @spec maybe_retrigger(t(), String.t(), pid(), CursorContext.t()) :: {t(), [tracking_fact()]}
  def maybe_retrigger(%__MODULE__{} = bridge, char, buffer_pid, %CursorContext{} = context) do
    clients = SyncServer.clients_for_buffer(buffer_pid)
    trigger_chars = clients |> Enum.flat_map(&get_trigger_characters/1) |> Enum.uniq()

    continue_char(
      bridge,
      char,
      char in trigger_chars,
      identifier_char?(char),
      buffer_pid,
      context
    )
  end

  @doc "Called when the debounce timer fires."
  @spec flush_debounce(t(), non_neg_integer()) :: {t(), [tracking_fact()]}
  def flush_debounce(
        %__MODULE__{
          phase: {:debounced, _timer, clients, buffer_pid, version, trigger_pos},
          gen: gen
        } = bridge,
        gen
      ) do
    case cursor_context(buffer_pid) do
      %CursorContext{version: ^version} = context ->
        send_completion_requests(bridge, clients, buffer_pid, gen, trigger_pos, context, nil)

      _ ->
        {dismiss(bridge), []}
    end
  end

  def flush_debounce(%__MODULE__{} = bridge, _gen), do: {bridge, []}

  @doc "Dismisses any active completion state and cancels debounce timer ownership."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = bridge) do
    bridge = cancel_debounce(bridge)
    cancel_session(bridge.session)
    %__MODULE__{bridge | phase: :idle, session: nil}
  end

  @doc "Synchronizes session selection after a user navigation transition."
  @spec sync_selection(t(), Completion.t()) :: t()
  def sync_selection(
        %__MODULE__{session: %Session{} = session} = bridge,
        %Completion{} = completion
      ) do
    session =
      session
      |> Session.select(completion.selected_item_id)
      |> Session.preview(completion.selected_item_id)

    %{bridge | session: session}
  end

  def sync_selection(%__MODULE__{} = bridge, %Completion{}), do: bridge

  @doc "Accepts one identity-checked provider batch into the active session."
  @spec accept_batch(t(), ProviderBatch.t()) :: {:ok, t()} | :stale
  def accept_batch(%__MODULE__{session: %Session{} = session} = bridge, %ProviderBatch{} = batch) do
    case Session.accept_batch(session, batch) do
      {:ok, session} -> {:ok, put_session(bridge, session)}
      :stale -> :stale
    end
  end

  def accept_batch(%__MODULE__{}, %ProviderBatch{}), do: :stale

  @doc "Starts resolve ownership for the currently selected stable item."
  @spec begin_resolve(t(), Item.t(), reference() | nil) ::
          {:ok, t(), Session.resolve_identity()} | :stale
  def begin_resolve(%__MODULE__{session: %Session{} = session} = bridge, %Item{} = item, timer) do
    {session, request, old_timer} = Session.clear_resolve(session)
    cancel_request(request)
    cancel_timer(old_timer)

    case provider_client(session, item.provider_id) do
      nil ->
        :stale

      client ->
        case Session.begin_resolve(session, item.id, client, timer) do
          {:ok, session} ->
            identity = {session.id, item.provider_id, item.id}
            {:ok, put_session(bridge, session), identity}

          :stale ->
            :stale
        end
    end
  end

  def begin_resolve(%__MODULE__{}, %Item{}, _timer), do: :stale

  @doc "Records the request reference for an exact resolve identity."
  @spec track_resolve(t(), Session.resolve_identity(), reference()) :: {:ok, t()} | :stale
  def track_resolve(%__MODULE__{session: %Session{} = session} = bridge, identity, ref) do
    case Session.track_resolve(session, identity, ref) do
      {:ok, session} -> {:ok, put_session(bridge, session)}
      :stale -> :stale
    end
  end

  def track_resolve(%__MODULE__{}, _identity, _ref), do: :stale

  @doc "Retriggers only incomplete providers with LSP trigger kind 3."
  @spec retrigger_incomplete(t(), CursorContext.t()) :: {t(), [tracking_fact()]}
  def retrigger_incomplete(%__MODULE__{session: %Session{} = session} = bridge, context) do
    providers = Session.retrigger_providers(session)
    do_retrigger_incomplete(bridge, context, providers)
  end

  def retrigger_incomplete(%__MODULE__{} = bridge, %CursorContext{}), do: {bridge, []}

  @doc "Returns whether an active session has provider work that must refresh after input."
  @spec retriggerable?(t()) :: boolean()
  def retriggerable?(%__MODULE__{session: %Session{} = session}),
    do: Session.retrigger_providers(session) != []

  def retriggerable?(%__MODULE__{}), do: false

  @doc "Returns the text typed since the trigger position (for prefix filtering)."
  @spec get_typed_since_trigger(pid() | CursorContext.t(), position()) :: String.t()
  def get_typed_since_trigger(buffer_pid, trigger_position) when is_pid(buffer_pid) do
    buffer_pid
    |> Buffer.cursor_context()
    |> get_typed_since_trigger(trigger_position)
  catch
    :exit, _ -> ""
  end

  def get_typed_since_trigger(%CursorContext{} = context, trigger_position) do
    CursorContext.text_since(context, trigger_position) || ""
  end

  @spec handle_char_type(t(), String.t(), [String.t()], [pid()], pid(), pid(), CursorContext.t()) ::
          {t(), [tracking_fact()]}
  defp handle_char_type(bridge, char, trigger_chars, clients, first_client, buffer_pid, context) do
    classify_char(
      bridge,
      char,
      char in trigger_chars,
      clients,
      first_client,
      buffer_pid,
      context
    )
  end

  defp classify_char(
         bridge,
         _char,
         true = _is_trigger,
         clients,
         _first_client,
         buffer_pid,
         context
       ) do
    bridge = cancel_debounce(bridge)

    send_completion_requests(
      bridge,
      clients,
      buffer_pid,
      bridge.gen + 1,
      nil,
      context,
      %{"triggerKind" => 2}
    )
  end

  defp classify_char(
         bridge,
         char,
         false = _is_trigger,
         clients,
         _first_client,
         buffer_pid,
         context
       ) do
    if identifier_char?(char) do
      schedule_debounced_trigger(bridge, clients, buffer_pid, context)
    else
      {dismiss(bridge), []}
    end
  end

  @spec continue_char(t(), String.t(), boolean(), boolean(), pid(), CursorContext.t()) ::
          {t(), [tracking_fact()]}
  defp continue_char(bridge, char, true, _identifier, buffer_pid, context),
    do: maybe_trigger(bridge, char, buffer_pid, context)

  defp continue_char(bridge, _char, false, true, _buffer_pid, context),
    do: retrigger_incomplete(bridge, context)

  defp continue_char(bridge, _char, false, false, _buffer_pid, _context),
    do: {dismiss(bridge), []}

  @spec send_completion_requests(
          t(),
          [pid()],
          pid(),
          non_neg_integer(),
          position() | nil,
          CursorContext.t(),
          map() | nil
        ) ::
          {t(), [tracking_fact()]}
  defp send_completion_requests(
         %__MODULE__{} = bridge,
         [],
         _buffer_pid,
         _gen,
         _trigger_pos,
         _context,
         _request_context
       ),
       do: {dismiss(bridge), []}

  defp send_completion_requests(
         %__MODULE__{} = bridge,
         clients,
         buffer_pid,
         gen,
         captured_trigger_pos,
         %CursorContext{} = context,
         request_context
       ) do
    case context do
      %CursorContext{file_path: nil} ->
        {bridge, []}

      %CursorContext{file_path: path, version: version} ->
        uri = SyncServer.path_to_uri(path)
        {line, col} = CursorContext.position(context)
        trigger_pos = captured_trigger_pos || {line, col}

        refs =
          Enum.map(clients, fn client ->
            position =
              PositionEncoding.to_lsp(
                {line, col},
                context.line_text,
                client_encoding(client)
              )

            params = completion_params(uri, position, request_context)
            Client.request(client, "textDocument/completion", params)
          end)

        bridge = supersede_session(bridge)
        session = session_for_request(bridge, gen, buffer_pid, version, trigger_pos)

        requests =
          refs
          |> Enum.zip(clients)
          |> Enum.map(fn {ref, client} -> {provider_id(client), client, ref} end)

        session = Session.register_requests(session, requests)
        facts = tracking_facts(refs, clients, buffer_pid, version, session.id, gen, trigger_pos)

        {%__MODULE__{bridge | phase: {:pending, trigger_pos}, gen: gen, session: session}, facts}
    end
  end

  @spec tracking_facts(
          [reference()],
          [pid()],
          pid(),
          non_neg_integer(),
          reference(),
          non_neg_integer(),
          position()
        ) :: [tracking_fact()]
  defp tracking_facts(refs, clients, buffer, version, session_id, gen, trigger_pos) do
    refs
    |> Enum.zip(clients)
    |> Enum.with_index()
    |> Enum.map(fn {{ref, client}, index} ->
      role = if index == 0, do: :primary, else: :secondary
      {ref, role, provider_id(client), client, buffer, version, session_id, gen, trigger_pos}
    end)
  end

  @spec schedule_debounced_trigger(t(), [pid()], pid(), CursorContext.t()) ::
          {t(), [tracking_fact()]}
  defp schedule_debounced_trigger(
         %__MODULE__{} = bridge,
         clients,
         buffer_pid,
         %CursorContext{} = context
       ) do
    bridge = bridge |> cancel_debounce() |> supersede_session()
    prefix = identifier_prefix(context.line_prefix)

    schedule_debounced_trigger(
      bridge,
      clients,
      buffer_pid,
      CursorContext.position(context),
      byte_size(prefix),
      String.length(prefix),
      context.version
    )
  end

  @spec schedule_debounced_trigger(
          t(),
          [pid()],
          pid(),
          position(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          {t(), [tracking_fact()]}
  defp schedule_debounced_trigger(
         %__MODULE__{} = bridge,
         clients,
         buffer_pid,
         {line, col},
         prefix_bytes,
         prefix_graphemes,
         version
       )
       when is_integer(prefix_graphemes) and prefix_graphemes >= 2 do
    gen = bridge.gen + 1
    trigger_pos = {line, col - prefix_bytes}
    timer = Process.send_after(self(), {:completion_debounce, gen}, @debounce_ms)

    session =
      Session.new(make_ref(), gen, buffer_pid, version, trigger_pos)
      |> Session.put_debounce_timer(timer)

    {%__MODULE__{
       bridge
       | phase: {:debounced, timer, clients, buffer_pid, version, trigger_pos},
         gen: gen,
         session: session
     }, []}
  end

  defp schedule_debounced_trigger(
         %__MODULE__{} = bridge,
         _clients,
         _buffer_pid,
         _position,
         _prefix_bytes,
         _prefix_graphemes,
         _version
       ),
       do: {bridge, []}

  @spec cancel_debounce(t()) :: t()
  defp cancel_debounce(
         %__MODULE__{phase: {:debounced, timer, _clients, _buffer, _version, _position}} = bridge
       ) do
    Process.cancel_timer(timer)

    session =
      case bridge.session do
        %Session{} = session -> Session.put_debounce_timer(session, nil)
        nil -> nil
      end

    %__MODULE__{bridge | phase: :idle, session: session}
  end

  defp cancel_debounce(%__MODULE__{} = bridge), do: bridge

  @spec do_retrigger_incomplete(t(), CursorContext.t(), [{Item.provider_id(), pid()}]) ::
          {t(), [tracking_fact()]}
  defp do_retrigger_incomplete(
         %__MODULE__{session: %Session{} = session} = bridge,
         %CursorContext{version: version},
         []
       ) do
    {%{bridge | session: Session.continue_locally(session, version)}, []}
  end

  defp do_retrigger_incomplete(
         %__MODULE__{session: %Session{} = session} = bridge,
         %CursorContext{file_path: path} = context,
         providers
       )
       when is_binary(path) do
    cancel_provider_requests(session.provider_requests)
    generation = session.generation + 1
    uri = SyncServer.path_to_uri(path)
    {line, col} = CursorContext.position(context)

    requests =
      Enum.map(providers, fn {provider_id, client} ->
        position =
          PositionEncoding.to_lsp({line, col}, context.line_text, client_encoding(client))

        params = completion_params(uri, position, %{"triggerKind" => 3})
        ref = Client.request(client, "textDocument/completion", params)
        {provider_id, client, ref}
      end)

    session = Session.retrigger(session, generation, context.version, requests)

    facts =
      requests
      |> Enum.with_index()
      |> Enum.map(fn {{provider_id, client, ref}, index} ->
        role = if index == 0, do: :primary, else: :secondary

        {ref, role, provider_id, client, session.buffer, session.buffer_version, session.id,
         generation, session.trigger_position}
      end)

    {%__MODULE__{
       bridge
       | phase: {:pending, session.trigger_position},
         gen: generation,
         session: session
     }, facts}
  end

  defp do_retrigger_incomplete(%__MODULE__{} = bridge, %CursorContext{}, _providers),
    do: {bridge, []}

  @spec session_for_request(t(), non_neg_integer(), pid(), non_neg_integer(), position()) ::
          Session.t()
  defp session_for_request(
         %__MODULE__{session: %Session{generation: gen, buffer: buffer, buffer_version: version}} =
           bridge,
         gen,
         buffer,
         version,
         trigger_pos
       ) do
    Session.activate(bridge.session, trigger_pos)
  end

  defp session_for_request(_bridge, gen, buffer, version, trigger_pos),
    do: Session.new(make_ref(), gen, buffer, version, trigger_pos)

  @spec supersede_session(t()) :: t()
  defp supersede_session(%__MODULE__{session: %Session{debounce_timer: timer}} = bridge)
       when is_reference(timer),
       do: bridge

  defp supersede_session(%__MODULE__{session: %Session{} = session} = bridge) do
    cancel_session(session)
    %{bridge | session: nil}
  end

  defp supersede_session(%__MODULE__{} = bridge), do: bridge

  @spec cancel_session(Session.t() | nil) :: :ok
  defp cancel_session(%Session{} = session) do
    {_session, requests, timers} = Session.teardown(session)

    cancel_provider_requests(
      Map.new(Enum.with_index(requests), fn {request, index} -> {index, request} end)
    )

    Enum.each(timers, &Process.cancel_timer/1)
    :ok
  end

  defp cancel_session(nil), do: :ok

  @spec cancel_provider_requests(%{term() => Session.provider_request()}) :: :ok
  defp cancel_provider_requests(requests) do
    Enum.each(requests, fn {_provider_id, {client, ref}} -> Client.cancel_request(client, ref) end)

    :ok
  end

  @spec cancel_request(Session.provider_request() | nil) :: :ok
  defp cancel_request({client, ref}), do: Client.cancel_request(client, ref)
  defp cancel_request(nil), do: :ok

  @spec cancel_timer(reference() | nil) :: :ok
  defp cancel_timer(timer) when is_reference(timer) do
    Process.cancel_timer(timer)
    :ok
  end

  defp cancel_timer(nil), do: :ok

  @spec provider_client(Session.t(), Item.provider_id()) :: pid() | nil
  defp provider_client(%Session{} = session, provider_id) do
    case Map.fetch(session.batches, provider_id) do
      {:ok, %ProviderBatch{client: client}} -> client
      :error -> nil
    end
  end

  @spec completion_params(String.t(), map(), map() | nil) :: map()
  defp completion_params(uri, position, nil),
    do: %{"textDocument" => %{"uri" => uri}, "position" => position}

  defp completion_params(uri, position, context),
    do: %{"textDocument" => %{"uri" => uri}, "position" => position, "context" => context}

  @spec provider_id(pid()) :: Item.provider_id()
  defp provider_id(client), do: {:lsp_client, client}

  @spec get_trigger_characters(pid()) :: [String.t()]
  defp get_trigger_characters(client) do
    client
    |> Client.capabilities()
    |> get_in(["completionProvider", "triggerCharacters"])
    |> List.wrap()
  catch
    :exit, _ -> ["."]
  end

  @spec cursor_context(pid()) :: CursorContext.t() | :stale
  defp cursor_context(buffer_pid) do
    Buffer.cursor_context(buffer_pid)
  catch
    :exit, _ -> :stale
  end

  @spec client_encoding(pid()) :: Minga.LSP.PositionEncoding.encoding()
  defp client_encoding(client) do
    Client.encoding(client)
  catch
    :exit, _ -> :utf16
  end

  @spec identifier_prefix(String.t()) :: String.t()
  defp identifier_prefix(line_prefix) do
    line_prefix
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.take_while(&identifier_char?/1)
    |> Enum.reverse()
    |> Enum.join()
  end

  @spec identifier_char?(String.t()) :: boolean()
  defp identifier_char?(grapheme) when is_binary(grapheme),
    do: String.match?(grapheme, ~r/^[\p{L}\p{N}\p{M}_]+$/u)
end
