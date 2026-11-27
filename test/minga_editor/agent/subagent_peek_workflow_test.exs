defmodule MingaEditor.Agent.SubagentPeekWorkflowTest do
  use ExUnit.Case, async: true

  import MingaEditor.RenderPipeline.TestHelpers

  alias Minga.Protocol.Opcodes
  alias MingaAgent.Event.ToolEnd
  alias MingaAgent.Event.ToolStart
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaEditor.Agent.SubagentPeekComposer, as: Composer
  alias MingaEditor.Agent.SubagentPeekWorkflow, as: Peek
  alias MingaEditor.Agent.Tasks.Subagent
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Input.SubagentPeek, as: PeekInput
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.Frontend.Protocol.GUI
  alias MingaEditor.Layout
  alias MingaEditor.RenderModel.UI.AgentChatBuilder
  alias MingaEditor.RenderModel.UI.SubagentPeekBuilder
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State
  alias MingaEditor.State.Windows
  alias MingaEditor.Window
  alias MingaEditor.WindowFocus
  alias MingaEditor.WindowTree

  test "stepping keeps the right split and close returns to the originating parent" do
    first = {"request", "new-batch", "first"}
    second = {"request", "new-batch", "second"}
    older = {"request", "old-batch", "first"}
    state = with_conversation([older, first, second])

    opened = Peek.open_latest(state, 2)

    assert %Window{id: peek, content: {:subagent_peek, {2, {"parent", ^first}}}} =
             Windows.active_struct(opened.workspace.windows)

    assert opened.workspace.windows.tree ==
             {:split, :vertical, {:leaf, 1}, {:split, :vertical, {:leaf, 2}, {:leaf, peek}, 0}, 0}

    assert opened.workspace.keymap_scope == :subagent_peek
    assert Peek.step(opened, :previous).workspace.windows == opened.workspace.windows

    unfolded = opened |> press(?z) |> press(?a)
    assert unfolded.agent_connection.peek_session.brief_open?

    drafting = unfolded |> press(?i) |> press(?q) |> press(27)
    stepped = drafting |> press(?]) |> press(?])

    assert %Window{id: ^peek, content: {:subagent_peek, {2, {"parent", ^second}}}} =
             Windows.active_struct(stepped.workspace.windows)

    assert {"", {0, 0}, false, nil} =
             Composer.presentation(stepped.agent_connection.peek_composer, {"parent", second})

    back = stepped |> press(?[) |> press(?[)

    assert {"q", {0, 1}, false, nil} =
             Composer.presentation(back.agent_connection.peek_composer, {"parent", first})

    assert Peek.step(stepped, :next).workspace.windows == stepped.workspace.windows
    assert Peek.step(stepped, :previous).workspace.windows.active == peek

    closed = press(stepped, ?q)
    assert closed.workspace.windows.active == 2
    assert closed.workspace.keymap_scope == :agent
    assert WindowTree.leaves(closed.workspace.windows.tree) == [1, 2]
  end

  test "window and layout close do not strand a peek without its parent" do
    key = {"request", "batch", "selected"}
    opened = [key] |> with_conversation() |> Peek.open_latest(2)

    closed_peek = MingaEditor.Commands.Movement.execute(opened, :window_close)
    assert closed_peek.workspace.windows.active == 2
    assert WindowTree.leaves(closed_peek.workspace.windows.tree) == [1, 2]
    assert closed_peek.agent_connection.peek_session == nil

    closed_parent =
      opened |> WindowFocus.focus(2) |> MingaEditor.Commands.Movement.execute(:window_close)

    assert closed_parent.workspace.windows.active == 1
    assert WindowTree.leaves(closed_parent.workspace.windows.tree) == [1]
    assert closed_parent.agent_connection.peek_session == nil

    restored_layout = MingaEditor.LayoutPreset.restore_default(opened)
    assert restored_layout.workspace.windows.active == 1
    assert WindowTree.leaves(restored_layout.workspace.windows.tree) == [1]
    assert restored_layout.agent_connection.peek_session == nil
  end

  test "opening from the parent composer gives the peek keyboard ownership without modifying the draft" do
    prompt = start_supervised!({Minga.Buffer, content: "parent draft"})
    state = with_conversation([{"request", "batch", "first"}, {"request", "batch", "second"}])

    ui =
      state.workspace.agent_ui
      |> UIState.attach_prompt_buffer(prompt)
      |> UIState.set_input_focused(true)

    state = %{state | workspace: SessionState.set_agent_ui(state.workspace, ui)}

    opened =
      MingaEditor.Input.AgentPanel.with_prompt_buffer(state, &Peek.open_from_current/1)

    assert %Window{content: {:subagent_peek, {2, {"parent", {"request", "batch", "first"}}}}} =
             Windows.active_struct(opened.workspace.windows)

    stepped = opened |> press(?]) |> press(?])

    assert %Window{content: {:subagent_peek, {2, {"parent", {"request", "batch", "second"}}}}} =
             Windows.active_struct(stepped.workspace.windows)

    assert press(stepped, ?q).workspace.windows.active == 2
    assert Minga.Buffer.content(prompt) == "parent draft"
  end

  test "a stale Started Return goes to the parent composer that took focus" do
    key = {"request", "batch", "first"}
    token = Subagent.action_token({"parent", key})
    parent = with_conversation([key])

    {tabs, ws} =
      MingaEditor.State.Tab.new_agent(1, "Parent")
      |> MingaEditor.State.TabBar.new()
      |> MingaEditor.State.TabBar.add_workspace("Parent", self())

    tabs = MingaEditor.State.TabBar.move_tab_to_workspace(tabs, 1, ws.id)
    shell = MingaEditor.Shell.Traditional.State.install_tab_bar(parent.shell_runtime.state, tabs)
    runtime = MingaEditor.Shell.Runtime.install_traditional_state(parent.shell_runtime, shell)
    parent = %{parent | shell_runtime: runtime}

    ui =
      parent.workspace.agent_ui
      |> MingaEditor.Agent.PromptBuffer.set_input_focused(true)
      |> MingaEditor.Agent.PromptBuffer.set_prompt_text("/help")

    focused = %{parent | workspace: SessionState.set_agent_ui(parent.workspace, ui)}

    returned = Peek.click(focused, :started_key, 2, "", token, {0, 0})
    assert returned.workspace.windows.active == 2
    assert MingaEditor.Agent.PromptBuffer.input_text(returned.workspace.agent_ui) == ""
    assert Peek.click(focused, :started, 2, "", token, {0, 0}).workspace.windows.active != 2
    assert Peek.click(parent, :started_key, 2, "", token, {0, 0}).workspace.windows.active != 2
  end

  test "committed Unicode reaches only the exact child that still owns the composer" do
    first = {"parent", {"request", "batch", "first"}}
    second = {"parent", {"request", "batch", "second"}}
    token = Subagent.action_token(first)
    other_token = Subagent.action_token(second)
    state = with_conversation([elem(first, 1), elem(second, 1)])
    opened = Peek.click(state, :started, 2, "", token, {0, 0})
    window = opened.workspace.windows.active
    editing = Peek.click(opened, :compose, window, token, "", {0, 0})
    text = "日本🙂"

    payload =
      <<8, window::16, byte_size(token)::16, token::binary, byte_size(text)::16, text::binary,
        0::64>>

    opcode = Opcodes.gui_action_subagent_peek_action()

    assert {:ok, {:subagent_peek_action, :insert_text, ^window, ^token, ^text, {0, 0}}} =
             GUI.decode_gui_action(opcode, payload)

    invalid = <<8, window::16, byte_size(token)::16, token::binary, 1::16, 255, 0::64>>
    assert :error = GUI.decode_gui_action(opcode, invalid)

    assert Peek.click(opened, :insert_text, window, token, text, {0, 0}) == opened
    written = Peek.click(editing, :insert_text, window, token, text, {0, 0})

    assert {^text, _, false, nil} =
             Composer.presentation(written.agent_connection.peek_composer, first)

    switched = Peek.click(written, :sibling, window, token, other_token, {0, 0})
    editing_sibling = Peek.click(switched, :compose, window, other_token, "", {0, 0})

    assert Peek.click(editing_sibling, :insert_text, window, token, "stale", {0, 0}) ==
             editing_sibling

    assert {"", _, false, nil} =
             Composer.presentation(editing_sibling.agent_connection.peek_composer, second)
  end

  test "terminal CUA sends Space to a child draft or uses it as a chord without editing the parent" do
    key = {"request", "batch", "first"}
    parent = with_conversation([key])
    prompt = start_supervised!({Minga.Buffer, content: "saved parent draft"})

    ui =
      parent.workspace.agent_ui
      |> UIState.toggle()
      |> UIState.attach_prompt_buffer(prompt)
      |> UIState.set_input_focused(true)

    state = %{
      parent
      | workspace: SessionState.set_agent_ui(parent.workspace, ui),
        frontend: %State.Frontend{backend: :tui},
        interaction: State.Interaction.new(editing_model: :cua)
    }

    opened = Peek.open_from_current(state)
    pane = opened.workspace.windows.active
    identity = {"parent", key}
    editing = Composer.focus(opened, {pane, identity})
    typed = MingaEditor.Input.Router.route_key(editing, ?\s, 0)

    assert {" ", _, false, nil} =
             Composer.presentation(typed.agent_connection.peek_composer, identity)

    returned =
      typed
      |> Composer.blur()
      |> MingaEditor.Input.Router.route_key(?\s, 0)
      |> MingaEditor.Input.Router.route_key(?w, 0)
      |> MingaEditor.Input.Router.route_key(?h, 0)

    assert returned.workspace.windows.active == 2
    assert Minga.Buffer.content(prompt) == "saved parent draft"

    assert {" ", _, false, nil} =
             Composer.presentation(returned.agent_connection.peek_composer, identity)
  end

  defp press(state, codepoint) do
    assert {:handled, next} = PeekInput.handle_key(state, codepoint, 0)
    next
  end

  test "an activation must name the parent conversation, its window, and an observed invocation" do
    key = {"request", "batch", "selected"}
    state = with_conversation([key])

    assert Peek.open(state, 2, {"other-parent", key}) == state
    assert Peek.open(state, 1, {"parent", key}) == state
    assert Peek.open(state, 2, {"parent", {"other", "batch", "selected"}}) == state

    assert %Window{content: {:subagent_peek, {2, {"parent", ^key}}}} =
             state
             |> Peek.open(2, {"parent", key})
             |> then(&Windows.active_struct(&1.workspace.windows))
  end

  test "a new record on the same Session pid retires the old split and rejects its invocation" do
    key = {"request", "batch", "selected"}
    opened = Peek.open_latest(with_conversation([key]), 2)
    peek = opened.workspace.windows.active
    new_target = ConnectionTarget.new(self(), "new-record", nil, make_ref())
    snapshot = %{opened.workspace.agent_ui.connection | target: new_target}
    ui = UIState.project_connection(opened.workspace.agent_ui, snapshot)
    workspace = SessionState.set_agent_ui(opened.workspace, ui)

    replaced =
      State.observe_agent_task_event(
        %{opened | workspace: workspace},
        self(),
        {:connection_changed, snapshot},
        2
      )
      |> Peek.resume_in_workspace()

    assert WindowTree.leaves(replaced.workspace.windows.tree) == [1, 2]
    assert Windows.active_struct(replaced.workspace.windows).id == 2
    assert Composer.focused(replaced) == nil

    assert Peek.open_latest(replaced, 2) == replaced
    assert Peek.open(replaced, 2, {"new-record", key}) == replaced

    next_key = {"new-request", "new-batch", "next"}

    next_event = %ToolStart{
      tool_call_id: "next",
      invocation_key: next_key,
      entry_id: 1,
      name: "subagent",
      args: %{"task" => "new task's brief"}
    }

    next =
      replaced
      |> State.observe_agent_task_event(self(), {:tool_started, next_event}, 3)
      |> Peek.open_latest(2)

    refute peek in WindowTree.leaves(next.workspace.windows.tree)

    assert %Window{content: {:subagent_peek, {2, {"new-record", ^next_key}}}} =
             Windows.active_struct(next.workspace.windows)
  end

  test "returning to a workspace restores its reader only while the exact parent survives" do
    key = {"request", "batch", "selected"}
    parent = with_conversation([key])
    opened = Peek.open_latest(parent, 2)
    peek = opened.workspace.windows.active

    away = Peek.resume_in_workspace(%{opened | workspace: parent.workspace})
    assert away.agent_connection.peek_session == nil
    restored = Peek.resume_in_workspace(%{away | workspace: opened.workspace})
    assert restored.agent_connection.peek_session.identity == {"parent", key}
    assert restored.workspace.windows.active == peek

    ui = UIState.restore_chat(restored.workspace.agent_ui, :unavailable)
    absent = %{restored | workspace: SessionState.set_agent_ui(restored.workspace, ui)}
    retired = Peek.resume_in_workspace(absent)
    assert retired.agent_connection.peek_session == nil
    assert retired.workspace.windows.active == 2
    assert WindowTree.leaves(retired.workspace.windows.tree) == [1, 2]
  end

  test "the semantic frame places the child to the right without hiding the parent conversation" do
    key = {"request", "batch", "selected"}
    state = with_conversation([key])

    event = %ToolEnd{
      tool_call_id: "selected",
      invocation_key: key,
      name: "subagent",
      outcome: :complete,
      result: "the original report"
    }

    state = State.observe_agent_task_event(state, self(), {:tool_ended, event}, 2)
    opened = Peek.open(state, 2, {"parent", key})
    ctx = opened |> Input.from_editor_state() |> Layout.put() |> Context.from_input()
    model = SubagentPeekBuilder.build(ctx)

    assert [{1, token, "Started identical brief", "1 of 1 reports in"}] = model.steps
    assert model.pane.token == token
    assert model.pane.result == "the original report"
    refute model.pane.brief_open?

    {row, parent_col, parent_width, _} = model.parent_rect
    {^row, child_col, _, _} = model.peek_rect
    assert child_col >= parent_col + parent_width
    assert AgentChatBuilder.build(ctx).visible?
    refute AgentChatBuilder.build(ctx).input_focused
  end

  test "a delayed sibling click cannot retarget a peek that no longer shows its source" do
    first = {"request", "batch", "first"}
    second = {"request", "batch", "second"}
    first_token = Subagent.action_token({"parent", first})
    second_token = Subagent.action_token({"parent", second})
    state = with_conversation([first, second])
    opcode = Opcodes.gui_action_subagent_peek_action()
    payload = <<0, 2::16, 0::16, byte_size(first_token)::16, first_token::binary, 0::64>>

    assert {:ok, {:subagent_peek_action, :started, 2, "", ^first_token, {0, 0}}} =
             GUI.decode_gui_action(opcode, payload)

    opened = Peek.click(state, :started, 2, "", first_token, {0, 0})
    peek = opened.workspace.windows.active
    stepped = Peek.click(opened, :sibling, peek, first_token, second_token, {0, 0})

    assert %Window{content: {:subagent_peek, {2, {"parent", ^second}}}} =
             Windows.active_struct(stepped.workspace.windows)

    assert Peek.click(stepped, :brief, peek, first_token, "", {0, 0}) == stepped
    assert :error = GUI.decode_gui_action(opcode, payload <> <<0>>)
  end

  defp with_conversation(keys) do
    state = base_state(content: "another window")
    parent = self()

    snapshot = %ConnectionSnapshot{
      target: ConnectionTarget.new(parent, "parent", nil, make_ref()),
      credential_readiness: :checking,
      model_selection: nil,
      provider_phase: :running,
      operation: :idle,
      problem: nil
    }

    ui =
      state.workspace.agent_ui
      |> UIState.transition_chat({:conversation, parent})
      |> UIState.project_connection(snapshot)

    windows = state.workspace.windows
    {agent_id, windows} = Windows.allocate_id(windows)
    {:ok, tree} = WindowTree.split(windows.tree, 1, :vertical, agent_id)

    windows =
      windows
      |> Windows.set_tree(tree)
      |> Windows.add_window(Window.new_agent_chat(agent_id, 24, 80))

    workspace =
      state.workspace |> SessionState.set_windows(windows) |> SessionState.set_agent_ui(ui)

    state = %{state | workspace: workspace} |> WindowFocus.focus(agent_id)
    state = State.follow_agent_task(state, parent, 0, title: "Parent")
    state = State.observe_agent_task_event(state, parent, {:connection_changed, snapshot}, 0)

    keys
    |> Enum.with_index(1)
    |> Enum.reduce(state, fn {{_, _, call} = key, entry_id}, acc ->
      event = %ToolStart{
        tool_call_id: call,
        invocation_key: key,
        entry_id: entry_id,
        name: "subagent",
        args: %{"task" => "identical brief"}
      }

      State.observe_agent_task_event(acc, parent, {:tool_started, event}, 1)
    end)
  end
end
