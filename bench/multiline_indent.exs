defmodule Minga.Bench.MultilineIndent do
  @moduledoc """
  Multiline `>` and `<` cost through the real command path (#3499).

  Each sample starts a fresh buffer process holding a deterministic production-scale document, selects whole lines with a Visual Line selection, and runs `MingaEditor.Commands.Editing.execute/2` from a fresh caller process. It then undoes and redoes once through `Minga.Buffer.undo/1` and `redo/1`, the calls the Editor makes. Every phase checks the resulting text, so a fast wrong answer cannot pass.

  Measured per sample:

    * `edit_us`: the command call, as the Editor would wait for it.
    * `settle_us`: from the command's return until the buffer has drained the change events it queued for itself, which subscribers then receive.
    * `undo_us` / `redo_us`: one `Buffer.undo/1` or `Buffer.redo/1` call. When the call outlives the default 5 s `GenServer.call` timeout, the sample records `caller_exit` and the time at which the buffer actually finished (`*_complete_us`). A phase still running at the cap is killed and recorded as `aborted`.
    * Work counters: buffer and caller reductions for the edit, version and change-sequence advance, undo entries added, retained undo-history bytes (heap words plus owned binaries), and the system-wide words the garbage collector reclaimed across the edit (an allocation proxy, not exact).

  Run, once per revision, alternating the order between rounds:

      MIX_ENV=test mix run bench/multiline_indent.exs -- --label candidate --round 1

  Then summarize every JSON file in a directory:

      MIX_ENV=test mix run bench/multiline_indent.exs -- --summarize bench/multiline_indent

  `MINGA_BENCH_INDENT_CAP_S` (default 120) bounds each phase. `MINGA_BENCH_INDENT_ONLY` takes a comma-separated list of cell names to run a subset.
  """

  alias Minga.Buffer
  alias MingaEditor.Commands.Editing
  alias MingaEditor.CommandStateHelpers

  @document_lines 100_000
  @out_dir Path.join(__DIR__, "multiline_indent")

  # {selection lines, style, samples}
  @core for lines <- [1, 1_000, 10_000, 100_000], do: {lines, :spaces4}
  @widths for lines <- [1, 1_000], style <- [:spaces2, :tabs8], do: {lines, style}

  @spec main([String.t()]) :: :ok
  def main(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(Enum.reject(argv, &(&1 == "--")),
        strict: [label: :string, round: :integer, summarize: :string]
      )

    case opts[:summarize] do
      nil -> run(Keyword.get(opts, :label, "run"), Keyword.get(opts, :round, 1))
      dir -> summarize(dir)
    end
  end

  # ── Run ──────────────────────────────────────────────────────────────────

  @spec run(String.t(), pos_integer()) :: :ok
  defp run(label, round) do
    File.mkdir_p!(@out_dir)
    text = document(@document_lines)
    cap_ms = String.to_integer(System.get_env("MINGA_BENCH_INDENT_CAP_S", "120")) * 1_000
    only = only_filter()

    cells =
      for {lines, style} <- @core ++ @widths,
          op <- [:indent, :dedent],
          name = cell_name(op, lines, style),
          only == nil or name in only,
          do: {name, op, lines, style}

    results =
      Enum.map(cells, fn {name, op, lines, style} ->
        samples = sample_count(lines)
        IO.puts(:stderr, "#{label} round #{round}: #{name} x#{samples}")
        warm(text, op, lines, style, cap_ms)

        observations =
          for index <- 1..samples, do: sample(text, op, lines, style, cap_ms, index)

        %{
          "cell" => name,
          "op" => Atom.to_string(op),
          "selection_lines" => lines,
          "style" => Atom.to_string(style),
          "samples" => observations
        }
      end)

    receipt = %{
      "label" => label,
      "round" => round,
      "revision" => revision(),
      "dirty_files" => dirty_files(),
      "machine" => machine(),
      "document" => %{
        "lines" => @document_lines,
        "bytes" => byte_size(text),
        "sha256" => Base.encode16(:crypto.hash(:sha256, text), case: :lower)
      },
      "cap_ms" => cap_ms,
      "cells" => results
    }

    path = Path.join(@out_dir, "#{label}-r#{round}.json")
    File.write!(path, JSON.encode!(receipt))
    IO.puts("wrote #{path}")
    :ok
  end

  defp only_filter do
    case System.get_env("MINGA_BENCH_INDENT_ONLY") do
      nil -> nil
      list -> String.split(list, ",", trim: true)
    end
  end

  defp sample_count(1), do: 21
  defp sample_count(1_000), do: 7
  defp sample_count(10_000), do: 3
  defp sample_count(100_000), do: 1

  defp cell_name(op, lines, style), do: "#{op}/#{lines}/#{style}"

  # One unrecorded sample per cell loads code and warms allocators for the
  # cell. Large cells are skipped: their cost dwarfs first-call effects.
  defp warm(text, op, lines, style, cap_ms) when lines <= 1_000 do
    _ = sample(text, op, lines, style, cap_ms, 0)
    :ok
  end

  defp warm(_text, _op, _lines, _style, _cap_ms), do: :ok

  defp sample(text, op, lines, style, cap_ms, index) do
    {:ok, buf} = Buffer.start_link(content: text)
    Process.unlink(buf)
    apply_style(buf, style)
    {first, last} = selection(lines)
    original = Buffer.content(buf)
    expected = expected_text(original, first, last, op, style)
    Buffer.move_to(buf, {last, 0})

    state =
      buf
      |> CommandStateHelpers.command_state()
      |> CommandStateHelpers.with_visual_selection({first, 0}, :line)

    command = if op == :indent, do: :indent_visual_selection, else: :dedent_visual_selection

    :erlang.garbage_collect(buf)
    {version_before, sequence_before} = Buffer.sync_revision(buf)
    undo_before = undo_count(buf)
    buf_reductions_before = reductions(buf)
    {_, reclaimed_before, _} = :erlang.statistics(:garbage_collection)

    edit =
      timed_phase(fn -> caller_run(fn -> Editing.execute(state, command) end) end, buf, cap_ms)

    observation =
      case edit do
        {:aborted, _} ->
          %{"edit" => "aborted"}

        {:ok,
         %{
           us: edit_us,
           settle_us: settle_us,
           caller_exit: edit_exit?,
           caller_reductions: caller_reductions
         }} ->
          buf_reductions = reductions(buf) - buf_reductions_before
          {_, reclaimed_after, _} = :erlang.statistics(:garbage_collection)
          {version_after, sequence_after} = Buffer.sync_revision(buf)
          shifted = Buffer.content(buf)
          verify_content!(buf, expected, op)
          :erlang.garbage_collect(buf)
          history = :sys.get_state(buf).undo_history

          base = %{
            "edit_us" => edit_us,
            "edit_caller_exit" => edit_exit?,
            "settle_us" => settle_us,
            "buffer_reductions" => buf_reductions,
            "caller_reductions" => caller_reductions,
            "gc_words_reclaimed" => reclaimed_after - reclaimed_before,
            "version_advance" => version_after - version_before,
            "sequence_advance" => sequence_after - sequence_before,
            "undo_entries_added" => undo_count(buf) - undo_before,
            "retained_undo_bytes" => term_bytes(history),
            "buffer_memory_bytes" => process_bytes(buf)
          }

          base
          |> Map.merge(history_phase("undo", buf, &Buffer.undo/1, original, cap_ms))
          |> Map.merge(history_phase("redo", buf, &Buffer.redo/1, shifted, cap_ms))
      end

    if Process.alive?(buf), do: Process.exit(buf, :kill)
    Map.put(observation, "index", index)
  end

  defp history_phase(name, buf, fun, expected, cap_ms) do
    if Process.alive?(buf),
      do: run_history_phase(name, buf, fun, expected, cap_ms),
      else: %{name => "skipped"}
  end

  defp run_history_phase(name, buf, fun, expected, cap_ms) do
    case timed_phase(caller_phase(fn -> fun.(buf) end), buf, cap_ms) do
      {:aborted, elapsed} ->
        %{name => "aborted", "#{name}_aborted_after_us" => elapsed}

      {:ok, %{us: us, settle_us: settle_us, caller_exit: exit?}} ->
        verify_content!(buf, expected, name)

        %{
          "#{name}_us" => us,
          "#{name}_complete_us" => us + settle_us,
          "#{name}_caller_exit" => exit?
        }
    end
  end

  defp caller_phase(fun), do: fn -> caller_run(fun) end

  defp verify_content!(buf, expected, phase) do
    if Buffer.content(buf) != expected, do: raise("#{phase} produced unexpected text")
    :ok
  end

  # Runs `fun` in a fresh caller process, as the Editor would, and waits for
  # the buffer to finish everything the call queued. Returns the caller's
  # elapsed time, the extra time the buffer needed to go idle, and whether
  # the caller exited on its call timeout.
  defp caller_run(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        reductions_before = reductions(self())
        started = System.monotonic_time(:microsecond)

        result =
          try do
            fun.()
            :returned
          catch
            :exit, {:timeout, _} -> :caller_exit
          end

        elapsed = System.monotonic_time(:microsecond) - started

        send(
          parent,
          {:caller_done, self(), result, elapsed, reductions(self()) - reductions_before}
        )
      end)

    receive do
      {:caller_done, ^pid, result, elapsed, caller_reductions} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        end

        {result, elapsed, caller_reductions}
    end
  end

  defp timed_phase(run, buf, cap_ms) do
    task =
      Task.async(fn ->
        {result, elapsed, caller_reductions} = run.()
        settle_started = System.monotonic_time(:microsecond)
        :sys.get_state(buf, :infinity)
        settle = System.monotonic_time(:microsecond) - settle_started

        %{
          us: elapsed,
          settle_us: settle,
          caller_exit: result == :caller_exit,
          caller_reductions: caller_reductions
        }
      end)

    case Task.yield(task, cap_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, measured} ->
        {:ok, measured}

      _ ->
        Process.exit(buf, :kill)
        {:aborted, cap_ms * 1_000}
    end
  end

  # ── Fixture ──────────────────────────────────────────────────────────────

  # A deterministic mix of blank, Unicode, tab-indented, space-indented
  # (2/4/8), and mixed-indentation lines, about 40 bytes per line.
  @patterns [
    "defmodule Example.Module#{"é"} do",
    "",
    "  @moduledoc \"résumé café 世界\"",
    "\tdef tabbed(value), do: value + 1",
    "    four_spaces = Enum.map(list, & &1)",
    "        eight_spaces # \u{1F642} emoji",
    "\t  mixed_tab_then_spaces()",
    "  ",
    "no_indent_line with some words in it",
    "      six = \"क्ष กำ\""
  ]

  defp document(lines) do
    patterns = List.to_tuple(@patterns)
    count = tuple_size(patterns)
    Enum.map_join(0..(lines - 1), "\n", fn i -> "#{elem(patterns, rem(i, count))} #{i}" end)
  end

  # The one-line case targets a four-space line in the middle of the document,
  # so dedent has work to do in every style.
  defp selection(1), do: {div(@document_lines, 2) + 4, div(@document_lines, 2) + 4}
  defp selection(lines) when lines >= @document_lines, do: {0, @document_lines - 1}

  defp selection(lines) do
    first = div(@document_lines - lines, 2)
    {first, first + lines - 1}
  end

  defp apply_style(buf, :spaces2), do: set_style(buf, :spaces, 2)
  defp apply_style(buf, :spaces4), do: set_style(buf, :spaces, 4)
  defp apply_style(buf, :tabs8), do: set_style(buf, :tabs, 8)

  defp set_style(buf, indent_with, width) do
    Buffer.set_option(buf, :indent_with, indent_with)
    Buffer.set_option(buf, :tab_width, width)
  end

  defp expected_text(text, first, last, op, style) do
    {unit, width} = style_unit(style)

    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.map_join("\n", fn
      {line, i} when i >= first and i <= last -> shift_line(op, line, unit, width)
      {line, _i} -> line
    end)
  end

  defp style_unit(:spaces2), do: {"  ", 2}
  defp style_unit(:spaces4), do: {"    ", 4}
  defp style_unit(:tabs8), do: {"\t", 8}

  defp shift_line(:indent, line, unit, _width), do: unit <> line
  defp shift_line(:dedent, "\t" <> rest, _unit, _width), do: rest

  defp shift_line(:dedent, line, _unit, width) do
    spaces = line |> String.graphemes() |> Enum.take_while(&(&1 == " ")) |> length()
    removed = min(spaces, width)
    binary_part(line, removed, byte_size(line) - removed)
  end

  # ── Measurement helpers ──────────────────────────────────────────────────

  defp reductions(pid) do
    {:reductions, count} = Process.info(pid, :reductions)
    count
  end

  defp undo_count(buf), do: Minga.Buffer.UndoHistory.undo_count(:sys.get_state(buf).undo_history)

  defp process_bytes(pid) do
    {:memory, heap} = Process.info(pid, :memory)
    {:binary, binaries} = Process.info(pid, :binary)
    heap + (binaries |> Enum.uniq_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)) |> Enum.sum())
  end

  # Heap words of the term plus the bytes of reference-counted binaries it
  # owns (binaries over 64 bytes live off the process heap).
  defp term_bytes(term),
    do: :erts_debug.size(term) * :erlang.system_info(:wordsize) + offheap(term, 0)

  defp offheap(term, acc) when is_binary(term) and byte_size(term) > 64, do: acc + byte_size(term)
  defp offheap(term, acc) when is_list(term), do: offheap_list(term, acc)
  defp offheap(term, acc) when is_tuple(term), do: term |> Tuple.to_list() |> offheap_list(acc)
  defp offheap(term, acc) when is_map(term), do: term |> Map.values() |> offheap_list(acc)
  defp offheap(_term, acc), do: acc

  defp offheap_list([head | tail], acc), do: offheap_list(tail, offheap(head, acc))
  defp offheap_list([], acc), do: acc
  defp offheap_list(improper, acc), do: offheap(improper, acc)

  defp revision do
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: __DIR__)
    String.trim(sha)
  end

  defp dirty_files do
    {status, 0} =
      System.cmd("git", ["status", "--porcelain", "--", "lib"], cd: Path.join(__DIR__, ".."))

    status |> String.split("\n", trim: true)
  end

  defp machine do
    {cpu, _} = System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true)
    {os, _} = System.cmd("sw_vers", ["-productVersion"], stderr_to_stdout: true)

    %{
      "cpu" => String.trim(cpu),
      "os" => "macOS " <> String.trim(os),
      "otp" => System.otp_release(),
      "elixir" => System.version(),
      "schedulers" => System.schedulers_online(),
      "mix_env" => Atom.to_string(Mix.env())
    }
  end

  # ── Summary ──────────────────────────────────────────────────────────────

  @metrics ~w(edit_us settle_us undo_complete_us redo_complete_us buffer_reductions gc_words_reclaimed retained_undo_bytes version_advance sequence_advance undo_entries_added)

  defp summarize(dir) do
    receipts =
      dir
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&(&1 |> File.read!() |> JSON.decode!()))

    receipts
    |> Enum.flat_map(fn receipt ->
      Enum.map(receipt["cells"], &{receipt["label"], &1["cell"], &1["samples"]})
    end)
    |> Enum.group_by(fn {label, cell, _} -> {cell, label} end, fn {_, _, samples} -> samples end)
    |> Enum.sort_by(fn {{cell, label}, _} -> {cell_order(cell), label} end)
    |> Enum.each(fn {{cell, label}, sample_lists} ->
      print_row(cell, label, List.flatten(sample_lists))
    end)
  end

  defp cell_order(cell) do
    [op, lines, style] = String.split(cell, "/")
    {style != "spaces4", style, String.to_integer(lines), op}
  end

  defp print_row(cell, label, samples) do
    stats =
      Enum.map_join(@metrics, " ", fn metric ->
        values =
          samples |> Enum.map(&Map.get(&1, metric)) |> Enum.filter(&is_number/1) |> Enum.sort()

        "#{metric}=#{percentiles(values)}"
      end)

    flags =
      samples
      |> Enum.flat_map(fn sample ->
        for {key, value} <- sample, value in ["aborted", true], do: "#{key}=#{value}"
      end)
      |> Enum.frequencies()
      |> Enum.map_join(" ", fn {flag, n} -> "#{flag}x#{n}" end)

    IO.puts("#{cell} #{label} n=#{length(samples)} #{stats} #{flags}")
  end

  defp percentiles([]), do: "-"

  defp percentiles(values) do
    Enum.map_join([10, 50, 90], "/", fn p -> nearest_rank(values, p) end)
  end

  defp nearest_rank(values, p) do
    index = max(0, ceil(p / 100 * length(values)) - 1)
    Enum.at(values, index)
  end
end

Minga.Bench.MultilineIndent.main(System.argv())
