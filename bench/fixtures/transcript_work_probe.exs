defmodule Minga.Bench.TranscriptWorkProbe do
  @moduledoc "Counts transcript work in a standalone diagnostic run, separate from latency samples."

  alias Minga.Frontend.Adapter.GUI.AgentTranscriptEncoder
  alias Minga.Test.HeadlessPort
  alias MingaAgent.Session
  alias MingaEditor.Agent.Transcript
  alias MingaEditor.Agent.UIState.Panel
  alias MingaEditor.AgentLifecycle
  alias MingaEditor.Frontend.Emit
  alias MingaEditor.RenderModel.UI.AgentChatBuilder

  @sync [:minga, :agent, :transcript_sync]
  @frame [:minga, :render, :emit_prepare, :stop]
  @typep work :: %{atom() => non_neg_integer()}
  @typep observation :: {pid(), pid(), pid(), pid(), reference()}
  @typep sampled_work :: {work(), work(), %{non_neg_integer() => work()}}
  @protocol_envelope_bytes 5

  @doc "Collects one source update and the following encoded frame."
  @spec measure(%{editor: pid(), port: pid()}, pid(), (-> term())) :: work()
  def measure(%{editor: editor, port: port}, session, mutation) do
    %{render: %{renderer: renderer}} = :sys.get_state(editor)
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
      {source_entries, {frame_seq, frame_bytes, acceptance}} = await_boundary(probe, nil)
      %{outcome: :accepted, last_frame_seq: ^frame_seq} = acceptance
      {projection, _, frames} = count_calls(stop_traces(pids), {%{}, %{}, %{}})
      frame = Map.fetch!(frames, frame_seq)
      true = Map.get(frame, :transcript_bytes, 0) <= frame_bytes

      %{
        copied_entries: source_entries,
        frame_bytes: frame_bytes,
        session_calls: Map.fetch!(projection, :session_calls),
        display_entries: Map.fetch!(projection, :display_entries),
        markdown_bytes: Map.fetch!(projection, :markdown_bytes),
        restyled: Map.get(projection, :restyled, 0),
        chat_visits: Map.fetch!(frame, :chat_visits),
        encoder_entries: Map.get(frame, :encoder_entries, 0),
        transcript_bytes: Map.get(frame, :transcript_bytes, 0)
      }
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
        %{entries_read: entries},
        %{outcome: :changed},
        {editor, _, _, driver, probe}
      )
      when self() == editor do
    send(driver, {probe, :source_entries, entries})
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
      {{Transcript, :display, 2},
       [{[:"$1", :_], [], [{:message, {{:display_entries, {:length, :"$1"}}}}]}]},
      {{Panel, :cache_transcript_display, 4},
       [
         {[:_, %{markdown: :"$1"}, :_, :_], [],
          [{:message, {{:markdown_bytes, {:byte_size, :"$1"}}}}]}
       ]},
      {{AgentLifecycle, :style_message, 3},
       [
         {[{:assistant, :_}, :_, :_], [], [{:message, :restyled}]},
         {[{:tool_call, %{result: :"$1"}}, :_, :_], [{:is_binary, :"$1"}, {:"/=", :"$1", ""}],
          [{:message, :restyled}]}
       ]},
      {{AgentChatBuilder, :build_gui_messages, 4},
       [{[:"$1", :_, :_, :_], [], [{:message, {{:chat_visits, {:length, :"$1"}}}}]}]},
      {{AgentTranscriptEncoder, :encode_changed, 5},
       [{[:_, :"$1", :_, :_, :_], [], [{:message, {{:encoder_entries, {:length, :"$1"}}}}]}]},
      {{AgentTranscriptEncoder, :frame, 1},
       [{[:"$1"], [], [{:message, {{:transcript_payload_bytes, {:byte_size, :"$1"}}}}]}]},
      {{Emit, :emit_encoded_frame, 7},
       [{[:_, :_, :_, :_, :"$1", :_, :_], [], [{:message, {{:rendered_frame, :"$1"}}}]}]}
    ]
  end

  @spec await_boundary(reference(), non_neg_integer() | nil) ::
          {non_neg_integer(), {non_neg_integer(), non_neg_integer(), map()}}
  defp await_boundary(probe, entries) do
    receive do
      {^probe, :source_entries, value} -> await_boundary(probe, (entries || 0) + value)
      {^probe, :encoded_frame, _frame} when is_nil(entries) -> await_boundary(probe, nil)
      {^probe, :encoded_frame, frame} -> {entries, frame}
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

  @spec count_calls([reference()], sampled_work()) :: sampled_work()
  defp count_calls([], work), do: work

  defp count_calls(barriers, work) do
    receive do
      {:trace, _pid, :call, _mfa, value} ->
        count_calls(barriers, count(value, work))

      {:trace_delivered, _pid, ref} ->
        count_calls(List.delete(barriers, ref), work)
    after
      30_000 -> raise "transcript work trace did not drain"
    end
  end

  @spec count(term(), sampled_work()) :: sampled_work()
  defp count({metric, value}, {projection, frame, finished})
       when metric in [:display_entries, :markdown_bytes],
       do: {add(projection, metric, value), frame, finished}

  defp count(metric, {projection, frame, finished}) when metric in [:restyled, :session_calls],
    do: {add(projection, metric, 1), frame, finished}

  defp count({:rendered_frame, seq}, {projection, frame, finished}),
    do: {projection, %{}, Map.put(finished, seq, frame)}

  defp count({:transcript_payload_bytes, bytes}, {projection, frame, finished}),
    do: {projection, add(frame, :transcript_bytes, bytes + @protocol_envelope_bytes), finished}

  defp count({metric, value}, {projection, frame, finished})
       when metric in [:chat_visits, :encoder_entries],
       do: {projection, add(frame, metric, value), finished}

  @spec add(work(), atom(), non_neg_integer()) :: work()
  defp add(totals, name, by), do: Map.update(totals, name, by, &(&1 + by))
end
