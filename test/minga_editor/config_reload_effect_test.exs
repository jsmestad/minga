defmodule MingaEditor.ConfigReloadEffectTest do
  @moduledoc "Deterministic Editor integration coverage for scheduler-owned config reload."

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias MingaEditor.Commands.BufferManagement
  alias MingaEditor.ConfigReloadEffect
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effect.Policy
  alias MingaEditor.EffectScheduler
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.NoticeWorkflow

  @timeout 15_000
  @marker_feature :config_reload_marker

  defmodule ReloadProbe do
    @moduledoc false

    @spec reload(pid()) :: :ok
    def reload(test_pid) when is_pid(test_pid) do
      send(test_pid, {:config_reload_started, self()})

      receive do
        :complete_config_reload -> :ok
      end
    end
  end

  test "uses one stable zero-queue resource and rejects a duplicate deterministically" do
    first = ConfigReloadEffect.request(ReloadProbe, [self()])
    duplicate = ConfigReloadEffect.request(ReloadProbe, [self()])

    assert first.resource == {:config_reload, :ordinary_config}
    assert duplicate.resource == first.resource
    assert first.policy == Policy.fifo(0)

    ctx = start_editor("scratch")
    test_pid = self()

    state =
      :sys.replace_state(
        ctx.editor,
        &BufferManagement.reload_config(&1, ReloadProbe, [test_pid])
      )

    assert_receive {:config_reload_started, worker}
    assert state.shell_runtime.state.notice.message == "Reloading config…"

    duplicate_state =
      :sys.replace_state(
        ctx.editor,
        &BufferManagement.reload_config(&1, ReloadProbe, [test_pid])
      )

    assert duplicate_state.shell_runtime.state.notice.message ==
             "Config reload already in progress"

    refute_received {:config_reload_started, _duplicate_worker}

    worker_monitor = Process.monitor(worker)
    send(worker, :complete_config_reload)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    final_state = await_notice(ctx.editor, "Config reloaded")
    refute EffectScheduler.active?(final_state.effect_scheduler, ConfigReloadEffect)
  end

  test "completion applies to current Editor state without losing intervening state or notices" do
    ctx = start_editor("scratch")
    test_pid = self()

    :sys.replace_state(
      ctx.editor,
      &BufferManagement.reload_config(&1, ReloadProbe, [test_pid])
    )

    assert_receive {:config_reload_started, worker}

    intervening =
      :sys.replace_state(ctx.editor, fn state ->
        workspace =
          SessionState.put_feature_state(
            state.workspace,
            :builtin,
            @marker_feature,
            :preserved
          )

        %{state | workspace: workspace}
        |> NoticeWorkflow.publish("Intervening notice")
      end)

    intervening_notice_id = intervening.shell_runtime.state.notice.id
    assert intervening.shell_runtime.state.notice.message == "Intervening notice"

    worker_monitor = Process.monitor(worker)
    send(worker, :complete_config_reload)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}
    completed = await_notice(ctx.editor, "Config reloaded")

    assert SessionState.get_feature_state(completed.workspace, :builtin, @marker_feature) ==
             :preserved

    assert completed.shell_runtime.state.notice.id > intervening_notice_id
  end

  test "an old Editor generation cannot execute or apply into its replacement" do
    old = start_editor("old")
    replacement = start_editor("replacement")
    test_pid = self()

    old_state =
      :sys.replace_state(
        old.editor,
        &BufferManagement.reload_config(&1, ReloadProbe, [test_pid])
      )

    old_scheduler = old_state.effect_scheduler
    assert_receive {:config_reload_started, old_worker}
    old_worker_monitor = Process.monitor(old_worker)

    :ok = Supervisor.stop(old.generation)
    assert_receive {:DOWN, ^old_worker_monitor, :process, ^old_worker, _reason}

    replacement_before = :sys.get_state(replacement.editor)
    request = ConfigReloadEffect.request(ReloadProbe, [self()])
    delayed_old_outcome = Outcome.completed(request, :ok)
    send(replacement.editor, {:effect_result, old_scheduler, delayed_old_outcome})
    replacement_after = :sys.get_state(replacement.editor)

    assert replacement_after == replacement_before
    assert replacement_after.shell_runtime.state.notice.message == nil
  end

  @spec await_notice(pid(), String.t()) :: MingaEditor.State.t()
  defp await_notice(editor, expected) do
    deadline = System.monotonic_time(:millisecond) + @timeout
    do_await_notice(editor, expected, deadline)
  end

  @spec do_await_notice(pid(), String.t(), integer()) :: MingaEditor.State.t()
  defp do_await_notice(editor, expected, deadline) do
    state = :sys.get_state(editor)

    if state.shell_runtime.state.notice.message == expected do
      state
    else
      if System.monotonic_time(:millisecond) < deadline do
        receive do
        after
          1 -> do_await_notice(editor, expected, deadline)
        end
      else
        flunk(
          "notice did not become #{inspect(expected)}: current=#{inspect(state.shell_runtime.state.notice.message)} stats=#{inspect(EffectScheduler.stats(state.effect_scheduler))}"
        )
      end
    end
  end
end
