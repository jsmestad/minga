defmodule Minga.Bench.MotionProcess do
  @moduledoc false

  alias Minga.Buffer.Document
  alias Minga.Buffer.Process, as: BufferProcess

  @line "alpha beta gamma delta epsilon zeta eta theta iota kappa\n"
  @iterations 1_000
  @warmup 50

  @spec run() :: :ok
  def run do
    content = String.duplicate(@line, 50_000)
    {:ok, legacy_buf} = BufferProcess.start_link(content: content)
    {:ok, new_buf} = BufferProcess.start_link(content: content)

    legacy_motion = fn ->
      doc = BufferProcess.snapshot(legacy_buf)
      pos = Minga.Editing.word_forward(doc, Document.cursor(doc))
      BufferProcess.move_to(legacy_buf, pos)
    end

    buffer_process_motion = fn ->
      BufferProcess.apply_motion(new_buf, &Minga.Editing.word_forward/2)
    end

    {legacy_us, legacy_growth} = measure(:legacy, legacy_motion)
    {new_us, new_growth} = measure(:buffer_process, buffer_process_motion)

    IO.puts("METRIC legacy_motion_us=#{Float.round(legacy_us, 2)}")
    IO.puts("METRIC buffer_process_motion_us=#{Float.round(new_us, 2)}")
    IO.puts("METRIC motion_speedup_x=#{Float.round(legacy_us / new_us, 2)}")
    IO.puts("METRIC legacy_caller_heap_growth_bytes=#{legacy_growth}")
    IO.puts("METRIC buffer_process_caller_heap_growth_bytes=#{new_growth}")
  end

  defp measure(label, fun) do
    parent = self()

    spawn(fn ->
      Enum.each(1..@warmup, fn _ -> fun.() end)
      :erlang.garbage_collect(self())
      {:memory, before_bytes} = Process.info(self(), :memory)

      {total_us, _} =
        :timer.tc(fn ->
          Enum.each(1..@iterations, fn _ -> fun.() end)
        end)

      {:memory, after_bytes} = Process.info(self(), :memory)
      send(parent, {label, total_us / @iterations, max(after_bytes - before_bytes, 0)})
    end)

    receive do
      {^label, avg_us, caller_growth_bytes} -> {avg_us, caller_growth_bytes}
    after
      30_000 -> raise "benchmark timed out for #{label}"
    end
  end
end

Minga.Bench.MotionProcess.run()
