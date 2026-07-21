defmodule MingaEditor.BufferFileIdentityTest do
  use ExUnit.Case, async: true

  alias Minga.Project.FileRef
  alias MingaEditor.BufferFileIdentity
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.FileTree
  alias MingaEditor.State.Tab
  alias MingaEditor.State.Tab.Context, as: TabContext
  alias MingaEditor.State.TabBar
  alias MingaEditor.Viewport

  @moduletag :tmp_dir

  test "rebinds every matching tab and workspace reference to the project path", %{tmp_dir: root} do
    path = Path.join(root, "lib/renamed.ex")
    buffer_ref = FileRef.from_buffer(self())

    context = %TabContext{
      present_fields: [:buffers],
      buffers: %Buffers{active: self(), list: [self()]}
    }

    first =
      Tab.new_file(1, "scratch")
      |> Tab.set_file_ref(buffer_ref)
      |> Tab.set_context(context)

    tab_bar = TabBar.new(first, root)
    {tab_bar, second} = TabBar.insert(tab_bar, :file, "second snapshot")

    second =
      second
      |> Tab.set_file_ref(buffer_ref)
      |> Tab.set_context(context)

    tab_bar =
      tab_bar
      |> TabBar.accept_tab(second)
      |> TabBar.add_workspace_file(0, buffer_ref)

    state = %EditorState{
      workspace: %SessionState{
        viewport: Viewport.new(80, 24),
        buffers: %Buffers{active: self(), list: [self()]},
        file_tree: %FileTree{project_root: root}
      },
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar})
    }

    rebound = BufferFileIdentity.rebind(state, self(), path)
    rebound_tab_bar = rebound.shell_runtime.state.tab_bar
    {:ok, expected} = FileRef.from_path(root, path)

    assert Enum.all?(rebound_tab_bar.tabs, &FileRef.equal?(&1.file_ref, expected))

    assert Enum.any?(
             TabBar.get_workspace(rebound_tab_bar, 0).files,
             &FileRef.equal?(&1, expected)
           )

    assert Enum.all?(tab_bar.tabs, &FileRef.equal?(&1.file_ref, buffer_ref))
  end

  test "falls back to buffer identity when the path is outside the project", %{tmp_dir: root} do
    tab = Tab.new_file(1, "scratch") |> Tab.set_file_ref(FileRef.from_buffer(self()))
    tab_bar = TabBar.new(tab, root)

    state = %EditorState{
      workspace: %SessionState{
        viewport: Viewport.new(80, 24),
        file_tree: %FileTree{project_root: root}
      },
      shell_runtime: Runtime.new(Runtime.default_entry(), %TraditionalState{tab_bar: tab_bar})
    }

    rebound = BufferFileIdentity.rebind(state, self(), "/outside/project.ex")

    assert %FileRef{kind: :buffer, buffer_pid: buffer_pid} =
             TabBar.active(rebound.shell_runtime.state.tab_bar).file_ref

    assert buffer_pid == self()
  end
end
