defmodule MingaEditor.UI.Picker.ContextArtifactSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Server, as: BufferServer
  alias MingaAgent.FileMention
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.State.Windows
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.ContextArtifactSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.Viewport
  alias MingaEditor.VimState
  alias MingaEditor.Window

  @moduletag :tmp_dir

  defp picker_context(project_root) do
    state = base_state()
    Context.from_editor_state(state, %{project_root: project_root})
  end

  defp base_state(opts \\ []) do
    buf = start_buffer(Keyword.get(opts, :content, "hello"))
    prompt_buf = start_buffer(Keyword.get(opts, :prompt, ""))

    agent_ui = %UIState{
      panel: %UIState.Panel{visible: true, input_focused: true, prompt_buffer: prompt_buf}
    }

    agent_tab = Tab.new_agent(1, "Agent")

    %EditorState{
      port_manager: nil,
      shell: MingaEditor.Shell.Traditional,
      terminal_viewport: Viewport.new(24, 80),
      workspace: %MingaEditor.Workspace.State{
        viewport: Viewport.new(24, 80),
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        },
        agent_ui: agent_ui
      },
      shell_state: %MingaEditor.Shell.Traditional.State{
        agent: %AgentState{},
        tab_bar: TabBar.new(agent_tab)
      }
    }
  end

  defp start_buffer(content) do
    start_supervised!(
      Supervisor.child_spec({BufferServer, content: content}, id: {BufferServer, make_ref()})
    )
  end

  defp write_artifact(project_root, filename, content \\ "summary") do
    context_dir = Path.join(project_root, ".minga/context")
    File.mkdir_p!(context_dir)
    path = Path.join(context_dir, filename)
    File.write!(path, content)
    path
  end

  describe "candidates/1" do
    test "lists context artifacts as mentionable relative paths", %{tmp_dir: dir} do
      write_artifact(dir, "session-summary-abc123-2026-05-09.md")

      assert [%Item{} = item] = ContextArtifactSource.candidates(picker_context(dir))
      assert item.id == ".minga/context/session-summary-abc123-2026-05-09.md"
      assert item.label == "session-summary-abc123-2026-05-09"
      assert item.description == ".minga/context"
    end

    test "ignores non-session markdown files", %{tmp_dir: dir} do
      write_artifact(dir, "session-summary-good.md")
      write_artifact(dir, "other.md")

      items = ContextArtifactSource.candidates(picker_context(dir))

      assert Enum.map(items, & &1.id) == [".minga/context/session-summary-good.md"]
    end

    test "returns no candidates when there are no artifacts", %{tmp_dir: dir} do
      assert ContextArtifactSource.candidates(picker_context(dir)) == []
    end
  end

  describe "on_select/2" do
    test "inserts an artifact @mention into an empty prompt" do
      state = base_state()
      item = %Item{id: ".minga/context/session-summary-abc123.md", label: "summary"}

      new_state = ContextArtifactSource.on_select(item, state)

      assert UIState.input_text(AgentAccess.panel(new_state)) ==
               "@.minga/context/session-summary-abc123.md "

      assert AgentAccess.input_focused?(new_state)
    end

    test "inserts at the prompt cursor and preserves existing text" do
      state = base_state(prompt: "please  now")
      BufferServer.set_cursor(AgentAccess.panel(state).prompt_buffer, {0, 7})
      item = %Item{id: ".minga/context/session-summary-abc123.md", label: "summary"}

      new_state = ContextArtifactSource.on_select(item, state)

      assert UIState.input_text(AgentAccess.panel(new_state)) ==
               "please @.minga/context/session-summary-abc123.md  now"
    end

    test "inserted mention resolves through FileMention", %{tmp_dir: dir} do
      write_artifact(dir, "session-summary-abc123.md", "## Decisions\n- Keep writer")
      state = base_state(prompt: "continue from ")
      item = %Item{id: ".minga/context/session-summary-abc123.md", label: "summary"}

      new_state = ContextArtifactSource.on_select(item, state)
      prompt = UIState.prompt_text(AgentAccess.panel(new_state))

      assert {:ok, resolved} = FileMention.resolve_prompt(prompt, dir)
      assert resolved =~ "Contents of .minga/context/session-summary-abc123.md:"
      assert resolved =~ "Keep writer"
      assert resolved =~ "continue from"
    end
  end
end
