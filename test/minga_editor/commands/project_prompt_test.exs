defmodule MingaEditor.Commands.ProjectPromptTest do
  # Mutates the global Minga.Project known-projects GenServer.
  use Minga.Test.EditorCase, async: false

  alias Minga.Project
  alias MingaEditor.Commands
  alias MingaEditor.MinibufferData
  alias MingaEditor.PromptUI
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Prompt, as: PromptState
  alias MingaEditor.UI.Prompt.ProjectRemoveConfirm
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defp temp_project_dir do
    Path.join(
      System.tmp_dir!(),
      "minga-project-remove-#{System.unique_integer([:positive])}"
    )
  end

  defp no_buffer_state do
    %EditorState{
      port_manager: nil,
      workspace: %SessionState{
        viewport: Viewport.new(24, 80),
        buffers: %Buffers{active: nil, list: []},
        editing: VimState.new()
      }
    }
  end

  defp clear_editor_buffers(ctx) do
    :sys.replace_state(ctx.editor, fn state ->
      state
      |> EditorState.set_buffers(%Buffers{active: nil, list: [], active_index: 0})
      |> EditorState.sync_active_window_buffer()
    end)

    ctx
  end

  describe "SPC p d" do
    setup do
      project = temp_project_dir()
      File.mkdir_p!(project)

      on_exit(fn ->
        Project.remove(project)
        File.rm_rf(project)
      end)

      Project.add(project)
      assert project in Project.known_projects()

      %{project: project}
    end

    test "opens known projects picker and confirms removal", %{project: project} do
      ctx = start_editor("")
      state = send_keys_sync(ctx, "<SPC>pd<CR>")

      assert %{
               shell_state: %{
                 modal:
                   {:prompt,
                    %{
                      prompt_ui: %{
                        handler: MingaEditor.UI.Prompt.ProjectRemoveConfirm,
                        context: %{path: ^project}
                      }
                    }}
               }
             } = state

      _state = send_keys_sync(ctx, "y<CR>")
      refute project in Project.known_projects()
    end

    test "SPC p d opens the removal picker without an active buffer", %{project: project} do
      ctx = start_editor("") |> clear_editor_buffers()

      state = send_keys_sync(ctx, "<SPC>pd")

      assert %{
               shell_state: %{
                 modal:
                   {:picker,
                    %{
                      picker_ui: %{
                        source: MingaEditor.UI.Picker.ProjectRemoveSource
                      }
                    }}
               }
             } = state

      assert project in Project.known_projects()
    end

    test "project_remove command opens the removal picker without an active buffer", %{
      project: project
    } do
      state = Commands.execute(no_buffer_state(), :project_remove)

      assert %{
               shell_state: %{
                 modal:
                   {:picker,
                    %{
                      picker_ui: %{
                        source: MingaEditor.UI.Picker.ProjectRemoveSource
                      }
                    }}
               }
             } = state

      assert project in Project.known_projects()
    end

    test "typing n cancels project removal and leaves the project intact", %{project: project} do
      state =
        no_buffer_state()
        |> PromptUI.open(ProjectRemoveConfirm, context: %{path: project})

      {state, nil} = PromptUI.handle_key(state, ?n, 0)
      {state, nil} = PromptUI.handle_key(state, 13, 0)

      assert state.shell_state.status_msg == "Project removal cancelled"
      assert project in Project.known_projects()
      refute PromptUI.open?(state)
    end
  end

  describe "SPC p a" do
    test "opens the add-project prompt from a leader sequence" do
      ctx = start_editor("")

      state = send_keys_sync(ctx, "<SPC>pa")

      assert %{
               shell_state: %{
                 modal:
                   {:prompt,
                    %{prompt_ui: %PromptState{handler: MingaEditor.UI.Prompt.ProjectAdd}}}
               }
             } = state
    end

    test "renders the add-project prompt in the TUI minibuffer" do
      ctx = start_editor("")

      _state = send_keys_sync(ctx, "<SPC>pa")
      sync_screen(ctx)

      assert_minibuffer_contains(ctx, "Add project: ")
    end

    test "exposes the add-project prompt through GUI minibuffer data" do
      ctx = start_editor("")

      state = send_keys_sync(ctx, "<SPC>pa")
      minibuffer = MinibufferData.from_state(state)

      assert minibuffer.visible == true
      assert minibuffer.mode == 10
      assert minibuffer.prompt == "Add project: "
      assert minibuffer.cursor_pos == String.length(minibuffer.input)
    end
  end
end
