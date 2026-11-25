defmodule Minga.Buffer.HistoryPerfTest do
  # Timings are only meaningful when nothing else runs; the review's perf7 and perf10 repros on a 12000-line file.
  use ExUnit.Case, async: false

  alias Minga.Buffer.Document
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory
  alias Minga.Buffer.UndoPatch

  @moduletag :perf
  @moduletag timeout: 600_000

  defp file(lines),
    do:
      Enum.map_join(1..lines, fn n ->
        "    value_#{n} = compute(alpha_#{n}, beta, gamma) # note #{n}\n"
      end)

  defp agent_write(buffer, content, source) do
    identity = {:buffer, "perf"}

    revision =
      FileMutation.revision(
        BufferProcess.content(buffer),
        BufferProcess.version(buffer),
        identity
      )

    {:ok, _receipt} =
      BufferProcess.conditional_mutate(buffer, revision, {:replace, content}, identity, source)
  end

  # CPU time of the whole VM, in milliseconds, so other load on the machine does not count.
  defp cpu(fun) do
    {_total, _since} = :erlang.statistics(:runtime)
    value = fun.()
    {_total, cpu_ms} = :erlang.statistics(:runtime)
    {cpu_ms, value}
  end

  # Reductions the process `pid` spends while `fun` runs: work counted the same on any machine and under any load.
  defp work(pid, fun) do
    {:reductions, before} = Process.info(pid, :reductions)
    value = fun.()
    {:reductions, after_fun} = Process.info(pid, :reductions)
    {after_fun - before, value}
  end

  defp ms(fun) do
    {micros, value} = :timer.tc(fun)
    {micros / 1000, value}
  end

  # Compaction runs in slices between messages; wait until the buffer has no slice left to run.
  defp settled(buffer, attempts \\ 100_000)
  defp settled(_buffer, 0), do: flunk("compaction never settled")

  defp settled(buffer, attempts) do
    case :sys.get_state(buffer) do
      %{compaction_scheduled: true} -> settled(buffer, attempts - 1)
      _idle -> buffer
    end
  end

  defp runs(buffer) do
    %{undo_history: history} = :sys.get_state(buffer)
    history |> UndoHistory.provenance() |> Provenance.run_count()
  end

  # Replacement records against runs, and the record's memory per run in bytes (flat size of the whole provenance).
  defp records(buffer) do
    %{undo_history: history} = :sys.get_state(buffer)
    provenance = UndoHistory.provenance(history)
    records = provenance |> Provenance.change_records() |> map_size()
    run_count = Provenance.run_count(provenance)
    bytes = :erts_debug.flat_size(provenance) * :erlang.system_info(:wordsize)
    {records, run_count, div(bytes, max(run_count, 1))}
  end

  # Records plus pull edges, and runs.
  defp record_links(buffer) do
    %{undo_history: history} = :sys.get_state(buffer)
    provenance = UndoHistory.provenance(history)
    records = Provenance.change_records(provenance)
    pulls = records |> Map.values() |> Enum.map(&length(&1.pulls)) |> Enum.sum()
    {map_size(records) + pulls, Provenance.run_count(provenance)}
  end

  test "20 whole-file steps stay under the run budget, and every call afterwards stays fast" do
    buffer = start_supervised!({BufferProcess, content: file(12_000)}, id: make_ref())

    step_times =
      for round <- 1..20 do
        new = String.replace(BufferProcess.content(buffer), ~r/beta\d*/, "beta#{round}")

        {time, _result} =
          ms(fn -> agent_write(buffer, new, EditSource.minga("t", "s#{round}")) end)

        # Replacement records and their links stay bounded by the runs at every step (Addendum 3).
        {links, run_count} = record_links(buffer)

        assert links <= 2 * run_count,
               "round #{round}: #{links} records and links for #{run_count} runs"

        time
      end

    settled(buffer)
    assert runs(buffer) <= 25_000
    {record_count, run_count, bytes_per_run} = records(buffer)

    IO.puts(
      "\n[records] records=#{record_count} runs=#{run_count} bytes_per_run=#{bytes_per_run}"
    )

    assert record_count <= run_count

    :ok = BufferProcess.move_to(buffer, {6000, 10})

    key_work =
      for char <- String.graphemes("hello"),
          do: elem(work(buffer, fn -> BufferProcess.insert_text(buffer, char) end), 0)

    # The same keystrokes in the same file with no history: the baseline, computed in this run.
    fresh = start_supervised!({BufferProcess, content: file(12_000)}, id: make_ref())
    :ok = BufferProcess.move_to(fresh, {6000, 10})

    fresh_work =
      for char <- String.graphemes("hello"),
          do: elem(work(fresh, fn -> BufferProcess.insert_text(fresh, char) end), 0)

    :ok = BufferProcess.break_undo_coalescing(buffer)
    {undo, _result} = cpu(fn -> BufferProcess.undo(buffer) end)
    {changes, _result} = cpu(fn -> BufferProcess.minga_changes(buffer, "t") end)
    {changes_work, _result} = work(buffer, fn -> BufferProcess.minga_changes(buffer, "t") end)
    {read_work, _result} = work(buffer, fn -> BufferProcess.content(buffer) end)
    {reject, {:ok, _steps}} = cpu(fn -> BufferProcess.undo_agent_session(buffer) end)

    IO.puts(
      "\n[perf7] steps_ms=#{inspect(Enum.map(step_times, &round/1))} runs=#{runs(buffer)} " <>
        "keys_work=#{inspect(key_work)} fresh_keys_work=#{inspect(fresh_work)} undo_cpu_ms=#{undo} " <>
        "minga_changes_cpu_ms=#{changes} minga_changes_work=#{changes_work} runs_now=#{runs(buffer)} " <>
        "reject_cpu_ms=#{reject}"
    )

    # No wall-clock bounds: each keystroke after the history costs at most a small multiple of the same keystroke with
    # no history (the record is O(log n) in the runs), and listing the task's changes is linear in the runs.
    assert Enum.max(key_work) < 20 * Enum.max(fresh_work) + 20_000
    assert changes_work < 200 * max(run_count, 1) + read_work
  end

  test "the first keystroke after 20 whole-file steps records quickly" do
    buffer = start_supervised!({BufferProcess, content: file(12_000)}, id: make_ref())

    for round <- 1..20,
        do:
          agent_write(
            buffer,
            String.replace(BufferProcess.content(buffer), ~r/beta\d*/, "beta#{round}"),
            EditSource.minga("t", "s#{round}")
          )

    settled(buffer)
    :erlang.garbage_collect(buffer)
    :ok = BufferProcess.move_to(buffer, {6000, 10})
    {_total, _since} = :erlang.statistics(:runtime)
    :ok = BufferProcess.insert_text(buffer, "h")
    {_total, first_key} = :erlang.statistics(:runtime)

    # CPU time, beside the same keystroke in a buffer with no history. The first keystroke after a full collection also
    # copies the history's heap once.
    fresh = start_supervised!({BufferProcess, content: file(12_000)}, id: make_ref())
    :erlang.garbage_collect(fresh)
    :ok = BufferProcess.move_to(fresh, {6000, 10})
    {_total, _since} = :erlang.statistics(:runtime)
    :ok = BufferProcess.insert_text(fresh, "h")
    {_total, baseline} = :erlang.statistics(:runtime)
    IO.puts("\n[perf10] first_key_ms=#{first_key} baseline_ms=#{baseline}")
    assert first_key < baseline + 50
  end

  # R5: steps sent back to back, with no gap for the compaction slices, still keep the history bounded, and cost in all
  # less than twice the same steps on a buffer that never compacts.
  test "20 back-to-back whole-file steps keep the runs under three times the budget" do
    {times, buffer} = back_to_back([])
    # Right after the burst, before the slices catch up.
    runs = runs(buffer)
    {record_count, _runs, bytes_per_run} = records(buffer)
    {plain_times, _plain} = back_to_back(history_run_budget: 100_000_000)

    IO.puts(
      "\n[back-to-back] steps_cpu_ms=#{inspect(times)} without_compaction_cpu_ms=#{inspect(plain_times)} " <>
        "runs=#{runs} records=#{record_count} bytes_per_run=#{bytes_per_run}"
    )

    assert record_count <= runs
    assert runs <= 75_000
    assert Enum.sum(times) < 2 * Enum.sum(plain_times)
  end

  # CPU time of the whole VM around each call, so other load on the machine does not count.
  defp back_to_back(opts) do
    buffer = start_supervised!({BufferProcess, [content: file(12_000)] ++ opts}, id: make_ref())

    times =
      for round <- 1..20 do
        new = String.replace(BufferProcess.content(buffer), ~r/beta\d*/, "beta#{round}")
        {_total, _since} = :erlang.statistics(:runtime)
        agent_write(buffer, new, EditSource.minga("t", "s#{round}"))
        {_total, cpu_ms} = :erlang.statistics(:runtime)
        cpu_ms
      end

    {times, buffer}
  end

  # R4: your :s over 12000 lines that each hold a Minga change records in linear time: at most twice the CPU of the
  # same :s over a file Minga never touched, measured in this run (the target in the PR body is 100 ms on an idle
  # machine; that number is reported, not asserted).
  test "your :s over Minga's change on every line of 12000 records quickly" do
    original = file(12_000)
    minga = String.replace(original, "beta", "beta7")
    yours = String.replace(minga, "beta7", "BETA")
    history = UndoHistory.new(Document.new(original))
    patches = UndoPatch.changes(Document.new(original), Document.new(minga))
    history = UndoHistory.record_edit_batch(history, 1, patches, {:minga, "t", "s1"}, 0)
    patches = UndoPatch.changes(Document.new(minga), Document.new(yours))

    # CPU time, so other load on the machine does not count.
    best =
      for _ <- 1..5 do
        :erlang.garbage_collect()
        {_total, _since} = :erlang.statistics(:runtime)
        UndoHistory.record_edit_batch(history, 2, patches, :user, 1)
        {_total, cpu_ms} = :erlang.statistics(:runtime)
        cpu_ms
      end
      |> Enum.min()

    untouched = UndoHistory.new(Document.new(minga))

    baseline =
      for _ <- 1..5 do
        :erlang.garbage_collect()
        {_total, _since} = :erlang.statistics(:runtime)
        UndoHistory.record_edit_batch(untouched, 1, patches, :user, 1)
        {_total, cpu_ms} = :erlang.statistics(:runtime)
        cpu_ms
      end
      |> Enum.min()

    IO.puts("\n[R4] record_cpu_ms=#{best} untouched_baseline_cpu_ms=#{baseline}")
    assert best < 2 * baseline + 10
  end
end
