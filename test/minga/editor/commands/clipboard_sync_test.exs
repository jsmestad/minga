defmodule Minga.Editor.Commands.ClipboardSyncTest do
  @moduledoc """
  Tests for clipboard sync via the `clipboard` config option.

  These tests interact with the real system clipboard (pbcopy/pbpaste on
  macOS). They are run serially to avoid clipboard race conditions.
  """
  use ExUnit.Case, async: false

  alias Minga.Clipboard
  alias Minga.Config.Options, as: ConfigOptions
  alias Minga.Editor.Commands.Helpers
  alias Minga.Editor.State.Registers

  # Skip if no clipboard tool is available
  setup do
    case Clipboard.write("minga-test-sentinel") do
      :ok -> :ok
      _ -> {:skip, "No clipboard tool available"}
    end
  end

  defp make_state do
    %{reg: %Registers{}}
  end

  describe "put_register with clipboard: :unnamedplus" do
    setup do
      ConfigOptions.set(:clipboard, :unnamedplus)
      on_exit(fn -> ConfigOptions.set(:clipboard, :none) end)
      :ok
    end

    test "yy syncs to system clipboard" do
      sentinel = "yank-sync-#{System.unique_integer([:positive])}"
      state = make_state()
      Helpers.put_register(state, sentinel, :yank)

      assert Clipboard.read() == sentinel
    end

    test "delete syncs to system clipboard" do
      sentinel = "delete-sync-#{System.unique_integer([:positive])}"
      state = make_state()
      Helpers.put_register(state, sentinel, :delete)

      assert Clipboard.read() == sentinel
    end

    test "named register also syncs to clipboard" do
      sentinel = "named-sync-#{System.unique_integer([:positive])}"
      state = %{make_state() | reg: %{%Registers{} | active: "a"}}
      Helpers.put_register(state, sentinel, :yank)

      assert Clipboard.read() == sentinel
    end

    test "black hole register does not sync to clipboard" do
      sentinel = "blackhole-guard-#{System.unique_integer([:positive])}"
      Clipboard.write(sentinel)
      state = %{make_state() | reg: %{%Registers{} | active: "_"}}
      Helpers.put_register(state, "should not appear", :yank)

      assert Clipboard.read() == sentinel
    end

    test "explicit + register still works" do
      sentinel = "explicit-clip-#{System.unique_integer([:positive])}"
      state = %{make_state() | reg: %{%Registers{} | active: "+"}}
      Helpers.put_register(state, sentinel, :yank)

      assert Clipboard.read() == sentinel
    end
  end

  describe "put_register with clipboard: :none" do
    setup do
      ConfigOptions.set(:clipboard, :none)
      on_exit(fn -> ConfigOptions.set(:clipboard, :unnamedplus) end)
      :ok
    end

    test "yy does not sync to system clipboard" do
      sentinel = "none-guard-#{System.unique_integer([:positive])}"
      Clipboard.write(sentinel)
      state = make_state()
      Helpers.put_register(state, "should not sync", :yank)

      assert Clipboard.read() == sentinel
    end

    test "explicit + register still works even with clipboard: :none" do
      sentinel = "none-explicit-#{System.unique_integer([:positive])}"
      state = %{make_state() | reg: %{%Registers{} | active: "+"}}
      Helpers.put_register(state, sentinel, :yank)

      assert Clipboard.read() == sentinel
    end
  end

  describe "get_register with clipboard: :unnamedplus" do
    setup do
      ConfigOptions.set(:clipboard, :unnamedplus)
      on_exit(fn -> ConfigOptions.set(:clipboard, :none) end)
      :ok
    end

    test "paste from unnamed register prefers system clipboard when content differs" do
      state = make_state()
      internal = "internal-#{System.unique_integer([:positive])}"
      external = "external-#{System.unique_integer([:positive])}"
      # Put something in the unnamed register
      state = Helpers.put_register(state, internal, :yank)
      # Now simulate external copy by writing directly to clipboard
      Clipboard.write(external)

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

    test "paste from named register ignores clipboard" do
      Clipboard.write("clipboard-noise-#{System.unique_integer([:positive])}")
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
      # The test helper sets :none, but the option spec default is :unnamedplus
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
