defmodule MingaEditor.CompletionTrigger do
  @moduledoc """
  Manages LSP completion request lifecycle.

  Manages the lifecycle of completion requests: deciding when to trigger,
  sending async requests to the LSP client, handling responses, and
  debouncing rapid keystrokes.

  ## Trigger Rules

  Completion fires in two cases:
  1. **Trigger character** (`.`, `:`, etc.) — fires immediately
  2. **Identifier typing** — fires after a debounce delay when the user
     has typed 2+ identifier characters since the last non-identifier

  ## Debouncing

  Character-triggered completions are instant. Identifier-triggered
  completions are debounced at 100ms to avoid flooding the server while
  the user is typing quickly.
  """

  alias Minga.Buffer
  alias Minga.Editing.Completion
  alias Minga.LSP.Client
  alias Minga.LSP.SyncServer

  @debounce_ms 100

  @typedoc "Completion bridge state tracked in the Editor."
  @type t :: %{
          pending_ref: reference() | nil,
          pending_refs: MapSet.t(reference()),
          debounce_timer: reference() | nil,
          trigger_position: {non_neg_integer(), non_neg_integer()} | nil,
          gen: non_neg_integer()
        }

  @typedoc """
  Result of classifying an incoming LSP completion response without parsing.

  The heavy parse/sort/filter is deferred to a Task (see
  `MingaEditor.CompletionHandling`); classification only decides whether the
  response is the primary one (replaces the menu), a secondary one to merge,
  or stale/ignorable. `gen` lets a late processed result be discarded if a
  newer request batch has superseded it (latest-wins).
  """
  @type classification ::
          {:primary | :merge, {non_neg_integer(), non_neg_integer()}, String.t(),
           non_neg_integer()}
          | :ignore

  @doc "Returns initial completion bridge state."
  @dialyzer {:no_opaque, new: 0}
  @spec new() :: t()
  def new do
    %{
      pending_ref: nil,
      pending_refs: MapSet.new(),
      debounce_timer: nil,
      trigger_position: nil,
      gen: 0
    }
  end

  @doc """
  Checks whether the given character should trigger completion and,
  if so, sends the request (possibly after a debounce delay).

  `char` is the character just inserted (a single-character string).
  Returns `{updated_bridge_state, updated_completion}` where completion
  may be unchanged (if debouncing) or nil (if dismissed).
  """
  @spec maybe_trigger(t(), String.t(), pid()) ::
          {t(), Completion.t() | nil}
  def maybe_trigger(bridge, char, buffer_pid) do
    clients = SyncServer.clients_for_buffer(buffer_pid)

    case clients do
      [] ->
        {bridge, nil}

      _ ->
        # Collect trigger characters from all clients
        all_trigger_chars =
          clients
          |> Enum.flat_map(&get_trigger_characters/1)
          |> Enum.uniq()

        # Use the first client for debounce scheduling, but send to all on fire
        [first_client | _] = clients

        handle_char_type(bridge, char, all_trigger_chars, clients, first_client, buffer_pid)
    end
  end

  @doc """
  Called when the debounce timer fires. Sends completion requests to all
  LSP servers attached to the buffer.
  """
  @spec flush_debounce(t(), [pid()], pid()) :: t()
  def flush_debounce(bridge, clients, buffer_pid) when is_list(clients) do
    {bridge, _completion} = send_completion_requests(bridge, clients, buffer_pid)
    bridge
  end

  @spec flush_debounce(t(), pid(), pid()) :: t()
  def flush_debounce(bridge, client, buffer_pid) when is_pid(client) do
    {bridge, _completion} = send_completion_requests(bridge, [client], buffer_pid)
    bridge
  end

  @doc """
  Classifies an incoming LSP completion response and updates the bridge's
  pending-ref bookkeeping, *without* parsing the (potentially huge) item list.

  This is the cheap, on-the-Editor half of completion handling: it matches the
  response `ref` against the bridge's pending refs and decides what the caller
  should do, then returns the trigger position, the prefix typed since the
  trigger, and the current request generation. The expensive parse/sort/filter
  is performed by the caller in a Task (see `MingaEditor.CompletionHandling`).

  Returns `{updated_bridge, classification}` where classification is one of:

    * `{:primary, trigger_pos, prefix, gen}` — the authoritative response for
      the request batch; the processed result replaces the menu.
    * `{:merge, trigger_pos, prefix, gen}` — a secondary server's response to
      merge into the existing menu.
    * `:ignore` — stale ref, error, or no live request.
  """
  @spec classify_response(t(), reference(), {:ok, term()} | {:error, term()}, pid()) ::
          {t(), classification()}
  def classify_response(bridge, ref, result, buffer_pid)

  def classify_response(%{pending_ref: ref} = bridge, ref, {:ok, _result}, buffer_pid) do
    trigger_pos = bridge.trigger_position || get_cursor_position(buffer_pid)
    prefix = get_typed_since_trigger(buffer_pid, trigger_pos)
    remaining = MapSet.delete(bridge.pending_refs, ref)
    bridge = %{bridge | pending_ref: nil, pending_refs: remaining}
    {bridge, {:primary, trigger_pos, prefix, bridge.gen}}
  end

  # Response from a secondary server: merge into existing completion.
  def classify_response(%{pending_refs: refs} = bridge, ref, {:ok, _result}, buffer_pid) do
    if MapSet.member?(refs, ref) do
      trigger_pos = bridge.trigger_position || get_cursor_position(buffer_pid)
      prefix = get_typed_since_trigger(buffer_pid, trigger_pos)
      remaining = MapSet.delete(refs, ref)
      bridge = %{bridge | pending_refs: remaining}
      {bridge, {:merge, trigger_pos, prefix, bridge.gen}}
    else
      # Stale ref, ignore.
      {bridge, :ignore}
    end
  end

  def classify_response(bridge, _ref, {:error, error}, _buffer_pid) do
    Minga.Log.debug(:lsp, "Completion request failed: #{inspect(error)}")
    {%{bridge | pending_ref: nil}, :ignore}
  end

  # Stale response (ref doesn't match any pending request).
  def classify_response(bridge, _ref, _result, _buffer_pid) do
    {bridge, :ignore}
  end

  @doc """
  Dismisses any active completion state and cancels pending requests.
  """
  @spec dismiss(t()) :: t()
  def dismiss(bridge) do
    bridge = cancel_debounce(bridge)
    %{bridge | pending_ref: nil, pending_refs: MapSet.new(), trigger_position: nil}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  @spec handle_char_type(t(), String.t(), [String.t()], [pid()], pid(), pid()) ::
          {t(), Completion.t() | nil}
  defp handle_char_type(bridge, char, trigger_chars, clients, first_client, buffer_pid) do
    classify_char(bridge, char, char in trigger_chars, clients, first_client, buffer_pid)
  end

  defp classify_char(bridge, _char, true = _is_trigger, clients, _first_client, buffer_pid) do
    bridge = cancel_debounce(bridge)
    send_completion_requests(bridge, clients, buffer_pid)
  end

  defp classify_char(bridge, char, false = _is_trigger, clients, _first_client, buffer_pid) do
    if identifier_char?(char) do
      schedule_debounced_trigger(bridge, clients, buffer_pid)
    else
      {dismiss(bridge), nil}
    end
  end

  # Sends completion requests to ALL LSP clients for the buffer.
  # Tracks all refs so responses from any client can be merged.
  @spec send_completion_requests(t(), [pid()], pid()) :: {t(), nil}
  defp send_completion_requests(bridge, clients, buffer_pid) do
    file_path = Buffer.file_path(buffer_pid)

    case file_path do
      nil ->
        {bridge, nil}

      path ->
        uri = SyncServer.path_to_uri(path)
        {line, col} = get_cursor_position(buffer_pid)

        params = %{
          "textDocument" => %{"uri" => uri},
          "position" => %{"line" => line, "character" => col}
        }

        refs =
          Enum.map(clients, fn client ->
            Client.request(client, "textDocument/completion", params)
          end)

        primary_ref = List.first(refs)
        all_refs = MapSet.new(refs)

        # Mint a new generation for this request batch. A processed result that
        # carries an older generation is discarded at apply time (latest-wins),
        # so a slow Task from a superseded request can never clobber the menu.
        {%{
           bridge
           | pending_ref: primary_ref,
             pending_refs: all_refs,
             trigger_position: {line, col},
             gen: bridge.gen + 1
         }, nil}
    end
  end

  @spec schedule_debounced_trigger(t(), [pid()], pid()) :: {t(), nil}
  defp schedule_debounced_trigger(bridge, clients, buffer_pid) do
    bridge = cancel_debounce(bridge)

    # Only trigger if we have 2+ identifier chars typed
    {line, col} = get_cursor_position(buffer_pid)
    prefix_len = identifier_prefix_length(buffer_pid, line, col)

    if prefix_len >= 2 do
      trigger_pos = {line, col - prefix_len}

      timer =
        Process.send_after(
          self(),
          {:completion_debounce, clients, buffer_pid},
          @debounce_ms
        )

      bridge = %{bridge | debounce_timer: timer, trigger_position: trigger_pos}
      {bridge, nil}
    else
      {bridge, nil}
    end
  end

  @spec cancel_debounce(t()) :: t()
  defp cancel_debounce(%{debounce_timer: nil} = bridge), do: bridge

  defp cancel_debounce(%{debounce_timer: timer} = bridge) do
    Process.cancel_timer(timer)
    %{bridge | debounce_timer: nil}
  end

  @spec get_trigger_characters(pid()) :: [String.t()]
  defp get_trigger_characters(client) do
    caps = Client.capabilities(client)

    caps
    |> get_in(["completionProvider", "triggerCharacters"])
    |> List.wrap()
  catch
    :exit, _ -> ["."]
  end

  @spec get_cursor_position(pid()) :: {non_neg_integer(), non_neg_integer()}
  defp get_cursor_position(buffer_pid) do
    {_content, {line, col}} = Buffer.content_and_cursor(buffer_pid)
    {line, col}
  end

  @spec get_typed_since_trigger(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t()
  @doc "Returns the text typed since the trigger position (for prefix filtering)."
  @spec get_typed_since_trigger(pid(), {non_neg_integer(), non_neg_integer()}) :: String.t()
  def get_typed_since_trigger(buffer_pid, {trigger_line, trigger_col}) do
    {content, {cursor_line, cursor_col}} = Buffer.content_and_cursor(buffer_pid)

    # Only makes sense on the same line
    if cursor_line == trigger_line and cursor_col > trigger_col do
      lines = String.split(content, "\n")

      case Enum.at(lines, cursor_line) do
        nil -> ""
        line_text -> String.slice(line_text, trigger_col, cursor_col - trigger_col)
      end
    else
      ""
    end
  end

  @spec identifier_prefix_length(pid(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  defp identifier_prefix_length(buffer_pid, line, col) do
    {content, _cursor} = Buffer.content_and_cursor(buffer_pid)
    lines = String.split(content, "\n")

    case Enum.at(lines, line) do
      nil ->
        0

      line_text ->
        # Walk backwards from col to find the start of the identifier
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
