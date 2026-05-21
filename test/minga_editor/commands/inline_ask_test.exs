defmodule MingaEditor.Commands.InlineAskTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer
  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Keymap.Bindings
  alias Minga.Keymap.Defaults
  alias MingaEditor.Commands.InlineAsk, as: InlineAskCommand
  alias MingaEditor.Input.InlineAsk, as: InlineAskInput
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree, as: FileTreeState
  alias MingaEditor.State.InlineAsk
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.Viewport
  alias MingaEditor.Window
  alias MingaEditor.WindowTree

  @moduletag :tmp_dir

  test "open stores an ask for the active buffer", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex")

    state = InlineAskCommand.open(state)

    assert %InlineAsk{file_label: "auth.ex", anchor_line: 0, prompt: "", context_text: "hello"} =
             active_ask(state, buffer)
  end

  test "input handler edits and dismisses the active ask", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex")
    state = InlineAskCommand.open(state)

    original_content = Buffer.content(buffer)
    original_workspace_count = length(state.shell_state.tab_bar.workspaces)

    assert {:handled, state} = InlineAskInput.handle_key(state, ?w, 0)
    assert {:handled, state} = InlineAskInput.handle_key(state, ?h, 0)
    assert active_ask(state, buffer).prompt == "wh"

    assert {:handled, state} = InlineAskInput.handle_key(state, 127, 0)
    assert active_ask(state, buffer).prompt == "w"

    assert {:handled, state} = InlineAskInput.handle_key(state, 27, 0)
    assert active_ask(state, buffer) == nil
    assert Buffer.content(buffer) == original_content
    assert length(state.shell_state.tab_bar.workspaces) == original_workspace_count
  end

  test "input handler ignores modified printable keys", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex")
    state = InlineAskCommand.open(state)

    assert {:handled, state} = InlineAskInput.handle_key(state, ?s, 0x02)
    assert active_ask(state, buffer).prompt == ""

    assert {:handled, state} = InlineAskInput.handle_key(state, ?s, 0x04)
    assert active_ask(state, buffer).prompt == ""

    assert {:handled, state} = InlineAskInput.handle_key(state, ?s, 0x08)
    assert active_ask(state, buffer).prompt == ""

    assert {:handled, state} = InlineAskInput.handle_key(state, ?S, 0x01)
    assert active_ask(state, buffer).prompt == "S"
  end

  test "enter submits through an injected ephemeral session asker", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex")
    state = InlineAskCommand.open(state)
    assert {:handled, state} = InlineAskInput.handle_key(state, ?w, 0)
    parent = self()

    asker = fn prompt, project_root, opts ->
      send(parent, {:asked, prompt, project_root, opts})
      {:ok, parent}
    end

    assert {:handled, state} = InlineAskInput.handle_key(state, 13, 0, session_asker: asker)
    assert_receive {:asked, prompt, ^root, opts}
    assert prompt =~ "Question:\nw"
    assert Keyword.get(opts, :subscriber) == self()
    assert %InlineAsk{status: :thinking, session_pid: ^parent} = active_ask(state, buffer)
  end

  test "SPC a ? is bound and inline ask is an overlay handler" do
    assert {:prefix, ai_node} = Bindings.lookup(Defaults.leader_trie(), {?a, 0})
    assert {:command, :inline_ask} = Bindings.lookup(ai_node, {??, 0})
    assert MingaEditor.Input.InlineAsk in MingaEditor.Input.overlay_handlers()
  end

  test "asks are independent per buffer", %{tmp_dir: root} do
    {state, first} = state_with_file(root, "lib/one.ex")
    second_path = Path.join(root, "lib/two.ex")
    File.write!(second_path, "two")

    second =
      start_supervised!({BufferProcess, content: "two", file_path: second_path},
        id: {:inline_ask_buffer, second_path}
      )

    state = InlineAskCommand.open(state)
    state = put_active_buffer(state, second)
    state = InlineAskCommand.open(state)

    assert active_ask(state, first).file_label == "one.ex"
    assert active_ask(state, second).file_label == "two.ex"

    assert {:handled, state} = InlineAskInput.handle_key(state, 27, 0)
    assert active_ask(state, first) != nil
    assert active_ask(state, second) == nil
  end

  test "visual selection is reflected in the ask header", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex", "one\ntwo\nthree")
    Buffer.move_to(buffer, {2, 0})

    state = put_visual_selection(state, {0, 0})
    state = InlineAskCommand.open(state)

    assert %InlineAsk{} = ask = active_ask(state, buffer)
    assert InlineAsk.header(ask) == "Ask about lines 1–3 of auth.ex"
    assert ask.context_text == "one\ntwo\nthree"
    assert InlineAsk.agent_prompt(ask) =~ "File: lib/auth.ex"
    assert InlineAsk.agent_prompt(ask) =~ "Relevant text:\none\ntwo\nthree"
  end

  test "promote creates an agent workspace with the file and seeded chat", %{tmp_dir: root} do
    {state, buffer} = state_with_file(root, "lib/auth.ex")
    state = InlineAskCommand.open(state)

    ask =
      state
      |> active_ask(buffer)
      |> InlineAsk.append_input("What is this?")
      |> InlineAsk.append_response("It authenticates users.")
      |> InlineAsk.answered()

    parent = self()

    state =
      InlineAskCommand.promote(state, ask,
        session_starter: &fake_start_agent_session/1,
        seeder: fn seed_state, seed_ask ->
          send(parent, {:seeded, seed_ask.prompt, seed_ask.response})
          seed_state
        end
      )

    assert_receive {:seeded, "What is this?", "It authenticates users."}
    assert active_ask(state, buffer) == nil
    assert %{shell_state: %{tab_bar: tb}} = state
    assert %{kind: :agent} = TabBar.active(tb)
    assert workspace = TabBar.active_workspace(tb)
    assert Enum.any?(workspace.files, &(&1.display_name == "auth.ex"))

    assert %{content: {:agent_chat, _agent_buffer}} =
             state.workspace.windows.map[state.workspace.windows.active]
  end

  defp state_with_file(root, rel_path, content \\ "hello") do
    path = Path.join(root, rel_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    {:ok, buffer} = start_supervised({BufferProcess, content: content, file_path: path})

    state = %EditorState{
      port_manager: self(),
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        file_tree: %FileTreeState{project_root: root},
        buffers: %Buffers{active: buffer, list: [buffer], active_index: 0},
        windows: %Windows{
          tree: WindowTree.new(1),
          map: %{1 => Window.new(1, buffer, 24, 80)},
          active: 1,
          next_id: 2
        }
      },
      shell_state: %TraditionalState{
        tab_bar: TabBar.new(Tab.new_file(1, Path.basename(rel_path)), root)
      }
    }

    {state, buffer}
  end

  defp active_ask(state, buffer) do
    state |> EditorState.inline_asks() |> InlineAsk.active(buffer)
  end

  defp put_active_buffer(state, buffer) do
    %Buffers{} = buffers = state.workspace.buffers

    workspace = %{
      state.workspace
      | buffers: %{buffers | active: buffer, list: Enum.uniq([buffer | buffers.list])}
    }

    %{state | workspace: workspace}
  end

  defp fake_start_agent_session(%{shell_state: %{tab_bar: %TabBar{} = tb}} = state) do
    session_pid = self()
    active_tab = TabBar.active(tb)
    {tb, workspace} = TabBar.add_workspace(tb, "Inline Ask", session_pid)

    tb =
      tb
      |> TabBar.update_tab(active_tab.id, &Tab.set_session(&1, session_pid))
      |> TabBar.move_tab_to_workspace(active_tab.id, workspace.id)

    EditorState.set_tab_bar(state, tb)
  end

  defp put_visual_selection(state, anchor) do
    visual = %Minga.Mode.VisualState{visual_type: :char, visual_anchor: anchor}

    %{
      state
      | workspace: %{
          state.workspace
          | editing: MingaEditor.VimState.transition(state.workspace.editing, :visual, visual)
        }
    }
  end
end
