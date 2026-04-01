defmodule Minga.Mode.NormalRegisterTest do
  @moduledoc """
  Pure function tests for register selection key dispatch in normal mode.

  Tests the " prefix → pending → register char → {:select_register, ...}
  FSM transitions without booting any GenServers.
  """
  use ExUnit.Case, async: true

  alias Minga.Keymap.Defaults
  alias Minga.Mode
  alias Minga.Mode.Normal
  alias Minga.Mode.State, as: ModeState

  defp fresh_state do
    %{
      Mode.initial_state()
      | leader_trie: Defaults.leader_trie(),
        normal_bindings: Defaults.normal_bindings()
    }
  end

  defp pending_register, do: %{fresh_state() | pending: :register}

  describe ~S[" (register selection)] do
    test ~S[" enters pending register state] do
      assert {:continue, %ModeState{pending: :register}} =
               Normal.handle_key({?", 0}, fresh_state())
    end

    test ~S[" + lowercase letter selects that register] do
      assert {:execute, {:select_register, "a"}, %ModeState{pending: nil}} =
               Normal.handle_key({?a, 0}, pending_register())
    end

    test ~S[" + z selects register z] do
      assert {:execute, {:select_register, "z"}, %ModeState{pending: nil}} =
               Normal.handle_key({?z, 0}, pending_register())
    end

    test ~S[" + uppercase letter selects uppercase register (append)] do
      assert {:execute, {:select_register, "A"}, %ModeState{pending: nil}} =
               Normal.handle_key({?A, 0}, pending_register())
    end

    test ~S[" + Z selects register Z] do
      assert {:execute, {:select_register, "Z"}, %ModeState{pending: nil}} =
               Normal.handle_key({?Z, 0}, pending_register())
    end

    test ~S[" + 0 selects yank register] do
      assert {:execute, {:select_register, "0"}, %ModeState{pending: nil}} =
               Normal.handle_key({?0, 0}, pending_register())
    end

    test ~S[" + _ selects black-hole register] do
      assert {:execute, {:select_register, "_"}, %ModeState{pending: nil}} =
               Normal.handle_key({?_, 0}, pending_register())
    end

    test ~S[" + + selects system clipboard register] do
      assert {:execute, {:select_register, "+"}, %ModeState{pending: nil}} =
               Normal.handle_key({?+, 0}, pending_register())
    end

    test ~S[" + " selects unnamed register] do
      assert {:execute, {:select_register, "\""}, %ModeState{pending: nil}} =
               Normal.handle_key({?", 0}, pending_register())
    end

    test ~S[" + invalid char cancels selection] do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({?!, 0}, pending_register())
    end

    test ~S[" + digit other than 0 cancels] do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({?5, 0}, pending_register())
    end

    test ~S[" + escape cancels] do
      assert {:continue, %ModeState{pending: nil}} =
               Normal.handle_key({27, 0}, pending_register())
    end
  end
end
