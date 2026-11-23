defmodule Minga.Bench.TranscriptWorkScenario do
  @moduledoc "Measures tail text, middle tool result, collapse and pin against a bound Session."

  alias Minga.Bench.ActiveSessionProvider
  alias Minga.Bench.TranscriptWorkProbe
  alias Minga.Config.Options
  alias Minga.Recovery.ProviderFixture
  alias Minga.Test.HeadlessPort
  alias MingaAgent.Event
  alias MingaAgent.EventLog
  alias MingaAgent.Session
  alias MingaAgent.Session.Transcript
  alias MingaEditor.Shell.Runtime

  @tool_id "middle-tool"
  @typep active_request :: {pid(), String.t()}

  @spec run(keyword(), (keyword(), (map() -> map()) -> map()), (map() -> pid())) :: :ok
  def run(editor_opts, with_editor, open_agent) do
    if Mix.env() != :test, do: raise("the transcript work benchmark requires MIX_ENV=test")
    _providers = LLMDB.providers()
    Minga.Git.Stub.ensure_table()

    opts =
      editor_opts ++
        [
          agent_provider_module: MingaAgent.Providers.Native,
          agent_provider_opts: ActiveSessionProvider.options(self())
        ]

    results =
      Enum.map([100, 10_000], fn entries ->
        IO.puts("Measuring transcript work at #{entries} retained entries")
        with_editor.(opts, &scenario(&1, entries, open_agent))
      end)

    assert_transfer_independent_of_history(results)

    path =
      Path.join(System.tmp_dir!(), "minga-transcript-work-#{System.os_time(:microsecond)}.json")

    File.write!(path, JSON.encode!(%{scenarios: results}) <> "\n")
    IO.puts("Wrote transcript work: #{path}")
    :ok
  end

  @spec scenario(map(), pos_integer(), (map() -> pid())) :: map()
  defp scenario(ctx, entries, open_agent) do
    {:ok, _} = Options.set(:agent_model, MingaAgent.Test.ModelSelectionFixture.model_intent())
    file_tab = active_tab(ctx.editor)
    session = open_agent.(ctx)
    agent_tab = active_tab(ctx.editor)

    try do
      switch_tab(ctx, file_tab)
      request = seed_request(session, entries)

      {:snapshot, %{count: ^entries, entries: history}} =
        Session.transcript_since(session, :snapshot)

      %{id: tool_id, message: {:tool_call, %{id: @tool_id}}} = Enum.at(history, div(entries, 2))
      %{id: tail_id, message: {:assistant, tail}} = List.last(history)
      switch_tab(ctx, agent_tab)
      ref = HeadlessPort.prepare_await(ctx.port, 1)
      send(ctx.editor, {:minga_input, {:key_press, ?a, 0, 1}})
      {:ok, %{agent_chat: %{lifecycle: :conversation}}} = HeadlessPort.collect_frame(ref, 30_000)

      text =
        TranscriptWorkProbe.measure(ctx, session, fn ->
          emit(request, %Event.TextDelta{delta: " +tail"})
        end)

      {:snapshot, %{count: ^entries, entries: history}} =
        Session.transcript_since(session, :snapshot)

      %{id: ^tail_id, message: {:assistant, revised}} = List.last(history)
      true = revised == tail <> " +tail"

      tool =
        TranscriptWorkProbe.measure(ctx, session, fn ->
          emit(request, %Event.ToolEnd{
            tool_call_id: @tool_id,
            name: "read_file",
            outcome: :complete,
            result: "Middle result\nwith another line"
          })
        end)

      before = middle_tool(session, entries, tool_id)
      "Middle result\nwith another line" = before.result

      collapse =
        TranscriptWorkProbe.measure(ctx, session, fn ->
          :ok = Session.toggle_tool_collapse(session, tool_id)
        end)

      true = before.collapsed != middle_tool(session, entries, tool_id).collapsed

      pin =
        TranscriptWorkProbe.measure(ctx, session, fn ->
          :ok = Session.toggle_pin(session, tool_id)
        end)

      {:snapshot, %{pinned_ids: pinned}} = Session.transcript_since(session, :snapshot)
      true = MapSet.member?(pinned, tool_id)

      switch_tab(ctx, file_tab)
      pin_entire_history(session)
      switch_tab(ctx, agent_tab)

      append =
        TranscriptWorkProbe.measure(ctx, session, fn ->
          emit(request, %Event.ThinkingDelta{delta: "Appended with the whole history pinned"})
        end)

      composer =
        TranscriptWorkProbe.measure(
          ctx,
          session,
          fn -> send(ctx.editor, {:minga_input, {:key_press, ?i, 0, 1}}) end,
          :frame
        )

      assert_work(text, entries, :content)
      assert_work(tool, entries, :content)
      assert_work(collapse, entries, :collapse)
      assert_work(pin, entries, :pin)
      assert_work(append, entries, :append)
      Enum.each([text, tool, collapse, pin, append], &assert_resident_work(&1, entries))
      assert_composer_work(composer, entries)

      expected = entries + 1

      {:snapshot, %{count: ^expected, pinned_ids: pinned}} =
        Session.transcript_since(session, :snapshot)

      ^entries = MapSet.size(pinned)

      %{
        retained_entries: entries,
        operations: %{
          tail_text: text,
          middle_tool_result: tool,
          collapse: collapse,
          pin: pin,
          fully_pinned_append: append,
          composer_only: composer
        }
      }
    after
      GenServer.stop(session, :normal, 30_000)
    end
  end

  defp pin_entire_history(session) do
    :sys.replace_state(session, fn %{transcript: transcript} = state ->
      {:snapshot, snapshot} = Transcript.since(transcript, :snapshot)

      transcript =
        Enum.reduce(snapshot.entries, transcript, fn entry, acc ->
          if MapSet.member?(snapshot.pinned_ids, entry.id),
            do: acc,
            else: Transcript.toggle_pin(acc, entry.id)
        end)

      %{state | transcript: transcript}
    end)
  end

  defp assert_work(work, entries, operation) do
    height = entries |> :math.log2() |> ceil()
    bound = 2 * (height + 1) + 2

    expected =
      case operation do
        :content -> {1, 0, 1, 1}
        :collapse -> {1, 0, 0, 0}
        :pin -> {0, 1, 0, 0}
        :append -> {1, 0, 1, 0}
      end

    actual = {work.copied_entries, work.pin_facts, work.line_derivations, work.restyled}

    unless work.session_calls == 1 and
             work.projection_visits <= bound and work.projection_copies <= bound and
             actual == expected do
      raise "#{operation} exceeded the transcript work contract at #{entries} entries: #{inspect(work)} (node bound #{bound})"
    end
  end

  # Renderer gate: one changed entry is transferred, derived and sized once;
  # unchanged bodies and footer bodies are not. Index node visits and copies stay
  # within 4 × (K+B+1) × (H+1) for K changed entries and B cap evictions plus
  # admissions.
  defp assert_resident_work(work, entries) do
    k = work.changed_entries
    b = work.cap_evictions + work.cap_admissions
    bound = 4 * (k + b + 1) * (work.index_height + 1)

    unless work.transferred_entries <= 1 and work.builder_derivations <= 1 and
             work.builder_sizings == work.builder_derivations and work.footer_sizings == 0 and
             work.decoration_derivations == 0 and work.index_visits <= bound and
             work.index_copies <= bound and :seed not in work.update_kinds do
      raise "resident transcript work exceeded the contract at #{entries} entries: #{inspect(work)} (node bound #{bound})"
    end
  end

  defp assert_composer_work(work, entries) do
    unless work.transferred_entries == 0 and work.builder_derivations == 0 and
             work.builder_sizings == 0 and work.index_visits == 0 and work.index_copies == 0 and
             Enum.all?(work.update_kinds, &(&1 == :unchanged)) do
      raise "a composer-only frame did transcript work at #{entries} entries: #{inspect(work)}"
    end
  end

  # Matched one-entry updates with identical bodies must not transfer more
  # flat BEAM words as retained history grows.
  defp assert_transfer_independent_of_history([small, large]) do
    for {operation, small_work} <- small.operations do
      large_work = Map.fetch!(large.operations, operation)

      if large_work.bearing_words > small_work.bearing_words do
        raise "#{operation} transferred #{large_work.bearing_words} words at #{large.retained_entries} entries but #{small_work.bearing_words} at #{small.retained_entries}"
      end
    end

    :ok
  end

  @spec seed_request(pid(), pos_integer()) :: active_request()
  defp seed_request(session, entries) do
    :ok = Session.send_prompt(session, "Benchmark retained transcript work")

    receive do
      {:recovery_request, transport_request} ->
        :ok = ProviderFixture.deliver(transport_request, ActiveSessionProvider.stream(self()))
    after
      15_000 -> raise "Session did not dispatch the benchmark request"
    end

    receive do
      {:active_stream_consumer, _consumer} -> :ok
    after
      15_000 -> raise "Native did not open its controlled stream"
    end

    # Retain Native's real admitted request identity. The controlled stream is
    # paused while the fixture orders provider events, including the late tool
    # result. Every event still enters the normal Session provider boundary.
    %{continuation: %{active_request: %{request_id: request_id}}} = :sys.get_state(session)
    request = {session, request_id}
    {:snapshot, %{count: initial}} = Session.transcript_since(session, :snapshot)
    middle = div(entries, 2)
    true = initial < middle
    seed_history(request, initial..(middle - 1), middle)
    emit(request, %Event.ToolStart{tool_call_id: @tool_id, name: "read_file", args: %{}})
    seed_history(request, (middle + 1)..(entries - 1), entries)
    # A control event makes Ingest forward the last text batch before the tab arrives.
    emit(request, %Event.ContextUsage{estimated_tokens: 0, context_limit: 100_000})
    request
  end

  @spec seed_history(active_request(), Range.t(), pos_integer()) :: :ok
  defp seed_history({session, _} = request, indices, end_index) do
    indices
    |> Stream.chunk_every(256)
    |> Enum.each(fn batch ->
      Enum.each(batch, &emit_history_entry(request, &1, end_index))
      _status = Session.status(session)
      :ok = EventLog.await_idle()
    end)
  end

  @spec emit_history_entry(active_request(), non_neg_integer(), pos_integer()) :: :ok
  defp emit_history_entry(request, index, end_index) do
    # Fixed-width text keeps matched updates byte-identical at every history size.
    delta = "Retained #{String.pad_leading(Integer.to_string(index), 5, "0")}"

    case rem(end_index - index, 2) do
      1 -> emit(request, %Event.TextDelta{delta: delta})
      0 -> emit(request, %Event.ThinkingDelta{delta: delta})
    end
  end

  @spec emit(active_request(), Event.t()) :: :ok
  defp emit({session, request}, event) do
    send(session, {:agent_provider_event, request, event})
    :ok
  end

  @spec middle_tool(pid(), pos_integer(), pos_integer()) :: MingaAgent.ToolCall.t()
  defp middle_tool(session, entries, id) do
    {:snapshot, %{count: ^entries, entries: history}} =
      Session.transcript_since(session, :snapshot)

    %{id: ^id, message: {:tool_call, tool}} = Enum.at(history, div(entries, 2))
    tool
  end

  @spec active_tab(pid()) :: pos_integer()
  defp active_tab(editor), do: Runtime.active_tab(:sys.get_state(editor).shell_runtime).id

  @spec switch_tab(map(), pos_integer()) :: :ok
  defp switch_tab(%{editor: editor, port: port}, tab) do
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:gui_action, {:select_tab, tab}}})
    {:ok, _frame} = HeadlessPort.collect_frame(ref, 30_000)
    ^tab = active_tab(editor)
    :ok
  end
end
