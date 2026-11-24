defmodule Minga.Buffer.HistoryPerfTest do
  # Timings are only meaningful when nothing else runs; the review's perf7 and perf10 repros on a 12000-line file.
  use ExUnit.Case, async: false

  alias Minga.Buffer.EditSource
  alias Minga.Buffer.FileMutation
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Buffer.Provenance
  alias Minga.Buffer.UndoHistory

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

  defp ms(fun) do
    {micros, value} = :timer.tc(fun)
    {micros / 1000, value}
  end

  # Compaction runs in slices between messages; wait until the buffer has no slice left to run.
  defp settled(buffer) do
    case :sys.get_state(buffer) do
      %{compaction_scheduled: true} -> settled(buffer)
      _idle -> buffer
    end
  end

  defp runs(buffer) do
    %{undo_history: history} = :sys.get_state(buffer)
    history |> UndoHistory.provenance() |> Provenance.run_count()
  end

  test "20 whole-file steps stay under the run budget, and every call afterwards stays fast" do
    buffer = start_supervised!({BufferProcess, content: file(12_000)}, id: make_ref())

    step_times =
      for round <- 1..20 do
        new = String.replace(BufferProcess.content(buffer), ~r/beta\d*/, "beta#{round}")

        {time, _result} =
          ms(fn -> agent_write(buffer, new, EditSource.minga("t", "s#{round}")) end)

        time
      end

    settled(buffer)
    assert runs(buffer) <= 25_000

    :ok = BufferProcess.move_to(buffer, {6000, 10})

    key_times =
      for char <- String.graphemes("hello"),
          do: elem(ms(fn -> BufferProcess.insert_text(buffer, char) end), 0)

    :ok = BufferProcess.break_undo_coalescing(buffer)
    {undo, _result} = ms(fn -> BufferProcess.undo(buffer) end)
    {changes, _result} = ms(fn -> BufferProcess.minga_changes(buffer, "t") end)
    {reject, {:ok, _steps}} = ms(fn -> BufferProcess.undo_agent_session(buffer) end)

    IO.puts(
      "\n[perf7] steps_ms=#{inspect(Enum.map(step_times, &round/1))} runs=#{runs(buffer)} " <>
        "keys_ms=#{inspect(key_times)} undo_ms=#{undo} minga_changes_ms=#{changes} reject_ms=#{reject}"
    )

    assert Enum.max(key_times) < 50
    assert changes < 100
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
    {first_key, :ok} = ms(fn -> BufferProcess.insert_text(buffer, "h") end)
    IO.puts("\n[perf10] first_key_ms=#{first_key}")
    assert first_key < 50
  end
end
