defmodule Minga.Bench.HighlightScroll do
  @moduledoc """
  Measures warm highlighted scroll construction with a fixed 40-row viewport.

  Run with `MIX_ENV=test mix run bench/highlight_scroll_bench.exs`. The deterministic parser fixture has seven spans per line and disables the parser process to exclude asynchronous parsing from the measurements. Times include the real Content stage and synchronous renderer preparation/commit, but exclude protocol transport and display presentation.
  """
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config
  alias Minga.Language.Highlight.Span
  alias Minga.Telemetry
  alias MingaEditor.Layout
  alias MingaEditor.Mouse
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.{BufferPrefetch, Content, Intent, Scroll}
  alias MingaEditor.Renderer.{BufferChanges, RenderReceipt}
  alias MingaEditor.Renderer.State, as: RendererState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Highlighting
  alias MingaEditor.UI.Highlight
  import MingaEditor.RenderPipeline.TestHelpers

  @line "def value(arg), do: call(arg) + other"
  @tokens [{0, 3}, {4, 9}, {10, 13}, {15, 17}, {19, 23}, {24, 27}, {31, 36}]
  @event [:minga, :bench, :highlight_scroll]

  @spec run() :: :ok
  def run do
    original = Config.get(:resident_store_max_lines)
    Config.set(:resident_store_max_lines, 1_000_000)
    handler = {__MODULE__, self()}
    :ok = :telemetry.attach(handler, @event ++ [:stop], &__MODULE__.record_duration/4, self())

    try do
      for size <- [500, 5_000, 65_000] do
        bench(size)
      end
    after
      :telemetry.detach(handler)
      Config.set(:resident_store_max_lines, original)
    end

    :ok
  end

  @doc false
  @spec record_duration([atom()], map(), map(), pid()) :: :ok
  def record_duration(_event, %{duration: duration}, %{part: part}, pid) do
    send(pid, {__MODULE__, part, System.convert_time_unit(duration, :native, :microsecond)})
    :ok
  end

  defp bench(size) do
    editor =
      gui_state(
        content: Enum.map_join(1..size, "\n", fn _ -> @line end),
        rows: 40,
        cols: 100,
        filetype: :text
      )

    buffer = editor.workspace.buffers.active
    BufferProcess.set_option(buffer, :wrap, false)

    spans =
      for i <- 0..(size - 1),
          {first, last} <- @tokens,
          do:
            Span.new(
              i * (byte_size(@line) + 1) + first,
              i * (byte_size(@line) + 1) + min(last, byte_size(@line)),
              0
            )

    highlight =
      Highlight.new(%{"keyword" => [fg: 0xFF0000]})
      |> Highlight.put_names(["keyword"])
      |> Highlight.put_spans(1, spans)

    highlighting = Highlighting.put_highlight(editor.parser.highlighting, buffer, highlight)

    editor = %{
      editor
      | parser: MingaEditor.State.Parser.accept_highlighting(editor.parser, highlighting)
    }

    state = %{
      editor: editor,
      renderer: RendererState.new(editor_pid: nil, pipeline: &RenderPipeline.run/1)
    }

    {_, state} = frame(state)
    {_, state} = frame(state)
    {_, state} = frame(state)

    {samples, _} =
      Enum.map_reduce(1..70, state, fn i, state ->
        direction = if rem(i, 2) == 0, do: :up, else: :down
        delta = if direction == :up, do: -3, else: 3

        editor =
          Mouse.handle_scroll_batch(
            state.editor,
            state.editor.workspace.windows.active,
            delta,
            direction
          )

        frame(%{state | editor: editor})
      end)

    samples = Enum.drop(samples, 10)
    true = Enum.all?(samples, &(&1.rows_composed == 0))

    metric = %{
      rows: size,
      spans: length(spans),
      samples: length(samples),
      rows_composed_max: Enum.max_by(samples, & &1.rows_composed).rows_composed,
      content_p50_us: percentile(samples, :content_us, 0.50),
      content_p95_us: percentile(samples, :content_us, 0.95),
      frame_p50_us: percentile(samples, :frame_us, 0.50),
      frame_p95_us: percentile(samples, :frame_us, 0.95),
      reductions_p50: percentile(samples, :reductions, 0.50)
    }

    IO.puts(JSON.encode!(metric))
    GenServer.stop(buffer)
  end

  defp frame(%{editor: editor, renderer: renderer}) do
    {frame_us, {sample, state}} =
      timed(:frame, fn ->
        {:reductions, before_reductions} = Process.info(self(), :reductions)
        editor = MingaEditor.WindowFocus.remember_active_cursor(editor)
        intent = Intent.from_editor_state(editor)
        {renderer, input} = BufferChanges.prepare(renderer, intent)
        input = Content.reset_rows_rasterized(input) |> RenderPipeline.compute_layout()
        layout = Layout.get(input)
        {prefetched, input} = BufferPrefetch.prefetch_scrolls(input, layout)
        {scrolls, input} = Scroll.scroll_windows(input, layout, prefetched)

        {content_us, {_contents, _cursor, output}} =
          timed(:content, fn -> Content.build_content(input, scrolls) end)

        renderer = BufferChanges.commit(renderer, output, intent)
        receipt = RenderReceipt.from_output(output, 0, 0, 0)
        editor = EditorState.integrate_synchronous_renderer_receipt(editor, receipt)
        {:reductions, after_reductions} = Process.info(self(), :reductions)

        {%{
           content_us: content_us,
           reductions: after_reductions - before_reductions,
           rows_composed: output.caches.frame_rows_rasterized
         }, %{editor: editor, renderer: renderer}}
      end)

    {Map.put(sample, :frame_us, frame_us), state}
  end

  defp timed(part, fun) do
    result = Telemetry.span(@event, %{part: part}, fun)

    receive do
      {__MODULE__, ^part, duration} -> {duration, result}
    end
  end

  defp percentile(samples, key, fraction) do
    values = samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()
    Enum.at(values, ceil(length(values) * fraction) - 1)
  end
end

Minga.Bench.HighlightScroll.run()
