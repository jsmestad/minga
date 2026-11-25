defmodule MingaEditor.Input.SubStateHandlersTest do
  @moduledoc """
  Tests for the extracted sub-state Input.Handler modules:
  MentionCompletion and ToolApproval. Diff Review keys are Agent scope
  bindings; see `MingaEditor.Input.DiffReviewKeysTest`.

  These modules were extracted from Input.Scoped in Phase 4 of the
  Surface refactoring. Each test verifies the handler intercepts the
  correct keys and passes through otherwise.

  AgentSearch was removed in the agent input handler cleanup (#631).
  """

  use ExUnit.Case, async: true

  alias MingaAgent.ToolApproval.Preview, as: ApprovalPreview
  alias MingaAgent.ToolApproval.Public
  alias MingaAgent.ToolApproval.Target
  alias MingaEditor.Agent.PendingApproval
  alias MingaEditor.Agent.UIState
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Scroll
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.Input.MentionCompletion
  alias MingaEditor.Input.ToolApproval

  defp base_state(opts) do
    buf = start_supervised!({BufferProcess, content: "hello world"}, id: make_ref())
    prompt_buf = start_supervised!({BufferProcess, content: ""}, id: make_ref())

    agent = %AgentState{
      pending_approval: Keyword.get(opts, :pending_approval, nil)
    }

    agentic = %UIState{
      panel: %UIState.Panel{
        visible: Keyword.get(opts, :panel_visible, false),
        input_focused: Keyword.get(opts, :input_focused, false),
        scroll: Scroll.new(),
        spinner_frame: 0,
        provider_name: "anthropic",
        model_name: "claude-sonnet-4",
        thinking_level: "medium",
        prompt_buffer: prompt_buf
      }
    }

    agentic =
      if Keyword.get(opts, :agentic_active, false),
        do: UIState.activate(agentic, nil, nil),
        else: agentic

    agentic = UIState.set_focus(agentic, Keyword.get(opts, :focus, :chat))

    tab_bar =
      if Keyword.get(opts, :agentic_active, false) do
        TabBar.new(Tab.new_agent(1, "Agent"))
      else
        TabBar.new(Tab.new_file(1, "[no file]"))
      end

    %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: self()},
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf]},
        keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
        agent_ui: agentic
      },
      interaction: %MingaEditor.State.Interaction{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          MingaEditor.Shell.Traditional.State.install_tab_bar(
            MingaEditor.Shell.Traditional.State.replace_agent(
              %MingaEditor.Shell.Traditional.State{},
              agent
            ),
            tab_bar
          )
        )
    }
  end

  # AgentSearch was removed in #631.

  # ══════════════════════════════════════════════════════════════════════════
  # MentionCompletion
  # ══════════════════════════════════════════════════════════════════════════

  describe "MentionCompletion.handle_key/3" do
    setup do
      completion = %{
        prefix: "@",
        all_files: ["lib/test.ex", "lib/foo.ex"],
        candidates: ["lib/test.ex", "lib/foo.ex"],
        selected: 0,
        anchor_line: 0,
        anchor_col: 0
      }

      {:ok, completion: completion}
    end

    test "handles keys in agent scope with mention active", %{completion: comp} do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | mention_completion: comp} end).(state.workspace.agent_ui.panel)
        )

      {:handled, _new_state} = MentionCompletion.handle_key(state, 27, 0)
    end

    test "handles keys in editor scope with mention active", %{completion: comp} do
      state = base_state(keymap_scope: :editor, panel_visible: true, input_focused: true)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | mention_completion: comp} end).(state.workspace.agent_ui.panel)
        )

      {:handled, _new_state} = MentionCompletion.handle_key(state, 27, 0)
    end

    test "Enter with a modifier closes the popup and reaches the composer's own binding", %{
      completion: comp
    } do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | mention_completion: comp} end).(state.workspace.agent_ui.panel)
        )

      # ⌥↩ queues and ⌘↩ sends; only plain Enter accepts the highlighted file.
      for mods <- [0x04, 0x08] do
        assert {:passthrough, passed} = MentionCompletion.handle_key(state, 13, mods)
        assert passed.workspace.agent_ui.panel.mention_completion == nil
      end

      assert {:handled, _accepted} = MentionCompletion.handle_key(state, 13, 0)
    end

    test "passes through when no mention completion active" do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: true)
      {:passthrough, _} = MentionCompletion.handle_key(state, ?h, 0)
    end

    test "passes through when input is not focused" do
      state = base_state(keymap_scope: :agent, agentic_active: true, input_focused: false)
      {:passthrough, _} = MentionCompletion.handle_key(state, ?h, 0)
    end
  end

  # ══════════════════════════════════════════════════════════════════════════
  # ToolApproval
  # ══════════════════════════════════════════════════════════════════════════

  describe "ToolApproval.handle_key/3" do
    setup do
      approval =
        PendingApproval.new(
          self(),
          Public.new(
            Target.new("handler-fixture", "admitted-request", "tc_1"),
            "write_file",
            %{"path" => "/tmp/test"},
            ApprovalPreview.new(:args, "", [])
          )
        )

      {:ok, approval: approval}
    end

    test "modified decision keys cannot resolve or widen the displayed approval", %{
      approval: approval
    } do
      state = base_state(keymap_scope: :agent, agentic_active: true, pending_approval: approval)

      for modifiers <- 1..15, key <- [?y, 13, ?a, ?t, ?n, 27] do
        assert {:passthrough, ^state} = ToolApproval.handle_key(state, key, modifiers)
      end
    end

    test "passes unrelated keys through when approval is pending", %{approval: approval} do
      state = base_state(keymap_scope: :agent, agentic_active: true, pending_approval: approval)
      {:passthrough, new_state} = ToolApproval.handle_key(state, ?x, 0)

      assert MingaEditor.Shell.Traditional.State.agent(new_state.shell_runtime.state).pending_approval !=
               nil
    end

    test "passes through when no approval pending" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      {:passthrough, _} = ToolApproval.handle_key(state, ?y, 0)
    end

    test "passes through when input is focused", %{approval: approval} do
      state =
        base_state(
          keymap_scope: :agent,
          agentic_active: true,
          input_focused: true,
          pending_approval: approval
        )

      {:passthrough, _} = ToolApproval.handle_key(state, ?y, 0)
    end
  end
end
