defmodule MingaEditor.Input.SubStateHandlersTest do
  @moduledoc """
  Tests for the extracted sub-state Input.Handler modules:
  MentionCompletion, ToolApproval, DiffReview.

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
  alias MingaEditor.Agent.DiffReview, as: DiffReviewData
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.View.Preview
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Editing.Scroll
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.VimState
  alias MingaEditor.Input.DiffReview
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

  # ══════════════════════════════════════════════════════════════════════════
  # DiffReview
  # ══════════════════════════════════════════════════════════════════════════

  describe "DiffReview.handle_key/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      review = DiffReviewData.new(Path.join(dir, "test.ex"), "old line\n", "new line\n")

      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)

      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_view(
          state,
          (fn v ->
             %{v | preview: %Preview{content: {:diff, review}}}
           end).(state.workspace.agent_ui.view)
        )

      {:ok, state: state}
    end

    test "y accepts hunk", %{state: state} do
      {:handled, _} = DiffReview.handle_key(state, ?y, 0)
    end

    test "x rejects hunk", %{state: state} do
      {:handled, _} = DiffReview.handle_key(state, ?x, 0)
    end

    test "Y accepts all hunks", %{state: state} do
      {:handled, _} = DiffReview.handle_key(state, ?Y, 0)
    end

    test "X rejects all hunks", %{state: state} do
      {:handled, _} = DiffReview.handle_key(state, ?X, 0)
    end

    test "navigation keys resolve through scope trie", %{state: state} do
      result = DiffReview.handle_key(state, ?j, 0)
      assert elem(result, 0) in [:handled, :passthrough]
    end

    test "modified decisions, scope prefixes and navigation reach their owning handlers", %{
      state: state
    } do
      for {cp, mods} <- [
            {?y, 0x02},
            {?x, 0x08},
            {?Y, 0x04},
            {?X, 0x08},
            {?j, 0},
            {?k, 0},
            {?], 0},
            {?g, 0},
            {9, 0}
          ] do
        assert {:passthrough, ^state} = DiffReview.handle_key(state, cp, mods)
      end
    end

    test "passes through when not in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :chat)
      {:passthrough, _} = DiffReview.handle_key(state, ?y, 0)
    end

    test "passes through when input is focused", %{state: state} do
      state =
        MingaEditor.Shell.Traditional.Workflow.install_agent_panel(
          state,
          (fn p -> %{p | input_focused: true} end).(state.workspace.agent_ui.panel)
        )

      {:passthrough, _} = DiffReview.handle_key(state, ?y, 0)
    end
  end
end
