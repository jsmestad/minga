defmodule Minga.Buffer.ReviewRecoveryTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Events
  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery
  alias Minga.Session.ControllableSwapBackend
  alias MingaAgent.Session, as: AgentSession

  @moduletag :tmp_dir
  @moduletag capture_log: true
  @task {:minga, "task"}
  @first {:minga, "task", "first"}
  @second {:minga, "task", "second"}

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "owned.txt")
    File.write!(path, "before\nother\n")
    %{path: path, swap_dir: Path.join(dir, "swap")}
  end

  test "an outstanding Keep observation leaves the buffer responsive and refuses a changed target",
       ctx do
    caller = self()

    observe = fn path, dirty? ->
      send(caller, {:capturing_keep, self(), path, dirty?})

      receive do
        :finish_observing -> :unproven
      after
        3_000 -> exit(:test_gate_not_released)
      end
    end

    buffer = start_buffer(ctx, keep_observer: observe)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    assert {:ok, target, @task, 1} = Buffer.prepare_review(buffer, :latest)
    request = Buffer.request_keep(buffer, target)
    assert_receive {:capturing_keep, worker, path, true}, 1_000
    assert path == ctx.path

    assert {:ok, ^target, @task, 1} = Buffer.prepare_review(buffer, :latest)
    assert {:error, :review_in_progress} = Buffer.decide_review(buffer, target, :keep)
    replace(buffer, {1, 0}, 0, "!", :user)
    assert Buffer.content(buffer) == "AFTER\n!other\n"
    send(worker, :finish_observing)

    assert {:reply, {:error, :stale_review}} = :gen_server.receive_response(request, 1_000)
    assert {:ok, _updated, @task, 1} = Buffer.prepare_review(buffer, :latest)
  end

  test "explicit save before dirty debounce reopens without layout, with exact authorship", ctx do
    first = start_buffer(ctx)
    replace(first, {0, 0}, 6, "AFTER", @first)

    assert {@task, @first, written_at, :unreviewed} =
             Buffer.attribution_at(first, {0, 1}, Buffer.version(first))

    assert is_integer(written_at)
    assert :ok = Buffer.save(first)
    assert :ok = GenServer.stop(first)
    assert {:ok, %{kind: :clean}, ""} = Swap.read(swap_path(ctx))
    assert [] = Recovery.scan(swap_dir: ctx.swap_dir)

    reopened = start_buffer(ctx)
    assert Buffer.content(reopened) == "AFTER\nother\n"
    refute Buffer.dirty?(reopened)
    assert Buffer.author_at(reopened, {0, 0}) == @task

    assert Buffer.attribution_at(reopened, {0, 1}, Buffer.version(reopened)) ==
             {@task, @first, written_at, :unreviewed}

    assert :ok = Buffer.undo(reopened)
    assert Buffer.content(reopened) == "AFTER\nother\n"

    assert {:ok, target, @task, 1} = Buffer.prepare_review(reopened, :latest)
    assert {:ok, [_]} = Buffer.decide_review(reopened, target, :reject)
    assert Buffer.content(reopened) == "before\nother\n"
    assert File.read!(ctx.path) == "AFTER\nother\n"
  end

  test "restored disjoint spans and the EOF deletion prepare precise decisions", ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    replace(buffer, {1, 0}, 5, "OTHER", @first)
    replace(buffer, {1, 5}, 1, "", @second)
    assert :ok = Buffer.save(buffer)
    assert :ok = GenServer.stop(buffer)

    reopened = start_buffer(ctx)
    assert Buffer.content(reopened) == "AFTER\nOTHER"
    assert {:ok, first, @task, 1} = Buffer.prepare_review(reopened, {:at_byte, 2})
    assert {:ok, ^first, @task, 1} = Buffer.prepare_review(reopened, {:at_byte, 8})
    assert :empty = Buffer.prepare_review(reopened, {:at_byte, 5})
    assert {:ok, tail, @task, 1} = Buffer.prepare_review(reopened, {:at_byte, 11})
    refute tail == first

    replace(reopened, {0, 0}, 0, ">", :user)
    assert {:error, :stale_review} = Buffer.decide_review(reopened, first, :keep)

    assert {:ok, updated, @task, 1} = Buffer.prepare_review(reopened, {:at_byte, 9})
    assert :ok = Buffer.decide_review(reopened, updated, :keep)
    assert Buffer.content(reopened) == ">AFTER\nOTHER"
    assert :empty = Buffer.prepare_review(reopened, {:at_byte, 3})
    assert :empty = Buffer.prepare_review(reopened, {:at_byte, 9})

    assert {:ok, tail, @task, 1} = Buffer.prepare_review(reopened, {:at_byte, 12})
    assert {:ok, [_]} = Buffer.decide_review(reopened, tail, :reject)
    assert Buffer.content(reopened) == ">AFTER\nOTHER\n"
  end

  test "range Reject checks all selected tasks before it changes anything", ctx do
    buffer = start_buffer(ctx)
    outside = {:minga, "blocking", "outside"}
    second_task = {:minga, "independent", "other"}
    replace(buffer, {0, 0}, 1, "A", @first)
    replace(buffer, {0, 4}, 1, "E", @first)
    replace(buffer, {1, 0}, 3, "XYZ", @first)
    replace(buffer, {0, 2}, 1, "F", second_task)
    replace(buffer, {1, 1}, 1, "q", outside)

    assert {:ok, selected, :multiple_tasks, 2} =
             Buffer.prepare_review(buffer, {:byte_range, 0, 6})

    assert {:blocked, {:overlaps, ^outside}} = Buffer.decide_review(buffer, selected, :reject)
    assert Buffer.content(buffer) == "AeFoEe\nXqZer\n"

    assert {:ok, blocker, {:minga, "blocking"}, 1} =
             Buffer.prepare_review(buffer, {:step, outside})

    assert {:ok, [_]} = Buffer.decide_review(buffer, blocker, :reject)
    assert {:error, :stale_review} = Buffer.decide_review(buffer, selected, :reject)

    assert {:ok, selected, :multiple_tasks, 2} =
             Buffer.prepare_review(buffer, {:byte_range, 0, 6})

    assert {:ok, [_, _]} = Buffer.decide_review(buffer, selected, :reject)
    assert Buffer.content(buffer) == "before\nother\n"
  end

  test "one Keep across tasks promotes only the selected units into the saved generation", ctx do
    buffer = start_buffer(ctx)
    second_task = {:minga, "independent", "other"}
    replace(buffer, {0, 0}, 1, "B", @first)
    replace(buffer, {0, 4}, 1, "R", second_task)
    replace(buffer, {1, 0}, 5, "OTHER", @second)
    assert :ok = Buffer.save(buffer)
    replace(buffer, {0, 6}, 0, "!", :user)

    assert {:ok, selected, :multiple_tasks, 2} =
             Buffer.prepare_review(buffer, {:byte_range, 0, 6})

    assert :ok = Buffer.decide_review(buffer, selected, :keep)
    assert Buffer.content(buffer) == "BefoRe!\nOTHER\n"
    assert :ok = GenServer.stop(buffer)

    reopened = start_buffer(ctx)
    assert Buffer.content(reopened) == "BefoRe\nOTHER\n"
    assert :empty = Buffer.prepare_review(reopened, {:byte_range, 0, 6})
    assert {[_pending], _, {1, 0}} = Buffer.task_review_entries(reopened, "task")
    assert {[], nil, {1, 0}} = Buffer.task_review_entries(reopened, "independent")
    assert {:ok, unselected, @task, 1} = Buffer.prepare_review(reopened, {:step, @second})
    assert {:ok, [_]} = Buffer.decide_review(reopened, unselected, :reject)
    assert {[], nil, {1, 1}} = Buffer.task_review_entries(reopened, "task")
    assert Buffer.content(reopened) == "BefoRe\nother\n"
  end

  test "auto-save publishes the review checkpoint without a dirty-swap callback", ctx do
    registry = Module.concat(__MODULE__, "Saved#{System.unique_integer([:positive])}")
    start_supervised!({Registry, keys: :duplicate, name: registry})
    :ok = Events.subscribe(:buffer_saved, registry)

    buffer =
      start_buffer(ctx,
        events_registry: registry,
        auto_save: 30,
        swap_timer_start: fn _owner, _message, _delay -> make_ref() end
      )

    replace(buffer, {0, 0}, 6, "AFTER", @first)
    assert_receive {:minga_event, :buffer_saved, _save}, 2_000
    assert :ok = GenServer.stop(buffer)

    reopened = start_buffer(ctx)
    refute Buffer.dirty?(reopened)
    assert Buffer.content(reopened) == "AFTER\nother\n"
    assert {:ok, _target, @task, 1} = Buffer.prepare_review(reopened, :latest)
  end

  test "review decisions checkpoint text without writing the project file on the auto-save timer",
       ctx do
    buffer = start_buffer(ctx, auto_save: 60_000)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    assert :ok = Buffer.save(buffer)

    replace(buffer, {1, 5}, 0, "!", :user)
    pending_save = :sys.get_state(buffer).auto_save_token
    assert {:ok, target, @task, 1} = Buffer.prepare_review(buffer, :latest)
    assert {:ok, [receipt]} = Buffer.decide_review(buffer, target, :reject)
    deliver_pending_saves(buffer, pending_save)

    assert Buffer.content(buffer) == "before\nother!\n"
    assert File.read!(ctx.path) == "AFTER\nother\n"
    assert {:ok, %{kind: :dirty}, "before\nother!\n"} = Swap.read(swap_path(ctx))

    assert :ok = Buffer.restore_review(buffer, receipt)
    deliver_pending_saves(buffer)

    assert Buffer.content(buffer) == "AFTER\nother!\n"
    assert File.read!(ctx.path) == "AFTER\nother\n"
    assert {:ok, %{kind: :dirty}, "AFTER\nother!\n"} = Swap.read(swap_path(ctx))

    replace(buffer, {1, 6}, 0, "?", :user)
    deliver_pending_saves(buffer)
    assert File.read!(ctx.path) == "AFTER\nother!?\n"
  end

  test "abrupt buffer loss restores the checkpointed dirty text and reversible ownership", ctx do
    original = start_buffer(ctx)
    replace(original, {0, 0}, 0, "abc", @first)
    replace(original, {0, 1}, 0, "X", :user)
    replace(original, {1, 0}, 5, "OTHER", @second)
    assert {:ok, keep, @task, 1} = Buffer.prepare_review(original, {:step, @second})
    assert :ok = Buffer.decide_review(original, keep, :keep)

    monitor = Process.monitor(original)
    Process.exit(original, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^original, :killed}
    assert File.read!(ctx.path) == "before\nother\n"
    assert {:ok, original_receipt, "aXbcbefore\nOTHER\n"} = Recovery.read(swap_path(ctx))

    recovered = start_buffer(ctx)
    assert Buffer.dirty?(recovered)
    assert Buffer.content(recovered) == "aXbcbefore\nOTHER\n"
    assert Buffer.author_at(recovered, {0, 0}) == @task
    assert Buffer.author_at(recovered, {0, 1}) == :you
    assert :ok = Buffer.adopt_recovered_text(recovered, "aXbcbefore\nOTHER\n", original_receipt)
    assert {:ok, reject, @task, 1} = Buffer.prepare_review(recovered, :latest)
    assert {:ok, [_]} = Buffer.decide_review(recovered, reject, :reject)
    assert Buffer.content(recovered) == "Xbefore\nOTHER\n"
    assert File.read!(ctx.path) == "before\nother\n"
  end

  test "deliberate dirty close carries Keep to the saved generation, not unsaved bytes", ctx do
    original = start_buffer(ctx)
    replace(original, {0, 0}, 6, "AFTER", @first)
    replace(original, {1, 0}, 5, "OTHER", @second)
    assert :ok = Buffer.save(original)
    replace(original, {1, 5}, 0, "!", :user)
    assert {:ok, target, @task, 1} = Buffer.prepare_review(original, {:step, @first})
    assert :ok = Buffer.decide_review(original, target, :keep)
    assert Buffer.content(original) == "AFTER\nOTHER!\n"
    assert :ok = GenServer.stop(original)

    reopened = start_buffer(ctx)
    refute Buffer.dirty?(reopened)
    assert Buffer.content(reopened) == "AFTER\nOTHER\n"
    assert Buffer.author_at(reopened, {0, 0}) == @task
    assert :empty = Buffer.prepare_review(reopened, {:step, @first})
    assert {:ok, reject, @task, 1} = Buffer.prepare_review(reopened, :latest)
    assert {:ok, [_]} = Buffer.decide_review(reopened, reject, :reject)
    assert Buffer.content(reopened) == "AFTER\nother\n"
  end

  test "reload of saved bytes abandons an unpublished Reject, not the saved pending unit", ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    assert :ok = Buffer.save(buffer)
    assert {:ok, target, @task, 1} = Buffer.prepare_review(buffer, :latest)
    assert {:ok, [_]} = Buffer.decide_review(buffer, target, :reject)
    assert Buffer.content(buffer) == "before\nother\n"

    assert :ok = Buffer.reload(buffer)
    assert Buffer.content(buffer) == "AFTER\nother\n"
    refute Buffer.dirty?(buffer)
    assert {:ok, target, @task, 1} = Buffer.prepare_review(buffer, :latest)
    assert {:ok, [_]} = Buffer.decide_review(buffer, target, :reject)
    assert Buffer.content(buffer) == "before\nother\n"
  end

  test "a disk save with a failed review checkpoint cannot recover older text unasked", ctx do
    buffer =
      start_buffer(ctx,
        swap_backend: ControllableSwapBackend,
        swap_backend_options: [controller: self()]
      )

    replace(buffer, {0, 0}, 6, "OLDER", @first)
    path = ctx.path
    send(buffer, :write_swap)
    assert_receive {:swap_prepare, worker, generation, ^path, "OLDER\nother\n"}
    send(worker, {:swap_prepare_result, generation, :ok})
    assert_receive {:swap_published, ^buffer, ^worker, ^generation, ^path, "OLDER\nother\n", :ok}
    replace(buffer, {0, 0}, 5, "NEWER", :user)

    save = Task.async(fn -> Buffer.save(buffer) end)
    assert_receive {:swap_prepare, ^buffer, generation, ^path, ""}
    send(buffer, {:swap_prepare_result, generation, {:ok, [publish: {:error, :disk_full}]}})
    assert :ok = Task.await(save)
    assert File.read!(path) == "NEWER\nother\n"
    assert :ok = GenServer.stop(buffer)

    reopened = start_buffer(ctx)
    assert Buffer.content(reopened) == "NEWER\nother\n"
    refute Buffer.dirty?(reopened)
    assert :empty = Buffer.prepare_review(reopened, :latest)
    assert :ok = GenServer.stop(reopened)

    assert [%{path: ^path, swap_path: held, changed_since?: true}] =
             Recovery.scan(swap_dir: ctx.swap_dir, pid_alive?: fn _pid -> true end)

    refute held == swap_path(ctx)
    assert {:ok, %{kind: :dirty}, "OLDER\nother\n"} = Swap.read(held)
  end

  test "damaged generation metadata leaves valid dirty text waiting for an explicit decision",
       ctx do
    path = ctx.path
    swap = swap_path(ctx)

    assert :ok =
             Swap.write(path, "recoverable bytes",
               swap_dir: ctx.swap_dir,
               incarnation: 1,
               generation: 3,
               review: %{kind: :dirty, dirty: "untrusted history", saved: nil}
             )

    <<first_fields::binary-34, _generation::64, rest::binary>> = File.read!(swap)
    File.write!(swap, <<first_fields::binary, 0::64, rest::binary>>)

    buffer = start_buffer(ctx)
    assert Buffer.content(buffer) == "before\nother\n"

    replace(buffer, {1, 0}, 5, "NEW", @second)
    assert {:ok, keep, @task, 1} = Buffer.prepare_review(buffer, :latest)
    assert :ok = Buffer.decide_review(buffer, keep, :keep)
    assert {:ok, %{kind: :dirty}, "before\nNEW\n"} = Swap.read(swap)
    assert :ok = GenServer.stop(buffer)

    assert [%{path: ^path, swap_path: held, changed_since?: true}] =
             Recovery.scan(swap_dir: ctx.swap_dir, pid_alive?: fn _pid -> true end)

    refute held == swap
    assert {:ok, source, "recoverable bytes"} = Recovery.read(held)
    recovered = start_buffer(ctx)
    assert :ok = Buffer.adopt_recovered_text(recovered, "recoverable bytes", source)
    assert Buffer.content(recovered) == "recoverable bytes"
    assert :empty = Buffer.prepare_review(recovered, :latest)
    refute File.exists?(held)
  end

  test "discarding held dirty text keeps review history for its matching saved bytes", ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    assert :ok = Buffer.save(buffer)
    replace(buffer, {1, 0}, 5, "OTHER", @second)
    assert {:ok, target, @task, 1} = Buffer.prepare_review(buffer, {:step, @second})
    assert :ok = Buffer.decide_review(buffer, target, :keep)

    monitor = Process.monitor(buffer)
    Process.exit(buffer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^buffer, :killed}
    path = ctx.path
    File.write!(path, "external\nchange\n")
    reopened = start_buffer(ctx)
    assert Buffer.content(reopened) == "external\nchange\n"
    assert :ok = GenServer.stop(reopened)

    assert [%{path: ^path, swap_path: held}] =
             Recovery.scan(swap_dir: ctx.swap_dir, pid_alive?: fn _pid -> true end)

    File.write!(path, "AFTER\nother\n")
    assert :ok = Recovery.remove(held)
    assert {:ok, %{kind: :clean, held?: true}, ""} = Swap.read(held)

    restored = start_buffer(ctx)
    assert Buffer.content(restored) == "AFTER\nother\n"
    assert {:ok, _target, @task, 1} = Buffer.prepare_review(restored, {:step, @first})
    assert :empty = Buffer.prepare_review(restored, {:step, @second})
  end

  test "clean and dirty file moves carry the saved review history to the new path", ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    assert :ok = Buffer.save(buffer)

    clean_move = %{ctx | path: Path.join(Path.dirname(ctx.path), "clean_move.txt")}
    File.rename!(ctx.path, clean_move.path)
    assert :ok = Buffer.retarget_path(buffer, clean_move.path)
    assert :ok = GenServer.stop(buffer)
    refute File.exists?(swap_path(ctx))
    assert {:ok, %{kind: :clean}, ""} = Swap.read(swap_path(clean_move))

    buffer = start_buffer(clean_move)
    assert {:ok, _target, @task, 1} = Buffer.prepare_review(buffer, :latest)
    replace(buffer, {1, 0}, 5, "OTHER", @second)

    dirty_move = %{ctx | path: Path.join(Path.dirname(ctx.path), "dirty_move.txt")}
    File.rename!(clean_move.path, dirty_move.path)
    assert :ok = Buffer.retarget_path(buffer, dirty_move.path)
    refute File.exists?(swap_path(clean_move))
    assert {:ok, %{kind: :dirty}, "AFTER\nOTHER\n"} = Swap.read(swap_path(dirty_move))
    assert :ok = GenServer.stop(buffer)

    reopened = start_buffer(dirty_move)
    assert Buffer.content(reopened) == "AFTER\nother\n"
    assert :empty = Buffer.prepare_review(reopened, {:step, @second})
    assert {:ok, target, @task, 1} = Buffer.prepare_review(reopened, {:step, @first})
    assert {:ok, [_]} = Buffer.decide_review(reopened, target, :reject)
    assert Buffer.content(reopened) == "before\nother\n"
  end

  test "a later save retires the exact foreign generation after a failed takeover", ctx do
    foreign = [swap_dir: ctx.swap_dir, os_pid: 99_999]
    source = start_buffer(ctx, swap_backend_options: [os_pid: 99_999])
    replace(source, {0, 0}, 6, "AFTER", @first)
    replace(source, {1, 0}, 5, "OTHER", @second)
    assert {:ok, keep, @task, 1} = Buffer.prepare_review(source, {:step, @second})
    assert :ok = Buffer.decide_review(source, keep, :keep)
    monitor = Process.monitor(source)
    Process.exit(source, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^source, :killed}

    old_swap = Swap.swap_path(ctx.path, foreign)
    assert {:ok, receipt, bytes} = Recovery.read(old_swap)
    target = controlled_buffer(ctx)
    adoption = Task.async(fn -> Buffer.adopt_recovered_text(target, bytes, receipt) end)
    release_prepare(target, ctx.path, bytes, {:error, :disk_full})
    assert :ok = Task.await(adoption)
    assert Buffer.content(target) == bytes
    assert File.exists?(old_swap)

    save = Task.async(fn -> Buffer.save(target) end)
    release_prepare(target, ctx.path, "", :ok)
    assert :ok = Task.await(save)
    refute File.exists?(old_swap)
    assert {:ok, %{kind: :clean}, ""} = Swap.read(swap_path(ctx))
  end

  test "release reports a failed swap discard and a successful retry retains saved review", ctx do
    buffer = controlled_buffer(ctx)
    replace(buffer, {0, 0}, 6, "AFTER", @first)
    save = Task.async(fn -> Buffer.save(buffer) end)
    release_prepare(buffer, ctx.path, "", :ok)
    assert :ok = Task.await(save)

    replace(buffer, {1, 0}, 5, "OTHER", @second)
    path = ctx.path
    send(buffer, :write_swap)
    assert_receive {:swap_prepare, worker, generation, ^path, "AFTER\nOTHER\n"}
    send(worker, {:swap_prepare_result, generation, :ok})
    assert_receive {:swap_published, ^buffer, ^worker, ^generation, ^path, "AFTER\nOTHER\n", :ok}

    release = Task.async(fn -> BufferProcess.release_swap(buffer, ctx.swap_dir) end)
    release_prepare(buffer, path, "", {:error, :disk_full})
    assert {:error, :disk_full} = Task.await(release)
    assert {:ok, %{kind: :dirty}, "AFTER\nOTHER\n"} = Swap.read(swap_path(ctx))

    release = Task.async(fn -> BufferProcess.release_swap(buffer, ctx.swap_dir) end)
    release_prepare(buffer, path, "", :ok)
    assert :ok = Task.await(release)
    assert {:ok, %{kind: :clean}, ""} = Swap.read(swap_path(ctx))
    assert :ok = GenServer.stop(buffer)

    reopened = start_buffer(ctx)
    assert Buffer.content(reopened) == "AFTER\nother\n"
    assert {:ok, _target, @task, 1} = Buffer.prepare_review(reopened, {:step, @first})
    assert :empty = Buffer.prepare_review(reopened, {:step, @second})
  end

  test "the same task can review its exact unreviewed edits after the agent session crashes",
       ctx do
    agent = start_agent(ctx)
    id = AgentSession.session_id(agent)
    task = {:minga, id}
    first = {:minga, id, "first-call"}
    buffer = start_buffer(ctx)
    replace(buffer, {0, 0}, 0, "abc", first)
    replace(buffer, {0, 1}, 0, "X", :user)
    assert :ok = Buffer.save(buffer)

    monitor = Process.monitor(agent)
    Process.exit(agent, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^agent, :killed}
    assert :ok = GenServer.stop(buffer)

    new_agent = start_agent(ctx, session_id: id)
    assert AgentSession.session_id(new_agent) == id
    reopened = start_buffer(ctx)
    assert Buffer.author_at(reopened, {0, 0}) == task
    assert Buffer.author_at(reopened, {0, 1}) == :you
    assert {:ok, target, ^task, 1} = Buffer.prepare_review(reopened, {:step, first})
    assert {:ok, [_]} = Buffer.decide_review(reopened, target, :reject)
    assert Buffer.content(reopened) == "Xbefore\nother\n"
    assert File.read!(ctx.path) == "aXbcbefore\nother\n"
  end

  defp start_agent(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [
          workdir: Path.dirname(ctx.path),
          provider: Minga.Test.SessionMockProvider,
          persist?: false,
          hooks_enabled?: false,
          session_start_hook_enabled?: false,
          recover_interrupted_work?: false
        ],
        opts
      )

    start_supervised!({AgentSession, opts}, id: make_ref(), restart: :temporary)
  end

  defp controlled_buffer(ctx) do
    start_buffer(ctx,
      swap_backend: ControllableSwapBackend,
      swap_backend_options: [controller: self()]
    )
  end

  defp release_prepare(buffer, path, content, result) do
    assert_receive {:swap_prepare, ^buffer, generation, ^path, ^content}
    send(buffer, {:swap_prepare_result, generation, result})
  end

  defp replace(buffer, position, length, text, key) do
    source =
      case key do
        {:minga, task, step} -> EditSource.minga(task, step)
        :user -> EditSource.user()
      end

    assert {:ok, _version} =
             BufferProcess.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               position,
               length,
               text,
               source
             )
  end

  defp deliver_pending_saves(buffer, previous \\ nil) do
    # Deliver already-armed callbacks directly rather than waiting on a wall-clock debounce.
    armed = :sys.get_state(buffer).auto_save_token

    for token <- Enum.uniq([previous, armed]),
        is_reference(token),
        do: send(buffer, {:auto_save, token})

    :sys.get_state(buffer)
  end

  defp start_buffer(ctx, opts \\ []) do
    {delay, opts} = Keyword.pop(opts, :auto_save, 0)

    opts = Keyword.merge([file_path: ctx.path, swap_dir: ctx.swap_dir], opts)

    buffer = start_supervised!({BufferProcess, opts}, id: make_ref(), restart: :temporary)
    {:ok, ^delay} = BufferProcess.set_option(buffer, :auto_save_delay_ms, delay)
    buffer
  end

  defp swap_path(ctx), do: Swap.swap_path(ctx.path, swap_dir: ctx.swap_dir)
end
