defmodule Minga.Clipboard.SystemTest do
  @moduledoc """
  Integration tests for `Minga.Clipboard.System`.

  These tests hit the real system clipboard tool (pbcopy/pbpaste on macOS,
  xclip/xsel/wl-copy on Linux). They must run serially because they share
  the system clipboard.

  Tagged `:system_clipboard` so they can be excluded in CI environments
  that lack a clipboard tool.
  """
  use ExUnit.Case, async: false

  @moduletag :system_clipboard

  alias Minga.Clipboard.System, as: ClipboardSystem

  setup do
    ClipboardSystem.reset_cache()
    on_exit(fn -> ClipboardSystem.reset_cache() end)
    :ok
  end

  describe "write/1" do
    test "completes without blocking on port exit timeout" do
      {time_μs, result} = :timer.tc(fn -> ClipboardSystem.write("perf regression test") end)

      assert result == :ok
      # The old code always hit a 500ms timeout in await_port_exit.
      # New code uses Port.close and should complete well under 100ms.
      assert time_μs < 100_000,
             "write took #{time_μs}µs (#{div(time_μs, 1000)}ms), expected < 100ms. " <>
               "This suggests the 500ms await_port_exit timeout bug has regressed."
    end

    test "handles empty string without crashing" do
      assert :ok = ClipboardSystem.write("")
    end
  end

  describe "caching" do
    test "reset_cache/0 does not crash" do
      # Populate cache
      ClipboardSystem.write("cache test")
      # Reset should succeed
      assert :ok = ClipboardSystem.reset_cache()
      # Write should still work after cache reset (re-detects tool)
      assert :ok = ClipboardSystem.write("after reset")
    end
  end
end
