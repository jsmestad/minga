defmodule Minga.Extension.DevReloadTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.DevReload

  test "starts without error" do
    pid = start_supervised!(DevReload)
    assert is_pid(pid)
  end

  test "watch and unwatch do not crash" do
    start_supervised!(DevReload)

    assert :ok = DevReload.watch(:test_ext, System.tmp_dir!())
    assert :ok = DevReload.unwatch(:test_ext)
  end

  test "debounce timer fires without crash" do
    pid = start_supervised!(DevReload)
    send(pid, :debounced_reload)
    Process.sleep(10)
    assert Process.alive?(pid)
  end
end
