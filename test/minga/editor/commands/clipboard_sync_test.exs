defmodule Minga.Editor.Commands.ClipboardSyncTest do
  @moduledoc """
  Tests for clipboard sync via the `clipboard` config option.

  Uses a Hammox mock for the clipboard backend so tests never touch the
  real system clipboard. An Agent acts as in-memory clipboard storage,
  letting read/write stubs behave naturally without external side effects.
  """
  use ExUnit.Case, async: false

  import Hammox

  alias Minga.Config.Options, as: ConfigOptions
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State.Registers

  setup :verify_on_exit!

  # Start an Agent to act as in-memory clipboard storage for the duration
  # of each test. Stubs route read/write through it.
  setup do
    {:ok, agent} = Agent.start_link(fn -> nil end)

    stub(Minga.Clipboard.Mock, :write, fn text ->
      Agent.update(agent, fn _ -> text end)
      :ok
    end)

    stub(Minga.Clipboard.Mock, :read, fn ->
      Agent.get(agent, & &1)
    end)

    %{clipboard: agent}
  end

  defp make_state do
    %{reg: %Registers{}}
  end

  defp clipboard_contents(agent) do
    Agent.get(agent, & &1)
  end

  describe "put_register with clipboard: :unnamedplus" do
    setup do
      ConfigOptions.set(:clipboard, :unnamedplus)
      on_exit(fn -> ConfigOptions.set(:clipboard, :none) end)
      :ok
    end

    test "yy syncs to system clipboard", %{clipboard: agent} do
      sentinel = "yank-sync-#{System.unique_integer([:positive])}"
      state = make_state()
      Helpers.put_register(state, sentinel, :yank)

      assert clipboard_contents(agent) == sentinel
    end

    test "delete syncs to system clipboard", %{clipboard: agent} do
      sentinel = "delete-sync-#{System.unique_integer([:positive])}"
      state = make_state()
      Helpers.put_register(state, sentinel, :delete)

      assert clipboard_contents(agent) == sentinel
    end

    test "named register also syncs to clipboard", %{clipboard: agent} do
      sentinel = "named-sync-#{System.unique_integer([:positive])}"
      state = %{make_state() | reg: %{%Registers{} | active: "a"}}
      Helpers.put_register(state, sentinel, :yank)

      assert clipboard_contents(agent) == sentinel
    end

    test "black hole register does not sync to clipboard", %{clipboard: agent} do
      sentinel = "blackhole-guard-#{System.unique_integer([:positive])}"
      Agent.update(agent, fn _ -> sentinel end)
      state = %{make_state() | reg: %{%Registers{} | active: "_"}}
      Helpers.put_register(state, "should not appear", :yank)

      assert clipboard_contents(agent) == sentinel
    end

    test "explicit + register still works", %{clipboard: agent} do
      sentinel = "explicit-clip-#{System.unique_integer([:positive])}"
      state = %{make_state() | reg: %{%Registers{} | active: "+"}}
      Helpers.put_register(state, sentinel, :yank)

      assert clipboard_contents(agent) == sentinel
    end
  end

  describe "put_register with clipboard: :none" do
    setup do
      ConfigOptions.set(:clipboard, :none)
      on_exit(fn -> ConfigOptions.set(:clipboard, :unnamedplus) end)
      :ok
    end

    test "yy does not sync to system clipboard", %{clipboard: agent} do
      sentinel = "none-guard-#{System.unique_integer([:positive])}"
      Agent.update(agent, fn _ -> sentinel end)
      state = make_state()
      Helpers.put_register(state, "should not sync", :yank)

      assert clipboard_contents(agent) == sentinel
    end

    test "explicit + register still works even with clipboard: :none", %{clipboard: agent} do
      sentinel = "none-explicit-#{System.unique_integer([:positive])}"
      state = %{make_state() | reg: %{%Registers{} | active: "+"}}
      Helpers.put_register(state, sentinel, :yank)

      assert clipboard_contents(agent) == sentinel
    end
  end

  describe "get_register with clipboard: :unnamedplus" do
    setup do
      ConfigOptions.set(:clipboard, :unnamedplus)
      on_exit(fn -> ConfigOptions.set(:clipboard, :none) end)
      :ok
    end

    test "paste from unnamed register prefers system clipboard when content differs", %{
      clipboard: agent
    } do
      state = make_state()
      internal = "internal-#{System.unique_integer([:positive])}"
      external = "external-#{System.unique_integer([:positive])}"
      # Put something in the unnamed register
      state = Helpers.put_register(state, internal, :yank)
      # Simulate external copy by writing directly to the in-memory clipboard
      Agent.update(agent, fn _ -> external end)

      {text, _state} = Helpers.get_register(state)
      assert text == external
    end

    test "paste from unnamed register uses internal when clipboard matches" do
      sentinel = "same-#{System.unique_integer([:positive])}"
      state = make_state()
      state = Helpers.put_register(state, sentinel, :yank)
      # Clipboard was synced, so it should match
      {text, _state} = Helpers.get_register(state)
      assert text == sentinel
    end

    test "paste from named register ignores clipboard", %{clipboard: agent} do
      Agent.update(agent, fn _ -> "clipboard-noise-#{System.unique_integer([:positive])}" end)
      state = make_state()
      sentinel = "reg-a-#{System.unique_integer([:positive])}"
      state = Helpers.put_in_register(state, "a", sentinel)
      state = %{state | reg: %{state.reg | active: "a"}}

      {text, _state} = Helpers.get_register(state)
      assert text == sentinel
    end
  end

  describe "clipboard option" do
    test "compile-time default is :unnamedplus" do
      ConfigOptions.set(:clipboard, :unnamedplus)
      assert ConfigOptions.get(:clipboard) == :unnamedplus
      ConfigOptions.set(:clipboard, :none)
    end

    test "can be set to :none" do
      ConfigOptions.set(:clipboard, :none)
      assert ConfigOptions.get(:clipboard) == :none
    end

    test "rejects invalid values" do
      assert {:error, _} = ConfigOptions.set(:clipboard, :invalid)
    end
  end
end
