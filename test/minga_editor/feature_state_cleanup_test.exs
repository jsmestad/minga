defmodule MingaEditor.FeatureStateCleanupTest do
  # Registers a temporary process under the global MingaEditor name.
  use ExUnit.Case, async: false

  alias MingaEditor.FeatureState

  @source {:extension, :cleanup_sync}

  test "source cleanup waits for editor feature-state cleanup before returning" do
    pid = start_fake_editor()

    try do
      assert FeatureState.unregister_source(@source) == :ok
      assert_received {:cleanup_finished, @source}
    after
      stop_fake_editor(pid)
    end
  end

  test "cleanup from inside editor process does not queue stale asynchronous extension cleanup" do
    pid = start_fake_editor()

    try do
      send(pid, {:run_self_cleanup, self(), @source})

      assert_receive {:self_cleanup_result, :ok}
      refute_receive {:cleanup_finished, @source}
    after
      stop_fake_editor(pid)
    end
  end

  test "config cleanup from inside editor process relies on the command path pre-cleanup" do
    pid = start_fake_editor()

    try do
      send(pid, {:run_self_cleanup, self(), :config})

      assert_receive {:self_cleanup_result, :ok}
      refute_receive {:cleanup_finished, :config}
    after
      stop_fake_editor(pid)
    end
  end

  @spec start_fake_editor() :: pid()
  defp start_fake_editor do
    test_pid = self()
    pid = spawn_link(fn -> fake_editor_loop(test_pid) end)
    assert_receive :fake_editor_ready
    pid
  end

  @spec stop_fake_editor(pid()) :: :ok
  defp stop_fake_editor(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
    :ok
  end

  @spec fake_editor_loop(pid()) :: no_return()
  defp fake_editor_loop(test_pid) do
    Process.register(self(), MingaEditor)
    send(test_pid, :fake_editor_ready)
    fake_editor_receive(test_pid)
  end

  @spec fake_editor_receive(pid()) :: no_return()
  defp fake_editor_receive(test_pid) do
    receive do
      {:"$gen_call", from, {:cleanup_feature_state, source}} ->
        send(test_pid, {:cleanup_finished, source})
        GenServer.reply(from, :ok)
        fake_editor_receive(test_pid)

      {:run_self_cleanup, caller, source} ->
        send(caller, {:self_cleanup_result, FeatureState.unregister_source(source)})
        fake_editor_receive(test_pid)

      :stop ->
        Process.unregister(MingaEditor)
        exit(:normal)
    end
  end
end
