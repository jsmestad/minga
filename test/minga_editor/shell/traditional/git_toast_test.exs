defmodule MingaEditor.Shell.Traditional.GitToastTest do
  use ExUnit.Case, async: true

  alias MingaEditor.Shell.Traditional.GitToast
  alias MingaEditor.Shell.Traditional.GitToastWorkflow

  import MingaEditor.RenderPipeline.TestHelpers

  test "latest toast replaces prior identity and protocol-independent content" do
    first = GitToast.publish(%GitToast{}, "Fetched", :success)
    second = GitToast.publish(first, "Push failed", :error, :pull_and_retry)

    assert %GitToast{id: 1, message: "Fetched", level: :success} = first

    assert %GitToast{
             id: 2,
             message: "Push failed",
             level: :error,
             action: :pull_and_retry,
             timer: nil
           } = second
  end

  test "only informational and success toasts accept timers and time out" do
    for level <- [:info, :success] do
      toast = GitToast.publish(%GitToast{}, "message", level)
      timer = make_ref()
      toast = GitToast.record_timer(toast, toast.id, timer)
      assert toast.timer == timer
      refute GitToast.present?(GitToast.timeout(toast, toast.id))
    end

    for level <- [:warning, :error] do
      toast = GitToast.publish(%GitToast{}, "message", level)
      assert GitToast.record_timer(toast, toast.id, make_ref()) == toast
      assert GitToast.timeout(toast, toast.id) == toast
    end
  end

  test "stale timed or manual dismissal cannot clear a replacement" do
    first = GitToast.publish(%GitToast{}, "first", :success)
    second = GitToast.publish(first, "second", :warning)
    assert GitToast.timeout(second, first.id) == second
    assert GitToast.dismiss(second, first.id) == second
    refute GitToast.present?(GitToast.dismiss(second, second.id))
  end

  test "Editor timeout messages cannot dismiss a replacement" do
    first =
      base_state()
      |> Map.put(:rendering, :disabled)
      |> GitToastWorkflow.publish("Fetched", :success)

    first_id = first.shell_runtime.state.git_toast.id
    replacement = GitToastWorkflow.publish(first, "Push failed", :error)

    assert {:noreply, stale_delivery} =
             MingaEditor.handle_info({:git_toast_timeout, first_id}, replacement)

    assert stale_delivery.shell_runtime.state.git_toast ==
             replacement.shell_runtime.state.git_toast
  end

  test "workflow cancels a replaced timer and ignores its stale timeout" do
    state = Map.put(base_state(), :backend, :test)
    first = GitToastWorkflow.publish(state, "Fetched", :success)
    first_id = first.shell_runtime.state.git_toast.id
    first_timer = first.shell_runtime.state.git_toast.timer

    assert is_reference(first_timer)
    assert is_integer(Process.read_timer(first_timer))

    replacement = GitToastWorkflow.publish(first, "Push failed", :error)

    assert Process.read_timer(first_timer) == false
    assert replacement.shell_runtime.state.git_toast.timer == nil
    assert GitToastWorkflow.timeout(replacement, first_id) == replacement
    assert GitToastWorkflow.dismiss(replacement, first_id) == replacement
    refute GitToast.present?(GitToastWorkflow.dismiss(replacement).shell_runtime.state.git_toast)
  end
end
