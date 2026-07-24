defmodule MingaEditor.CompletionTrigger do
  @moduledoc """
  Manages LSP completion request lifecycle.
  """

  alias Minga.Buffer
  alias Minga.LSP.Client
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
  @spec maybe_trigger(t(), String.t(), pid()) :: {t(), [tracking_fact()]}
  def maybe_trigger(%__MODULE__{} = bridge, char, buffer_pid) do
    clients = SyncServer.clients_for_buffer(buffer_pid)

    case clients do
      [] ->
        {bridge, []}

      _ ->
        trigger_chars = clients |> Enum.flat_map(&get_trigger_characters/1) |> Enum.uniq()
        [first_client | _] = clients
        handle_char_type(bridge, char, trigger_chars, clients, first_client, buffer_pid)
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
    if buffer_version(buffer_pid) == version do
      send_completion_requests(bridge, clients, buffer_pid, gen, trigger_pos)
    else
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
  @spec get_typed_since_trigger(pid(), position()) :: String.t()
  def get_typed_since_trigger(buffer_pid, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buffer_pid)

    if cursor_line == trigger_line and cursor_col > trigger_col do
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> ""
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      ""
    end
  catch
    :exit, _ -> ""
  end

  @spec handle_char_type(t(), String.t(), [String.t()], [pid()], pid(), pid()) ::
          {t(), [tracking_fact()]}
  defp handle_char_type(bridge, char, trigger_chars, clients, first_client, buffer_pid) do
    classify_char(bridge, char, char in trigger_chars, clients, first_client, buffer_pid)
  end

  defp classify_char(bridge, _char, true = _is_trigger, clients, _first_client, buffer_pid) do
    bridge = cancel_debounce(bridge)
    send_completion_requests(bridge, clients, buffer_pid, bridge.gen + 1, nil)
  end

  defp classify_char(bridge, char, false = _is_trigger, clients, _first_client, buffer_pid) do
    if identifier_char?(char) do
      schedule_debounced_trigger(bridge, clients, buffer_pid)
    else
      {dismiss(bridge), []}
    end
  end

  @spec send_completion_requests(t(), [pid()], pid(), non_neg_integer(), position() | nil) ::
          {t(), [tracking_fact()]}
  defp send_completion_requests(%__MODULE__{} = bridge, [], _buffer_pid, _gen, _trigger_pos),
    do: {bridge, []}

  defp send_completion_requests(
         %__MODULE__{} = bridge,
         clients,
         buffer_pid,
         gen,
         captured_trigger_pos
       ) do
    file_path = Buffer.file_path(buffer_pid)
    version = buffer_version(buffer_pid)

    case {file_path, version} do
      {nil, _version} ->
        {bridge, []}

      {_path, :stale} ->
        {bridge, []}

      {path, version} ->
        uri = SyncServer.path_to_uri(path)
        {line, col} = get_cursor_position(buffer_pid)
        trigger_pos = captured_trigger_pos || {line, col}

        params = %{
          "textDocument" => %{"uri" => uri},
          "position" => %{"line" => line, "character" => col}
        }

        refs = Enum.map(clients, &Client.request(&1, "textDocument/completion", params))
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

  @spec schedule_debounced_trigger(t(), [pid()], pid()) :: {t(), [tracking_fact()]}
  defp schedule_debounced_trigger(%__MODULE__{} = bridge, clients, buffer_pid) do
    bridge = cancel_debounce(bridge)
    {line, col} = get_cursor_position(buffer_pid)
    prefix_len = identifier_prefix_length(buffer_pid, line, col)
    schedule_debounced_trigger(bridge, clients, buffer_pid, {line, col}, prefix_len)
  end

  @spec schedule_debounced_trigger(t(), [pid()], pid(), position(), non_neg_integer()) ::
          {t(), [tracking_fact()]}
  defp schedule_debounced_trigger(
         %__MODULE__{} = bridge,
         clients,
         buffer_pid,
         {line, col},
         prefix_len
       )
       when is_integer(prefix_len) and prefix_len >= 2 do
    gen = bridge.gen + 1
    trigger_pos = {line, col - prefix_len}

    case buffer_version(buffer_pid) do
      :stale ->
        {bridge, []}

      version ->
        timer = Process.send_after(self(), {:completion_debounce, gen}, @debounce_ms)

        {%__MODULE__{
           bridge
           | phase: {:debounced, timer, clients, buffer_pid, version, trigger_pos},
             gen: gen
         }, []}
    end
  end

  defp schedule_debounced_trigger(
         %__MODULE__{} = bridge,
         _clients,
         _buffer_pid,
         _position,
         _prefix_len
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

  @spec get_cursor_position(pid()) :: position()
  defp get_cursor_position(buffer_pid) do
    {_content, {line, col}} = Buffer.content_and_cursor(buffer_pid)
    {line, col}
  end

  @spec buffer_version(pid()) :: non_neg_integer() | :stale
  defp buffer_version(buffer_pid) do
    Buffer.version(buffer_pid)
  catch
    :exit, _ -> :stale
  end

  @spec identifier_prefix_length(pid(), non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defp identifier_prefix_length(buffer_pid, line, col) do
    {content, _cursor} = Buffer.content_and_cursor(buffer_pid)
    lines = String.split(content, "\n")

    case Enum.at(lines, line) do
      nil ->
        0

      line_text ->
        prefix = String.slice(line_text, 0, col)

        prefix
        |> String.graphemes()
        |> Enum.reverse()
        |> Enum.take_while(&identifier_char?/1)
        |> Enum.count()
    end
  end

  @spec identifier_char?(String.t()) :: boolean()
  defp identifier_char?(<<c>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_, do: true
  defp identifier_char?(_), do: false
end
