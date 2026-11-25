defmodule MingaEditor.ProjectSessionTest do
  @moduledoc """
  `minga .` in a project with a saved session: files, splits, cursors and scroll come back, the echo area says how many files, `SPC q n` starts fresh, and quitting saves what the window held.
  """

  use Minga.Test.EditorCase, async: true

  alias Minga.Session
  alias Minga.Session.BufferEntry
  alias Minga.Session.Pane
  alias Minga.Session.Snapshot
  alias MingaEditor.WindowTree

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "defmodule P.MixProject do\nend\n")
    lib_a = Path.join(root, "lib/a.ex")
    lib_b = Path.join(root, "lib/b.ex")
    File.write!(lib_a, Enum.map_join(1..120, "\n", &"a line #{&1}"))
    File.write!(lib_b, Enum.map_join(1..120, "\n", &"b line #{&1}"))

    %{root: root, sessions: Path.join(dir, "sessions"), lib_a: lib_a, lib_b: lib_b}
  end

  defp save_split_session(ctx, active_pane \\ 1)

  defp save_split_session(%{root: root, sessions: sessions, lib_a: a, lib_b: b}, active_pane) do
    snapshot = %Snapshot{
      version: 2,
      project_root: root,
      buffers: [
        %BufferEntry{file: a, cursor_line: 40, cursor_col: 2},
        %BufferEntry{file: b, cursor_line: 70, cursor_col: 0}
      ],
      active_file: b,
      layout:
        {:split, :vertical, {:pane, %Pane{file: a, cursor_line: 40, cursor_col: 2, top: 30}},
         {:pane, %Pane{file: b, cursor_line: 70, cursor_col: 0, top: 60}}, 0},
      active_pane: active_pane
    }

    :ok = Session.save(snapshot, session_dir: sessions, project_root: root)
  end

  defp open_project(ctx) do
    start_editor("",
      empty: true,
      project_root: ctx.root,
      session_dir: ctx.sessions,
      rendering: :disabled,
      width: 120,
      height: 40
    )
  end

  test "a saved session comes back with its splits, cursors, scroll and an echo note", ctx do
    save_split_session(ctx)
    editor = open_project(ctx)

    state =
      wait_until(editor, &match?([_, _], &1.workspace.buffers.list),
        max_attempts: 100,
        message: "the saved session was not restored"
      )

    windows = state.workspace.windows
    assert {:split, :vertical, {:leaf, left}, {:leaf, right}, 0} = windows.tree
    assert windows.active == right
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == ctx.lib_b
    assert Minga.Buffer.cursor(state.workspace.buffers.active) == {70, 0}
    assert windows.map[left].cursor == {40, 2}
    assert windows.map[left].viewport.top == 30
    assert windows.map[right].viewport.top == 60
    assert notice_message(editor) == "Restored 2 files from last time"
  end

  test "focus returns to the window that had it, even when it shows an earlier file", ctx do
    save_split_session(ctx, 0)
    editor = open_project(ctx)

    state = wait_until(editor, &(map_size(&1.workspace.windows.map) == 2), max_attempts: 100)

    assert {:split, :vertical, {:leaf, left}, {:leaf, _right}, 0} = state.workspace.windows.tree
    assert state.workspace.windows.active == left
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == ctx.lib_a
    assert Minga.Buffer.cursor(state.workspace.buffers.active) == {40, 2}
  end

  test "a window whose file is gone is dropped and focus stays on the window that had it", ctx do
    save_split_session(ctx, 1)
    File.rm!(ctx.lib_a)
    editor = open_project(ctx)

    state = wait_until(editor, &match?([_], &1.workspace.buffers.list), max_attempts: 100)

    assert {:leaf, only} = state.workspace.windows.tree
    assert state.workspace.windows.active == only
    assert Minga.Buffer.file_path(state.workspace.buffers.active) == ctx.lib_b
    assert notice_message(editor) == "Restored 1 file from last time"
  end

  test "minga <file> neither restores nor saves the project's session", ctx do
    save_split_session(ctx)
    saved = File.read!(Session.session_file(session_dir: ctx.sessions, project_root: ctx.root))

    # Production starts the editor empty and the command line opens the file afterwards.
    editor =
      start_editor("",
        empty: true,
        startup_file: ctx.lib_a,
        project_root: ctx.root,
        session_dir: ctx.sessions,
        rendering: :disabled
      )

    state = editor_state(editor)
    refute MingaEditor.Handlers.SessionHandler.persists_project?(state)
    assert state.workspace.buffers.list == []

    send(editor.editor, :save_session)
    _ = editor_state(editor)

    assert File.read!(Session.session_file(session_dir: ctx.sessions, project_root: ctx.root)) ==
             saved
  end

  test "an editor started with a file buffer neither restores nor saves the project's session",
       ctx do
    save_split_session(ctx)
    saved = File.read!(Session.session_file(session_dir: ctx.sessions, project_root: ctx.root))

    editor =
      start_editor("one file",
        file_path: ctx.lib_a,
        project_root: ctx.root,
        session_dir: ctx.sessions,
        rendering: :disabled
      )

    send(editor.editor, :save_session)
    state = editor_state(editor)

    refute MingaEditor.Handlers.SessionHandler.persists_project?(state)
    assert [_] = state.workspace.buffers.list

    assert File.read!(Session.session_file(session_dir: ctx.sessions, project_root: ctx.root)) ==
             saved
  end

  test "starting fresh closes the restored files and keeps unsaved ones", ctx do
    save_split_session(ctx)
    editor = open_project(ctx)
    wait_until(editor, &match?([_, _], &1.workspace.buffers.list), max_attempts: 100)

    send_keys_sync(editor, "ix<Esc>")
    state = start_fresh(editor)
    assert [buffer] = MingaEditor.Handlers.BufferRegistry.buffer_inventory(state)
    assert Minga.Buffer.file_path(buffer) == ctx.lib_b
    assert Minga.Buffer.dirty?(buffer)

    assert MingaEditor.Shell.Traditional.NoticeWorkflow.message(state) ==
             "Kept 1 unsaved file open"
  end

  test "starting fresh with nothing unsaved leaves no files open", ctx do
    save_split_session(ctx)
    editor = open_project(ctx)
    wait_until(editor, &match?([_, _], &1.workspace.buffers.list), max_attempts: 100)

    assert MingaEditor.Handlers.BufferRegistry.buffer_inventory(start_fresh(editor)) == []
  end

  # `SPC q n` binds the command once the project home lands; until then it runs from the command palette.
  defp start_fresh(editor) do
    editor |> editor_state() |> MingaEditor.Commands.Launchpad.execute(:session_start_fresh)
  end

  test "a project without a saved session opens with no files", ctx do
    editor = open_project(ctx)

    state = editor_state(editor)
    assert state.workspace.buffers.list == []
    assert WindowTree.count(state.workspace.windows.tree) == 1
  end

  test "the session captured from the editor round-trips through restore", ctx do
    save_split_session(ctx)
    editor = open_project(ctx)
    state = wait_until(editor, &match?([_, _], &1.workspace.buffers.list), max_attempts: 100)

    captured = MingaEditor.Session.Capture.snapshot(state)

    assert captured.project_root == ctx.root

    assert Enum.map(captured.buffers, & &1.file) |> Enum.sort() ==
             Enum.sort([ctx.lib_a, ctx.lib_b])

    assert captured.active_pane == 1

    assert {:split, :vertical, {:pane, %Pane{file: a, top: 30}}, {:pane, %Pane{file: b, top: 60}},
            0} =
             captured.layout

    assert {a, b} == {ctx.lib_a, ctx.lib_b}
  end
end
