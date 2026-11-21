defmodule MingaEditor.Session.AgentPresentationTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias MingaEditor.Agent.DiffReview
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Agent.UIState.View
  alias MingaEditor.Agent.View.Preview
  alias MingaEditor.Session.State
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: ShellState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.TabWorkflow
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  test "body transitions cover every window kind without converting human or empty windows" do
    chat = Window.new_agent_chat(1, 24, 80)
    review = Window.show_agent_body(chat, :review)
    human = Window.new(2, self(), 24, 80)
    empty = Window.new_empty_state(3, 24, 80)

    for {window, body, expected} <- [
          {chat, :chat, {:agent_chat, :semantic}},
          {chat, :review, {:agent_review, :semantic}},
          {review, :chat, {:agent_chat, :semantic}},
          {review, :review, {:agent_review, :semantic}},
          {human, :chat, human.content},
          {human, :review, human.content},
          {empty, :chat, empty.content},
          {empty, :review, empty.content}
        ] do
      presented = Window.show_agent_body(window, body)
      assert presented.content == expected
      assert presented.id == window.id
      assert presented.viewport == window.viewport

      if expected == window.content do
        assert presented == window
      else
        refute presented.accessibility_generation == window.accessibility_generation
      end
    end
  end

  test "UI installation preserves human focus and frozen review identity through observation and chat return" do
    human = Window.new(1, self(), 24, 80)
    chat = Window.new_agent_chat(2, 24, 80)
    {:ok, tree} = WindowTree.split(WindowTree.new(1), 1, :vertical, 2)
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
    prompt = start_supervised!({BufferProcess, content: "keep this draft"})
    ui = UIState.new() |> UIState.attach_prompt_buffer(prompt) |> UIState.replace_preview(preview)

    workspace = %State{
      keymap_scope: :file_tree,
      buffers: %Buffers{active: self(), list: [self()]},
      windows: %Windows{tree: tree, map: %{1 => human, 2 => chat}, active: 1, next_id: 3},
      agent_ui: ui
    }

    reviewing = State.set_agent_ui(workspace, UIState.set_focus(ui, :file_viewer))
    review_window = reviewing.windows.map[2]
    assert review_window.content == {:agent_review, :semantic}
    assert reviewing.windows.map[1] == human
    assert reviewing.windows.active == 1
    assert reviewing.windows.tree == tree
    assert %{reviewing | agent_ui: workspace.agent_ui, windows: workspace.windows} == workspace

    stale = Preview.refresh_after_write(preview, "selected.ex")
    {:ok, observed} = Preview.observe_review(stale, Preview.review_source(stale), 100, 8)
    stale_ui = UIState.replace_preview(reviewing.agent_ui, observed)
    refreshed = State.set_agent_ui(reviewing, UIState.toggle_help(stale_ui))
    assert refreshed.windows.map[2] == review_window
    assert View.agent_body(refreshed.agent_ui.view) == :review

    input_ui = UIState.set_input_focused(stale_ui, true)
    returned = State.set_agent_ui(refreshed, input_ui)
    assert returned.windows.map[2].content == {:agent_chat, :semantic}
    assert returned.windows.map[1] == human
    assert returned.windows.active == 1
    assert View.focus(returned.agent_ui.view) == :chat
    assert returned.agent_ui.view.preview == observed
    assert returned.agent_ui.panel.prompt_buffer == prompt
    assert Buffer.content(prompt) == "keep this draft"

    released = UIState.set_input_focused(input_ui, false)
    assert View.agent_body(released.view) == :chat
    assert {:ok, selected_again} = UIState.switch_focus(released)
    resumed = State.set_agent_ui(returned, selected_again)
    assert resumed.windows.map[2].content == {:agent_review, :semantic}
    assert resumed.agent_ui.view.preview == observed
    refute resumed.agent_ui.panel.input_focused
    assert resumed.windows.map[1] == human
  end

  test "the last resolution returns to chat while a remaining hunk keeps the review" do
    review = DiffReview.new("selected.ex", "before", "after")

    view =
      View.new()
      |> View.replace_preview(Preview.set_diff(Preview.new(), review))
      |> View.set_focus(:file_viewer)

    for action <- [:accept_current, :reject_current, :accept_all, :reject_all] do
      assert {:ok, completed, _write} = View.resolve_diff_review(view, action)
      assert View.agent_body(completed) == :chat
      assert View.focus(completed) == :chat
      assert Preview.empty?(completed.preview)
    end

    before = Enum.map_join(1..20, "\n", &"line #{&1}")

    after_content =
      before
      |> String.replace("line 1\n", "first changed\n")
      |> String.replace("line 20", "last changed")

    review = DiffReview.new("selected.ex", before, after_content)
    view = View.replace_preview(view, Preview.set_diff(Preview.new(), review))
    assert {:ok, incomplete, :no_write} = View.resolve_diff_review(view, :accept_current)
    assert View.agent_body(incomplete) == :review
    assert View.focus(incomplete) == :file_viewer
  end

  test "restoring a saved Agent UI keeps its review focus and normalizes incoming pane content" do
    preview = Preview.set_diff(Preview.new(), DiffReview.new("selected.ex", "before", "after"))
    stale = Preview.refresh_after_write(preview, "selected.ex")

    saved =
      UIState.new()
      |> UIState.replace_preview(stale)
      |> UIState.set_focus(:file_viewer)

    {tab_bar, group} =
      Tab.new_agent(1, "Agent")
      |> TabBar.new(__DIR__)
      |> TabBar.add_workspace("Agent")

    tab_bar =
      tab_bar
      |> TabBar.move_tab_to_workspace(1, group.id)
      |> TabBar.set_workspace_agent_ui(group.id, saved)

    chat = Window.new_agent_chat(1, 24, 80)

    state = %EditorState{
      workspace: %State{
        keymap_scope: :agent,
        windows: %Windows{tree: WindowTree.new(1), map: %{1 => chat}, active: 1, next_id: 2}
      },
      shell_runtime:
        Runtime.new(Runtime.default_entry(), ShellState.install_tab_bar(%ShellState{}, tab_bar))
    }

    restored = TabWorkflow.sync_active_workspace_agent_ui(state)
    assert restored.workspace.windows.map[1].content == {:agent_review, :semantic}
    assert restored.workspace.windows.active == 1
    assert restored.workspace.agent_ui.view.preview == stale
    assert View.focus(restored.workspace.agent_ui.view) == :file_viewer
    refute restored.workspace.agent_ui.panel.input_focused

    # The payload was transferred. A later context restore must use the live UI.
    repeated = TabWorkflow.sync_active_workspace_agent_ui(restored)
    assert repeated.workspace.windows == restored.workspace.windows
    assert repeated.workspace.agent_ui == restored.workspace.agent_ui

    incoming = %{restored | workspace: State.replace_window(restored.workspace, 1, chat)}
    normalized = TabWorkflow.sync_active_workspace_agent_ui(incoming)
    assert normalized.workspace.agent_ui == restored.workspace.agent_ui
    assert normalized.workspace.windows.map[1].content == {:agent_review, :semantic}
  end

  test "focus switching reports a missing review without creating a blank viewer" do
    ui = UIState.new()
    assert UIState.switch_focus(ui) == {:error, :no_review}
    assert View.agent_body(ui.view) == :chat
  end
end
