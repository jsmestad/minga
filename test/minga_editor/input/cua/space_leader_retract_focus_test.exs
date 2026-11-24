defmodule MingaEditor.Input.CUA.SpaceLeaderRetractFocusTest do
  @moduledoc """
  A GUI space-leader retract removes the space only from the surface that took it and never edits a file buffer hidden behind the focused surface.

  In CUA mode the macOS frontend holds SPC for a short grace period. When SPC stays down longer, it sends the space as an ordinary key, which the focused surface handles, and sends `space_leader_retract` with the next key. Agent chat navigation and a focused bottom panel drop that space, so the retract must leave the file alone; a focused composer took it, so the retract removes it there. The cursor sits at the end of the file, so a retraction from the wrong buffer would delete a real character.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaEditor.Agent.PromptBuffer
  alias MingaEditor.Agent.UIState
  alias MingaEditor.BottomPanel
  alias MingaEditor.Commands
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.FocusOwner
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.Shell.Traditional.Workflow
  alias MingaEditor.Sidebar.BuiltinSurfaces

  @moduletag :tmp_dir

  test "on the focused file buffer, SPC held into f f retracts the space and opens find-file",
       %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)

    held_space_then(ctx, ?f)
    assert leader_prefix_open?(ctx)
    send_keys_sync(ctx, "f")

    assert picker_open?(ctx)
    refute leader_prefix_open?(ctx)
    assert buffer_content(ctx) == "focus"
  end

  test "a clean SPC f chord followed by f opens find-file without typing into the file", %{
    tmp_dir: dir
  } do
    ctx = cua_gui_editor(dir)

    send_gui_action(ctx, {:space_leader_chord, ?f, 0})
    send_keys_sync(ctx, "f")

    assert picker_open?(ctx)
    assert buffer_content(ctx) == "focus"
  end

  test "a key outside the open leader group closes it and reaches the file", %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)

    held_space_then(ctx, ?f)
    send_keys_sync(ctx, "z")

    refute leader_prefix_open?(ctx)
    refute picker_open?(ctx)
    assert buffer_content(ctx) == "focusz"
  end

  for {surface, focus} <- [
        agent_chat: &__MODULE__.focus_agent_chat/1,
        bottom_panel: &__MODULE__.focus_bottom_panel/1
      ] do
    test "on a focused #{surface}, SPC held into f f opens find-file and leaves the hidden file unchanged",
         %{tmp_dir: dir} do
      ctx = cua_gui_editor(dir)
      :sys.replace_state(ctx.editor, unquote(focus))

      held_space_then(ctx, ?f)
      send_keys_sync(ctx, "f")

      assert picker_open?(ctx)
      assert buffer_content(ctx) == "focus"
    end
  end

  test "on a focused composer, SPC held into f f removes the space from the draft and opens find-file",
       %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)
    :sys.replace_state(ctx.editor, &focus_composer/1)

    held_space_then(ctx, ?f)
    send_keys_sync(ctx, "f")

    assert picker_open?(ctx)
    assert buffer_content(ctx) == "focus"
    assert PromptBuffer.prompt_text(editor_state(ctx).workspace.agent_ui) == ""
  end

  test "focus that moves back to the file between the space and the retract leaves the file unchanged",
       %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)
    :sys.replace_state(ctx.editor, &focus_agent_chat/1)

    send_keys_sync(ctx, "<SPC>")

    :sys.replace_state(ctx.editor, fn state ->
      %{state | workspace: SessionState.set_keymap_scope(state.workspace, :editor)}
    end)

    send_gui_action(ctx, {:space_leader_retract, ?f, 0})
    send_keys_sync(ctx, "f")

    assert picker_open?(ctx)
    assert buffer_content(ctx) == "focus"
  end

  test "on a focused BEAM Observatory sidebar, SPC held into f leaves the file unchanged", %{
    tmp_dir: dir
  } do
    ctx = cua_gui_editor(dir)
    :ok = BuiltinSurfaces.sync_observatory(true, ctx.sidebar_registry)
    assert %{input_handler: nil, focused?: true} = Sidebar.active_left(ctx.sidebar_registry)

    held_space_then(ctx, ?f)

    assert buffer_content(ctx) == "focus"
  end

  test "a mouse event between the space and the retract makes the next key plain text", %{
    tmp_dir: dir
  } do
    ctx = cua_gui_editor(dir)

    send_keys_sync(ctx, "<SPC>")
    send_mouse(ctx, editor_row(ctx), 2, :left)
    send_gui_action(ctx, {:space_leader_retract, ?f, 0})

    # The space stays and f is typed as text wherever the click left the cursor.
    assert String.length(buffer_content(ctx)) == String.length("focus f")
    refute leader_prefix_open?(ctx)
  end

  test "a cursor that moved off the space keeps the file's characters", %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)

    send_keys_sync(ctx, "<SPC>")
    Minga.Buffer.move_to(ctx.buffer, {0, 3})
    send_gui_action(ctx, {:space_leader_retract, ?f, 0})

    assert buffer_content(ctx) == "focus "
  end

  test "on a focused file tree, SPC held into f leaves the file unchanged", %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)
    :sys.replace_state(ctx.editor, &Commands.execute(&1, :toggle_file_tree))
    assert %{surface: :file_tree} = FocusOwner.derive(editor_state(ctx))

    held_space_then(ctx, ?f)

    assert buffer_content(ctx) == "focus"
  end

  test "with a picker open, SPC held into f types both keys into the query", %{tmp_dir: dir} do
    ctx = cua_gui_editor(dir)
    :sys.replace_state(ctx.editor, &Commands.execute(&1, :find_file))
    query = picker_state(ctx).query

    held_space_then(ctx, ?f)

    assert picker_state(ctx).query == query <> " f"
    assert buffer_content(ctx) == "focus"
  end

  # The grace period expired, so the frontend sent the space as a key, then the
  # next key arrived while SPC was still down.
  defp held_space_then(ctx, codepoint) do
    send_keys_sync(ctx, "<SPC>")
    send_gui_action(ctx, {:space_leader_retract, codepoint, 0})
  end

  # The first row of the editor body, below the tab bar the headless port stacks above it.
  defp editor_row(ctx), do: Minga.Test.HeadlessPort.editor_row_offset(ctx.port)

  defp leader_prefix_open?(ctx),
    do: Runtime.state(editor_state(ctx).shell_runtime).whichkey.node != nil

  @doc false
  @spec focus_agent_chat(MingaEditor.State.t()) :: MingaEditor.State.t()
  def focus_agent_chat(state) do
    refute state.workspace.agent_ui.panel.input_focused
    %{state | workspace: SessionState.set_keymap_scope(state.workspace, :agent)}
  end

  @doc false
  @spec focus_bottom_panel(MingaEditor.State.t()) :: MingaEditor.State.t()
  def focus_bottom_panel(state) do
    shell_state = Runtime.state(state.shell_runtime)
    panel = shell_state.bottom_panel |> BottomPanel.show() |> BottomPanel.focus()
    shell_state = TraditionalState.install_bottom_panel(shell_state, panel)
    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
  end

  defp focus_composer(state) do
    agent_ui =
      state.workspace.agent_ui
      |> UIState.toggle()
      |> PromptBuffer.set_input_focused(true)

    state
    |> focus_agent_chat()
    |> Workflow.install_agent_ui(agent_ui)
  end

  defp cua_gui_editor(dir) do
    path = Path.join(dir, "focus.txt")
    File.write!(path, "focus")
    options = start_supervised!(Supervisor.child_spec({Options, name: nil}, id: make_ref()))

    ctx =
      start_editor("focus",
        file_path: path,
        project_root: dir,
        editing_model: :cua,
        options_server: options
      )

    Minga.Buffer.move_to(ctx.buffer, {0, 5})
    ctx
  end
end
