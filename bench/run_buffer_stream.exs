defmodule Minga.Bench.RunBufferStream.Tap do
  @moduledoc """
  Port manager placed in front of `Minga.Test.HeadlessPort` for the run-buffer stream bench.

  Records every render batch the renderer admits (receive time, bytes, opcode counts) in the shared ETS event table, so the bench sees the exact wire shape of every frame without retaining packets.

  Sink modes:

    * `:headless` forwards each batch with a synchronous call, so the renderer waits for HeadlessPort to decode the frame, exactly as it does when HeadlessPort is the port manager.
    * `:drop` answers `:accepted` at once and discards the batch, like a production `Frontend.Manager` admission without the port write. HeadlessPort's test decoder then costs nothing.

  Every other call and cast goes to HeadlessPort unchanged.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec await_frames(pid(), non_neg_integer(), timeout()) :: :ok
  def await_frames(tap, count, timeout), do: GenServer.call(tap, {:await_frames, count}, timeout)

  @spec frame_count(pid()) :: non_neg_integer()
  def frame_count(tap), do: GenServer.call(tap, :tap_frame_count)

  @impl true
  def init(opts) do
    {:ok,
     %{
       headless: Keyword.fetch!(opts, :headless),
       table: Keyword.fetch!(opts, :table),
       sink: Keyword.fetch!(opts, :sink),
       frames: 0,
       waiters: []
     }}
  end

  @impl true
  def handle_call({:send_render_commands, commands, _sent_at}, from, state) do
    received_at = System.monotonic_time()
    :ets.insert(state.table, {key(), received_at, self(), :tap_frame, inventory(commands), %{}})

    reply =
      case state.sink do
        :headless -> GenServer.call(state.headless, {:send_commands, commands}, :infinity)
        :drop -> :accepted
      end

    GenServer.reply(from, reply)
    state = %{state | frames: state.frames + 1}
    {:noreply, release_waiters(state)}
  end

  def handle_call({:await_frames, count}, from, state) do
    {:noreply, release_waiters(%{state | waiters: [{count, from} | state.waiters]})}
  end

  def handle_call(:tap_frame_count, _from, state), do: {:reply, state.frames, state}

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, GenServer.call(state.headless, {:subscribe, pid}), state}
  end

  def handle_call(message, _from, state) do
    {:reply, GenServer.call(state.headless, message, :infinity), state}
  end

  @impl true
  def handle_cast(message, state) do
    GenServer.cast(state.headless, message)
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp release_waiters(state) do
    {ready, waiting} = Enum.split_with(state.waiters, fn {count, _} -> state.frames >= count end)
    Enum.each(ready, fn {_count, from} -> GenServer.reply(from, :ok) end)
    %{state | waiters: waiting}
  end

  defp inventory(commands) do
    Enum.reduce(commands, %{bytes: 0, opcodes: %{}}, fn command, acc ->
      binary = IO.iodata_to_binary(command)

      opcode =
        case binary do
          <<op, _::binary>> -> op
          _ -> :empty
        end

      %{
        acc
        | bytes: acc.bytes + byte_size(binary),
          opcodes: Map.update(acc.opcodes, opcode, 1, &(&1 + 1))
      }
    end)
  end

  defp key, do: System.unique_integer([:monotonic, :positive])
end

defmodule Minga.Bench.RunBufferStream do
  @moduledoc """
  Does the resident-row update path keep up when one ~50,000-row buffer takes output that is not append-only?

  Written for spike #4387 and kept as the acceptance bench for #4397 (two distant edits in one frame). It measures the BEAM side only: fetch, build, encode and bytes handed to the port. It does not measure a frontend drawing the frame. Post results on the issue, not in the tree.

      RUN_BENCH_SINK=drop RUN_BENCH_SCENARIOS=A:top,B:top,C:growing RUN_BENCH_ROUNDS=3 MIX_ENV=test mix run bench/run_buffer_stream.exs

  ## Scenarios

    * `A` append-only baseline: one writer appends `lines` lines per flush at the end.
    * `B` mid-document growth: writer 1 inserts at the end of block `growing_block`, writer 2 appends at the end.
    * `C` B plus, at half time, one edit that deletes the whole `evict_block` (default 10,000 rows).
    * `D` B with every block except the two being written folded in the window fold map (default 22 blocks, 20 folds).

  Each scenario token is `SCENARIO:VIEWPORT`:

    * `end`: one focused window, cursor on the last line. Writer 2 uses `Buffer.append/2`, which moves the cursor to the new end, so the viewport tails the output. Writer 1's sourced insert also moves the buffer cursor, so the focused viewport jumps to the growing block and back on every flush in B, C and D.
    * `top` / `growing`: the run window is positioned (`gg`, or `{n}G` on the last row of the growing block), then the editor splits and the focused split takes an empty buffer. The run buffer stays in the unfocused window, which keeps its own cursor, so its viewport holds. Writer 2 then inserts at the trailing empty line with a sourced zero-width edit. Every run reports the run window's viewport top before and after (`viewport_held`).

  The two writers flush on absolute deadlines from one driver process; `RUN_BENCH_PHASE` is writer 2's offset as a fraction of the period (0.5 default, 0 = both writes back to back).

  ## Environment

    * `RUN_BENCH_SIZE` `full` (default) or `small` (2,000 rows, 400-row evict block, 2 seconds).
    * `RUN_BENCH_SCENARIOS` comma list of tokens, default `A:top,B:top,B:growing,B:end,C:growing,D:growing`.
    * `RUN_BENCH_ROUNDS` repeats the whole token list this many times, interleaved (A, B, A, B, ...). Default 1.
    * `RUN_BENCH_ROWS`, `RUN_BENCH_EVICT_ROWS`, `RUN_BENCH_SECONDS`, `RUN_BENCH_HZ` (30), `RUN_BENCH_PHASE` (0.5), `RUN_BENCH_LINES` (3 per flush), `RUN_BENCH_BLOCKS` (20), `RUN_BENCH_FOLDED_BLOCKS` (22, scenario D), `RUN_BENCH_GROWING_BLOCK` (5, 1-indexed), `RUN_BENCH_EVICT_BLOCK` (10, 1-indexed).
    * `RUN_BENCH_SERIAL` `1` waits for the Editor to handle each edit before the next write, so every edit gets its own frame. It shows what the row-delta path costs when no two edits share a frame.
    * `RUN_BENCH_SINK` `headless` (default; the renderer waits for HeadlessPort to decode each frame) or `drop` (admit and discard, like a production port admission).
    * `RUN_BENCH_RENDER` `sync` (default; the `:headless` backend renders synchronously inside the Editor turn) or `async` (experimental and unsupported: `:gui` backend, globally named `Renderer.Server` with `require_ack?: false` and no frontend acknowledgements, real debounced render timer; its numbers are leads, not measurements).
    * `RUN_BENCH_WIDTH` / `RUN_BENCH_HEIGHT` frame size in cells, default 160x50.

  Run with: `MIX_ENV=test mix run bench/run_buffer_stream.exs`
  """

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Fold.Range, as: FoldRange
  alias Minga.Bench.RunBufferStream.Tap
  alias Minga.Protocol.Opcodes
  alias Minga.Test.HeadlessPort
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Capabilities

  @caps %Capabilities{frontend_type: :native_gui, semantic_ui: true}

  @events [
    [:minga, :render, :buffer_deltas],
    [:minga, :render, :line_fetch],
    [:minga, :render, :full_hydration],
    [:minga, :render, :resident_work],
    [:minga, :render, :coalesced],
    [:minga, :render, :pipeline, :start],
    [:minga, :render, :pipeline, :stop],
    [:minga, :render, :pipeline, :exception],
    [:minga, :render, :stage, :stop],
    [:minga, :render, :adapter_encode, :stop],
    [:minga, :render, :emit_prepare, :start],
    [:minga, :render, :emit_prepare, :stop]
  ]

  # ── Entry point ───────────────────────────────────────────────────────────

  @spec main() :: :ok
  def main do
    config = config()
    IO.puts(:stderr, "run_buffer_stream config: #{inspect(Map.drop(config, [:tokens]))}")

    runs =
      for round <- 1..config.rounds, token <- config.tokens do
        {scenario, viewport} = token
        IO.puts(:stderr, "round #{round}: scenario #{scenario} viewport #{viewport}")
        result = run_one(config, scenario, viewport)
        Map.merge(result, %{round: round, scenario: scenario, viewport: viewport})
      end

    Enum.each(runs, &print_metrics/1)

    payload = %{
      schema: "minga.run_buffer_stream.spike.v1",
      ticket: 4387,
      config: Map.update!(config, :tokens, fn tokens -> Enum.map(tokens, &token_label/1) end),
      runs: runs,
      aggregate: aggregate(runs)
    }

    IO.puts(JSON.encode!(payload))
    :ok
  end

  # ── Configuration ─────────────────────────────────────────────────────────

  defp config do
    small? = System.get_env("RUN_BENCH_SIZE", "full") == "small"

    tokens =
      "RUN_BENCH_SCENARIOS"
      |> System.get_env("A:top,B:top,B:growing,B:end,C:growing,D:growing")
      |> String.split(",", trim: true)
      |> Enum.map(&parse_token/1)

    %{
      size: if(small?, do: "small", else: "full"),
      rows: env_int("RUN_BENCH_ROWS", if(small?, do: 2_000, else: 50_000)),
      evict_rows: env_int("RUN_BENCH_EVICT_ROWS", if(small?, do: 400, else: 10_000)),
      seconds: env_float("RUN_BENCH_SECONDS", if(small?, do: 2.0, else: 10.0)),
      hz: env_int("RUN_BENCH_HZ", 30),
      phase: env_float("RUN_BENCH_PHASE", 0.5),
      lines: env_int("RUN_BENCH_LINES", 3),
      blocks: env_int("RUN_BENCH_BLOCKS", 20),
      folded_blocks: env_int("RUN_BENCH_FOLDED_BLOCKS", 22),
      growing_block: env_int("RUN_BENCH_GROWING_BLOCK", 5),
      evict_block: env_int("RUN_BENCH_EVICT_BLOCK", 10),
      rounds: env_int("RUN_BENCH_ROUNDS", 1),
      sink: env_atom("RUN_BENCH_SINK", "headless", ~w(headless drop)),
      render: env_atom("RUN_BENCH_RENDER", "sync", ~w(sync async)),
      width: env_int("RUN_BENCH_WIDTH", 160),
      height: env_int("RUN_BENCH_HEIGHT", 50),
      tokens: tokens
    }
  end

  defp parse_token(token) do
    case String.split(String.trim(token), ":") do
      [s] -> {scenario!(s), "end"}
      [s, v] when v in ~w(top growing end) -> {scenario!(s), v}
      _ -> raise ArgumentError, "bad scenario token #{inspect(token)}"
    end
  end

  defp scenario!(s) when s in ~w(A B C D), do: s
  defp scenario!("E"), do: raise(ArgumentError, "scenario E is not built; see the hand-back")
  defp scenario!(s), do: raise(ArgumentError, "unknown scenario #{inspect(s)}")

  defp token_label({scenario, viewport}), do: "#{scenario}:#{viewport}"

  defp env_int(name, default),
    do: name |> System.get_env() |> then(&if(&1, do: String.to_integer(&1), else: default))

  defp env_float(name, default) do
    case System.get_env(name) do
      nil -> default
      value -> value |> Float.parse() |> elem(0)
    end
  end

  defp env_atom(name, default, allowed) do
    value = System.get_env(name, default)

    if value in allowed,
      do: String.to_atom(value),
      else: raise("#{name} must be one of #{inspect(allowed)}")
  end

  # ── One run ───────────────────────────────────────────────────────────────

  defp run_one(config, scenario, viewport) do
    block_count = if scenario == "D", do: config.folded_blocks, else: config.blocks
    layout = initial_layout(config, block_count)
    table = :ets.new(:run_bench_events, [:ordered_set, :public, write_concurrency: true])
    ctx = start_editor(config, layout, table)
    handler = attach_telemetry(table)

    try do
      if scenario == "D", do: fold_blocks(ctx, layout, config)
      position_viewport(ctx, layout, viewport, config)
      if viewport != "end", do: unfocus_run_window(ctx)
      warm(ctx)
      positioned_cursor = Tuple.to_list(Buffer.cursor(ctx.buffer))
      window_before = run_window(ctx)
      residence = warm_residence(table, ctx.buffer)

      if scenario in ~w(A B C) and residence != true do
        raise "scenario #{scenario} is not resident after warm-up (full_residence?=#{inspect(residence)})"
      end

      :ets.delete_all_objects(table)
      sampler = start_sampler(ctx)
      {flushes, layout, drive} = drive(ctx, layout, config, scenario, end_primitive(viewport))
      IO.puts(:stderr, "  #{length(flushes)} flushes written; draining")
      drained = drain(table, ctx, List.last(flushes))
      samples = stop_sampler(sampler)
      events = :ets.tab2list(table)

      result = analyze(events, flushes, samples, ctx)
      window_after = run_window(ctx)

      Map.merge(result, %{
        run_window_focused: viewport == "end",
        run_window_before: window_before,
        run_window_after: window_after,
        viewport_held: window_before.top == window_after.top,
        warm_full_residence: residence,
        drive: drive,
        drained: drained,
        final_line_count: Buffer.line_count(ctx.buffer),
        expected_line_count: layout_line_count(layout),
        positioned_cursor: positioned_cursor,
        final_cursor: Tuple.to_list(Buffer.cursor(ctx.buffer)),
        end_writer_primitive: end_primitive(viewport),
        block_count: block_count,
        folds: if(scenario == "D", do: block_count - 2, else: 0)
      })
    after
      :telemetry.detach(handler)
      stop_editor(ctx)
      :ets.delete(table)
    end
  end

  # ── Document layout ───────────────────────────────────────────────────────

  # A list of blocks `%{id, rows, bytes}` in document order. The document is every block's lines, each ending in "\n", plus one trailing empty line, so an append at the end and an insert at the start of the next block are both whole-line insertions.
  defp initial_layout(config, block_count) do
    evict = config.evict_block
    others = block_count - 1
    rest = config.rows - config.evict_rows

    if config.evict_block > block_count or rest < others * 2 do
      raise ArgumentError,
            "layout does not fit: rows=#{config.rows} evict_rows=#{config.evict_rows}"
    end

    base = div(rest, others)
    extra = rem(rest, others)

    {blocks, _} =
      Enum.map_reduce(1..block_count, 0, fn id, seen ->
        rows =
          cond do
            id == evict -> config.evict_rows
            seen < extra -> base + 1
            true -> base
          end

        seen = if id == evict, do: seen, else: seen + 1
        bytes = Enum.reduce(0..(rows - 1), 0, &(&2 + byte_size(block_line(id, &1))))
        {%{id: id, rows: rows, bytes: bytes}, seen}
      end)

    blocks
  end

  defp block_line(id, row) do
    "b#{pad(id, 2)} r#{pad(row, 6)} lorem ipsum dolor sit amet consectetur adipiscing\n"
  end

  defp output_line(writer, flush, line) do
    "w#{writer} f#{pad(flush, 5)} l#{line} streamed output from a running command\n"
  end

  defp pad(n, width), do: n |> Integer.to_string() |> String.pad_leading(width, "0")

  defp document(layout) do
    layout
    |> Enum.map(fn %{id: id, rows: rows} -> Enum.map(0..(rows - 1), &block_line(id, &1)) end)
    |> IO.iodata_to_binary()
  end

  defp layout_line_count(layout), do: Enum.sum_by(layout, & &1.rows) + 1

  defp block_start(layout, id),
    do: layout |> Enum.take_while(&(&1.id != id)) |> Enum.sum_by(& &1.rows)

  defp block_end_line(layout, id), do: block_start(layout, id) + block(layout, id).rows - 1

  defp block(layout, id), do: Enum.find(layout, &(&1.id == id))

  defp grow(layout, id, rows, bytes) do
    Enum.map(layout, fn
      %{id: ^id} = b -> %{b | rows: b.rows + rows, bytes: b.bytes + bytes}
      b -> b
    end)
  end

  # ── Editor lifecycle ──────────────────────────────────────────────────────

  defp start_editor(config, layout, table) do
    id = System.unique_integer([:positive])
    sidebar_registry = :"minga_run_bench_sidebar_#{id}"
    {:ok, sidebar} = Sidebar.start_link(name: sidebar_registry, notify: false)
    events = :"minga_run_bench_events_#{id}"
    {:ok, registry} = Registry.start_link(keys: :duplicate, name: events)

    {:ok, headless} =
      HeadlessPort.start_link(width: config.width, height: config.height, capabilities: @caps)

    {:ok, tap} = Tap.start_link(headless: headless, table: table, sink: config.sink)

    {:ok, buffer} =
      BufferProcess.start_link(
        content: document(layout),
        filetype: :text,
        buffer_name: "*run-bench*",
        events_registry: events
      )

    {:ok, _} = BufferProcess.set_option(buffer, :wrap, false)

    {renderer, editor_name, backend} =
      case config.render do
        :sync ->
          {nil, :"run_bench_editor_#{id}", :headless}

        :async ->
          {:ok, renderer} =
            MingaEditor.Renderer.Server.start_link(
              name: MingaEditor.Renderer.Server,
              editor_pid: MingaEditor,
              require_ack?: false
            )

          {renderer, MingaEditor, :gui}
      end

    {:ok, generation} =
      MingaEditor.GenerationSupervisor.start_editor_generation_link(
        name: editor_name,
        backend: backend,
        port_manager: tap,
        buffer: buffer,
        width: config.width,
        height: config.height,
        editing_model: :vim,
        sidebar_registry: sidebar_registry,
        events_registry: events,
        redirect_console: false,
        suppress_tool_prompts: true
      )

    {:ok, editor} = MingaEditor.GenerationSupervisor.editor_owner(generation)
    send(editor, {:minga_input, {:ready, config.width, config.height}})
    :ok = Tap.await_frames(tap, 1, 120_000)
    _ = :sys.get_state(editor, :infinity)

    %{
      generation: generation,
      editor: editor,
      buffer: buffer,
      headless: headless,
      tap: tap,
      sidebar: sidebar,
      registry: registry,
      renderer: renderer,
      seq: :counters.new(1, [])
    }
  end

  defp stop_editor(ctx) do
    Enum.each(
      [
        ctx.generation,
        ctx.renderer,
        ctx.buffer,
        ctx.tap,
        ctx.headless,
        ctx.sidebar,
        ctx.registry
      ],
      &stop_if_alive/1
    )
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    Process.unlink(pid)
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp stop_if_alive(_), do: :ok

  defp renderer_pid(ctx) do
    case ctx.renderer do
      pid when is_pid(pid) -> pid
      nil -> :sys.get_state(ctx.editor, :infinity).render.renderer
    end
  end

  # Sends keys as the frontend would and waits for the frame each one draws.
  defp keys(ctx, codepoints) do
    Enum.each(codepoints, fn cp ->
      before = Tap.frame_count(ctx.tap)
      :counters.add(ctx.seq, 1, 1)
      send(ctx.editor, {:minga_input, {:key_press, cp, 0, :counters.get(ctx.seq, 1)}})
      _ = :sys.get_state(ctx.editor, :infinity)
      :ok = Tap.await_frames(ctx.tap, before + 1, 120_000)
    end)
  end

  defp fold_blocks(ctx, layout, _config) do
    last = List.last(layout).id
    growing = growing_block_id(layout)

    ranges =
      for %{id: id, rows: rows} <- layout, id not in [growing, last], rows >= 2 do
        start = block_start(layout, id)
        FoldRange.new!(start, start + rows - 1)
      end

    :ok = GenServer.call(ctx.editor, {:api_set_fold_ranges, ranges}, :infinity)
    :ok = GenServer.call(ctx.editor, {:api_execute_command, :fold_close_all}, :infinity)
  end

  defp growing_block_id(layout) do
    min(String.to_integer(System.get_env("RUN_BENCH_GROWING_BLOCK", "5")), length(layout))
  end

  defp position_viewport(ctx, layout, viewport, _config) do
    case viewport do
      "top" ->
        keys(ctx, [?g, ?g])

      "end" ->
        keys(ctx, [?G])

      "growing" ->
        line = block_end_line(layout, growing_block_id(layout)) + 1
        keys(ctx, String.to_charlist(Integer.to_string(line)) ++ [?G])
    end
  end

  # Every buffer write primitive moves the buffer cursor (append follows the end, a sourced replace moves to the end of the inserted text), and the focused window's viewport follows the buffer cursor. To hold the viewport at `top` or `growing`, split, then give the focused window a new empty buffer: the run buffer stays in the unfocused window, which uses its own remembered cursor. The split's new window starts with a fresh cursor, viewport and fold map, so focus moves to it and it takes the empty buffer; the original window keeps the run buffer with its positioned viewport and folds.
  defp unfocus_run_window(ctx) do
    original = active_window(ctx)
    command(ctx, :split_vertical)
    if active_window(ctx) == original, do: command(ctx, :window_right)
    if active_window(ctx) == original, do: command(ctx, :window_left)
    if active_window(ctx) == original, do: raise("could not focus the split's new window")
    command(ctx, :new_buffer)
    %{id: ^original, active: false} = run_window(ctx)
    :ok
  end

  defp command(ctx, name),
    do: :ok = GenServer.call(ctx.editor, {:api_execute_command, name}, :infinity)

  defp active_window(ctx), do: :sys.get_state(ctx.editor, :infinity).workspace.windows.active

  defp run_window(ctx) do
    state = :sys.get_state(ctx.editor, :infinity)
    windows = state.workspace.windows

    {id, window} =
      Enum.find(windows.map, fn {_id, w} -> w.content == {:buffer, ctx.buffer} end)

    %{
      id: id,
      active: windows.active == id,
      window_count: map_size(windows.map),
      top: window.viewport.top,
      rows: window.viewport.rows,
      folds: MingaEditor.FoldMap.count(window.fold_map)
    }
  end

  # Residence arms on one eligible frame and promotes on the next.
  defp warm(ctx), do: keys(ctx, [27, 27, 27])

  defp warm_residence(table, buffer) do
    table
    |> :ets.tab2list()
    |> Enum.filter(fn {_, _, _, event, _, meta} ->
      event == [:minga, :render, :line_fetch] and meta[:buffer] == buffer
    end)
    |> List.last()
    |> case do
      nil -> nil
      {_, _, _, _, _, meta} -> meta[:full_residence?]
    end
  end

  # ── Telemetry capture ─────────────────────────────────────────────────────

  defp attach_telemetry(table) do
    id = "run-bench-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle_event/4, table)
    id
  end

  @doc false
  def handle_event(event, measurements, metadata, table) do
    :ets.insert(
      table,
      {System.unique_integer([:monotonic, :positive]), System.monotonic_time(), self(), event,
       measurements, slim(metadata)}
    )
  end

  defp slim(%{kind: kind, reason: reason} = metadata) when is_map_key(metadata, :stacktrace) do
    %{exception: kind |> Exception.format_banner(reason) |> String.slice(0, 300)}
    |> Map.merge(Map.take(metadata, [:buffer, :window_count, :frame_seq]))
  end

  defp slim(metadata) do
    Map.take(metadata, [
      :window_count,
      :buffer,
      :version,
      :reset_required?,
      :full_residence?,
      :window_id,
      :reason,
      :operation,
      :stage,
      :path,
      :rows_rasterized,
      :byte_count,
      :frame_seq,
      :keyframe?,
      :window_row_bytes,
      :window_gutter_bytes,
      :window_overlay_bytes,
      :window_metadata_bytes,
      :chrome_bytes
    ])
  end

  # ── Writers ───────────────────────────────────────────────────────────────

  # `Buffer.append/2` always moves the cursor to the new end (`Document.append_text_and_follow/2`), so it is the tailing writer for the `end` viewport. With the viewport at `top` or `growing` it would yank the cursor, and the follow-cursor viewport, to the end on the first write, so writer 2 inserts at the trailing empty line with a zero-width sourced edit instead.
  defp end_primitive("end"), do: :append
  defp end_primitive(_viewport), do: :insert_at_end

  # One driver issues both writers' flushes on absolute deadlines: writer 1 (mid-document) at k / hz, writer 2 (end) `phase` of a period later. Edits are serialized by the buffer process either way; a single driver keeps the layout and buffer version exact without coordinating two processes.
  defp drive(ctx, layout, config, scenario, end_primitive) do
    period_us = 1_000_000 / config.hz
    duration_us = round(config.seconds * 1_000_000)
    flush_count = trunc(config.seconds * config.hz)

    writer1 =
      if scenario == "A",
        do: [],
        else: Enum.map(0..(flush_count - 1), &{&1 * period_us, :mid, &1})

    writer2 =
      Enum.map(0..(flush_count - 1), &{&1 * period_us + period_us * config.phase, :end, &1})

    evict = if scenario == "C", do: [{duration_us / 2, :evict, 0}], else: []
    schedule = Enum.sort_by(writer1 ++ writer2 ++ evict, &elem(&1, 0))

    version = Buffer.version(ctx.buffer)
    started = System.monotonic_time(:microsecond)

    {flushes, {layout, _version, late}} =
      Enum.map_reduce(schedule, {layout, version, []}, fn {offset, kind, n},
                                                          {layout, version, late} ->
        deadline = started + round(offset)
        wait_until(deadline)
        late_us = System.monotonic_time(:microsecond) - deadline
        {flush, layout, version} = flush(ctx, layout, version, {kind, end_primitive}, n, config)

        # RUN_BENCH_SERIAL=1: wait until the Editor has handled this edit's change event (and so,
        # on the synchronous path, rendered it) before the next write. Each edit then gets its
        # own frame. This stands in for a resident store that fetches one range per edit.
        if System.get_env("RUN_BENCH_SERIAL") == "1" do
          :sys.get_state(ctx.buffer)
          :sys.get_state(ctx.editor)
        end

        {Map.put(flush, :late_us, late_us), {layout, version, [late_us | late]}}
      end)

    finished = System.monotonic_time(:microsecond)

    drive = %{
      scheduled_flushes: length(schedule),
      achieved_flushes: length(flushes),
      wall_ms: div(finished - started, 1000),
      achieved_hz_per_writer:
        Float.round(flush_count / max((finished - started) / 1_000_000, 0.001), 2),
      start_late_us_p50: percentile(late, 0.5),
      start_late_us_max: Enum.max(late, fn -> 0 end),
      edit_call_us_p50: percentile(Enum.map(flushes, & &1.edit_us), 0.5),
      edit_call_us_max: Enum.max(Enum.map(flushes, & &1.edit_us), fn -> 0 end)
    }

    {flushes, layout, drive}
  end

  defp wait_until(deadline_us) do
    remaining_ms = div(deadline_us - System.monotonic_time(:microsecond), 1000)

    if remaining_ms > 0 do
      receive do
      after
        remaining_ms -> :ok
      end
    end

    :ok
  end

  defp flush(ctx, layout, version, {:mid, _}, n, config) do
    id = growing_block_id(layout)
    text = Enum.map_join(1..config.lines, &output_line(1, n, &1))
    line = block_end_line(layout, id) + 1
    t0 = System.monotonic_time()

    {:ok, new_version} =
      BufferProcess.replace_byte_range_if_version(
        ctx.buffer,
        version,
        {line, 0},
        0,
        text,
        EditSource.unknown()
      )

    t1 = System.monotonic_time()
    layout = grow(layout, id, config.lines, byte_size(text))

    flush =
      Map.merge(record(:mid, n, new_version, t0, t1), %{
        line: line,
        line_count: layout_line_count(layout)
      })

    {flush, layout, new_version}
  end

  defp flush(ctx, layout, version, {:end, :insert_at_end}, n, config) do
    text = Enum.map_join(1..config.lines, &output_line(2, n, &1))
    t0 = System.monotonic_time()

    {:ok, new_version} =
      BufferProcess.replace_byte_range_if_version(
        ctx.buffer,
        version,
        {layout_line_count(layout) - 1, 0},
        0,
        text,
        EditSource.unknown()
      )

    t1 = System.monotonic_time()
    last = List.last(layout).id
    layout = grow(layout, last, config.lines, byte_size(text))
    {record(:end, n, new_version, t0, t1), layout, new_version}
  end

  defp flush(ctx, layout, _version, {:end, :append}, n, config) do
    text = Enum.map_join(1..config.lines, &output_line(2, n, &1))
    t0 = System.monotonic_time()
    :ok = Buffer.append(ctx.buffer, text)
    t1 = System.monotonic_time()
    # Only this driver edits the buffer, so the next version read is this append's.
    new_version = Buffer.version(ctx.buffer)
    last = List.last(layout).id
    layout = grow(layout, last, config.lines, byte_size(text))
    {record(:end, n, new_version, t0, t1), layout, new_version}
  end

  defp flush(ctx, layout, version, {:evict, _}, n, _config) do
    id = min(String.to_integer(System.get_env("RUN_BENCH_EVICT_BLOCK", "10")), length(layout))
    %{rows: rows, bytes: bytes} = block(layout, id)
    start = block_start(layout, id)
    t0 = System.monotonic_time()

    {:ok, new_version} =
      BufferProcess.replace_byte_range_if_version(
        ctx.buffer,
        version,
        {start, 0},
        bytes,
        "",
        EditSource.unknown()
      )

    t1 = System.monotonic_time()
    layout = grow(layout, id, -rows, -bytes)
    IO.puts(:stderr, "  evicted block #{id}: lines #{start}..#{start + rows - 1} (#{rows} rows)")
    mid_line = block_end_line(layout, growing_block_id(layout)) + 1

    flush =
      Map.merge(record(:evict, n, new_version, t0, t1), %{
        line: start,
        line_count: layout_line_count(layout),
        mid_insert_line: mid_line,
        mid_to_end_span: layout_line_count(layout) - mid_line
      })

    {flush, layout, new_version}
  end

  defp record(kind, n, version, t0, t1) do
    %{kind: kind, n: n, version: version, returned_at: t1, edit_us: to_us(t1 - t0)}
  end

  # Waits until a frame carries the last edit's version, then for the Editor mailbox to drain. Returns how long that took.
  defp drain(table, ctx, last_flush) do
    started = System.monotonic_time(:millisecond)
    deadline = started + 120_000

    rendered? = fn ->
      :ets.foldl(
        fn
          {_, _, _, [:minga, :render, :buffer_deltas], _, %{version: v, buffer: b}}, acc ->
            acc or (b == ctx.buffer and v >= last_flush.version)

          _, acc ->
            acc
        end,
        false,
        table
      )
    end

    wait = fn wait ->
      cond do
        rendered?.() ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          :timeout

        true ->
          receive do
          after
            20 -> wait.(wait)
          end
      end
    end

    status = wait.(wait)
    _ = :sys.get_state(ctx.editor, :infinity)
    _ = :sys.get_state(renderer_pid(ctx), :infinity)
    %{status: status, ms: System.monotonic_time(:millisecond) - started}
  end

  # ── Mailbox sampler ───────────────────────────────────────────────────────

  defp start_sampler(ctx) do
    targets = %{editor: ctx.editor, renderer: renderer_pid(ctx), buffer: ctx.buffer}
    parent = self()
    spawn_link(fn -> sample_loop(parent, targets, System.monotonic_time(:millisecond), []) end)
  end

  defp sample_loop(parent, targets, next, acc) do
    sample = Map.new(targets, fn {name, pid} -> {name, queue_len(pid)} end)
    acc = [sample | acc]
    next = next + 10
    delay = max(next - System.monotonic_time(:millisecond), 0)

    receive do
      {:stop, ^parent} -> send(parent, {:samples, self(), Enum.reverse(acc)})
    after
      delay -> sample_loop(parent, targets, next, acc)
    end
  end

  defp stop_sampler(pid) do
    send(pid, {:stop, self()})

    receive do
      {:samples, ^pid, samples} -> samples
    after
      10_000 -> []
    end
  end

  defp queue_len(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> 0
    end
  end

  defp queue_len(_), do: 0

  # ── Analysis ──────────────────────────────────────────────────────────────

  defp analyze(events, flushes, samples, ctx) do
    renderer = renderer_pid(ctx)
    {failed, frames} = events |> frames(ctx.buffer, renderer) |> Enum.split_with(& &1[:failed?])
    edit_frames = Enum.filter(frames, &(&1.deltas_consumed > 0))

    latencies = Enum.map(flushes, &flush_latency(&1, frames))
    matched = Enum.reject(latencies, &is_nil/1)

    stage_names =
      frames |> Enum.flat_map(&Map.keys(&1.stages)) |> Enum.uniq() |> Enum.sort()

    %{
      frames: length(frames),
      frames_with_edits: length(edit_frames),
      frames_without_edits: length(frames) - length(edit_frames),
      path_counts: Enum.frequencies_by(frames, & &1.path),
      edit_path_counts: Enum.frequencies_by(edit_frames, & &1.path),
      full_hydrations: Enum.sum_by(frames, & &1.hydrations),
      reset_required_frames: Enum.count(frames, & &1.reset_required?),
      failed_attempts: length(failed),
      failed_attempt_us: dist(Enum.map(failed, & &1.pipeline_us)),
      failed_attempt_lines_fetched: dist(Enum.map(failed, & &1.lines_fetched)),
      failed_attempt_reasons:
        failed
        |> Enum.map(&Regex.replace(~r/version \d+/, &1.reason || "", "version N"))
        |> Enum.frequencies(),
      frames_carrying_rows: Enum.count(frames, & &1.rows?),
      coalesced_events:
        Enum.count(events, fn e -> elem(e, 3) == [:minga, :render, :coalesced] end),
      flushes: length(flushes),
      flushes_matched_to_frame: length(matched),
      latency_to_handoff_us: dist(Enum.map(matched, & &1.handoff_us)),
      latency_to_written_us: dist(Enum.map(matched, & &1.written_us)),
      latency_by_writer_written_us:
        matched
        |> Enum.group_by(& &1.kind)
        |> Map.new(fn {kind, ls} -> {kind, dist(Enum.map(ls, & &1.written_us))} end),
      evict_frame: Enum.find(latencies, &(&1 && &1.kind == :evict)),
      evict_flush:
        flushes |> Enum.find(&(&1.kind == :evict)) |> then(&(&1 && Map.drop(&1, [:returned_at]))),
      last_mid_flush:
        flushes
        |> Enum.filter(&(&1.kind == :mid))
        |> List.last()
        |> then(&(&1 && Map.drop(&1, [:returned_at]))),
      evict_timeline: evict_timeline(flushes, failed ++ frames),
      bytes_per_frame: dist(Enum.map(frames, & &1.bytes)),
      bytes_per_edit_frame: dist(Enum.map(edit_frames, & &1.bytes)),
      rows_rasterized_per_frame: dist(Enum.map(frames, & &1.rows_rasterized)),
      rows_rasterized_per_edit_frame: dist(Enum.map(edit_frames, & &1.rows_rasterized)),
      lines_fetched_per_frame: dist(Enum.map(frames, & &1.lines_fetched)),
      resident_work_totals:
        Enum.reduce(frames, %{}, fn f, acc ->
          Map.merge(acc, f.resident_work, fn _, a, b -> a + b end)
        end),
      pipeline_us: dist(Enum.map(frames, & &1.pipeline_us)),
      stage_us:
        Map.new(stage_names, fn stage ->
          {stage, dist(Enum.flat_map(frames, &List.wrap(Map.get(&1.stages, stage))))}
        end),
      adapter_encode_us: dist(Enum.flat_map(frames, &List.wrap(&1.encode_us))),
      emit_call_us: dist(Enum.flat_map(frames, &List.wrap(&1.emit_us))),
      opcode_totals:
        Enum.reduce(frames, %{}, fn f, acc ->
          Map.merge(acc, f.opcodes, fn _, a, b -> a + b end)
        end)
        |> Map.new(fn {op, n} -> {opcode_name(op), n} end),
      editor_queue: queue_dist(samples, :editor),
      renderer_queue: queue_dist(samples, :renderer),
      buffer_queue: queue_dist(samples, :buffer),
      queue_samples: length(samples)
    }
  end

  # The first render attempts that consumed the eviction's version, in order, including failed ones.
  defp evict_timeline(flushes, attempts) do
    case Enum.find(flushes, &(&1.kind == :evict)) do
      nil ->
        nil

      evict ->
        attempts
        |> Enum.sort_by(& &1.order)
        |> Enum.drop_while(&(&1.version < evict.version))
        |> Enum.take(8)
        |> Enum.map(fn a ->
          %{
            failed: a[:failed?] || false,
            pipeline_us: a.pipeline_us,
            lines_fetched: a.lines_fetched,
            path: a[:path],
            rows_rasterized: a[:rows_rasterized],
            deltas_consumed: a.deltas_consumed,
            version: a.version,
            stages: a.stages
          }
        end)
    end
  end

  defp queue_dist(samples, name) do
    values = Enum.map(samples, &Map.fetch!(&1, name))

    %{
      max: Enum.max(values, fn -> 0 end),
      p95: percentile(values, 0.95),
      p50: percentile(values, 0.5)
    }
  end

  # Groups renderer events into frames. A frame ends at its pipeline stop; events after the previous stop (the change-log consume runs before the pipeline span) belong to the next frame. A frame's version is the highest buffer version the renderer has consumed so far.
  defp frames(events, buffer, renderer) do
    {frames, _current, _version} =
      events
      |> Enum.filter(fn {_, _, pid, event, _, _} -> pid == renderer or event == :tap_frame end)
      |> Enum.reduce({[], new_frame(), 0}, fn {key, t, _pid, event, m, meta},
                                              {done, cur, version} ->
        cur = if cur.started_at, do: cur, else: %{cur | started_at: t, order: key}

        case event do
          [:minga, :render, :buffer_deltas] when meta.buffer == buffer ->
            {done,
             %{
               cur
               | deltas_consumed: cur.deltas_consumed + m.deltas_consumed,
                 reset_required?: cur.reset_required? or meta.reset_required?
             }, max(version, meta.version)}

          [:minga, :render, :line_fetch] when meta.buffer == buffer ->
            {done,
             %{
               cur
               | lines_fetched: cur.lines_fetched + m.lines_fetched,
                 full_residence?: meta.full_residence?
             }, version}

          [:minga, :render, :full_hydration] ->
            {done, %{cur | hydrations: cur.hydrations + 1}, version}

          [:minga, :render, :resident_work] ->
            work = Map.merge(cur.resident_work, m, fn _, a, b -> a + b end)
            {done, %{cur | resident_work: work}, version}

          [:minga, :render, :stage, :stop] ->
            stages =
              Map.update(cur.stages, meta.stage, to_us(m.duration), &(&1 + to_us(m.duration)))

            {done, %{cur | stages: stages}, version}

          [:minga, :render, :adapter_encode, :stop] ->
            {done, %{cur | encode_us: to_us(m.duration)}, version}

          [:minga, :render, :emit_prepare, :start] ->
            {done, %{cur | handoff_at: t, emit_bytes: meta[:byte_count]}, version}

          [:minga, :render, :emit_prepare, :stop] ->
            {done, %{cur | written_at: t, emit_us: to_us(m.duration)}, version}

          :tap_frame ->
            opcodes = Map.merge(cur.opcodes, m.opcodes, fn _, a, b -> a + b end)
            {done, %{cur | bytes: cur.bytes + m.bytes, opcodes: opcodes}, version}

          # FrameHandler wraps RenderPipeline.run in a second span with the same name (frame_handler.ex:179 around render_pipeline.ex:64). Only the inner span carries :window_count; the outer one is ignored.
          [:minga, :render, :pipeline, :exception] when is_map_key(meta, :window_count) ->
            failed =
              Map.merge(cur, %{
                failed?: true,
                pipeline_us: to_us(m.duration),
                reason: meta[:exception],
                version: version
              })

            {[failed | done], new_frame(), version}

          [:minga, :render, :pipeline, :stop] when is_map_key(meta, :window_count) ->
            frame =
              Map.merge(cur, %{
                version: version,
                pipeline_us: to_us(m.duration),
                rows_rasterized: meta[:rows_rasterized] || 0,
                classifier_path: meta[:path]
              })

            {[classify(frame) | done], new_frame(), version}

          _ ->
            {done, cur, version}
        end
      end)

    frames |> Enum.reverse() |> Enum.filter(&(&1[:failed?] || &1.handoff_at))
  end

  defp new_frame do
    %{
      deltas_consumed: 0,
      reset_required?: false,
      lines_fetched: 0,
      full_residence?: nil,
      hydrations: 0,
      resident_work: %{},
      stages: %{},
      encode_us: nil,
      emit_us: nil,
      handoff_at: nil,
      written_at: nil,
      emit_bytes: nil,
      bytes: 0,
      opcodes: %{},
      started_at: nil,
      order: nil
    }
  end

  # resident_* means the window took the full-document residence path this frame; windowed_* means it fetched only the viewport (plus overscan or the fold display map's span). The suffix is the wire shape for the window rows.
  defp classify(frame) do
    content = Map.get(frame.opcodes, Opcodes.gui_window_content(), 0) > 0
    rows_delta = Map.get(frame.opcodes, Opcodes.gui_window_rows_delta(), 0) > 0
    viewport_rows = Map.get(frame.opcodes, Opcodes.gui_window_viewport_delta(), 0) > 0

    shape =
      cond do
        frame.hydrations > 0 or content -> "store_replace"
        rows_delta -> "row_delta"
        viewport_rows -> "viewport_rows"
        true -> "no_rows"
      end

    prefix =
      case frame.full_residence? do
        true -> "resident"
        false -> "windowed"
        nil -> "no_window_fetch"
      end

    Map.merge(frame, %{path: "#{prefix}_#{shape}", rows?: shape != "no_rows"})
  end

  defp flush_latency(flush, frames) do
    # Credit an edit to the first frame that consumed its version and carried window rows. A frame can consume a delta and still go out with only an overlay delta (scenario C), so a consumed version alone is not proof.
    case Enum.find(
           frames,
           &(&1.rows? and &1.version >= flush.version and &1.handoff_at >= flush.returned_at)
         ) do
      nil ->
        nil

      frame ->
        %{
          kind: flush.kind,
          handoff_us: to_us(frame.handoff_at - flush.returned_at),
          written_us: to_us((frame.written_at || frame.handoff_at) - flush.returned_at),
          path: frame.path,
          bytes: frame.bytes
        }
    end
  end

  defp opcode_name(op) when is_integer(op) do
    known = %{
      Opcodes.gui_window_content() => "gui_window_content",
      Opcodes.gui_window_rows_delta() => "gui_window_rows_delta",
      Opcodes.gui_window_viewport_delta() => "gui_window_viewport_delta",
      Opcodes.gui_window_overlay_delta() => "gui_window_overlay_delta",
      Opcodes.gui_resident_semantics() => "gui_resident_semantics",
      Opcodes.begin_frame() => "begin_frame",
      Opcodes.commit_frame() => "commit_frame"
    }

    Map.get(known, op, "0x" <> String.pad_leading(Integer.to_string(op, 16), 2, "0"))
  end

  defp opcode_name(op), do: to_string(op)

  defp dist([]), do: %{n: 0, p50: 0, p95: 0, max: 0}

  defp dist(values) do
    %{
      n: length(values),
      p50: percentile(values, 0.5),
      p95: percentile(values, 0.95),
      max: Enum.max(values)
    }
  end

  defp percentile([], _ratio), do: 0

  defp percentile(values, ratio) do
    sorted = Enum.sort(values)
    Enum.at(sorted, max(0, ceil(length(sorted) * ratio) - 1))
  end

  defp to_us(native), do: System.convert_time_unit(native, :native, :microsecond)

  # ── Output ────────────────────────────────────────────────────────────────

  defp print_metrics(run) do
    label = "#{run.scenario}_#{run.viewport}_r#{run.round}"
    metric = fn name, value -> IO.puts("METRIC run_stream_#{label}_#{name}=#{value}") end

    Enum.each(run.path_counts, fn {path, n} -> metric.("frames_#{path}", n) end)
    metric.("frames", run.frames)
    metric.("frames_with_edits", run.frames_with_edits)
    metric.("failed_attempts", run.failed_attempts)
    metric.("viewport_held", run.viewport_held)
    metric.("flushes", run.flushes)
    metric.("flushes_matched", run.flushes_matched_to_frame)

    for {name, d} <- [
          latency_written_us: run.latency_to_written_us,
          latency_handoff_us: run.latency_to_handoff_us,
          bytes_per_frame: run.bytes_per_frame,
          bytes_per_edit_frame: run.bytes_per_edit_frame,
          rows_rasterized_per_frame: run.rows_rasterized_per_frame,
          lines_fetched_per_frame: run.lines_fetched_per_frame,
          failed_attempt_us: run.failed_attempt_us,
          pipeline_us: run.pipeline_us
        ],
        field <- [:p50, :p95, :max] do
      metric.("#{name}_#{field}", Map.fetch!(d, field))
    end

    Enum.each(run.stage_us, fn {stage, d} ->
      metric.("stage_#{stage}_us_p50", d.p50)
      metric.("stage_#{stage}_us_p95", d.p95)
    end)

    metric.("editor_queue_max", run.editor_queue.max)
    metric.("editor_queue_p95", run.editor_queue.p95)
    metric.("renderer_queue_max", run.renderer_queue.max)
    metric.("full_hydrations", run.full_hydrations)
  end

  defp aggregate(runs) do
    runs
    |> Enum.group_by(&"#{&1.scenario}:#{&1.viewport}")
    |> Map.new(fn {label, group} ->
      {label,
       %{
         rounds: length(group),
         latency_written_us_p50: Enum.map(group, & &1.latency_to_written_us.p50),
         latency_written_us_p95: Enum.map(group, & &1.latency_to_written_us.p95),
         bytes_per_edit_frame_p50: Enum.map(group, & &1.bytes_per_edit_frame.p50),
         editor_queue_max: Enum.map(group, & &1.editor_queue.max),
         path_counts: Enum.map(group, & &1.path_counts)
       }}
    end)
  end
end

Minga.Bench.RunBufferStream.main()
