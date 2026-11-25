defmodule MingaEditor.ProjectHomeTest do
  @moduledoc """
  The project home, `*home*`, in the running editor: a resting view where `q` does nothing, number keys open recent files, `SPC p h` brings it back over open buffers without letting keys reach a hidden buffer, and `SPC q n` starts fresh into it.
  """

  use Minga.Test.EditorCase, async: true

  alias MingaEditor.Input.EmptyState, as: HomeInput

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "defmodule P.MixProject do\nend\n")
    File.write!(Path.join(root, "lib/a.ex"), "alpha\nbeta\n")
    File.write!(Path.join(root, "lib/b.ex"), "bravo\n")
    %{root: root}
  end

  defp open_home(ctx) do
    start_editor("",
      empty: true,
      project_root: ctx.root,
      home: [place: :project, recents: ["lib/a.ex"], git: nil],
      rendering: :disabled
    )
  end

  defp showing_home?(editor), do: editor |> editor_state() |> HomeInput.showing_home?()

  test "a project opens on its home, and q does nothing there", ctx do
    editor = open_home(ctx)
    assert showing_home?(editor)

    send_keys_sync(editor, "q")

    assert showing_home?(editor)
    assert editor_state(editor).workspace.buffers.list == []
  end

  test "1 opens the first recent file in place of the home", ctx do
    editor = open_home(ctx)

    send_keys_sync(editor, "1")

    refute showing_home?(editor)
    state = editor_state(editor)

    assert Minga.Buffer.file_path(state.workspace.buffers.active) ==
             Path.join(ctx.root, "lib/a.ex")
  end

  test "SPC p h shows the home over open buffers, and editing keys never reach them", ctx do
    editor = open_home(ctx)
    send_keys_sync(editor, "1")
    buffer = editor_state(editor).workspace.buffers.active

    send_keys_sync(editor, "<Space>ph")
    assert showing_home?(editor)

    send_keys_sync(editor, "ddx")
    send_keys_sync(editor, "<Space>fs")

    assert Minga.Buffer.content(buffer) == "alpha\nbeta\n"
    refute Minga.Buffer.dirty?(buffer)
    assert showing_home?(editor)

    # Opening the file again replaces the home with the same buffer.
    send_keys_sync(editor, ":e #{Path.join(ctx.root, "lib/a.ex")}<CR>")
    refute showing_home?(editor)
    assert editor_state(editor).workspace.buffers.active == buffer
  end

  test "j moves the focus and Enter opens the focused row", ctx do
    editor = open_home(ctx)
    assert editor_state(editor).workspace.launchpad.focused_id == "recent-1"

    send_keys_sync(editor, "jk")
    assert editor_state(editor).workspace.launchpad.focused_id == "recent-1"

    send_keys_sync(editor, "<CR>")
    refute showing_home?(editor)
  end

  test "a click on a row opens it, as its key does", ctx do
    editor = open_home(ctx)

    send(editor.editor, {:minga_input, {:gui_action, {:empty_state_activate, "recent-1"}}})

    refute showing_home?(editor)
  end

  test "SPC q n starts fresh into the home", ctx do
    editor = open_home(ctx)
    send_keys_sync(editor, "1")

    send_keys_sync(editor, "<Space>qn")

    assert showing_home?(editor)
    assert editor_state(editor).workspace.buffers.list == []
  end

  test "a file argument that cannot be opened says why instead of showing the home in silence",
       ctx do
    editor =
      start_editor("",
        empty: true,
        startup_file: Path.join(ctx.root, "lib"),
        project_root: ctx.root,
        rendering: :disabled
      )

    assert notice_message(editor) =~ ~r/^Could not open .*lib: /
  end

  test "a file argument that does not exist says so", ctx do
    path = Path.join(ctx.root, "lib/new.ex")

    editor =
      start_editor("",
        empty: true,
        startup_file: path,
        project_root: ctx.root,
        rendering: :disabled
      )

    assert notice_message(editor) == "Could not open #{path}: no such file or directory"
  end

  for command <-
        ~w(%s/alpha/X/ w x wq sort g/alpha/d normal\ dd 1 e! set\ ft=ruby bn bp close) do
    test "`:#{command}` on the home leaves the files behind it alone", ctx do
      editor = open_home(ctx)
      send_keys_sync(editor, "1")
      buffer = editor_state(editor).workspace.buffers.active
      Minga.Buffer.insert_text(buffer, "edited ")
      send_keys_sync(editor, "<Space>ph")

      send_keys_sync(editor, ":#{unquote(command)}<CR>")

      assert Minga.Buffer.content(buffer) == "edited alpha\nbeta\n"
      assert Minga.Buffer.dirty?(buffer)
      assert showing_home?(editor)
    end
  end

  test "quitting from the home still warns about a modified file behind it", ctx do
    editor = open_home(ctx)
    send_keys_sync(editor, "1")
    Minga.Buffer.insert_text(editor_state(editor).workspace.buffers.active, "edited ")
    send_keys_sync(editor, "<Space>ph")

    send_keys_sync(editor, ":q<CR>")

    assert notice_message(editor) =~ "Modified buffers exist"
  end

  test "the session saved from the home keeps the splits of the tab behind it", ctx do
    editor = open_home(ctx)
    send_keys_sync(editor, "1")
    send_keys_sync(editor, ":vsplit<CR>")
    send_keys_sync(editor, "<Space>ph")

    snapshot = editor |> editor_state() |> MingaEditor.Session.Capture.snapshot()

    assert [_, _] = Minga.Session.Layout.panes(snapshot.layout)
    assert snapshot.active_file == Path.join(ctx.root, "lib/a.ex")
  end

  test "SPC , on the home lists the files behind it and opens their tab", ctx do
    editor = open_home(ctx)
    send_keys_sync(editor, "1")
    send_keys_sync(editor, "<Space>ph")

    send_keys_sync(editor, "<Space>,")
    send_keys_sync(editor, "<CR>")

    refute showing_home?(editor)

    assert Minga.Buffer.file_path(editor_state(editor).workspace.buffers.active) ==
             Path.join(ctx.root, "lib/a.ex")
  end

  test "SPC p h from a split shows the home, and opening the file brings the split back", ctx do
    editor = open_home(ctx)
    send_keys_sync(editor, "1")
    send_keys_sync(editor, ":vsplit<CR>")
    assert has_split?(editor)

    send_keys_sync(editor, "<Space>ph")
    refute has_split?(editor)
    assert showing_home?(editor)

    send_keys_sync(editor, ":e #{Path.join(ctx.root, "lib/a.ex")}<CR>")
    assert has_split?(editor)
    refute showing_home?(editor)
  end

  test "a task started from the home returns to the home and its row opens it again", ctx do
    editor = open_home(ctx)

    send_keys_sync(editor, "<Space>aSn")
    assert editor_state(editor).workspace.keymap_scope == :agent

    send_keys_sync(editor, "<Esc><Esc><Esc>")
    assert showing_home?(editor)
    assert editor_state(editor).workspace.keymap_scope == :editor

    # The task model follows a session once it reports in; a stand-in session reports for this one.
    session = spawn(fn -> receive do: (:stop -> :ok) end)
    :sys.replace_state(editor.editor, &follow_task(&1, session, "Add tests"))
    state = editor_state(editor)

    assert [%{label: "Add tests"}] = home_task_rows(state)

    [task_id] =
      MingaEditor.State.Launchpad.task_ids(
        state.agent_connection.tasks,
        state.shell_runtime.state.tab_bar,
        state.workspace.launchpad
      )

    send(editor.editor, {:minga_input, {:gui_action, {:empty_state_activate, task_id}}})

    refute showing_home?(editor)
    assert editor_state(editor).workspace.keymap_scope == :agent
  end

  test "the home's New task opens the New task prompt, and a task started there keeps the home in front",
       ctx do
    editor = open_home(ctx)

    send(
      editor.editor,
      {:minga_input, {:gui_action, {:empty_state_activate, "action-agent_new_task"}}}
    )

    assert {:prompt, %{prompt_ui: %{handler: MingaEditor.UI.Prompt.NewTask}}} =
             editor_state(editor).shell_runtime.state.modal

    # Esc cancels the prompt and leaves the home where it was.
    send_keys_sync(editor, "<Esc>")
    assert showing_home?(editor)

    # A started task works in a background workspace, so the home stays in front.
    send(
      editor.editor,
      {:minga_input, {:gui_action, {:empty_state_activate, "action-agent_new_task"}}}
    )

    send_keys_sync(editor, "Add tests<CR>")

    assert showing_home?(editor)
    assert editor_state(editor).workspace.keymap_scope == :editor
  end

  defp home_with_two_files(ctx) do
    editor = open_home(ctx)
    send_keys_sync(editor, ":e #{Path.join(ctx.root, "lib/a.ex")}<CR>")
    send_keys_sync(editor, ":e #{Path.join(ctx.root, "lib/b.ex")}<CR>")
    send_keys_sync(editor, "<Space>ph")
    assert showing_home?(editor)
    editor
  end

  defp file_tab_ids(editor) do
    editor
    |> editor_state()
    |> then(& &1.shell_runtime.state.tab_bar.tabs)
    |> Enum.filter(&(&1.kind == :file))
    |> Enum.map(& &1.id)
  end

  test "moving through SPC , on the home and leaving with Esc keeps the home", ctx do
    editor = home_with_two_files(ctx)

    send_keys_sync(editor, "<Space>,")
    send_keys_sync(editor, "<C-j>")
    send_keys_sync(editor, "<C-k>")
    send_keys_sync(editor, "<Esc>")

    assert showing_home?(editor)
  end

  test "closing a tab from the tab bar while the home shows keeps the home", ctx do
    editor = home_with_two_files(ctx)
    [first, second] = file_tab_ids(editor)

    send(editor.editor, {:minga_input, {:gui_action, {:close_tab, first}}})

    assert showing_home?(editor)
    assert file_tab_ids(editor) == [second]
  end

  test "killing a file from SPC , on the home closes its tab and keeps the home", ctx do
    editor = home_with_two_files(ctx)
    state = editor_state(editor)
    [buffer | _] = MingaEditor.Handlers.BufferRegistry.buffer_inventory(state)
    item = %MingaEditor.UI.Picker.Item{id: {:buffer, buffer}, label: "a"}

    # The action runs in the Editor process, as the picker runs it.
    :sys.replace_state(
      editor.editor,
      &MingaEditor.UI.Picker.BufferSource.on_action(:kill, item, &1)
    )

    state = editor_state(editor)

    assert MingaEditor.Input.EmptyState.showing_home?(state)
    assert [_] = file_tab_ids(editor)
  end

  test "a task started from the home with files behind it returns to the home", ctx do
    editor = home_with_two_files(ctx)

    send_keys_sync(editor, "<Space>aSn")
    assert editor_state(editor).workspace.keymap_scope == :agent
    send_keys_sync(editor, "<Esc><Esc><Esc>")

    assert showing_home?(editor)
    assert [_, _] = file_tab_ids(editor)
  end

  defp follow_task(state, session, title) do
    alias MingaEditor.Shell.Runtime
    alias MingaEditor.Shell.Traditional.State, as: ShellState

    [%{id: workspace_id} | _] =
      Enum.filter(state.shell_runtime.state.tab_bar.workspaces, &(&1.kind == :agent))

    tab_bar =
      MingaEditor.State.TabBar.set_workspace_session(
        state.shell_runtime.state.tab_bar,
        workspace_id,
        session
      )

    shell_state = ShellState.install_tab_bar(Runtime.state(state.shell_runtime), tab_bar)

    %{state | shell_runtime: Runtime.install_traditional_state(state.shell_runtime, shell_state)}
    |> MingaEditor.State.follow_agent_task(session, 0, title: title)
  end

  defp home_task_rows(state) do
    model =
      state
      |> MingaEditor.Frontend.Emit.Context.from_editor_state()
      |> MingaEditor.RenderModel.UI.EmptyStateBuilder.build()

    Enum.flat_map(model.sections, &if(&1.id == :tasks, do: &1.items, else: []))
  end

  for which <- [:highlighted, :other] do
    test "a click on a #{which} row of SPC , on the home opens its tab and closes the picker, as Return does",
         ctx do
      editor = home_with_two_files(ctx)
      send_keys_sync(editor, "<Space>,")

      state = editor_state(editor)
      {:picker, %{picker_ui: picker_ui}} = state.shell_runtime.state.modal
      offer = picker_ui.activation_offer
      selected = picker_ui.picker.selected

      {activation_id, _index, %{id: {:buffer, buffer}}} =
        Enum.find(offer.items, fn {_id, index, _item} ->
          if unquote(which) == :highlighted, do: index == selected, else: index != selected
        end)

      # Both frontends send one item activation for a click on a picker row.
      send(
        editor.editor,
        {:minga_input, {:gui_action, {:picker_item_activate, offer.generation, activation_id}}}
      )

      state = editor_state(editor)
      refute showing_home?(editor)
      assert state.workspace.buffers.active == buffer
      refute match?({:picker, _}, state.shell_runtime.state.modal)
    end
  end
end
