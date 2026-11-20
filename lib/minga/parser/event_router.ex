defmodule Minga.Parser.EventRouter do
  @moduledoc """
  Parser event decoding, snippet correlation, and editor-buffer event routing.

  The manager supplies synchronization work and installs the returned values.
  Parser buffer IDs never escape to editor presentation.
  """

  alias Minga.Language.Grammar
  alias Minga.Parser.BufferRegistration
  alias Minga.Parser.BufferRegistry
  alias Minga.Parser.EventCorrelation
  alias Minga.Parser.ParseSync
  alias Minga.Parser.PortLifecycle
  alias Minga.Parser.Protocol
  alias Minga.Parser.RequestHandler
  alias Minga.Parser.SnippetState

  @snippet_buffer_id_start 4_000_000_000

  @type route_result :: {ParseSync.t(), SnippetState.t()}
  @type highlight_start_result ::
          {:noreply, SnippetState.t()} | {:reply, :unsupported, SnippetState.t()}
  @type highlight_source_event ::
          {:highlight_names, non_neg_integer(), [String.t()]}
          | {:highlight_spans, non_neg_integer(), non_neg_integer(),
             [Minga.Language.Highlight.Span.t()]}

  @doc "Starts a synchronous snippet highlight request or reports an unsupported grammar."
  @spec start_highlight(
          String.t(),
          String.t(),
          non_neg_integer(),
          GenServer.from(),
          port() | nil,
          SnippetState.t()
        ) :: highlight_start_result()
  def start_highlight(language, source, timeout, from, port, snippets) do
    case Grammar.read_query(language) do
      {:ok, query} ->
        start_highlight_request(language, query, source, timeout, from, port, snippets)

      {:error, _reason} ->
        {:reply, :unsupported, snippets}
    end
  end

  @doc "Routes one encoded parser frame to a synchronous requester or subscriber."
  @spec route(binary(), port() | nil, ParseSync.t(), SnippetState.t(), %{pid() => reference()}) ::
          route_result()
  def route(data, port, work, snippets, subscribers) do
    case Protocol.decode_event(data) do
      {:ok, {:indent_result, request_id, _line, indent_level}} ->
        {reply_request(work, request_id, indent_level), snippets}

      {:ok, {kind, request_id, result}}
      when kind in [:textobject_result, :match_item_result, :node_info] ->
        {reply_request(work, request_id, result), snippets}

      {:ok, {:highlight_names, _buffer_id, _names} = event} ->
        handle_highlight_or_broadcast(event, port, work, snippets, subscribers)

      {:ok, {:highlight_spans, _buffer_id, _version, _spans} = event} ->
        handle_highlight_or_broadcast(event, port, work, snippets, subscribers)

      {:ok, {:request_reparse, buffer_id}} ->
        {recover_parser_buffer(work, port, buffer_id), snippets}

      {:ok, {:log_message, _level, _text} = event} ->
        broadcast(subscribers, {:minga_highlight, event})
        {work, snippets}

      {:ok, event} ->
        broadcast_or_drop_snippet_event(event, port, work, snippets, subscribers)

      :unknown ->
        Minga.Log.warning(:port, "Parser: received unknown opcode")
        {work, snippets}

      {:error, reason} ->
        Minga.Log.warning(:port, "Parser: failed to decode event: #{inspect(reason)}")
        {work, snippets}
    end
  end

  @doc "Times out and closes one synchronous snippet buffer."
  @spec timeout_highlight(non_neg_integer(), port() | nil, SnippetState.t()) ::
          {:noreply, SnippetState.t()}
  def timeout_highlight(buffer_id, port, snippets) do
    case SnippetState.pop(snippets, buffer_id) do
      {nil, _snippets} ->
        {:noreply, snippets}

      {pending, snippets} ->
        GenServer.reply(pending.from, :timeout)
        PortLifecycle.close_buffer(port, buffer_id)
        {:noreply, snippets}
    end
  end

  @spec start_highlight_request(
          String.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          GenServer.from(),
          port() | nil,
          SnippetState.t()
        ) :: {:noreply, SnippetState.t()}
  defp start_highlight_request(language, query, source, timeout, from, port, snippets) do
    buffer_id = SnippetState.next_buffer_id(snippets)
    timer_ref = Process.send_after(self(), {:highlight_source_timeout, buffer_id}, timeout)
    pending = %{from: from, names: nil, spans: nil, timer_ref: timer_ref}
    {^buffer_id, snippets} = SnippetState.allocate(snippets, pending)

    commands = [
      Protocol.encode_set_language(buffer_id, language),
      Protocol.encode_set_highlight_query(buffer_id, query),
      Protocol.encode_parse_buffer(buffer_id, 1, source)
    ]

    _sent? = PortLifecycle.send_batch(port, commands)
    {:noreply, snippets}
  end

  @spec handle_highlight_or_broadcast(
          highlight_source_event(),
          port() | nil,
          ParseSync.t(),
          SnippetState.t(),
          %{pid() => reference()}
        ) :: route_result()
  defp handle_highlight_or_broadcast(event, port, work, snippets, subscribers) do
    case handle_highlight_event(event, port, snippets) do
      {:handled, snippets} ->
        {work, snippets}

      :miss ->
        broadcast_or_drop_snippet_event(event, port, work, snippets, subscribers)
    end
  end

  @spec handle_highlight_event(highlight_source_event(), port() | nil, SnippetState.t()) ::
          {:handled, SnippetState.t()} | :miss
  defp handle_highlight_event({:highlight_names, buffer_id, names}, port, snippets),
    do: update_highlight_pending(buffer_id, :names, names, port, snippets)

  defp handle_highlight_event({:highlight_spans, buffer_id, _version, spans}, port, snippets),
    do: update_highlight_pending(buffer_id, :spans, spans, port, snippets)

  @spec broadcast_or_drop_snippet_event(
          term(),
          port() | nil,
          ParseSync.t(),
          SnippetState.t(),
          %{pid() => reference()}
        ) :: route_result()
  defp broadcast_or_drop_snippet_event(event, port, work, snippets, subscribers) do
    if snippet_buffer_event?(event) do
      Minga.Log.debug(:port, "Parser: dropping late snippet event #{inspect(event_name(event))}")
      {work, snippets}
    else
      {broadcast_editor_event(event, work, port, subscribers), snippets}
    end
  end

  @spec broadcast_editor_event(
          term(),
          ParseSync.t(),
          port() | nil,
          %{pid() => reference()}
        ) :: ParseSync.t()
  defp broadcast_editor_event(
         {:highlight_spans, buffer_id, version, _spans} = event,
         work,
         port,
         subscribers
       ) do
    with buffer_pid when is_pid(buffer_pid) <- BufferRegistry.resolve(work.buffers, buffer_id),
         {:ok, next_work, completed} <- ParseSync.complete_parse(work, port, buffer_pid, version) do
      broadcast(subscribers, {:minga_highlight, tag_editor_buffer(event, buffer_pid, completed)})
      next_work
    else
      _stale_or_missing -> work
    end
  end

  defp broadcast_editor_event(event, work, _port, subscribers) do
    case editor_event_identity(event) do
      {:versioned, buffer_id, version} ->
        broadcast_versioned(work.buffers, buffer_id, version, event, subscribers)

      {:unversioned, buffer_id} ->
        broadcast_registered(work.buffers, buffer_id, event, subscribers)

      :global ->
        broadcast(subscribers, {:minga_highlight, event})
    end

    work
  end

  @spec editor_event_identity(term()) ::
          {:versioned, non_neg_integer(), pos_integer()}
          | {:unversioned, non_neg_integer()}
          | :global
  defp editor_event_identity({:conceal_spans, id, version, _}), do: {:versioned, id, version}
  defp editor_event_identity({:fold_ranges, id, version, _}), do: {:versioned, id, version}

  defp editor_event_identity({:textobject_positions, id, version, _}),
    do: {:versioned, id, version}

  defp editor_event_identity({:document_symbols, id, version, _}), do: {:versioned, id, version}
  defp editor_event_identity({:highlight_names, id, _}), do: {:unversioned, id}
  defp editor_event_identity({:injection_ranges, id, _}), do: {:unversioned, id}
  defp editor_event_identity(_event), do: :global

  @spec broadcast_versioned(BufferRegistry.t(), non_neg_integer(), pos_integer(), term(), %{
          pid() => reference()
        }) :: :ok
  defp broadcast_versioned(buffers, buffer_id, version, event, subscribers) do
    with buffer_pid when is_pid(buffer_pid) <- BufferRegistry.resolve(buffers, buffer_id),
         {:ok, registration} <- BufferRegistry.fetch(buffers, buffer_pid),
         true <- BufferRegistration.accepts_version?(registration, version) do
      broadcast(
        subscribers,
        {:minga_highlight, tag_editor_buffer(event, buffer_pid, registration)}
      )
    end

    :ok
  end

  @spec broadcast_registered(BufferRegistry.t(), non_neg_integer(), term(), %{
          pid() => reference()
        }) :: :ok
  defp broadcast_registered(buffers, buffer_id, event, subscribers) do
    with buffer_pid when is_pid(buffer_pid) <- BufferRegistry.resolve(buffers, buffer_id),
         {:ok, registration} <- BufferRegistry.fetch(buffers, buffer_pid) do
      broadcast(
        subscribers,
        {:minga_highlight, tag_editor_buffer(event, buffer_pid, registration)}
      )
    end

    :ok
  end

  @spec tag_editor_buffer(term(), pid(), BufferRegistration.t()) :: term()
  defp tag_editor_buffer(event, buffer_pid, registration) do
    correlation =
      EventCorrelation.new(registration.generation, event_parse_version(event, registration))

    {:buffer_event, buffer_pid, correlation, strip_editor_identity(event)}
  end

  @spec event_parse_version(term(), BufferRegistration.t()) :: non_neg_integer()
  defp event_parse_version(event, registration) do
    case editor_event_identity(event) do
      {:versioned, _buffer_id, version} -> version
      _other -> registration_parse_version(registration)
    end
  end

  @spec registration_parse_version(BufferRegistration.t()) :: non_neg_integer()
  defp registration_parse_version(%BufferRegistration{phase: {:parsing, version, _target}}),
    do: version

  defp registration_parse_version(%BufferRegistration{last_completed_version: version}),
    do: version

  @spec strip_editor_identity(term()) :: term()
  defp strip_editor_identity({:highlight_names, _id, value}), do: {:highlight_names, value}

  defp strip_editor_identity({:highlight_spans, _id, _version, value}),
    do: {:highlight_spans, value}

  defp strip_editor_identity({:injection_ranges, _id, value}), do: {:injection_ranges, value}
  defp strip_editor_identity({:conceal_spans, _id, _version, value}), do: {:conceal_spans, value}
  defp strip_editor_identity({:fold_ranges, _id, _version, value}), do: {:fold_ranges, value}

  defp strip_editor_identity({:textobject_positions, _id, _version, value}),
    do: {:textobject_positions, value}

  defp strip_editor_identity({:document_symbols, _id, _version, value}),
    do: {:document_symbols, value}

  defp strip_editor_identity(event), do: event

  @spec update_highlight_pending(
          non_neg_integer(),
          :names | :spans,
          [term()],
          port() | nil,
          SnippetState.t()
        ) ::
          {:handled, SnippetState.t()} | :miss
  defp update_highlight_pending(buffer_id, field, value, port, snippets) do
    case SnippetState.fetch(snippets, buffer_id) do
      :error ->
        :miss

      {:ok, pending} ->
        maybe_complete_highlight(buffer_id, Map.put(pending, field, value), port, snippets)
    end
  end

  @spec maybe_complete_highlight(
          non_neg_integer(),
          SnippetState.pending_highlight(),
          port() | nil,
          SnippetState.t()
        ) ::
          {:handled, SnippetState.t()}
  defp maybe_complete_highlight(
         buffer_id,
         %{names: names, spans: spans} = pending,
         port,
         snippets
       )
       when is_list(names) and is_list(spans) do
    Process.cancel_timer(pending.timer_ref)
    GenServer.reply(pending.from, {:ok, names, spans})
    {_pending, snippets} = SnippetState.pop(snippets, buffer_id)
    PortLifecycle.close_buffer(port, buffer_id)
    {:handled, snippets}
  end

  defp maybe_complete_highlight(buffer_id, pending, _port, snippets),
    do: {:handled, SnippetState.put(snippets, buffer_id, pending)}

  @spec recover_parser_buffer(ParseSync.t(), port() | nil, non_neg_integer()) :: ParseSync.t()
  defp recover_parser_buffer(work, port, buffer_id) do
    case BufferRegistry.resolve(work.buffers, buffer_id) do
      buffer_pid when is_pid(buffer_pid) -> ParseSync.force_parse(work, port, buffer_pid)
      nil -> work
    end
  end

  @spec snippet_buffer_event?(term()) :: boolean()
  defp snippet_buffer_event?(event), do: snippet_buffer_id?(event_buffer_id(event))

  @spec event_buffer_id(term()) :: non_neg_integer() | nil
  defp event_buffer_id({:highlight_names, id, _}), do: id
  defp event_buffer_id({:highlight_spans, id, _, _}), do: id
  defp event_buffer_id({:injection_ranges, id, _}), do: id
  defp event_buffer_id({:fold_ranges, id, _, _}), do: id
  defp event_buffer_id({:textobject_positions, id, _, _}), do: id
  defp event_buffer_id({:document_symbols, id, _, _}), do: id
  defp event_buffer_id({:conceal_spans, id, _, _}), do: id
  defp event_buffer_id(_event), do: nil

  @spec snippet_buffer_id?(non_neg_integer() | nil) :: boolean()
  defp snippet_buffer_id?(id) when is_integer(id), do: id >= @snippet_buffer_id_start
  defp snippet_buffer_id?(_id), do: false

  @spec event_name(tuple()) :: atom()
  defp event_name(event), do: elem(event, 0)

  @spec reply_request(ParseSync.t(), non_neg_integer(), term()) :: ParseSync.t()
  defp reply_request(work, request_id, result) do
    {:noreply, requests} = RequestHandler.reply(work.requests, request_id, result)
    ParseSync.put_requests(work, requests)
  end

  @spec broadcast(%{pid() => reference()}, term()) :: :ok
  defp broadcast(subscribers, message) do
    subscribers |> Map.keys() |> Enum.each(&send(&1, message))
  end
end
