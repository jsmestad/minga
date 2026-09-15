defmodule MingaEditor.CompletionTrigger do
  @moduledoc """
  Manages LSP completion request lifecycle.
  """

  alias Minga.Buffer
  alias Minga.Buffer.CursorContext
  alias Minga.LSP.Client
  alias Minga.LSP.PositionEncoding
  alias Minga.LSP.SyncServer

  @debounce_ms 100

  @typedoc "Cursor position captured when completion was triggered."
  @type position :: {non_neg_integer(), non_neg_integer()}

  @typedoc "Role assigned to a completion request reference within a batch."
  @type response_role :: :primary | :secondary

  @typedoc "Request tracking fact returned to the Editor-global LSP owner."
  @type tracking_fact ::
          {reference(), response_role(), pid(), pid(), non_neg_integer(), non_neg_integer(),
           position()}

  @typedoc "Exclusive completion trigger phase tracked in the Editor."
  @type phase ::
          :idle
          | {:debounced, reference(), [pid()], pid(), non_neg_integer(), position()}
          | {:pending, position()}

  defstruct phase: :idle, gen: 0

  @typedoc "Completion bridge state tracked in the Editor."
  @type t :: %__MODULE__{phase: phase(), gen: non_neg_integer()}

  @doc "Returns initial completion bridge state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Returns the latest-wins request generation."
  @spec generation(t()) :: non_neg_integer()
  def generation(%__MODULE__{gen: gen}), do: gen

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
        send_completion_requests(bridge, clients, buffer_pid, gen, trigger_pos, context)

      _ ->
        {%__MODULE__{bridge | phase: :idle}, []}
    end
  end

  def flush_debounce(%__MODULE__{} = bridge, _gen), do: {bridge, []}

  @doc "Dismisses any active completion state and cancels debounce timer ownership."
  @spec dismiss(t()) :: t()
  def dismiss(%__MODULE__{} = bridge) do
    bridge = cancel_debounce(bridge)
    %__MODULE__{bridge | phase: :idle}
  end

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
    send_completion_requests(bridge, clients, buffer_pid, bridge.gen + 1, nil, context)
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

  @spec send_completion_requests(
          t(),
          [pid()],
          pid(),
          non_neg_integer(),
          position() | nil,
          CursorContext.t()
        ) ::
          {t(), [tracking_fact()]}
  defp send_completion_requests(
         %__MODULE__{} = bridge,
         [],
         _buffer_pid,
         _gen,
         _trigger_pos,
         _context
       ),
       do: {bridge, []}

  defp send_completion_requests(
         %__MODULE__{} = bridge,
         clients,
         buffer_pid,
         gen,
         captured_trigger_pos,
         %CursorContext{} = context
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

            params = %{"textDocument" => %{"uri" => uri}, "position" => position}
            Client.request(client, "textDocument/completion", params)
          end)

        facts = tracking_facts(refs, clients, buffer_pid, version, gen, trigger_pos)

        {%__MODULE__{bridge | phase: {:pending, trigger_pos}, gen: gen}, facts}
    end
  end

  @spec tracking_facts(
          [reference()],
          [pid()],
          pid(),
          non_neg_integer(),
          non_neg_integer(),
          position()
        ) :: [tracking_fact()]
  defp tracking_facts(refs, clients, buffer, version, gen, trigger_pos) do
    refs
    |> Enum.zip(clients)
    |> Enum.with_index()
    |> Enum.map(fn {{ref, client}, index} ->
      role = if index == 0, do: :primary, else: :secondary
      {ref, role, client, buffer, version, gen, trigger_pos}
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
    bridge = cancel_debounce(bridge)
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

    {%__MODULE__{
       bridge
       | phase: {:debounced, timer, clients, buffer_pid, version, trigger_pos},
         gen: gen
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
    %__MODULE__{bridge | phase: :idle}
  end

  defp cancel_debounce(%__MODULE__{} = bridge), do: bridge

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
