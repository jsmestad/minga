defmodule Minga.Clipboard.SystemTest do
  @moduledoc """
  Integration tests for `Minga.Clipboard.System`.

  These tests use the native macOS pasteboard or the Linux clipboard tools.
  They must run serially because they share the system clipboard.

  Tagged `:system_clipboard` so they can be excluded in CI environments
  that lack a clipboard tool.
  """
  # Uses the shared system clipboard and real clipboard OS processes.
  use ExUnit.Case, async: false

  @moduletag :heavy

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
      # The historical port close path spent 500ms waiting even after the tool had finished.
      assert time_μs < 250_000,
             "write took #{time_μs}µs (#{div(time_μs, 1000)}ms), expected < 250ms. " <>
               "This suggests the 500ms await_port_exit timeout bug has regressed."
    end

    test "writes RTF-looking UTF-8 bytes as literal plain text" do
      text = "{\\rtf1 literal λ界\t  \n}"
      assert :ok = ClipboardSystem.write(text)
      assert ClipboardSystem.read() == text
    end

    test "replaces previous clipboard contents with an empty string" do
      assert :ok = ClipboardSystem.write("previous content")
      assert :ok = ClipboardSystem.write("")
      assert ClipboardSystem.read() == ""
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
