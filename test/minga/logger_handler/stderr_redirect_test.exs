defmodule Minga.LoggerHandler.StderrRedirectTest do
  use ExUnit.Case, async: true

  alias Minga.LoggerHandler.StderrRedirect

  @moduletag :tmp_dir

  # Each test redirects a device name of its own, never the VM's `:standard_error`.
  setup %{tmp_dir: dir} do
    id = System.unique_integer([:positive])
    device_name = :"stderr_redirect_test_device_#{id}"
    {:ok, original} = StringIO.open("")
    Process.register(original, device_name)
    on_exit(fn -> :persistent_term.erase({StderrRedirect, device_name}) end)

    %{
      device_name: device_name,
      original: original,
      holder: :"stderr_redirect_test_holder_#{id}",
      log_path: Path.join(dir, "minga.log")
    }
  end

  describe "redirect/2" do
    test "writes to the device reach the log file", ctx do
      start_holder(ctx)

      assert :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      IO.puts(ctx.device_name, "to the log")

      assert StderrRedirect.redirected?(ctx.holder)
      assert File.read!(ctx.log_path) == "to the log\n"
      assert StringIO.contents(ctx.original) == {"", ""}
    end

    test "asking again keeps the device that is already in place", ctx do
      start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      device = Process.whereis(ctx.device_name)

      assert :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)

      assert Process.whereis(ctx.device_name) == device
    end

    test "the redirect outlives the process that asked for it", ctx do
      start_holder(ctx)
      holder = ctx.holder
      log_path = ctx.log_path

      {asker, ref} = spawn_monitor(fn -> :ok = StderrRedirect.redirect(holder, log_path) end)
      assert_receive {:DOWN, ^ref, :process, ^asker, :normal}

      IO.puts(ctx.device_name, "after the asker exited")

      assert File.read!(ctx.log_path) == "after the asker exited\n"
    end

    test "is refused when no device has the name", ctx do
      start_holder(ctx)
      Process.unregister(ctx.device_name)

      assert {:error, :device_not_registered} = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      refute StderrRedirect.redirected?(ctx.holder)
    end

    test "a log file that cannot be opened leaves the original device registered", ctx do
      start_holder(ctx)
      missing = Path.join([Path.dirname(ctx.log_path), "missing", "minga.log"])

      assert {:error, :enoent} = StderrRedirect.redirect(ctx.holder, missing)

      assert Process.whereis(ctx.device_name) == ctx.original
      refute StderrRedirect.redirected?(ctx.holder)
    end
  end

  describe "restore/1" do
    test "registers the original device again, and later writes reach it", ctx do
      start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)

      assert :ok = StderrRedirect.restore(ctx.holder)
      IO.puts(ctx.device_name, "to the original")

      assert Process.whereis(ctx.device_name) == ctx.original
      assert StringIO.contents(ctx.original) == {"", "to the original\n"}
      refute StderrRedirect.redirected?(ctx.holder)
    end

    test "does nothing when there is no redirect", ctx do
      start_holder(ctx)

      assert :ok = StderrRedirect.restore(ctx.holder)
      assert Process.whereis(ctx.device_name) == ctx.original
    end
  end

  describe "failures" do
    test "a killed holder is started again and installs the redirect again", ctx do
      holder = start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      first_device = Process.whereis(ctx.device_name)

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      second_device = wait_for_new_device(ctx.device_name, [first_device, ctx.original])
      IO.puts(ctx.device_name, "after the holder was killed")

      assert second_device != first_device
      assert StderrRedirect.redirected?(ctx.holder)
      assert File.read!(ctx.log_path) == "after the holder was killed\n"
    end

    test "a holder that fails registers the original device before it exits, then reinstalls",
         ctx do
      holder = start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      first_device = Process.whereis(ctx.device_name)

      ref = Process.monitor(holder)

      # The holder traps exits, so a plain exit signal does not stop it. Stopping it with a reason does.
      :ok = GenServer.stop(holder, :failure)
      assert_receive {:DOWN, ^ref, :process, ^holder, :failure}

      # The name is never free here: the failing holder hands it to the original, the new holder takes it back.
      second_device = wait_for_new_device(ctx.device_name, [first_device, ctx.original])
      IO.puts(ctx.device_name, "after the holder failed")

      assert second_device != first_device
      assert File.read!(ctx.log_path) == "after the holder failed\n"
    end

    test "when the log-file process dies the holder opens the file again", ctx do
      start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      first_device = Process.whereis(ctx.device_name)

      Process.exit(first_device, :kill)

      second_device = wait_for_new_device(ctx.device_name, [first_device])
      IO.puts(ctx.device_name, "after the device died")

      assert second_device != ctx.original
      assert File.read!(ctx.log_path) == "after the device died\n"
    end

    test "asking for the redirect after the log-file process died returns with a live device in place",
         ctx do
      start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)
      first_device = Process.whereis(ctx.device_name)

      ref = Process.monitor(first_device)
      Process.exit(first_device, :kill)
      assert_receive {:DOWN, ^ref, :process, ^first_device, :killed}

      # Whether the holder has read the device's `:DOWN` yet or not, the answer is the same.
      assert :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)

      assert StderrRedirect.redirected?(ctx.holder)
      IO.puts(ctx.device_name, "after asking again")
      assert File.read!(ctx.log_path) == "after asking again\n"
    end

    test "a holder that is stopped registers the original device and forgets the redirect", ctx do
      start_holder(ctx)
      :ok = StderrRedirect.redirect(ctx.holder, ctx.log_path)

      :ok = stop_supervised!(StderrRedirect)

      assert Process.whereis(ctx.device_name) == ctx.original

      start_holder(ctx)
      refute StderrRedirect.redirected?(ctx.holder)
      assert Process.whereis(ctx.device_name) == ctx.original
    end
  end

  describe "a redirect requested before the holder started" do
    test "is held by the caller, then adopted by the holder", ctx do
      assert :ok = StderrRedirect.redirect_without_holder(ctx.device_name, ctx.log_path)
      interim = Process.whereis(ctx.device_name)
      assert interim != ctx.original
      ref = Process.monitor(interim)

      start_holder(ctx)

      assert_receive {:DOWN, ^ref, :process, ^interim, _reason}
      assert StderrRedirect.redirected?(ctx.holder)
      IO.puts(ctx.device_name, "after adoption")
      assert File.read!(ctx.log_path) == "after adoption\n"

      :ok = StderrRedirect.restore(ctx.holder)
      assert Process.whereis(ctx.device_name) == ctx.original
    end

    test "can be undone without a holder", ctx do
      :ok = StderrRedirect.redirect_without_holder(ctx.device_name, ctx.log_path)

      assert :ok = StderrRedirect.restore_without_holder(ctx.device_name)

      assert Process.whereis(ctx.device_name) == ctx.original
    end
  end

  defp start_holder(ctx) do
    start_supervised!({StderrRedirect, name: ctx.holder, device_name: ctx.device_name})
  end

  # The test receives no message for the supervisor's restart or for the holder's reaction to a dead device.
  # So it polls the registered name: a bounded wait, not a fixed delay.
  defp wait_for_new_device(device_name, excluded, attempts \\ 500) do
    case Process.whereis(device_name) do
      pid when is_pid(pid) ->
        if pid in excluded, do: retry_new_device(device_name, excluded, attempts), else: pid

      nil ->
        retry_new_device(device_name, excluded, attempts)
    end
  end

  defp retry_new_device(device_name, _excluded, 0),
    do: flunk("no new device was registered as #{inspect(device_name)}")

  defp retry_new_device(device_name, excluded, attempts) do
    receive do
    after
      10 -> wait_for_new_device(device_name, excluded, attempts - 1)
    end
  end
end
