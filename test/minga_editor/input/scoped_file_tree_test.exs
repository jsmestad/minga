defmodule MingaEditor.Input.ScopedFileTreeTest do
  use ExUnit.Case, async: true

  @moduledoc false
  @moduletag :tmp_dir

  import Minga.Test.ScopedInputHelpers

  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Input.FileTreeHandler
  alias MingaEditor.Input.Scoped
  alias Minga.Project.FileTree

  describe "file tree scope" do
    test "q closes tree", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      {:handled, new_state} = FileTreeHandler.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert ft(new_state).tree == nil
    end

    test "unbound key delegates to mode FSM for vim nav", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # j is not bound in file_tree scope (handled by mode FSM delegation)
      {:handled, new_state} = FileTreeHandler.handle_key(state, ?j, 0)
      assert ft(new_state).tree.cursor == 1
    end

    test "leader sequence in progress delegates to mode FSM", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)
      # Use a real Bindings.Node, not a plain map, because the mode FSM
      # calls Bindings.lookup on leader_node.
      leader_node = %Minga.Keymap.Bindings.Node{children: %{}, command: nil, description: nil}

      leader_state = %{
        state
        | workspace:
            SessionState.set_editing(
              state.workspace,
              MingaEditor.VimState.set_mode_state(state.workspace.editing, %{
                state.workspace.editing.mode_state
                | leader_node: leader_node
              })
            )
      }

      {:handled, _new_state} = FileTreeHandler.handle_key(leader_state, ?f, 0)
    end

    test "tree scope bindings are handled", %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "subdir"))

      for {key, file_count} <- [{?h, 0}, {?l, 0}, {?r, 3}] do
        state = make_tree_state(tmp_dir, file_count)
        assert {:handled, _new_state} = FileTreeHandler.handle_key(state, key, 0)
      end
    end

    test "H toggles hidden files (scope binding)", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, ".hidden"), "")
      state = make_tree_state(tmp_dir, 0)

      entries_before = Enum.count(FileTree.visible_entries(ft(state).tree))
      {:handled, new_state} = FileTreeHandler.handle_key(state, ?H, 0)
      entries_after = Enum.count(FileTree.visible_entries(ft(new_state).tree))

      assert entries_after != entries_before
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Scope inactive guards
  # ══════════════════════════════════════════════════════════════════════════

  describe "scope inactive guards" do
    test "agent scope with agentic not active passes through" do
      state = base_state(keymap_scope: :agent, agentic_active: false)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
    end

    test "file_tree scope with tree not focused passes through", %{tmp_dir: tmp_dir} do
      state = make_tree_state(tmp_dir)

      state =
        then(state, fn state ->
          %{
            state
            | workspace:
                then(
                  state.workspace,
                  &MingaEditor.Session.State.set_file_tree(&1, %{ft(state) | focused: false})
                )
          }
        end)

      assert {:passthrough, _} = FileTreeHandler.handle_key(state, ?q, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Cross-scope leader sequences
  # ══════════════════════════════════════════════════════════════════════════

  describe "leader sequences work across all scopes" do
    test "SPC and pending leader pass through in non-input scopes" do
      agent_state = base_state(keymap_scope: :agent, agentic_active: true)

      leader_state = %{
        agent_state
        | workspace:
            SessionState.set_editing(
              agent_state.workspace,
              MingaEditor.VimState.set_mode_state(agent_state.workspace.editing, %{
                agent_state.workspace.editing.mode_state
                | leader_node: %{}
              })
            )
      }

      for {state, key} <- [
            {agent_state, ?\s},
            {base_state(keymap_scope: :editor), ?\s},
            {leader_state, ?a}
          ] do
        assert {:passthrough, _} = Scoped.handle_key(state, key, 0)
      end
    end

    test "SPC self-inserts in agent insert mode" do
      state =
        base_state(
          keymap_scope: :agent,
          agentic_active: true,
          input_focused: true,
          panel_visible: true
        )

      {:handled, new_state} = walk_surface_handlers(state, ?\s, 0)
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) =~ " "
    end
  end
end
