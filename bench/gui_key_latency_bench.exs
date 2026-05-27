defmodule Minga.Bench.GUIKeyLatency do
  @moduledoc false

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.HeadlessPort
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.Frontend.Capabilities
  alias MingaEditor.UI.Theme

  @events [
    [:minga, :render, :window_model_build, :stop],
    [:minga, :render, :ui_model_build, :stop],
    [:minga, :render, :adapter_encode, :stop],
    [:minga, :render, :emit_prepare, :stop]
  ]

  @runs 5
  @width 100
  @height 40

  def run do
    parent = self()
    handler_id = "minga-gui-key-latency-bench-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      @events,
      fn event, measurements, metadata, _config ->
        send(parent, {:bench_telemetry, event, measurements, metadata})
      end,
      nil
    )

    try do
      results = for _ <- 1..@runs, do: run_once()
      emit_metrics(results)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp run_once do
    registry = :"minga_gui_bench_events_#{System.unique_integer([:positive])}"
    {:ok, _events} = Registry.start_link(keys: :duplicate, name: registry)

    ctx =
      start_editor(
        document(),
        width: @width,
        height: @height,
        file_path: "bench_elixir.ex",
        events_registry: registry,
        capabilities: %Capabilities{
          frontend_type: :native_gui,
          float_support: :native,
          image_support: :native
        }
      )

    try do
      %{
        cursor_move: measure_cursor_move(ctx),
        one_line_scroll: measure_one_line_scroll(ctx),
        one_character_edit: measure_one_character_edit(ctx),
        selection_movement: measure_selection_movement(ctx),
        resize: measure_resize(ctx),
        theme_change: measure_theme_change(ctx)
      }
    after
      stop_if_alive(ctx.editor)
      stop_if_alive(ctx.buffer)
      stop_if_alive(ctx.port)
      stop_if_alive(ctx.sidebar)
      stop_if_alive(Process.whereis(registry))
    end
  end

  defp document do
    1..2_000
    |> Enum.map_join("\n", fn i -> "line #{i} alpha beta gamma delta epsilon zeta eta theta" end)
  end

  defp start_editor(content, opts) do
    id = System.unique_integer([:positive])
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    events_registry = Keyword.fetch!(opts, :events_registry)
    capabilities = Keyword.fetch!(opts, :capabilities)
    sidebar_registry = :"minga_gui_bench_sidebar_#{id}"

    {:ok, sidebar} = Sidebar.start_link(name: sidebar_registry, notify: false)

    {:ok, port} =
      HeadlessPort.start_link(width: width, height: height, capabilities: capabilities)

    buffer_opts = [content: content, events_registry: events_registry]

    buffer_opts =
      if file_path = Keyword.get(opts, :file_path),
        do: [{:file_path, file_path} | buffer_opts],
        else: buffer_opts

    {:ok, buffer} = BufferProcess.start_link(buffer_opts)

    {:ok, editor} =
      MingaEditor.start_link(
        name: :"gui_bench_editor_#{id}",
        backend: :headless,
        port_manager: port,
        buffer: buffer,
        width: width,
        height: height,
        editing_model: :vim,
        events_registry: events_registry,
        sidebar_registry: sidebar_registry,
        suppress_tool_prompts: true
      )

    ref = HeadlessPort.prepare_await(port)
    send(editor, {:minga_input, {:ready, width, height}})
    {:ok, _snapshot} = HeadlessPort.collect_frame(ref, 15_000)
    _ = :sys.get_state(editor)
    _ = HeadlessPort.get_screen(port)

    %{editor: editor, buffer: buffer, port: port, sidebar: sidebar, width: width, height: height}
  end

  defp measure_cursor_move(ctx), do: measure_key(ctx, ?j)

  defp measure_one_line_scroll(ctx) do
    Enum.each(1..@height, fn _ -> send_key_unmeasured(ctx, ?j) end)
    measure_key(ctx, ?j)
  end

  defp measure_one_character_edit(ctx) do
    send_key_unmeasured(ctx, ?i)
    sample = measure_key(ctx, ?a)
    send_key_unmeasured(ctx, 27)
    sample
  end

  defp measure_selection_movement(ctx) do
    send_key_unmeasured(ctx, ?v)
    sample = measure_key(ctx, ?j)
    send_key_unmeasured(ctx, 27)
    sample
  end

  defp measure_resize(%{editor: editor, port: port} = ctx) do
    measure_frame(ctx, fn ->
      HeadlessPort.resize(port, @width + 10, @height + 2)
      send(editor, {:minga_input, {:resize, @width + 10, @height + 2}})
    end)
  end

  defp measure_theme_change(%{editor: editor} = ctx) do
    measure_frame(ctx, fn ->
      theme = Theme.get!(:one_light)
      :sys.replace_state(editor, fn state -> %{state | theme: theme, layout: nil} end)
      MingaEditor.render(editor)
    end)
  end

  defp measure_key(ctx, key),
    do: measure_frame(ctx, fn -> send(ctx.editor, {:minga_input, {:key_press, key, 0}}) end)

  defp send_key_unmeasured(ctx, key) do
    measure_key(ctx, key)
    :ok
  end

  defp measure_frame(%{editor: editor, port: port}, action) do
    _ = :sys.get_state(editor)
    drain_events([])
    ref = HeadlessPort.prepare_await(port)
    started_at = System.monotonic_time(:microsecond)
    action.()

    case HeadlessPort.collect_frame(ref, 5_000) do
      {:ok, _snapshot} ->
        _ = :sys.get_state(editor)
        stopped_at = System.monotonic_time(:microsecond)
        events = drain_events([])
        summarize_frame(stopped_at - started_at, events)

      {:error, :timeout} ->
        raise "timed out waiting for rendered GUI-path frame"
    end
  end

  defp drain_events(acc) do
    receive do
      {:bench_telemetry, event, measurements, metadata} ->
        drain_events([%{event: event, measurements: measurements, metadata: metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp summarize_frame(wall_us, events) do
    adapter_metadata = metadata_for(events, [:minga, :render, :adapter_encode, :stop])

    %{
      wall_us: wall_us,
      window_model_us: sum_duration(events, [:minga, :render, :window_model_build, :stop]),
      ui_model_us: sum_duration(events, [:minga, :render, :ui_model_build, :stop]),
      adapter_encode_us: sum_duration(events, [:minga, :render, :adapter_encode, :stop]),
      emit_prepare_us: sum_duration(events, [:minga, :render, :emit_prepare, :stop]),
      window_row_bytes: sum_metadata(adapter_metadata, :window_row_bytes),
      window_overlay_bytes: sum_metadata(adapter_metadata, :window_overlay_bytes),
      window_gutter_bytes: sum_metadata(adapter_metadata, :window_gutter_bytes),
      window_annotation_bytes: sum_metadata(adapter_metadata, :window_annotation_bytes),
      window_metadata_bytes: sum_metadata(adapter_metadata, :window_metadata_bytes),
      metal_ui_bytes: sum_metadata(adapter_metadata, :metal_ui_bytes),
      chrome_bytes: sum_metadata(adapter_metadata, :chrome_bytes),
      frame_cmd_bytes: sum_metadata(adapter_metadata, :frame_cmd_bytes)
    }
  end

  defp sum_duration(events, event_name) do
    events
    |> Enum.filter(&(&1.event == event_name))
    |> Enum.map(&native_to_us(&1.measurements.duration))
    |> Enum.sum()
  end

  defp metadata_for(events, event_name) do
    events
    |> Enum.filter(&(&1.event == event_name))
    |> Enum.map(& &1.metadata)
  end

  defp sum_metadata(metadata, key), do: metadata |> Enum.map(&Map.get(&1, key, 0)) |> Enum.sum()

  defp native_to_us(duration), do: System.convert_time_unit(duration, :native, :microsecond)

  defp emit_metrics(results) do
    scenario_names = [
      :cursor_move,
      :one_line_scroll,
      :one_character_edit,
      :selection_movement,
      :resize,
      :theme_change
    ]

    Enum.each(scenario_names, fn scenario ->
      summaries = Enum.map(results, &Map.fetch!(&1, scenario))
      emit_scenario_metrics(scenario, summaries)
    end)
  end

  defp emit_scenario_metrics(scenario, summaries) do
    fields = [
      :wall_us,
      :window_model_us,
      :ui_model_us,
      :adapter_encode_us,
      :emit_prepare_us,
      :window_row_bytes,
      :window_overlay_bytes,
      :window_gutter_bytes,
      :window_annotation_bytes,
      :window_metadata_bytes,
      :metal_ui_bytes,
      :chrome_bytes,
      :frame_cmd_bytes
    ]

    Enum.each(fields, fn field ->
      value = summaries |> Enum.map(&Map.fetch!(&1, field)) |> median()
      IO.puts("METRIC gui_#{scenario}_#{field}=#{format_number(value)}")
    end)
  end

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      (Enum.at(sorted, middle - 1) + Enum.at(sorted, middle)) / 2
    end
  end

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)
  defp format_number(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 2)

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end
end

Minga.Bench.GUIKeyLatency.run()
