defmodule Minga.Editor.EditingTest do
  @moduledoc """
  Unit tests for the Editing facade module.

  Verifies that all query and mutation functions correctly delegate to
  the underlying VimState. These tests use raw EditorState structs
  (no GenServer) since the facade is pure functions.
  """

  use ExUnit.Case, async: true

  alias Minga.Editor.Editing
  alias Minga.Editor.MacroRecorder
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Mode

  @port_manager :fake_port

  defp build_state(overrides \\ []) do
    vim =
      Keyword.get(overrides, :vim, %VimState{
        mode: Keyword.get(overrides, :mode, :normal),
        mode_state: Keyword.get(overrides, :mode_state, Mode.initial_state())
      })

    %EditorState{
      port_manager: @port_manager,
      workspace: %Minga.Workspace.State{
        viewport: Viewport.new(24, 80),
        vim: vim
      }
    }
  end

  # ── Query functions ──────────────────────────────────────────────────────

  describe "mode/1" do
    test "returns the current mode" do
      assert Editing.mode(build_state(mode: :normal)) == :normal
      assert Editing.mode(build_state(mode: :insert)) == :insert
      assert Editing.mode(build_state(mode: :visual)) == :visual
    end
  end

  describe "mode_state/1" do
    test "returns the mode state struct" do
      ms = Mode.initial_state()
      state = build_state(mode_state: ms)
      assert Editing.mode_state(state) == ms
    end
  end

  describe "inserting?/1" do
    test "returns true only in insert mode" do
      assert Editing.inserting?(build_state(mode: :insert))
      refute Editing.inserting?(build_state(mode: :normal))
      refute Editing.inserting?(build_state(mode: :visual))
    end
  end

  describe "selecting?/1" do
    test "returns true for visual modes" do
      assert Editing.selecting?(build_state(mode: :visual))
      assert Editing.selecting?(build_state(mode: :visual_line))
      assert Editing.selecting?(build_state(mode: :visual_block))
      refute Editing.selecting?(build_state(mode: :normal))
      refute Editing.selecting?(build_state(mode: :insert))
    end
  end

  describe "minibuffer_mode?/1" do
    test "returns true for minibuffer modes" do
      assert Editing.minibuffer_mode?(build_state(mode: :command))
      assert Editing.minibuffer_mode?(build_state(mode: :search))
      assert Editing.minibuffer_mode?(build_state(mode: :eval))
      assert Editing.minibuffer_mode?(build_state(mode: :search_prompt))
      refute Editing.minibuffer_mode?(build_state(mode: :normal))
      refute Editing.minibuffer_mode?(build_state(mode: :insert))
    end
  end

  describe "in_leader?/1" do
    test "returns true when leader_node is a map" do
      ms = %{Mode.initial_state() | leader_node: %{children: %{}}}
      assert Editing.in_leader?(build_state(mode_state: ms))
    end

    test "returns false when leader_node is nil" do
      ms = %{Mode.initial_state() | leader_node: nil}
      refute Editing.in_leader?(build_state(mode_state: ms))
    end

    test "returns false when mode_state has no leader_node field" do
      vim = %VimState{mode: :insert, mode_state: %{}}
      refute Editing.in_leader?(build_state(vim: vim))
    end
  end

  describe "cursor_shape/1" do
    test "returns :beam for insert mode (dispatched through VimModel)" do
      assert Editing.cursor_shape(build_state(mode: :insert)) == :beam
    end

    test "returns :block for normal mode (dispatched through VimModel)" do
      assert Editing.cursor_shape(build_state(mode: :normal)) == :block
    end

    test "returns :underline for replace mode" do
      assert Editing.cursor_shape(build_state(mode: :replace)) == :underline
    end

    test "returns :underline when pending_replace is true in normal mode" do
      ms = %{Mode.initial_state() | pending_replace: true}
      assert Editing.cursor_shape(build_state(mode: :normal, mode_state: ms)) == :underline
    end

    test "returns :beam for minibuffer modes" do
      for mode <- [:command, :search, :eval, :search_prompt] do
        assert Editing.cursor_shape(build_state(mode: mode)) == :beam,
               "expected :beam for #{mode}"
      end
    end
  end

  describe "key_sequence_pending?/1" do
    test "false in normal mode at rest" do
      refute Editing.key_sequence_pending?(build_state())
    end

    test "true when leader_node is set" do
      ms = %{Mode.initial_state() | leader_node: %{children: %{}}}
      assert Editing.key_sequence_pending?(build_state(mode_state: ms))
    end

    test "true when prefix_node is set" do
      ms = %{Mode.initial_state() | prefix_node: %Minga.Keymap.Bindings.Node{}}
      assert Editing.key_sequence_pending?(build_state(mode_state: ms))
    end
  end

  describe "status_segment/1" do
    test "returns NORMAL for normal mode" do
      assert Editing.status_segment(build_state(mode: :normal)) == "NORMAL"
    end

    test "returns INSERT for insert mode" do
      assert Editing.status_segment(build_state(mode: :insert)) == "INSERT"
    end
  end

  describe "visual_anchor/1" do
    test "returns the anchor from mode_state" do
      ms = %Minga.Mode.VisualState{visual_anchor: {5, 3}, visual_type: :char}
      vim = %VimState{mode: :visual, mode_state: ms}
      assert Editing.visual_anchor(build_state(vim: vim)) == {5, 3}
    end

    test "returns nil when mode_state has no visual_anchor" do
      assert Editing.visual_anchor(build_state()) == nil
    end
  end

  # ── Compound accessors ────────────────────────────────────────────────────

  describe "macro_recorder/1" do
    test "returns the macro recorder" do
      state = build_state()
      assert %MacroRecorder{} = Editing.macro_recorder(state)
    end
  end

  describe "macro_recording?/1" do
    test "returns false when not recording" do
      assert Editing.macro_recording?(build_state()) == false
    end
  end

  describe "active_register/1" do
    test "returns the active register name" do
      assert Editing.active_register(build_state()) == ""
    end
  end

  # ── Mutation functions ─────────────────────────────────────────────────────

  describe "set_active_register/2" do
    test "sets the active register" do
      state = Editing.set_active_register(build_state(), "a")
      assert Editing.active_register(state) == "a"
    end
  end

  describe "put_register/3" do
    test "stores text in a named register" do
      state = Editing.put_register(build_state(), "a", "hello")
      reg = Editing.registers(state)
      assert Minga.Editor.State.Registers.get(reg, "a") == {"hello", :charwise}
    end
  end

  describe "reset_active_register/1" do
    test "resets the active register to unnamed" do
      state =
        build_state()
        |> Editing.set_active_register("x")
        |> Editing.reset_active_register()

      assert Editing.active_register(state) == ""
    end
  end

  describe "set_leader_node/2" do
    test "sets the leader node on mode state" do
      node = %{children: %{"f" => :find_file}}
      state = Editing.set_leader_node(build_state(), node)
      assert Editing.mode_state(state).leader_node == node
    end
  end

  describe "update_mode_state/2 with function" do
    test "applies function to mode state" do
      state =
        Editing.update_mode_state(build_state(), fn ms ->
          %{ms | pending_describe_key: true}
        end)

      assert Editing.mode_state(state).pending_describe_key == true
    end
  end

  describe "set_macro_recorder/2" do
    test "replaces the macro recorder" do
      rec = MacroRecorder.new() |> MacroRecorder.start_recording("a")
      state = Editing.set_macro_recorder(build_state(), rec)
      assert Editing.macro_recording?(state) == {true, "a"}
    end
  end

  describe "save_jump_pos/2" do
    test "stores the jump position" do
      state = Editing.save_jump_pos(build_state(), {10, 5})
      assert state.workspace.vim.last_jump_pos == {10, 5}
    end
  end
end
