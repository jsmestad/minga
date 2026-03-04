defmodule Minga.Config.HooksTest do
  use ExUnit.Case, async: false

  alias Minga.Config.Hooks

  setup do
    case Hooks.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Hooks.reset()
    end

    on_exit(fn ->
      try do
        Hooks.reset()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "register/2" do
    test "registers a hook for a valid event" do
      assert :ok = Hooks.register(:after_save, fn _buf, _path -> :ok end)
    end

    test "returns error for unknown event" do
      assert {:error, msg} = Hooks.register(:nonexistent, fn -> :ok end)
      assert msg =~ "unknown event"
    end
  end

  describe "run/2" do
    test "fires registered hooks with arguments" do
      test_pid = self()
      Hooks.register(:after_save, fn buf, path -> send(test_pid, {:hook_fired, buf, path}) end)

      Hooks.run(:after_save, [:fake_buf, "/tmp/test.ex"])

      assert_receive {:hook_fired, :fake_buf, "/tmp/test.ex"}, 500
    end

    test "fires multiple hooks in order" do
      test_pid = self()
      Hooks.register(:after_save, fn _, _ -> send(test_pid, :first) end)
      Hooks.register(:after_save, fn _, _ -> send(test_pid, :second) end)

      Hooks.run(:after_save, [:buf, "/path"])

      assert_receive :first, 500
      assert_receive :second, 500
    end

    test "crashing hook does not prevent other hooks from running" do
      test_pid = self()
      Hooks.register(:after_save, fn _, _ -> raise "boom" end)
      Hooks.register(:after_save, fn _, _ -> send(test_pid, :second_ran) end)

      Hooks.run(:after_save, [:buf, "/path"])

      assert_receive :second_ran, 500
    end

    test "no-op when no hooks registered" do
      assert :ok = Hooks.run(:after_open, [:buf, "/path"])
    end

    test "on_mode_change hooks receive mode atoms" do
      test_pid = self()

      Hooks.register(:on_mode_change, fn old, new ->
        send(test_pid, {:mode_change, old, new})
      end)

      Hooks.run(:on_mode_change, [:normal, :insert])

      assert_receive {:mode_change, :normal, :insert}, 500
    end
  end

  describe "reset/0" do
    test "removes all hooks" do
      test_pid = self()
      Hooks.register(:after_save, fn _, _ -> send(test_pid, :should_not_fire) end)
      Hooks.reset()

      Hooks.run(:after_save, [:buf, "/path"])
      refute_receive :should_not_fire, 100
    end
  end
end
