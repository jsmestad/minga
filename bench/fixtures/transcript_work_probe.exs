defmodule Minga.Bench.TranscriptWorkProbe do
  @moduledoc "Counts transcript work in a standalone diagnostic run, separate from latency samples."

  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder
  alias Minga.Test.HeadlessPort
  alias MingaAgent.Session
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.TranscriptProjection.{Row, Tree}
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.RenderModel.UI.AgentChatResident
  alias MingaEditor.RenderModel.UI.AgentChatResident.{Entry, Trie}
  alias MingaEditor.Renderer.FrameHandler

  @sync [:minga, :agent, :transcript_sync]
  @frame [:minga, :render, :emit_prepare, :stop]
  @typep work :: %{atom() => non_neg_integer()}
  @typep observation :: {pid(), pid(), pid(), pid(), reference()}
  @typep sampled_work :: {work(), work(), %{non_neg_integer() => work()}, map()}
  @protocol_envelope_bytes 5

  @doc "Collects one source update and the following encoded frame."
  @spec measure(%{editor: pid(), port: pid()}, pid(), (-> term())) :: work()
  def measure(ctx, session, mutation), do: measure(ctx, session, mutation, :source)

  @doc "Collects work up to the first encoded frame; `:frame` mode expects no source update."
  @spec measure(%{editor: pid(), port: pid()}, pid(), (-> term()), :source | :frame) :: work()
  def measure(%{editor: editor, port: port}, session, mutation, mode) do
    %{render: %{renderer: renderer}} = :sys.get_state(editor)
    before = :sys.get_state(renderer).agent_transcript
    pids = [editor, session, renderer]
    patterns = patterns(editor)
    probe = make_ref()

    :ok =
      :telemetry.attach_many(
        probe,
        [@sync, @frame],
        &observe/4,
        {editor, renderer, port, self(), probe}
      )

    try do
      Enum.each(patterns, fn {mfa, match} ->
        {module, _function, _arity} = mfa
        Code.ensure_loaded!(module)
        1 = :erlang.trace_pattern(mfa, match, [:local])
      end)

      Enum.each(pids, fn pid ->
        1 = :erlang.trace(pid, true, [:call, :arity, {:tracer, self()}])
      end)

      mutation.()
      initial = if mode == :frame, do: %{entries_read: 0, pin_facts: 0}, else: nil
      {source_work, {frame_seq, frame_bytes, acceptance}} = await_boundary(probe, initial)
      %{outcome: :accepted, last_frame_seq: ^frame_seq} = acceptance
      {projection, _, frames, renderer_work} =
        count_calls(stop_traces(pids), editor, {%{}, %{}, %{}, %{submissions: []}})

      frame = Map.fetch!(frames, frame_seq)
      true = Map.get(frame, :transcript_bytes, 0) <= frame_bytes
      after_root = :sys.get_state(renderer).agent_transcript
      resident = resident_work(renderer_work, before, after_root)

      %{
        copied_entries: source_work.entries_read,
        pin_facts: source_work.pin_facts,
        frame_bytes: frame_bytes,
        session_calls: Map.get(projection, :session_calls, 0),
        line_derivations: Map.get(projection, :line_derivations, 0),
        projection_visits:
          Map.get(projection, :projection_visits, 0) + Map.get(projection, :summary_reads, 0),
        ordinal_path_visits: Map.get(projection, :projection_visits, 0),
        summary_reads: Map.get(projection, :summary_reads, 0),
        first_run_reads: Map.get(projection, :first_run_reads, 0),
        naming_reads: Map.get(projection, :naming_reads, 0),
        status_reads: Map.get(projection, :status_reads, 0),
        projection_copies: Map.get(projection, :projection_copies, 0),
        restyled: Map.get(projection, :restyled, 0),
        encoder_entries: Map.get(frame, :encoder_entries, 0),
        transcript_bytes: Map.get(frame, :transcript_bytes, 0)
      }
      |> Map.merge(resident)
    after
      :telemetry.detach(probe)
      Enum.each(patterns, fn {mfa, _match} -> :erlang.trace_pattern(mfa, false, [:local]) end)
      Enum.each(pids, &:erlang.trace(&1, false, [:call]))
    end
  end

  @doc false
  @spec observe([atom()], map(), map(), observation()) :: :ok
  def observe(
        @sync,
        %{entries_read: _, pin_facts: _} = measurements,
        %{outcome: :changed},
        {editor, _, _, driver, probe}
      )
      when self() == editor do
    send(driver, {probe, :source_work, measurements})
    :ok
  end

  def observe(
        @frame,
        _measurements,
        %{frame_seq: seq, byte_count: bytes},
        {_, renderer, port, driver, probe}
      )
      when self() == renderer do
    # The renderer sent this frame to the port before invoking the stop
    # handler. A call from the same sender fences that write before another
    # render can replace its transaction outcome.
    acceptance = HeadlessPort.production_state(port)
    send(driver, {probe, :encoded_frame, {seq, bytes, acceptance}})
    :ok
  end

  def observe(_event, _measurements, _metadata, _config), do: :ok

  @spec patterns(pid()) :: [{{module(), atom(), arity()}, :erlang.trace_match_spec()}]
  defp patterns(editor) do
    [
      {{Session, :handle_call, 3}, [{[:_, {editor, :_}, :_], [], [{:message, :session_calls}]}]},
      {{Transcript, :line_profile, 1}, [{[:_], [], [{:message, :line_derivations}]}]},
      {{Tree, :replace, 4}, [{[:_, :_, :_, :_], [], [{:message, :projection_visits}]}]},
      {{Tree, :summary, 1}, [{[:"$1"], [{:"/=", :"$1", nil}], [{:message, :summary_reads}]}]},
      {{Tree, :first_run?, 1}, [{[:_], [], [{:message, :first_run_reads}]}]},
      {{Tree, :names_and_turns, 1}, [{[:_], [], [{:message, :naming_reads}]}]},
      {{Tree, :turn_count, 1}, [{[:_], [], [{:message, :status_reads}]}]},
      {{Tree, :branch, 4}, [{[:_, :_, :_, :_], [], [{:message, :projection_copies}]}]},
      {{Row, :new, 2}, [{[:_, :_], [], [{:message, :projection_copies}]}]},
      {{Row, :revise, 2},
       [
         {[%{entry: %{content_revision: :"$1"}}, %{content_revision: :"$1"}], [],
          [{:message, :projection_copies}]}
       ]},
      {{Row, :pin, 2},
       [{[%{pinned?: :"$1"}, :"$2"], [{:"/=", :"$1", :"$2"}], [{:message, :projection_copies}]}]},
      {{Row, :style, 3}, [{[:_, :_, :_], [], [{:message, :projection_copies}]}]},
      {{AgentLifecycle, :style_message, 3},
       [
         {[{:assistant, :_}, :_, :_], [], [{:message, :restyled}]},
         {[{:tool_call, %{result: :"$1"}}, :_, :_], [{:is_binary, :"$1"}, {:"/=", :"$1", ""}],
          [{:message, :restyled}]}
       ]},
      {{FrameHandler, :observe_submission, 2},
       [{[:"$1", :"$2"], [], [{:message, {{:submission, :"$2", :"$1"}}}]}]},
      {{AgentChatResident, :derive, 4}, [{[:_, :_, :_, :_], [], [{:message, :builder_derivations}]}]},
      {{AgentChatResident, :rederive, 4},
       [{[:_, :_, :_, :_], [], [{:message, :decoration_derivations}]}]},
      {{AgentChatResident, :weigh, 3},
       [
         {[nil, :_, :_], [], [{:message, :footer_sizings}]},
         {[:_, :_, :_], [], [{:message, :builder_sizings}]}
       ]},
      {{Trie, :fetch_at, 3}, [{[:_, :_, :_], [], [{:message, :index_visits}]}]},
      {{Trie, :put_at, 4}, [{[:_, :_, :_, :_], [], [{:message, :index_visits}]}]},
      {{Trie, :delete_at, 3}, [{[:_, :_, :_], [], [{:message, :index_visits}]}]},
      {{Trie, :fit_node, 5}, [{[:_, :_, :_, :_, :_], [], [{:message, :index_visits}]}]},
      {{Trie, :branch, 2}, [{[:_, :_], [], [{:message, :index_copies}]}]},
      {{Trie, :reduce_node, 6},
       [
         {[%{__struct__: Entry}, :_, :_, :_, :_, :_], [], [{:message, :adapter_enumerated}]}
       ]},
      {{AgentTranscriptEncoder, :encode_changed, 5},
       [{[:_, :"$1", :_, :_, :_], [], [{:message, {{:encoder_entries, {:length, :"$1"}}}}]}]},
      {{AgentTranscriptEncoder, :frame, 1},
       [{[:"$1"], [], [{:message, {{:transcript_payload_bytes, {:byte_size, :"$1"}}}}]}]},
      {{Emit, :emit_encoded_frame, 7},
       [{[:_, :_, :_, :_, :"$1", :_, :_], [], [{:message, {{:rendered_frame, :"$1"}}}]}]}
    ]
  end

  @spec await_boundary(reference(), work() | nil) ::
          {work(), {non_neg_integer(), non_neg_integer(), map()}}
  defp await_boundary(probe, work) do
    receive do
      {^probe, :source_work, measured} ->
        next = Map.merge(work || %{}, measured, fn _key, before, amount -> before + amount end)
        await_boundary(probe, next)

      {^probe, :encoded_frame, _frame} when is_nil(work) ->
        await_boundary(probe, nil)

      {^probe, :encoded_frame, frame} ->
        {work, frame}
    after
      30_000 -> raise "the transcript mutation did not emit a changed source and frame"
    end
  end

  @spec stop_traces([pid()]) :: [reference()]
  defp stop_traces(pids) do
    Enum.map(pids, fn pid ->
      1 = :erlang.trace(pid, false, [:call])
      :erlang.trace_delivered(pid)
    end)
  end

  # Transfer words are the flat BEAM size of every complete submission the
  # renderer admitted in the window. Entries transferred count the seed entries
  # or keyed changes those submissions carried; unchanged markers carry none.
  @spec resident_work(map(), AgentChatResident.t() | nil, AgentChatResident.t() | nil) :: work()
  defp resident_work(work, before, after_root) do
    submissions = Enum.reverse(work.submissions)
    updates = Enum.map(submissions, fn {_seq, submission} -> submission.transcript end)
    {before_ids, after_ids} = {resident_ids(before), resident_ids(after_root)}

    %{
      submissions: length(submissions),
      transfer_words: Enum.sum(Enum.map(submissions, &:erts_debug.flat_size(elem(&1, 1)))),
      bearing_words: bearing_words(submissions),
      transcript_words: Enum.sum(Enum.map(updates, &:erts_debug.flat_size/1)),
      transferred_entries: Enum.sum(Enum.map(updates, &update_entries/1)),
      update_kinds: Enum.map(updates, &update_kind/1),
      changed_entries: Enum.sum(Enum.map(updates, &changed_entries/1)),
      builder_derivations: Map.get(work, :builder_derivations, 0),
      decoration_derivations: Map.get(work, :decoration_derivations, 0),
      builder_sizings: Map.get(work, :builder_sizings, 0),
      footer_sizings: Map.get(work, :footer_sizings, 0),
      index_visits: Map.get(work, :index_visits, 0),
      index_copies: Map.get(work, :index_copies, 0),
      index_height: if(after_root, do: AgentChatResident.height(after_root), else: 0),
      cap_evictions: MapSet.size(MapSet.difference(before_ids, after_ids)),
      cap_admissions: MapSet.size(MapSet.difference(after_ids, before_ids)),
      adapter_enumerated: Map.get(work, :adapter_enumerated, 0)
    }
  end

  # The largest submission in the window that carries transcript content; an
  # unchanged window reports its largest submission.
  defp bearing_words(submissions) do
    sizes =
      for {_seq, submission} <- submissions,
          update_kind(submission.transcript) in [:changes, :seed],
          do: :erts_debug.flat_size(submission)

    case sizes do
      [] -> submissions |> Enum.map(&:erts_debug.flat_size(elem(&1, 1))) |> Enum.max(fn -> 0 end)
      sizes -> Enum.max(sizes)
    end
  end

  defp resident_ids(nil), do: MapSet.new()

  defp resident_ids(root) do
    {messages, _truncated?} = AgentChatResident.resident_messages(root)
    MapSet.new(messages, &elem(&1, 0))
  end

  defp update_kind(nil), do: :none
  defp update_kind(update), do: elem(update, 0)

  defp update_entries({:seed, _, _, _, entries}), do: length(entries)
  defp update_entries({:changes, _, _, _, _, changes}), do: Enum.count(changes, &(elem(&1, 0) == :put))
  defp update_entries(_update), do: 0

  defp changed_entries({:changes, _, _, _, _, changes}), do: length(changes)
  defp changed_entries({:seed, _, _, _, entries}), do: length(entries)
  defp changed_entries(_update), do: 0

  @spec count_calls([reference()], pid(), sampled_work()) :: sampled_work()
  defp count_calls([], _editor, work), do: work

  defp count_calls(barriers, editor, work) do
    receive do
      {:trace, pid, :call, _mfa, value} ->
        count_calls(barriers, editor, count(value, pid == editor, work))

      {:trace_delivered, _pid, ref} ->
        count_calls(List.delete(barriers, ref), editor, work)
    after
      30_000 -> raise "transcript work trace did not drain"
    end
  end

  @spec count(term(), boolean(), sampled_work()) :: sampled_work()
  defp count({:submission, seq, submission}, _from_editor?, {projection, frame, finished, work}),
    do:
      {projection, frame, finished,
       Map.update!(work, :submissions, &[{seq, submission} | &1])}

  defp count(metric, false, {projection, frame, finished, work})
       when metric in [
              :builder_derivations,
              :decoration_derivations,
              :builder_sizings,
              :footer_sizings,
              :index_visits,
              :index_copies,
              :adapter_enumerated
            ],
       do: {projection, frame, finished, add(work, metric, 1)}

  defp count(metric, true, {projection, frame, finished, work})
       when metric in [
              :restyled,
              :line_derivations,
              :projection_visits,
              :summary_reads,
              :first_run_reads,
              :naming_reads,
              :status_reads,
              :projection_copies
            ],
       do: {add(projection, metric, 1), frame, finished, work}

  defp count(:session_calls, false, {projection, frame, finished, work}),
    do: {add(projection, :session_calls, 1), frame, finished, work}

  defp count({:rendered_frame, seq}, _from_editor?, {projection, frame, finished, work}),
    do: {projection, %{}, Map.put(finished, seq, frame), work}

  defp count({:transcript_payload_bytes, bytes}, _from_editor?, {projection, frame, finished, work}),
    do:
      {projection, add(frame, :transcript_bytes, bytes + @protocol_envelope_bytes), finished,
       work}

  defp count({:encoder_entries, value}, _from_editor?, {projection, frame, finished, work}),
    do: {projection, add(frame, :encoder_entries, value), finished, work}

  defp count(_other, _from_editor?, work), do: work

  @spec add(work(), atom(), non_neg_integer()) :: work()
  defp add(totals, name, by), do: Map.update(totals, name, by, &(&1 + by))
end
