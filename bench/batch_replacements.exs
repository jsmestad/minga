defmodule Minga.Bench.BatchReplacements do
  @moduledoc """
  Batch range replacement cost, baseline against candidate (#3500), and the cost of undoing and
  redoing a batch (#3941).

  Three measurements:

    * `stage`: the pure batch operation. Each sample runs the sequential control (the pre-#3500
      algorithm, copied below so this script runs unchanged on any commit) and
      `Minga.Buffer.Operation.replace_ranges_with_patches/2` (whatever the checked-out commit
      ships), in alternating order, each in a fresh process. Every sample checks that both
      return the same content, cursor, line index, and undo patches.
    * `consumer`: the complete Buffer path that callers use. The `apply_edits/3` call on a
      started `Minga.Buffer.Process`, then one `undo/1` and one `redo/1`, each sent as the same
      message the public function sends but without its 5 s call timeout. The checked-out
      commit decides the implementation, so run this mode once on the baseline commit and once
      on the candidate commit. It measures the middle placements and two boundary cases. Every
      sample checks content, cursor, version, undo, and redo against the commit's own pure
      operation, which stage mode checks against the sequential control. Undo and redo are
      timed for every batch size.
    * `history`: undo and redo of a recorded batch. Each sample runs the per-patch control (the
      pre-#3941 history replay, copied below: one `UndoPatch.apply/2` and `UndoPatch.invert/2`
      per patch) and `Minga.Buffer.UndoHistory.undo/3` or `redo/3` (whatever the checked-out
      commit ships), in alternating order, each in a fresh process. Every sample checks that both
      return the same content, cursor, and line index, and that undo restores the original.

  Run with:

      MIX_ENV=test mix run bench/batch_replacements.exs stage OUT_DIR
      MIX_ENV=test mix run bench/batch_replacements.exs consumer OUT_DIR
      MIX_ENV=test mix run bench/batch_replacements.exs history OUT_DIR

  Add `--quick` to skip the 16 MiB, 10,000-edit cells, whose sequential samples take minutes, and
  `--only TEXT` to run only workloads whose name contains TEXT.
  Each run writes `samples.csv` (one line per sample), `summary.json`, and `identity.json`
  (commit, machine, runtime) into OUT_DIR.
  """

  alias Minga.Buffer.Document
  alias Minga.Buffer.Lines
  alias Minga.Buffer.Operation
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch

  @mib 1_048_576
  @max_samples 15
  @budget_us 20_000_000
  @consumer_max_samples 5
  @source Minga.Buffer.EditSource.lsp(:unknown)

  # ── Sequential control ──────────────────────────────────────────────────────

  @doc """
  The pre-#3500 batch algorithm: one `replace_range/4` per edit, from the end.

  It uses the checked-out commit's `replace_range/4`, so it follows that commit's range semantics. The bench workloads are valid UTF-8, so it needs no rejection check.
  """
  @spec sequential(Document.t(), [Operation.range_edit()]) :: {Document.t(), [UndoPatch.t()]}
  def sequential(%Document{} = doc, edits) do
    edits
    |> Enum.sort(fn {from_a, _, _}, {from_b, _, _} -> from_a >= from_b end)
    |> Enum.reduce({doc, []}, fn {from_pos, to_pos, replacement}, {acc_doc, patches} ->
      {:edited, new_doc, delta} = Operation.replace_range(acc_doc, from_pos, to_pos, replacement)
      {new_doc, [UndoPatch.from_delta(delta, acc_doc) | patches]}
    end)
  end

  @doc """
  The pre-#3941 history replay: one `UndoPatch.apply/2` per patch, each inverted against the document it applied to.
  """
  @spec sequential_replay([UndoPatch.t()], Document.t()) :: {Document.t(), [UndoPatch.t()]}
  def sequential_replay(patches, %Document{} = doc) do
    Enum.reduce(patches, {doc, []}, fn patch, {acc_doc, inverses} ->
      {:ok, new_doc} = UndoPatch.apply(patch, acc_doc)
      {new_doc, [UndoPatch.invert(patch, acc_doc) | inverses]}
    end)
  end

  # The production operation returns `{:ok, doc, patches}` since #3940 and `{doc, patches}` before
  # it. Every workload is valid UTF-8, so a rejection is a bench failure.
  defp production(doc, edits) do
    case Operation.replace_ranges_with_patches(doc, edits) do
      {:ok, new_doc, patches} -> {new_doc, patches}
      {%Document{} = new_doc, patches} -> {new_doc, patches}
      {:error, reason} -> raise "batch rejected: #{inspect(reason)}"
    end
  end

  # ── Fixtures ────────────────────────────────────────────────────────────────

  # Elixir-shaped source lines. Column 6 starts `function_<n>`, the identifier each edit renames.
  defp ascii_line(n), do: "  def function_#{n}(conn, params), do: handle(conn, params, #{n})"

  # The same shape with multi-byte characters, a combining mark, and an emoji on every line.
  defp unicode_line(n), do: "  déf función_#{n}(cønn, 字段), do: é 😀 handle(#{n})"

  defp document(line_fun, separator, size) do
    lines = take_lines(line_fun, separator, size, 0, 0, [])
    Enum.join(lines, separator) <> separator
  end

  defp take_lines(line_fun, separator, size, n, bytes, acc) do
    line = line_fun.(n)
    next = bytes + byte_size(line) + byte_size(separator)

    if next > size,
      do: Enum.reverse(acc),
      else: take_lines(line_fun, separator, size, n + 1, next, [line | acc])
  end

  # One rename per line on `count` consecutive lines at the start, middle, or end of the text.
  defp placed_lines(_line_count, count, :start), do: 0..(count - 1)
  defp placed_lines(line_count, count, :eof), do: (line_count - count)..(line_count - 1)

  defp placed_lines(line_count, count, :middle) do
    first = div(line_count - count, 2)
    first..(first + count - 1)
  end

  defp rename_edits(lines), do: for(line <- lines, do: {{line, 6}, {line, 13}, "renamed"})

  # ── Workloads ───────────────────────────────────────────────────────────────

  defp workloads(quick?) do
    production =
      for size_mib <- [1, 16],
          count <- [1, 10, 1_000, 10_000],
          placement <- [:start, :middle, :eof],
          not (quick? and size_mib == 16 and count == 10_000) do
        %{
          name: "#{size_mib}MiB/#{count}/#{placement}",
          size_mib: size_mib,
          text: {:ascii, "\n"},
          edits: fn line_count ->
            line_count |> placed_lines(count, placement) |> rename_edits()
          end
        }
      end

    production ++ boundary_cases()
  end

  # Boundary cases at 1 MiB and 1,000 edits in the middle unless named otherwise.
  defp boundary_cases do
    middle = fn line_count -> placed_lines(line_count, 1_000, :middle) end

    [
      {"unsorted", {:ascii, "\n"},
       fn lc -> lc |> then(middle) |> rename_edits() |> shuffle() end},
      # Each edit's span runs into the next line's edit, so every edit resolves against the
      # previous one.
      {"overlapping", {:ascii, "\n"},
       fn lc -> for line <- middle.(lc), do: {{line, 6}, {line + 1, 8}, "x"} end},
      # Two edits share every start position.
      {"conflicting", {:ascii, "\n"},
       fn lc ->
         for line <- middle.(lc),
             replacement <- ["a", "bb"],
             do: {{line, 6}, {line, 13}, replacement}
       end},
      # Ten one-character spans that touch, on each of 100 lines.
      {"adjacent", {:ascii, "\n"},
       fn lc ->
         for line <- Enum.take(middle.(lc), 100),
             col <- 6..15,
             do: {{line, col}, {line, col}, "Z"}
       end},
      {"equal endpoints", {:ascii, "\n"},
       fn lc -> for line <- middle.(lc), do: {{line, 6}, {line, 6}, "X"} end},
      {"eof insertion", {:ascii, "\n"}, fn lc -> [{{lc, 0}, {lc, 0}, "# tail\n"}] end},
      {"column past line end", {:ascii, "\n"},
       fn lc -> for line <- middle.(lc), do: {{line, 500}, {line, 500}, "!"} end},
      {"unicode", {:unicode, "\n"},
       fn lc -> for line <- middle.(lc), do: {{line, 7}, {line, 15}, "fünktion_字"} end},
      # Each caret follows "é", so the run asks Cursor whether the caret is a grapheme boundary.
      {"unicode caret check", {:unicode, "\n"},
       fn lc -> for line <- middle.(lc), do: {{line, 5}, {line, 5}, "ф"} end},
      {"crlf", {:ascii, "\r\n"}, fn lc -> lc |> then(middle) |> rename_edits() end},
      {"multi-line replacements", {:ascii, "\n"},
       fn lc -> for line <- middle.(lc), do: {{line, 6}, {line, 13}, "a\nb\n"} end}
    ]
    |> Enum.map(fn {name, text, edits} ->
      %{name: "boundary/#{name}", size_mib: 1, text: text, edits: edits}
    end)
  end

  defp shuffle(list) do
    :rand.seed(:exsss, {3500, 1, 1})
    Enum.shuffle(list)
  end

  defp build(%{size_mib: size_mib, text: {kind, separator}, edits: edits_fun}) do
    line_fun = if kind == :ascii, do: &ascii_line/1, else: &unicode_line/1
    text = document(line_fun, separator, size_mib * @mib)
    doc = Document.new(text)
    # The final separator leaves an empty last line; edits target the lines before it.
    {text, doc, edits_fun.(Document.line_count(doc) - 1)}
  end

  # ── Measurement ─────────────────────────────────────────────────────────────

  # Runs `fun` in a fresh process and returns its result with wall time, reductions, and the
  # binary bytes the result keeps alive beyond the input.
  defp isolated(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        :erlang.garbage_collect()
        {:reductions, reductions_before} = Process.info(self(), :reductions)
        started = System.monotonic_time(:microsecond)
        result = fun.()
        wall_us = System.monotonic_time(:microsecond) - started
        {:reductions, reductions_after} = Process.info(self(), :reductions)
        :erlang.garbage_collect()
        send(parent, {:sample, self(), result, wall_us, reductions_after - reductions_before})
      end)

    receive do
      {:sample, ^pid, result, wall_us, reductions} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        end

        {result, wall_us, reductions}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        raise "sample process exited: #{inspect(reason)}"
    end
  end

  defp same_result!({doc, patches}, {expected_doc, expected_patches}, name) do
    same? =
      Document.content(doc) == Document.content(expected_doc) and
        Document.cursor(doc) == Document.cursor(expected_doc) and
        Lines.snapshot(doc) == Lines.snapshot(expected_doc) and patches == expected_patches

    unless same?, do: raise("#{name}: production result differs from the sequential control")
  end

  defp stage(workload) do
    {_text, doc, edits} = build(workload)

    IO.puts(
      :stderr,
      "stage #{workload.name}: #{byte_size(Document.content(doc))} bytes, #{length(edits)} edits"
    )

    sample_until_budget(fn index ->
      runs = [
        {"sequential", fn -> sequential(doc, edits) end},
        {"production", fn -> production(doc, edits) end}
      ]

      ordered = if rem(index, 2) == 0, do: runs, else: Enum.reverse(runs)

      results =
        Map.new(ordered, fn {impl, fun} ->
          {result, wall_us, reductions} = isolated(fun)
          {impl, {result, wall_us, reductions}}
        end)

      {sequential_result, _, _} = results["sequential"]
      {production_result, _, _} = results["production"]
      same_result!(production_result, sequential_result, workload.name)

      for {impl, {_result, wall_us, reductions}} <- results do
        %{
          workload: workload.name,
          impl: impl,
          index: index,
          wall_us: wall_us,
          reductions: reductions
        }
      end
    end)
  end

  defp consumer(workload) do
    {text, doc, edits} = build(workload)

    IO.puts(
      :stderr,
      "consumer #{workload.name}: #{byte_size(text)} bytes, #{length(edits)} edits"
    )

    # Stage mode proves the production operation equals the sequential control on every
    # workload, and the production operation is quick to compute on any commit.
    {expected_doc, _patches} =
      production(Document.move_to(doc, {3, 2}), edits)

    expected = Document.content(expected_doc)
    expected_cursor = Document.cursor(expected_doc)

    sample_until_budget(
      fn index ->
        {:ok, pid} = BufferProcess.start_link(content: text)
        BufferProcess.move_to(pid, {3, 2})
        version = BufferProcess.version(pid)
        :erlang.garbage_collect(pid)

        {apply_us, :ok} = :timer.tc(fn -> call(pid, {:apply_edits, edits, @source}) end)

        unless BufferProcess.content(pid) == expected and
                 BufferProcess.cursor(pid) == expected_cursor and
                 BufferProcess.version(pid) == version + 1,
               do: raise("#{workload.name}: apply_edits differs from the sequential control")

        {undo_us, redo_us} = undo_redo(pid, text, expected, workload.name)

        GenServer.stop(pid)

        [
          %{
            workload: workload.name,
            impl: "apply_edits",
            index: index,
            wall_us: apply_us,
            reductions: nil
          },
          %{
            workload: workload.name,
            impl: "undo",
            index: index,
            wall_us: undo_us,
            reductions: nil
          },
          %{
            workload: workload.name,
            impl: "redo",
            index: index,
            wall_us: redo_us,
            reductions: nil
          }
        ]
      end,
      @consumer_max_samples
    )
  end

  defp history(workload) do
    {text, doc, edits} = build(workload)
    original = Document.move_to(doc, {3, 2})
    {edited, patches} = production(original, edits)

    IO.puts(
      :stderr,
      "history #{workload.name}: #{byte_size(text)} bytes, #{length(patches)} patches"
    )

    recorded = UndoHistory.record_edit_batch(UndoHistory.new(), 0, patches, :lsp, 1)
    {:ok, undo_restore, after_undo} = UndoHistory.undo(recorded, 1, edited)
    {_undone, redo_patches} = sequential_replay(patches, edited)

    unless Document.content(undo_restore.document) == text and
             Document.cursor(undo_restore.document) == {3, 2},
           do: raise("#{workload.name}: undo did not restore the original")

    steps = [
      {"undo", fn -> sequential_replay(patches, edited) end,
       fn -> UndoHistory.undo(recorded, 1, edited) end},
      {"redo", fn -> sequential_replay(redo_patches, undo_restore.document) end,
       fn -> UndoHistory.redo(after_undo, 0, undo_restore.document) end}
    ]

    sample_until_budget(fn index ->
      Enum.flat_map(steps, &history_step(workload.name, index, &1))
    end)
  end

  # Runs one undo or redo step through the control and the candidate, in alternating order.
  defp history_step(name, index, {step, control, candidate}) do
    runs = [{"#{step} per-patch", control}, {"#{step} one-pass", candidate}]
    ordered = if rem(index, 2) == 0, do: runs, else: Enum.reverse(runs)
    results = Map.new(ordered, fn {impl, fun} -> {impl, isolated(fun)} end)

    {{control_doc, _inverses}, _, _} = results["#{step} per-patch"]
    {{:ok, %{document: candidate_doc}, _history}, _, _} = results["#{step} one-pass"]

    unless Document.content(candidate_doc) == Document.content(control_doc) and
             Document.cursor(candidate_doc) == Document.cursor(control_doc) and
             Lines.snapshot(candidate_doc) == Lines.snapshot(control_doc),
           do: raise("#{name}: #{step} differs from the per-patch control")

    for {impl, {_result, wall_us, reductions}} <- results do
      %{workload: name, impl: impl, index: index, wall_us: wall_us, reductions: reductions}
    end
  end

  defp undo_redo(pid, text, expected, name) do
    {undo_us, _} = :timer.tc(fn -> call(pid, :undo) end)

    unless BufferProcess.content(pid) == text and BufferProcess.cursor(pid) == {3, 2},
      do: raise("#{name}: undo did not restore the original")

    {redo_us, _} = :timer.tc(fn -> call(pid, :redo) end)

    unless BufferProcess.content(pid) == expected,
      do: raise("#{name}: redo did not reapply the batch")

    {undo_us, redo_us}
  end

  # The public `apply_edits/3`, `undo/1`, and `redo/1` send these messages with the default
  # 5 s call timeout. Large sequential batches and batch undo exceed it, so the bench waits for
  # the reply to measure the handler's real cost.
  defp call(pid, message), do: GenServer.call(pid, message, :infinity)

  # Samples until the cap, or until the elapsed time passes the budget after at least one sample.
  defp sample_until_budget(fun, max_samples \\ @max_samples) do
    started = System.monotonic_time(:microsecond)

    Enum.reduce_while(0..(max_samples - 1), [], fn index, acc ->
      rows = fun.(index)
      elapsed = System.monotonic_time(:microsecond) - started
      if elapsed > @budget_us, do: {:halt, acc ++ rows}, else: {:cont, acc ++ rows}
    end)
  end

  # The consumer path differs from the stage only by the Buffer process work around it, so it
  # measures the middle placement and the two boundary cases most likely to show a regression.
  # History mode measures the same cells.
  defp consumer_workload?(name),
    do: String.ends_with?(name, "/middle") or name in ["boundary/overlapping", "boundary/unicode"]

  # ── Reporting ───────────────────────────────────────────────────────────────

  defp percentile(sorted, p) do
    rank = max(1, ceil(p / 100 * length(sorted)))
    Enum.at(sorted, rank - 1)
  end

  defp summarize(rows) do
    rows
    |> Enum.group_by(&{&1.workload, &1.impl})
    |> Enum.map(fn {{workload, impl}, samples} ->
      walls = samples |> Enum.map(& &1.wall_us) |> Enum.sort()
      reductions = samples |> Enum.map(& &1.reductions) |> Enum.reject(&is_nil/1) |> Enum.sort()

      %{
        workload: workload,
        impl: impl,
        samples: length(walls),
        p10_ms: percentile(walls, 10) / 1000,
        p50_ms: percentile(walls, 50) / 1000,
        p90_ms: percentile(walls, 90) / 1000,
        p95_ms: percentile(walls, 95) / 1000,
        reductions_p50: if(reductions == [], do: nil, else: percentile(reductions, 50))
      }
    end)
    |> Enum.sort_by(&{&1.workload, &1.impl})
  end

  defp identity(mode) do
    {commit, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {status, 0} = System.cmd("git", ["status", "--porcelain", "--", "lib"])
    {chip, _} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true)
    {memory, _} = System.cmd("sysctl", ["-n", "hw.memsize"], stderr_to_stdout: true)
    {os, _} = System.cmd("sw_vers", ["-productVersion"], stderr_to_stdout: true)

    %{
      mode: mode,
      commit: String.trim(commit),
      lib_dirty: status != "",
      machine: String.trim(chip),
      memory_bytes: memory |> String.trim() |> String.to_integer(),
      macos: String.trim(os),
      elixir: System.version(),
      otp: System.otp_release(),
      schedulers: System.schedulers_online(),
      mix_env: Mix.env(),
      started_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @doc "Runs one mode and writes its receipt files."
  @spec main([String.t()]) :: :ok
  def main(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [quick: :boolean, only: :string])
    [mode, out_dir] = positional
    File.mkdir_p!(out_dir)
    identity = identity(mode)
    File.write!(Path.join(out_dir, "identity.json"), JSON.encode!(identity))

    measure =
      case mode do
        "stage" -> &stage/1
        "consumer" -> &consumer/1
        "history" -> &history/1
      end

    only = Keyword.get(opts, :only, "")

    rows =
      opts
      |> Keyword.get(:quick, false)
      |> workloads()
      |> Enum.filter(
        &((mode == "stage" or consumer_workload?(&1.name)) and String.contains?(&1.name, only))
      )
      |> Enum.flat_map(measure)

    csv =
      ["workload,impl,index,wall_us,reductions"] ++
        Enum.map(rows, fn row ->
          Enum.join([row.workload, row.impl, row.index, row.wall_us, row.reductions || ""], ",")
        end)

    File.write!(Path.join(out_dir, "samples.csv"), Enum.join(csv, "\n") <> "\n")
    summary = summarize(rows)

    File.write!(
      Path.join(out_dir, "summary.json"),
      JSON.encode!(%{identity: identity, cells: summary})
    )

    for cell <- summary do
      IO.puts(
        "#{cell.workload}\t#{cell.impl}\tn=#{cell.samples}\tp10=#{cell.p10_ms}\tp50=#{cell.p50_ms}\tp90=#{cell.p90_ms}\tp95=#{cell.p95_ms}\tred50=#{cell.reductions_p50}"
      )
    end

    :ok
  end
end

Minga.Bench.BatchReplacements.main(System.argv())
