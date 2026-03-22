defmodule Minga.Mode.Visual.UserOverrideTest do
  @moduledoc "Tests for user-defined visual mode bindings via Keymap.Active."
  use ExUnit.Case, async: false

  alias Minga.Keymap.Active, as: KeymapActive
  alias Minga.Mode.Visual
  alias Minga.Mode.VisualState

  defp visual_state(anchor \\ {0, 0}, type \\ :char) do
    %VisualState{visual_anchor: anchor, visual_type: type}
  end

  setup do
    # KeymapActive is a global singleton; start_supervised! won't work until
    # it accepts a name: param. See autoresearch.md for the planned refactor.
    case KeymapActive.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> KeymapActive.reset()
    end

    on_exit(fn ->
      try do
        KeymapActive.reset()
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "user-defined visual-mode overrides" do
    test "Ctrl+X bound to :custom_cut executes the command" do
      KeymapActive.bind(:visual, "C-x", :custom_cut, "Custom cut")

      state = visual_state()
      assert {:execute, :custom_cut, _} = Visual.handle_key({?x, 0x02}, state)
    end

    test "unbound key falls through to default (continue)" do
      state = visual_state()
      # Ctrl+Z is not bound by default
      assert {:continue, _} = Visual.handle_key({?z, 0x02}, state)
    end

    test "built-in visual keys still work when user overrides exist" do
      KeymapActive.bind(:visual, "C-x", :custom_cut, "Custom cut")

      state = visual_state()
      # Escape should still transition to normal
      assert {:transition, :normal, _} = Visual.handle_key({27, 0}, state)

      # d should still delete selection
      assert {:execute_then_transition, [:delete_visual_selection], :normal, _} =
               Visual.handle_key({?d, 0}, state)
    end
  end
end
