defmodule Minga.Bench.ResidentFrame do
  @moduledoc false

  # Wall-clock evidence for #2658 AC 1/AC 5: edit-frame build cost is flat across
  # resident document sizes. NOT a CI gate (wall-clock is noisy); the CI assertion
  # is the operation-count test in
  # test/minga_editor/render_pipeline/resident_incremental_test.exs. Run with:
  #
  #     MIX_ENV=test mix run bench/resident_frame_bench.exs
  #
  # It reports p50/p95 build time for a single-line edit frame at each size, plus
  # the warm keyframe (first full build) for contrast. Flat p50/p95 across sizes
  # is the claim.

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Config
  alias MingaEditor.Layout
  alias MingaEditor.RenderPipeline
  alias MingaEditor.RenderPipeline.Content
  alias MingaEditor.RenderPipeline.Scroll
  alias MingaEditor.State, as: EditorState

  import MingaEditor.RenderPipeline.TestHelpers

  @sizes [500, 5_000, 65_000]
  @warmup 5
  @measured 60

  def run do
    original = Config.get(:resident_store_max_lines)
    Config.set(:resident_store_max_lines, 1_000_000)

    try do
      IO.puts("\n#2658 resident edit-frame build (p50/p95 µs), single-line in-place edit\n")
      IO.puts(String.pad_trailing("lines", 10) <> "keyframe   p50      p95")

      for size <- @sizes, do: bench_size(size)
    after
      Config.set(:resident_store_max_lines, original)
    end
  end

  defp bench_size(size) do
    state = resident_state(size)

    # First-paint-then-promote (#2679): the first frame renders windowed (arming
    # promotion); discard it so `keyframe_us` measures the first full resident
    # build. The following frame settles the incremental base for the edit samples.
    {_arm_us, state} = timed_frame(state)
    {keyframe_us, state} = timed_frame(state)
    {_us, state} = timed_frame(state)

    buffer = state.workspace.buffers.active
    edit_line = div(size, 2)

    samples =
      Enum.map(1..(@warmup + @measured), fn i ->
        BufferProcess.move_to(buffer, {edit_line, 0})
        BufferProcess.insert_text(buffer, if(rem(i, 2) == 0, do: "a", else: "b"))
        {us, next} = timed_frame(state)
        _ = next
        us
      end)
      |> Enum.drop(@warmup)
      |> Enum.sort()

    IO.puts(
      String.pad_trailing(Integer.to_string(size), 10) <>
        String.pad_trailing("#{keyframe_us}", 11) <>
        String.pad_trailing("#{percentile(samples, 50)}", 9) <>
        "#{percentile(samples, 95)}"
    )
  end

  defp timed_frame(state) do
    state = Content.reset_rows_rasterized(state)
    state = MingaEditor.WindowFocus.remember_active_cursor(state)
    state = RenderPipeline.compute_layout(state)
    layout = Layout.get(state)
    {scrolls, state} = Scroll.scroll_windows(state, layout)

    start = System.monotonic_time(:microsecond)
    {_contents, _cursor, state} = Content.build_content(state, scrolls)
    elapsed = System.monotonic_time(:microsecond) - start

    {elapsed, state}
  end

  defp resident_state(size) do
    state = gui_state(content: long_content(size), rows: 40, cols: 100, filetype: :text)
    BufferProcess.set_option(state.workspace.buffers.active, :wrap, false)
    state
  end

  defp percentile([], _p), do: 0

  defp percentile(sorted, p) do
    index = min(round(length(sorted) * p / 100), length(sorted) - 1)
    Enum.at(sorted, index)
  end
end

Minga.Bench.ResidentFrame.run()
