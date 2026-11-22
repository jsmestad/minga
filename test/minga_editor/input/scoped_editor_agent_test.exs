defmodule MingaEditor.Input.ScopedEditorAgentTest do
  use ExUnit.Case, async: true

  @moduledoc false
  @moduletag :tmp_dir

  import Minga.Test.ScopedInputHelpers

  alias Minga.Buffer
  alias Minga.Keymap.Bindings
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Agent
  alias MingaEditor.State.TabBar
  alias MingaEditor.Input.AgentPanel
  alias MingaEditor.Input.Scoped
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow

  describe "editor scope (no panel)" do
    test "all keys pass through" do
      state = base_state(keymap_scope: :editor)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
      assert {:passthrough, _} = Scoped.handle_key(state, ?k, 0)
      assert {:passthrough, _} = Scoped.handle_key(state, ?\s, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Editor scope with agent side panel
  # ══════════════════════════════════════════════════════════════════════════

  describe "editor scope — agent side panel nav" do
    setup do
      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true
        )

      {:ok, state: state}
    end

    test "q and ESC toggle the agent split", %{state: state} do
      for key <- [?q, 27] do
        {:handled, new_state} = walk_surface_handlers(state, key, 0)
        refute is_nil(new_state)
      end
    end

    test "i focuses the input", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?i, 0)
      assert new_state.workspace.agent_ui.panel.input_focused == true
    end

    test "j scrolls the semantic transcript", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?j, 0)
      assert new_state.workspace.agent_ui.panel.scroll.offset == 1
    end

    test "passthrough when panel not visible" do
      state = base_state(keymap_scope: :editor, panel_visible: false)
      assert {:passthrough, _} = AgentPanel.handle_key(state, ?j, 0)
    end
  end

  describe "editor scope — agent side panel input" do
    setup do
      state =
        base_state(
          keymap_scope: :editor,
          panel_visible: true,
          input_focused: true
        )

      {:ok, state: state}
    end

    test "printable chars go to input", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, ?x, 0)
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) =~ "x"
    end

    test "ESC switches to input normal mode (editor scope side panel)", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 27, 0)
      assert new_state.workspace.agent_ui.panel.input_focused
      assert new_state.workspace.editing.mode == :normal
    end

    test "safe control keys are handled", %{state: state} do
      for {key, mods} <- [{127, 0}, {?c, 0x02}, {?d, 0x02}] do
        assert {:handled, _new_state} = walk_surface_handlers(state, key, mods)
      end
    end

    test "Enter on empty prompt is no-op", %{state: state} do
      {:handled, new_state} = walk_surface_handlers(state, 13, 0)
      assert new_state.workspace.agent_ui.panel.input_focused == true
    end

    test "modified Enter inserts newline", %{state: state} do
      for mods <- [0x01, 0x04] do
        {:handled, new_state} = walk_surface_handlers(state, 13, mods)

        assert Enum.count(
                 MingaEditor.Agent.PromptBuffer.input_lines(new_state.workspace.agent_ui.panel)
               ) > 1
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Agent scope (full-screen agentic view)
  # ══════════════════════════════════════════════════════════════════════════

  describe "agent scope — normal mode" do
    setup do
      {state, session, file_buffer} = activated_agent_state()
      {:ok, state: state, session: session, file_buffer: file_buffer}
    end

    test "navigation keys pass through Scoped and are handled by AgentNav", %{state: state} do
      for {key, mods} <- [{?j, 0}, {?k, 0}, {?G, 0}, {?d, 0x02}, {?u, 0x02}, {?~, 0}] do
        assert_passthrough_then_handled(state, key, mods)
      end
    end

    test "q returns to the recorded file tab and keeps the agent session", %{
      state: state,
      session: session,
      file_buffer: file_buffer
    } do
      assert state.workspace.keymap_scope == :agent
      return_target = state.workspace.agent_ui.view |> View.return_target()
      assert return_target.active_tab_id == 1
      assert return_target.active_buffer == file_buffer

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.shell_runtime.state.tab_bar.active_id == 1
      assert TabBar.filter_by_kind(new_state.shell_runtime.state.tab_bar, :agent) != []

      assert Enum.any?(
               new_state.shell_runtime.state.tab_bar.tabs,
               &match?(%Tab{kind: :agent, payload: %Agent{session: ^session}}, &1)
             )
    end

    test "ESC returns to the recorded file tab when nothing transient is open", %{state: state} do
      assert state.workspace.keymap_scope == :agent

      assert state.workspace.agent_ui.view |> View.return_target() |> Map.fetch!(:active_tab_id) ==
               1

      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.shell_runtime.state.tab_bar.active_id == 1
      assert TabBar.filter_by_kind(new_state.shell_runtime.state.tab_bar, :agent) != []
    end

    test "return falls back to the most recent remaining file tab when the target closed", %{
      state: state
    } do
      {tb, fallback_tab} = TabBar.insert(state.shell_runtime.state.tab_bar, :file, "fallback.ex")
      {:ok, tb} = TabBar.remove(tb, 1)

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tb
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert new_state.shell_runtime.state.tab_bar.active_id == fallback_tab.id
    end

    test "return without file tabs does not create an untitled fallback", %{
      state: state,
      file_buffer: file_buffer
    } do
      {:ok, tb} = TabBar.remove(state.shell_runtime.state.tab_bar, 1)

      state =
        then(state, fn root ->
          shell_state =
            MingaEditor.Shell.Traditional.State.install_tab_bar(
              MingaEditor.Shell.Runtime.state(root.shell_runtime),
              tb
            )

          %{
            root
            | shell_runtime:
                MingaEditor.Shell.Runtime.install_traditional_state(
                  root.shell_runtime,
                  shell_state
                )
          }
        end)

      {:handled, new_state} = Scoped.handle_key(state, ?q, 0)
      assert new_state.workspace.keymap_scope == :editor
      assert TabBar.filter_by_kind(new_state.shell_runtime.state.tab_bar, :file) == []
      assert new_state.workspace.buffers.active == file_buffer
      assert hd(new_state.workspace.buffers.list) == file_buffer
      assert new_state.shell_runtime.state.notice.message == "No file tabs in this workspace"
    end

    test "? toggles help", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ??, 0)
      assert new_state.workspace.agent_ui.view.help_visible
    end

    test "Normal Tab opens retained Review without changing a focused draft", %{state: state} do
      state = focus_prompt(state, "Retained draft")
      review = Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", "after"))

      for {preview, focus} <- [{Preview.new(), :chat}, {review, :file_viewer}],
          focused <- [false, true],
          visible <- [false, true] do
        ui =
          state.workspace.agent_ui
          |> UIState.replace_preview(preview)
          |> UIState.set_input_focused(focused)

        current =
          state
          |> MingaEditor.Shell.Traditional.Workflow.install_agent_ui(ui)
          |> MingaEditor.Shell.Traditional.Workflow.install_agent_panel(%{
            ui.panel
            | visible: visible
          })

        result =
          Enum.reduce_while(
            MingaEditor.Input.surface_handlers(current),
            {:passthrough, current},
            fn handler, {_, routed} ->
              case handler.handle_key(routed, 9, 0) do
                {:handled, updated} -> {:halt, {:handled, updated}}
                {:passthrough, updated} -> {:cont, {:passthrough, updated}}
              end
            end
          )

        assert {:handled, updated} = result
        assert View.focus(updated.workspace.agent_ui.view) == focus

        assert MingaEditor.Agent.PromptBuffer.prompt_text(updated.workspace.agent_ui) ==
                 "Retained draft"
      end
    end

    test "Normal Tab toggles hidden paste but the visible focused panel opens Review", %{
      state: state
    } do
      state = focus_prompt(state, "")
      paste = "first\nsecond\nthird"
      review = Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", "after"))

      ui =
        state.workspace.agent_ui
        |> PromptBuffer.insert_paste(paste)
        |> UIState.replace_preview(review)

      buffer = ui.panel.prompt_buffer
      Buffer.move_to(buffer, {0, 3})
      version = Buffer.version(buffer)
      state = TraditionalWorkflow.install_agent_ui(state, ui)
      visible = TraditionalWorkflow.install_agent_panel(state, %{ui.panel | visible: true})

      assert {:handled, reviewed} = walk_surface_handlers(visible, 9, 0)
      assert View.focus(reviewed.workspace.agent_ui.view) == :file_viewer
      assert Buffer.content_and_cursor(buffer) == {"\0PASTE:0", {0, 3}}
      assert Buffer.version(buffer) == version
      assert [%{expanded: false}] = reviewed.workspace.agent_ui.panel.pasted_blocks

      assert {:handled, toggled} = walk_surface_handlers(state, 9, 0)

      assert View.focus(toggled.workspace.agent_ui.view) == :chat
      assert Buffer.content_and_cursor(buffer) == {paste, {0, 0}}
      assert [%{expanded: true}] = toggled.workspace.agent_ui.panel.pasted_blocks
    end

    test "a later expanded duplicate claims Tab without editing or opening Review", %{
      state: state
    } do
      paste = "one\ntwo\nthree"
      raw = "#{paste}\nseparator\n#{paste}"
      state = focus_prompt(state, raw)
      review = Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", "after"))

      ui =
        state.workspace.agent_ui
        |> UIState.append_paste_block(paste)
        |> UIState.mark_paste_expanded(0, true)
        |> UIState.replace_preview(review)

      buffer = ui.panel.prompt_buffer
      Buffer.move_to(buffer, {5, 1})
      version = Buffer.version(buffer)
      state = TraditionalWorkflow.install_agent_ui(state, ui)

      assert {:handled, updated} = walk_surface_handlers(state, 9, 0)
      assert View.focus(updated.workspace.agent_ui.view) == :chat
      assert Buffer.content_and_cursor(buffer) == {raw, {5, 1}}
      assert Buffer.version(buffer) == version
      assert [%{text: ^paste, expanded: true}] = updated.workspace.agent_ui.panel.pasted_blocks
    end

    test "malformed and unknown paste tokens claim Tab even without paste metadata", %{
      state: state
    } do
      review = Preview.set_diff(Preview.new(), DiffReview.new("checkout.ex", "before", "after"))

      for token <- ["\0PASTE:", "\0PASTE:malformed", "\0PASTE:42"] do
        current = focus_prompt(state, token)
        ui = UIState.replace_preview(current.workspace.agent_ui, review)
        buffer = ui.panel.prompt_buffer
        Buffer.move_to(buffer, {0, 2})
        version = Buffer.version(buffer)
        current = TraditionalWorkflow.install_agent_ui(current, ui)

        assert {:handled, updated} = walk_surface_handlers(current, 9, 0)
        assert View.focus(updated.workspace.agent_ui.view) == :chat
        assert Buffer.content_and_cursor(buffer) == {token, {0, 2}}
        assert Buffer.version(buffer) == version
        assert updated.workspace.agent_ui.panel.pasted_blocks == []
      end
    end

    test "Tab outside a paste continues the pending agent trie sequence", %{state: state} do
      paste = "one\ntwo\nthree"
      state = focus_prompt(state, "#{paste}\nRetained draft")
      prefix = Bindings.bind(Bindings.new(), [{9, 0}], :agent_toggle_help, "Toggle help")

      ui =
        state.workspace.agent_ui
        |> UIState.append_paste_block(paste)
        |> UIState.mark_paste_expanded(0, true)
        |> UIState.set_prefix(prefix)

      Buffer.move_to(ui.panel.prompt_buffer, {3, 1})
      state = TraditionalWorkflow.install_agent_ui(state, ui)

      assert {:handled, updated} = walk_surface_handlers(state, 9, 0)
      assert updated.workspace.agent_ui.view.help_visible
      assert View.pending_prefix(updated.workspace.agent_ui.view) == nil
      assert PromptBuffer.input_text(updated.workspace.agent_ui) == "#{paste}\nRetained draft"
    end

    test "i focuses input", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?i, 0)
      assert new_state.workspace.agent_ui.panel.input_focused
    end

    test "prefix keys start a prefix sequence", %{state: state} do
      for key <- [?g, ?z, 93, 91] do
        {:handled, new_state} = Scoped.handle_key(state, key, 0)
        assert new_state.workspace.agent_ui.view |> View.pending_prefix() != nil
      end
    end

    test "gg scrolls to top via prefix", %{state: state} do
      {:handled, g_state} = Scoped.handle_key(state, ?g, 0)
      assert {:handled, _} = Scoped.handle_key(g_state, ?g, 0)
    end

    test "panel resize keys work", %{state: state} do
      {:handled, grow} = Scoped.handle_key(state, ?}, 0)

      assert grow.workspace.agent_ui.view.chat_width_pct >
               state.workspace.agent_ui.view.chat_width_pct

      {:handled, shrink} = Scoped.handle_key(state, ?{, 0)

      assert shrink.workspace.agent_ui.view.chat_width_pct <
               state.workspace.agent_ui.view.chat_width_pct
    end

    test "= resets panel split", %{state: state} do
      {:handled, resized} = Scoped.handle_key(state, ?}, 0)
      {:handled, reset} = Scoped.handle_key(resized, ?=, 0)

      assert reset.workspace.agent_ui.view.chat_width_pct ==
               state.workspace.agent_ui.view.chat_width_pct
    end

    test "ESC dismisses help before returning to the editor", %{state: state} do
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_view(
          state,
          (fn v -> %{v | help_visible: true} end).(state.workspace.agent_ui.view)
        )

      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      refute new_state.workspace.agent_ui.view.help_visible
      assert new_state.workspace.keymap_scope == :agent

      assert new_state.shell_runtime.state.tab_bar.active_id ==
               state.shell_runtime.state.tab_bar.active_id
    end

    test "ESC leaves prompt focus without clearing prompt text before returning", %{state: state} do
      state = focus_prompt(state, "keep this")
      agent_tab_id = TabBar.find_by_kind(state.shell_runtime.state.tab_bar, :agent).id

      {:handled, unfocused_state} = Scoped.handle_key(state, 27, 0)
      refute unfocused_state.workspace.agent_ui.panel.input_focused

      assert MingaEditor.Agent.PromptBuffer.prompt_text(unfocused_state.workspace.agent_ui) ==
               "keep this"

      assert unfocused_state.workspace.keymap_scope == :agent

      {:handled, returned_state} = Scoped.handle_key(unfocused_state, 27, 0)
      assert returned_state.workspace.keymap_scope == :editor
      assert returned_state.shell_runtime.state.tab_bar.active_id == 1

      reopened_state = MingaEditor.TabWorkflow.switch(returned_state, agent_tab_id)

      assert MingaEditor.Agent.PromptBuffer.prompt_text(reopened_state.workspace.agent_ui) ==
               "keep this"
    end

    test "ESC keeps prompt focus when cancelling visual and operator-pending prompt states", %{
      state: state
    } do
      for {enter_key, mode} <- [{?v, :visual}, {?d, :operator_pending}] do
        state = state |> focus_prompt("#{mode} draft")

        {:handled, mode_state} = Scoped.handle_key(state, enter_key, 0)
        assert mode_state.workspace.agent_ui.panel.input_focused
        assert Minga.Editing.mode(mode_state) == mode

        {:handled, new_state} = Scoped.handle_key(mode_state, 27, 0)
        assert new_state.workspace.agent_ui.panel.input_focused
        assert new_state.workspace.editing.mode == :normal

        assert MingaEditor.Agent.PromptBuffer.prompt_text(new_state.workspace.agent_ui) ==
                 "#{mode} draft"
      end
    end
  end

  describe "agent scope — insert mode" do
    setup do
      {:ok,
       state:
         base_state(
           keymap_scope: :agent,
           agentic_active: true,
           input_focused: true,
           panel_visible: true
         )}
    end

    test "ESC switches to input normal mode", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, 27, 0)
      assert new_state.workspace.agent_ui.panel.input_focused
      assert new_state.workspace.editing.mode == :normal
    end

    test "printable char self-inserts", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?x, 0)
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) =~ "x"
    end

    test "editing control keys are handled", %{state: state} do
      {:handled, with_char} = Scoped.handle_key(state, ?a, 0)
      assert {:handled, _} = Scoped.handle_key(with_char, 127, 0)
      assert {:handled, _} = Scoped.handle_key(state, ?c, 0x02)
    end

    test "SPC types a space when input is focused (not leader key)", %{state: state} do
      {:handled, new_state} = Scoped.handle_key(state, ?\s, 0)
      assert MingaEditor.Agent.PromptBuffer.input_text(new_state.workspace.agent_ui.panel) =~ " "
    end
  end

  describe "agent scope — search (standard vim)" do
    test "/ passes through to standard vim search" do
      # After #631, search is handled by the standard Mode FSM.
      # `/` is no longer bound in the agent scope trie.
      state = base_state(keymap_scope: :agent, agentic_active: true)
      assert {:passthrough, _} = Scoped.handle_key(state, ?/, 0)

      # Full handler chain handles it (AgentNav → Mode FSM enters search mode)
      {:handled, new_state} = walk_surface_handlers(state, ?/, 0)
      assert new_state.workspace.editing.mode == :search
    end
  end

  describe "agent scope — command line" do
    test ": in chat navigation opens the command line" do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      assert {:passthrough, _} = Scoped.handle_key(state, ?:, 0)
      {:handled, new_state} = walk_surface_handlers(state, ?:, 0)
      assert new_state.workspace.editing.mode == :command
    end

    test "command-line keys reach the command line instead of chat bindings" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      {:handled, state} = walk_surface_handlers(state, ?:, 0)

      # Each of these is a chat binding in navigation mode.
      for {cp, mods} <- [{?q, 0}, {?a, 0}, {?i, 0}, {?y, 0}, {?s, 0}, {13, 0}, {27, 0}] do
        assert {:passthrough, _} = Scoped.handle_key(state, cp, mods)
      end

      state =
        Enum.reduce([?q, ?a], state, fn cp, acc ->
          {:handled, acc} = walk_surface_handlers(acc, cp, 0)
          acc
        end)

      assert state.workspace.editing.mode == :command
      assert state.workspace.keymap_scope == :agent
      assert state.workspace.editing.mode_state.input == "qa"
    end

    test "unbound chat keys never edit or focus the buffer behind the chat" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      buffer = state.workspace.buffers.active

      for keys <- [~c"x", ~c"o", ~c"p", ~c"J", ~c"~", ~c"dd", ~c"v", ~c"r"] do
        {:handled, after_keys} =
          Enum.reduce(keys, {:handled, state}, fn cp, {_, acc} ->
            walk_surface_handlers(acc, cp, 0)
          end)

        assert after_keys.workspace.keymap_scope == :agent, "#{keys} left the agent scope"
        assert after_keys.workspace.editing.mode == :normal, "#{keys} changed the mode"
        assert Buffer.content(buffer) == "hello world", "#{keys} edited the file buffer"
      end
    end
  end

  describe "agent scope — toast dismiss" do
    test "any key dismisses toast then processes normally" do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_ui(
          state,
          (fn ui ->
             UIState.push_toast(ui, "test", :info)
           end).(state.workspace.agent_ui)
        )

      assert UIState.toast_visible?(state.workspace.agent_ui)

      # Toast dismissal is still handled by Scoped, but j itself returns passthrough
      {:passthrough, new_state} = Scoped.handle_key(state, ?j, 0)
      # Toast should be dismissed
      refute UIState.toast_visible?(new_state.workspace.agent_ui)
      # Full chain still handles the key (through AgentNav)
      {:handled, _} = walk_surface_handlers(state, ?j, 0)
    end
  end

  describe "agent scope — file viewer focus" do
    test "j passthrough, handled by AgentNav in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)
      assert {:passthrough, _} = Scoped.handle_key(state, ?j, 0)
      # Full chain handling through AgentNav
      assert {:handled, _} = walk_surface_handlers(state, ?j, 0)
    end

    test "Tab switches back to chat from viewer" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)
      {:handled, new_state} = Scoped.handle_key(state, 9, 0)
      assert new_state.workspace.agent_ui.view |> View.focus() == :chat
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # Mode FSM keys on every agent surface
  # ══════════════════════════════════════════════════════════════════════════

  @agent_surfaces [
    chat: [keymap_scope: :agent, agentic_active: true],
    side_panel: [keymap_scope: :editor, panel_visible: true],
    file_viewer: [keymap_scope: :agent, agentic_active: true, focus: :file_viewer]
  ]

  describe "agent surfaces — mode FSM keys" do
    test "keys typed into the command line from the side panel stay there" do
      state = base_state(keymap_scope: :editor, panel_visible: true)

      # q closes the split, i focuses the draft, and j/G scroll the panel.
      state = walk_keys(state, [{?:, 0}, {?q, 0}, {?a, 0}, {?i, 0}, {?j, 0}, {?G, 0}])

      assert state.workspace.editing.mode == :command
      assert state.workspace.editing.mode_state.input == "qaijG"
      assert state.workspace.agent_ui.panel.visible
      refute state.workspace.agent_ui.panel.input_focused
    end

    test "SPC and : from the file viewer reach the mode FSM like in chat" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)

      command_line = walk_keys(state, [{?:, 0}, {?w, 0}, {?q, 0}])
      assert command_line.workspace.editing.mode == :command
      assert command_line.workspace.editing.mode_state.input == "wq"

      assert Minga.Editing.in_leader?(walk_keys(state, [{?\s, 0}]))
    end

    for {surface, opts} <- @agent_surfaces, key <- [?q, ?j, ?x, 27] do
      @tag surface: surface, opts: opts, key: key
      @outcome if key == 27, do: "cancels describe-key", else: "describes the key"
      test "SPC h k then #{inspect(<<key::utf8>>)} #{@outcome} in #{surface}", %{
        opts: opts,
        key: key
      } do
        state = base_state(opts)
        buffer = state.workspace.buffers.active

        state = walk_keys(state, [{?\s, 0}, {?h, 0}, {?k, 0}])
        assert Minga.Editing.key_sequence_pending?(state)

        {:handled, state} = walk_surface_handlers(state, key, 0)

        refute Minga.Editing.key_sequence_pending?(state)
        assert Buffer.content(buffer) == "hello world"
        describe_or_cancel(state, key)
      end
    end
  end

  # Escape cancels the describe-key prompt; every other key is described.
  defp describe_or_cancel(state, 27), do: assert(help_text(state) == nil)

  defp describe_or_cancel(state, key),
    do: assert(help_text(state) =~ ~r/Key(:| not bound:)\s+#{<<key::utf8>>}\b/)
end
