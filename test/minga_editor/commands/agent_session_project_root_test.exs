defmodule MingaEditor.Commands.AgentSessionProjectRootTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project.FileRef
  alias MingaAgent.ProjectView
  alias MingaAgent.Providers.RecordingProvider
  alias MingaAgent.Session
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Commands.AgentSession
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State.TabBar
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentConnection
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Frontend
  alias MingaEditor.State.Interaction
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Windows
  alias MingaEditor.VimState
  alias MingaEditor.Window
  alias MingaEditor.State.Workspace.Agent, as: WorkspaceAgent

  @moduletag :tmp_dir

  test "an agent session started from the editor is rooted at the editor's project, not the launch directory",
       %{tmp_dir: dir} do
    project = Path.join(Path.expand(dir), "project")
    File.mkdir_p!(project)
    notes = Path.join(project, "notes.md")
    File.write!(notes, "project notes\n")

    refute project == File.cwd!()

    state = AgentSession.start_catalog_ready(editor_state(project, notes), false, false)
    session = started_session(state)
    on_exit(fn -> MingaAgent.SessionManager.stop_session_by_pid(session) end)

    assert {:ok, %{project_root: ^project, project_view: %ProjectView{} = view}} =
             RecordingProvider.get_state(Session.get_provider(session))

    on_exit(fn -> ProjectView.close(view) end)
    assert view.project_root == project
    assert ProjectView.read_file(view, "notes.md") == {:ok, "project notes\n"}
  end

  @spec editor_state(String.t(), String.t()) :: EditorState.t()
  defp editor_state(project, notes) do
    buf = start_supervised!({BufferProcess, content: File.read!(notes), file_path: notes})
    prompt = start_supervised!({BufferProcess, content: ""}, id: :prompt)
    source_ref = FileRef.from_buffer(buf)

    tab_bar =
      Tab.new_file(1, FileRef.display_label(source_ref))
      |> Tab.set_file_ref(source_ref)
      |> TabBar.new()
      |> TabBar.add_workspace_file(0, source_ref)

    agent_ui = %UIState{panel: %UIState.Panel{prompt_buffer: prompt}}

    %EditorState{
      frontend: %Frontend{port_manager: nil},
      agent_connection: AgentConnection.new(RecordingProvider, test_pid: self()),
      workspace: %MingaEditor.Session.State{
        editing: VimState.new(),
        buffers: %Buffers{active: buf, list: [buf], active_index: 0},
        windows: %Windows{
          tree: {:leaf, 1},
          map: %{1 => Window.new(1, buf, 24, 80)},
          active: 1,
          next_id: 2
        },
        file_tree: FileTree.set_project_root(%FileTree{}, project),
        agent_ui: agent_ui
      },
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.install_tab_bar(%TraditionalState{}, tab_bar)
        ),
      interaction: %Interaction{}
    }
  end

  @spec started_session(EditorState.t()) :: pid()
  defp started_session(state) do
    assert [%{payload: %WorkspaceAgent{session: session}}] =
             Enum.filter(state.shell_runtime.state.tab_bar.workspaces, &(&1.kind == :agent))

    assert is_pid(session)
    session
  end
end
