defmodule Minga.Bench.FrameStagingCapture do
  @moduledoc """
  Captures the exact frame packets a real Editor sends to a native GUI frontend for three workloads (#3652).

  The macOS `NativeRenderPerformance` target replays each capture through the production `CommandDispatcher` on the main thread, so the measured staging, freeze, and publish work uses real semantic encoder output instead of synthetic Swift values. Capture is deterministic: inputs are fixed, the Agent stream comes from the request-bound provider fixture, and no provider HTTP request is made.

  Each packet is one `Port.command/3` payload: the concatenated command binaries of one frontend admission, which is what the Swift `ProtocolReader` decodes as one `DecodedFrame`. The output file stores packets as `<<byte_size::32-big, payload::binary>>`. A JSON manifest beside it names the first measured packet; earlier packets build the starting state (keyframe, warmup).

  Workloads (220x60 native GUI, semantic UI):

    * `scroll`: a 50,000-line Elixir file, 20 warmup and 300 measured trackpad scroll batches of 3 lines each.
    * `typing`: a 2,000-line Elixir file in Insert mode, 20 warmup and 300 measured printable keys.
    * `agent_stream`: an active Agent session with 10,000 retained transcript entries, 20 warmup and 100 measured streamed text chunks.

  Run with: `MIX_ENV=test mix run bench/frame_staging_capture.exs OUTPUT_DIR`
  """

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config.Options
  alias Minga.Recovery.ProviderFixture
  alias Minga.Test.HeadlessPort
  alias MingaAgent.Session
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.Shell.Runtime

  Code.require_file("fixtures/agent_stream_replay.exs", __DIR__)
  Code.require_file("../scripts/agent_recovery_provider.exs", __DIR__)

  unless Code.ensure_loaded?(MingaAgent.Test.ModelSelectionFixture) do
    Code.require_file("../test/support/minga_agent/model_selection_fixture.ex", __DIR__)
  end

  Code.require_file("fixtures/active_session_provider.exs", __DIR__)

  @width 220
  @height 60
  @warmup 20
  @measured 300
  # A full transcript replace takes hundreds of milliseconds to replay, so the Agent workload measures fewer inputs.
  @agent_measured 100
  @scroll_lines 3
  @scroll_file_lines 50_000
  @typing_file_lines 2_000
  @retained_entries 10_000
  @typed_text ~c"the quick brown fox jumps over the lazy dog "

  @caps %Capabilities{
    frontend_type: :native_gui,
    float_support: :native,
    image_support: :native,
    semantic_ui: true
  }

  @spec run([String.t()]) :: :ok
  def run([output_dir]) do
    File.mkdir_p!(output_dir)
    Enum.each([:scroll, :typing, :agent_stream], &capture(&1, output_dir))
  end

  def run(_args),
    do: raise("usage: MIX_ENV=test mix run bench/frame_staging_capture.exs OUTPUT_DIR")

  @spec capture(atom(), String.t()) :: :ok
  defp capture(workload, output_dir) do
    IO.puts("Capturing #{workload}")
    {:ok, recorder} = Agent.start_link(fn -> [] end)

    {manifest, packets} =
      with_editor(workload, recorder, fn ctx ->
        measure_from = drive_setup(workload, ctx, recorder)
        manifest = drive_measured(workload, ctx)
        # Every measured input has produced its frame; the recorder holds all packets.
        _ = :sys.get_state(ctx.port)
        packets = recorded(recorder)
        {Map.merge(manifest, %{measure_from_packet: measure_from}), packets}
      end)

    Agent.stop(recorder)
    bin_path = Path.join(output_dir, "#{workload}.packets")
    File.write!(bin_path, Enum.map(packets, &[<<byte_size(&1)::32-big>>, &1]))

    manifest =
      Map.merge(manifest, %{
        workload: workload,
        viewport: "#{@width}x#{@height}",
        warmup_inputs: @warmup,
        measured_inputs: measured_inputs(workload),
        packet_count: length(packets),
        measured_packet_bytes:
          packets
          |> Enum.drop(manifest.measure_from_packet)
          |> Enum.map(&byte_size/1)
          |> Enum.sum(),
        revision: revision()
      })

    File.write!(Path.join(output_dir, "#{workload}.json"), JSON.encode!(manifest) <> "\n")

    IO.puts(
      "Wrote #{bin_path} (#{length(packets)} packets, measure from #{manifest.measure_from_packet})"
    )
  end

  # ── Workload setup and measured inputs ─────────────────────────────────────

  @spec drive_setup(atom(), map(), pid()) :: non_neg_integer()
  defp drive_setup(:scroll, ctx, recorder) do
    window_id = active_window_id(ctx)
    Enum.each(1..@warmup, fn _ -> scroll(ctx, window_id) end)
    packet_count(ctx, recorder)
  end

  defp drive_setup(:typing, ctx, recorder) do
    _ = key(ctx, ?i)
    Enum.each(0..(@warmup - 1), fn index -> key(ctx, typed(index)) end)
    packet_count(ctx, recorder)
  end

  defp drive_setup(:agent_stream, ctx, recorder) do
    {:ok, _model} =
      Options.set(:agent_model, MingaAgent.Test.ModelSelectionFixture.model_intent())

    session = open_agent(ctx)
    warm_session(session)
    {:snapshot, %{count: initial}} = Session.transcript_since(session, :snapshot)
    messages = for n <- (initial + 1)..@retained_entries, do: {:assistant, "Retained #{n}"}
    :ok = Session.seed_messages(session, messages)
    {:snapshot, %{count: @retained_entries}} = Session.transcript_since(session, :snapshot)
    :ok = Session.send_prompt(session, "Stream the fixed benchmark response")
    producer = start_stream()
    Process.put(:frame_staging_producer, producer)
    Enum.each(1..@warmup, fn _ -> stream_chunk(ctx, producer) end)
    packet_count(ctx, recorder)
  end

  @spec drive_measured(atom(), map()) :: map()
  defp drive_measured(:scroll, ctx) do
    window_id = active_window_id(ctx)
    Enum.each(1..@measured, fn _ -> scroll(ctx, window_id) end)

    %{
      file_lines: @scroll_file_lines,
      file_bytes: byte_size(document(@scroll_file_lines)),
      scroll_lines_per_input: @scroll_lines
    }
  end

  defp drive_measured(:typing, ctx) do
    Enum.each(@warmup..(@warmup + @measured - 1), fn index -> key(ctx, typed(index)) end)

    %{
      file_lines: @typing_file_lines,
      file_bytes: byte_size(document(@typing_file_lines)),
      typed_text: List.to_string(@typed_text)
    }
  end

  defp drive_measured(:agent_stream, ctx) do
    producer = Process.get(:frame_staging_producer)
    Enum.each(1..@agent_measured, fn _ -> stream_chunk(ctx, producer) end)
    send(producer, {:finish_benchmark_stream, self()})
    %{retained_entries: @retained_entries, streamed_chunks_per_input: 1}
  end

  @spec measured_inputs(atom()) :: pos_integer()
  defp measured_inputs(:agent_stream), do: @agent_measured
  defp measured_inputs(_workload), do: @measured

  @spec typed(non_neg_integer()) :: char()
  defp typed(index), do: Enum.at(@typed_text, rem(index, length(@typed_text)))

  @spec scroll(map(), non_neg_integer()) :: :ok
  defp scroll(%{editor: editor} = ctx, window_id) do
    await_frame(ctx, fn ->
      send(editor, {:minga_input, {:scroll_batch, window_id, @scroll_lines, :down}})
    end)
  end

  @spec key(map(), char()) :: :ok
  defp key(%{editor: editor} = ctx, codepoint) do
    await_frame(ctx, fn -> send(editor, {:minga_input, {:key_press, codepoint, 0, 0}}) end)
  end

  @spec stream_chunk(map(), pid()) :: :ok
  defp stream_chunk(ctx, producer) do
    await_frame(ctx, fn -> send(producer, {:benchmark_stream_chunk, self()}) end)
  end

  @spec await_frame(map(), (-> term())) :: :ok
  defp await_frame(%{editor: editor, port: port}, input) do
    _ = :sys.get_state(editor, 30_000)
    ref = HeadlessPort.prepare_await(port)
    input.()
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref, 15_000)
    :ok
  end

  @spec active_window_id(map()) :: non_neg_integer()
  defp active_window_id(%{editor: editor}) do
    state = :sys.get_state(editor)
    MingaEditor.Session.State.active_window_struct(state.workspace).id
  end

  @spec open_agent(map()) :: pid()
  defp open_agent(%{editor: editor} = ctx) do
    await_frame(ctx, fn ->
      send(editor, {:minga_input, {:gui_action, {:execute_command, "agent_new_session"}}})
    end)

    session = Runtime.active_session(:sys.get_state(editor).shell_runtime)
    true = is_pid(session)
    session
  end

  @spec warm_session(pid()) :: :ok
  defp warm_session(session) do
    :ok = Session.subscribe(session)
    :ok = Session.send_prompt(session, "Benchmark conversation")

    receive do
      {:recovery_request, request} ->
        :ok = ProviderFixture.deliver(request, ProviderFixture.text("Initial response"))
    after
      15_000 -> raise "active Session did not dispatch its warmup request"
    end

    receive do
      {:agent_event, ^session, {:resumable_boundary, _revision}} -> :ok
    after
      15_000 -> raise "active Session did not finish its warmup turn"
    end

    :idle = Session.status(session)
    Session.unsubscribe(session)
  end

  @spec start_stream() :: pid()
  defp start_stream do
    receive do
      {:recovery_request, request} ->
        :ok = ProviderFixture.deliver(request, Minga.Bench.ActiveSessionProvider.stream(self()))
    after
      15_000 -> raise "active Session did not dispatch the benchmark request"
    end

    receive do
      {:active_stream_consumer, consumer} -> consumer
    after
      15_000 -> raise "Native worker did not consume the benchmark stream"
    end
  end

  # ── Packet recording ───────────────────────────────────────────────────────

  # A sys debug hook on the HeadlessPort records each admission in mailbox order without changing the frontend.
  @spec install_recorder(pid(), pid()) :: :ok
  defp install_recorder(port, recorder) do
    :sys.install(port, {&record_event/3, recorder})
  end

  @spec record_event(pid(), term(), term()) :: pid()
  defp record_event(recorder, {:in, {:"$gen_cast", {:send_commands, commands}}}, _name),
    do: record(recorder, commands)

  defp record_event(recorder, {:in, {:"$gen_call", _from, {:send_commands, commands}}}, _name),
    do: record(recorder, commands)

  defp record_event(
         recorder,
         {:in, {:"$gen_call", _from, {:send_render_commands, commands, _sent_at}}},
         _name
       ),
       do: record(recorder, commands)

  defp record_event(recorder, _event, _name), do: recorder

  @spec record(pid(), [binary()]) :: pid()
  defp record(recorder, commands) do
    packet = IO.iodata_to_binary(commands)
    Agent.cast(recorder, fn packets -> [packet | packets] end)
    recorder
  end

  @spec recorded(pid()) :: [binary()]
  defp recorded(recorder), do: recorder |> Agent.get(& &1) |> Enum.reverse()

  @spec packet_count(map(), pid()) :: non_neg_integer()
  defp packet_count(%{port: port}, recorder) do
    _ = :sys.get_state(port)
    Agent.get(recorder, &length/1)
  end

  # ── Editor lifecycle ───────────────────────────────────────────────────────

  @spec with_editor(atom(), pid(), (map() -> result)) :: result when result: term()
  defp with_editor(workload, recorder, fun) do
    ctx = start_editor(workload, recorder)

    try do
      fun.(ctx)
    after
      Enum.each([ctx.generation, ctx.buffer, ctx.port, ctx.sidebar], &stop/1)
    end
  end

  @spec start_editor(atom(), pid()) :: map()
  defp start_editor(workload, recorder) do
    id = System.unique_integer([:positive])
    sidebar_registry = :"minga_frame_staging_sidebar_#{id}"
    {:ok, sidebar} = Sidebar.start_link(name: sidebar_registry, notify: false)
    {:ok, port} = HeadlessPort.start_link(width: @width, height: @height, capabilities: @caps)
    :ok = install_recorder(port, recorder)
    lines = if workload == :scroll, do: @scroll_file_lines, else: @typing_file_lines
    # The buffer loads its path from disk, so the fixture document must exist there.
    path = Path.join(System.tmp_dir!(), "minga_frame_staging_#{id}_#{workload}.ex")
    File.write!(path, document(lines))
    {:ok, buffer} = BufferProcess.start_link(file_path: path)
    true = Minga.Buffer.content(buffer) == document(lines)

    {:ok, generation} =
      MingaEditor.GenerationSupervisor.start_editor_generation_link(
        [
          name: :"frame_staging_editor_#{id}",
          backend: :headless,
          port_manager: port,
          buffer: buffer,
          width: @width,
          height: @height,
          editing_model: :vim,
          sidebar_registry: sidebar_registry,
          suppress_tool_prompts: true
        ] ++ agent_opts(workload)
      )

    {:ok, editor} = MingaEditor.GenerationSupervisor.editor_owner(generation)
    ctx = %{generation: generation, editor: editor, buffer: buffer, port: port, sidebar: sidebar}
    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, @width, @height}})
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref, 15_000)
    ctx
  end

  @spec agent_opts(atom()) :: keyword()
  defp agent_opts(:agent_stream) do
    _providers = LLMDB.providers()
    Minga.Git.Stub.ensure_table()

    [
      agent_provider_module: MingaAgent.Providers.Native,
      agent_provider_opts: Minga.Bench.ActiveSessionProvider.options(self())
    ]
  end

  defp agent_opts(_workload), do: []

  @spec document(pos_integer()) :: String.t()
  defp document(lines) do
    Enum.map_join(1..lines, "\n", fn index ->
      case rem(index, 5) do
        0 -> "  def function_#{index}(value), do: value + #{index}"
        1 -> "  # comment line #{index} alpha beta gamma delta"
        2 -> "  @spec function_#{index + 3}(integer()) :: integer()"
        3 -> "  defp helper_#{index}(%{key: key}), do: {:ok, key, \"text #{index}\"}"
        4 -> ""
      end
    end)
  end

  @spec revision() :: String.t()
  defp revision do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  @spec stop(pid()) :: :ok
  defp stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end
end

Minga.Bench.FrameStagingCapture.run(System.argv())
