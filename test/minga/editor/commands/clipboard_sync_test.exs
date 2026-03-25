defmodule Minga.Editor.Commands.ClipboardSyncTest do
  @moduledoc """
  Tests for clipboard sync via the `clipboard` config option.

  Uses a Hammox mock for the clipboard backend so tests never touch the
  real system clipboard. An Agent acts as in-memory clipboard storage,
  letting read/write stubs behave naturally without external side effects.

  Clipboard behavior is injected via the `clipboard` parameter on
  `put_register/4` and `get_register/2` rather than mutating global
  Options state, so these tests can run `async: true` without leaking
  into other test modules.
  """
  use ExUnit.Case, async: true

  import Hammox

  alias Minga.Config.Options
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State
  alias Minga.Editor.Viewport

  setup :verify_on_exit!

  # Start an Agent to act as in-memory clipboard storage for the duration
  # of each test. Stubs route read/write through it.
  #
  # The mock stub sends {:clipboard_written, text} to the test process
  # so tests can use assert_receive as a synchronization barrier. This is
  # necessary because clipboard writes are now async (via Task.Supervisor).
  setup do
    {:ok, agent} = Agent.start_link(fn -> nil end)
    test_pid = self()

    stub(Minga.Clipboard.Mock, :write, fn text ->
      Agent.update(agent, fn _ -> text end)
      send(test_pid, {:clipboard_written, text})
      :ok
    end)

    stub(Minga.Clipboard.Mock, :read, fn ->
      Agent.get(agent, & &1)
    end)

    %{clipboard: agent}
  end

  defp make_state do
    %State{
      port_manager: nil,
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80)
      }
    }
  end

  defp clipboard_contents(agent) do
    Agent.get(agent, & &1)
  end

  describe "put_register with clipboard: :unnamedplus" do
    test "yy syncs to system clipboard", %{clipboard: agent} do
      sentinel = "yank-sync-#{System.unique_integer([:positive])}"
      state = make_state()

      Helpers.put_register_with_clipboard_override(
        state,
        sentinel,
        :yank,
        :charwise,
        :unnamedplus
      )

      # Clipboard write is async; wait for the Task to complete
      assert_receive {:clipboard_written, ^sentinel}, 200
      assert clipboard_contents(agent) == sentinel
    end

    test "delete syncs to system clipboard", %{clipboard: agent} do
      sentinel = "delete-sync-#{System.unique_integer([:positive])}"
      state = make_state()

      Helpers.put_register_with_clipboard_override(
        state,
        sentinel,
        :delete,
        :charwise,
        :unnamedplus
      )

      assert_receive {:clipboard_written, ^sentinel}, 200
      assert clipboard_contents(agent) == sentinel
    end

    test "named register also syncs to clipboard", %{clipboard: agent} do
      sentinel = "named-sync-#{System.unique_integer([:positive])}"
      state = put_in(make_state().workspace.vim.reg.active, "a")

      Helpers.put_register_with_clipboard_override(
        state,
        sentinel,
        :yank,
        :charwise,
        :unnamedplus
      )

      assert_receive {:clipboard_written, ^sentinel}, 200
      assert clipboard_contents(agent) == sentinel
    end

    test "black hole register does not sync to clipboard", %{clipboard: agent} do
      sentinel = "blackhole-guard-#{System.unique_integer([:positive])}"
      Agent.update(agent, fn _ -> sentinel end)
      state = put_in(make_state().workspace.vim.reg.active, "_")

      Helpers.put_register_with_clipboard_override(
        state,
        "should not appear",
        :yank,
        :charwise,
        :unnamedplus
      )

      # Async write should NOT have been triggered for the black hole register
      refute_receive {:clipboard_written, _}, 50
      assert clipboard_contents(agent) == sentinel
    end

    test "explicit + register still works", %{clipboard: agent} do
      sentinel = "explicit-clip-#{System.unique_integer([:positive])}"
      state = put_in(make_state().workspace.vim.reg.active, "+")

      Helpers.put_register_with_clipboard_override(
        state,
        sentinel,
        :yank,
        :charwise,
        :unnamedplus
      )

      assert_receive {:clipboard_written, ^sentinel}, 200
      assert clipboard_contents(agent) == sentinel
    end
  end

  describe "put_register with clipboard: :none" do
    test "yy does not sync to system clipboard", %{clipboard: agent} do
      sentinel = "none-guard-#{System.unique_integer([:positive])}"
      Agent.update(agent, fn _ -> sentinel end)
      state = make_state()

      Helpers.put_register_with_clipboard_override(
        state,
        "should not sync",
        :yank,
        :charwise,
        :none
      )

      refute_receive {:clipboard_written, _}, 50
      assert clipboard_contents(agent) == sentinel
    end

    test "explicit + register still works even with clipboard: :none", %{clipboard: agent} do
      sentinel = "none-explicit-#{System.unique_integer([:positive])}"
      state = put_in(make_state().workspace.vim.reg.active, "+")
      Helpers.put_register_with_clipboard_override(state, sentinel, :yank, :charwise, :none)

      assert_receive {:clipboard_written, ^sentinel}, 200
      assert clipboard_contents(agent) == sentinel
    end
  end

  describe "get_register with clipboard: :unnamedplus" do
    test "paste from unnamed register prefers system clipboard when content differs", %{
      clipboard: agent
    } do
      state = make_state()
      internal = "internal-#{System.unique_integer([:positive])}"
      external = "external-#{System.unique_integer([:positive])}"
      # Put something in the unnamed register
      state =
        Helpers.put_register_with_clipboard_override(
          state,
          internal,
          :yank,
          :charwise,
          :unnamedplus
        )

      # Wait for the async clipboard write to complete before simulating
      # an external copy, otherwise the Task overwrites our external value.
      assert_receive {:clipboard_written, ^internal}, 200

      # Simulate external copy by writing directly to the in-memory clipboard
      Agent.update(agent, fn _ -> external end)

      {text, _type, _state} = Helpers.get_register(state, :unnamedplus)
      assert text == external
    end

    test "paste from unnamed register uses internal when clipboard matches" do
      sentinel = "same-#{System.unique_integer([:positive])}"
      state = make_state()

      state =
        Helpers.put_register_with_clipboard_override(
          state,
          sentinel,
          :yank,
          :charwise,
          :unnamedplus
        )

      # Clipboard read returns nil until the async Task completes; nil falls
      # back to the stored register value, so this is safe without synchronization.
      {text, _type, _state} = Helpers.get_register(state, :unnamedplus)
      assert text == sentinel
    end

    test "paste from named register ignores clipboard", %{clipboard: agent} do
      Agent.update(agent, fn _ -> "clipboard-noise-#{System.unique_integer([:positive])}" end)
      state = make_state()
      sentinel = "reg-a-#{System.unique_integer([:positive])}"
      state = Helpers.put_in_register(state, "a", sentinel)
      state = put_in(state.workspace.vim.reg.active, "a")

      {text, _type, _state} = Helpers.get_register(state, :unnamedplus)
      assert text == sentinel
    end
  end

  describe "clipboard option" do
    test "compile-time default is :unnamedplus" do
      assert Options.default(:clipboard) == :unnamedplus
    end

    test "rejects invalid values" do
      assert {:error, _} = Options.set(:clipboard, :invalid)
    end
  end
end
