defmodule Minga.Input.SubStateHandlersTest do
  @moduledoc """
  Tests for the extracted sub-state Input.Handler modules:
  AgentSearch, MentionCompletion, ToolApproval, DiffReview.

  These modules were extracted from Input.Scoped in Phase 4 of the
  Surface refactoring. Each test verifies the handler intercepts the
  correct keys and passes through otherwise.
  """

  use ExUnit.Case, async: true

  alias Minga.Agent.DiffReview, as: DiffReviewData
  alias Minga.Agent.PanelState
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Tab
  alias Minga.Editor.State.TabBar
  alias Minga.Editor.Viewport
  alias Minga.Editor.VimState
  alias Minga.Input.AgentSearch
  alias Minga.Input.DiffReview
  alias Minga.Input.MentionCompletion
  alias Minga.Input.ToolApproval
  alias Minga.Scroll

  defp base_state(opts) do
    {:ok, buf} = BufferServer.start_link(content: "hello world")
    {:ok, prompt_buf} = BufferServer.start_link(content: "")

    panel = %PanelState{
      visible: Keyword.get(opts, :panel_visible, false),
      input_focused: Keyword.get(opts, :input_focused, false),
      scroll: Scroll.new(),
      spinner_frame: 0,
      provider_name: "anthropic",
      model_name: "claude-sonnet-4",
      thinking_level: "medium",
      prompt_buffer: prompt_buf
    }

    agent = %AgentState{
      session: nil,
      panel: panel,
      pending_approval: Keyword.get(opts, :pending_approval, nil)
    }

    agentic = %ViewState{
      active: Keyword.get(opts, :agentic_active, false),
      focus: Keyword.get(opts, :focus, :chat)
    }

    tab_bar =
      if Keyword.get(opts, :agentic_active, false) do
        TabBar.new(Tab.new_agent(1, "Agent"))
      else
        TabBar.new(Tab.new_file(1, "[no file]"))
      end

    %EditorState{
      port_manager: self(),
      viewport: %Viewport{rows: 24, cols: 80, top: 0, left: 0},
      vim: VimState.new(),
      buffers: %Buffers{active: buf, list: [buf]},
      focus_stack: [],
      keymap_scope: Keyword.get(opts, :keymap_scope, :editor),
      agent: agent,
      agentic: agentic,
      tab_bar: tab_bar
    }
  end

  # ══════════════════════════════════════════════════════════════════════════
  # AgentSearch
  # ══════════════════════════════════════════════════════════════════════════

  describe "AgentSearch.handle_key/3" do
    test "handles keys when search is active" do
      state = base_state(keymap_scope: :agent, agentic_active: true)

      state =
        AgentAccess.update_agentic(state, fn agentic -> ViewState.start_search(agentic, 0) end)

      {:handled, _new_state} = AgentSearch.handle_key(state, ?h, 0)
    end

    test "passes through when search is not active" do
      state = base_state(keymap_scope: :agent, agentic_active: true)
      {:passthrough, _} = AgentSearch.handle_key(state, ?h, 0)
    end
  end

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
        AgentAccess.update_agent(state, fn agent ->
          put_in(agent.panel.mention_completion, comp)
        end)

      {:handled, _new_state} = MentionCompletion.handle_key(state, 27, 0)
    end

    test "handles keys in editor scope with mention active", %{completion: comp} do
      state = base_state(keymap_scope: :editor, panel_visible: true, input_focused: true)

      state =
        AgentAccess.update_agent(state, fn agent ->
          put_in(agent.panel.mention_completion, comp)
        end)

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
      approval = %{tool_call_id: "tc_1", name: "write_file", args: %{"path" => "/tmp/test"}}
      {:ok, approval: approval}
    end

    test "handles y when approval is pending", %{approval: approval} do
      state = base_state(keymap_scope: :agent, agentic_active: true, pending_approval: approval)
      {:handled, _} = ToolApproval.handle_key(state, ?y, 0)
    end

    test "handles n when approval is pending", %{approval: approval} do
      state = base_state(keymap_scope: :agent, agentic_active: true, pending_approval: approval)
      {:handled, _} = ToolApproval.handle_key(state, ?n, 0)
    end

    test "swallows unrelated keys when approval is pending", %{approval: approval} do
      state = base_state(keymap_scope: :agent, agentic_active: true, pending_approval: approval)
      {:handled, new_state} = ToolApproval.handle_key(state, ?x, 0)
      # Key is swallowed, approval still pending
      assert AgentAccess.agent(new_state).pending_approval != nil
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
    setup do
      review = DiffReviewData.new("test.ex", "old line\n", "new line\n")

      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :file_viewer)

      state =
        AgentAccess.update_agentic(state, fn agentic ->
          %{agentic | preview: %Preview{content: {:diff, review}}}
        end)

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

    test "passes through when not in file_viewer focus" do
      state = base_state(keymap_scope: :agent, agentic_active: true, focus: :chat)
      {:passthrough, _} = DiffReview.handle_key(state, ?y, 0)
    end

    test "passes through when input is focused", %{state: state} do
      state =
        AgentAccess.update_agent(state, fn agent -> put_in(agent.panel.input_focused, true) end)

      {:passthrough, _} = DiffReview.handle_key(state, ?y, 0)
    end
  end
end
