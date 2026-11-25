defmodule MingaEditor.SwapFilesTest do
  @moduledoc """
  Unsaved text survives a crash and never survives a decision: buffers the editor opens write swap files, a quit leaves none, and the next start of the same project gets the text back in one step.
  """

  # Sets the application-wide swap directory default and shutdown function, and the default owner check runs `kill -0`.
  use Minga.Test.EditorCase, async: false, rendering: :disabled

  alias Minga.Buffer
  alias Minga.Session
  alias Minga.Session.BufferEntry
  alias Minga.Session.Snapshot
  alias Minga.Session.Swap
  alias Minga.Session.Swap.Recovery

  @moduletag :tmp_dir
  @moduletag capture_log: true

  # No process has this id, so a swap written under it belongs to an editor that is gone.
  @dead_editor 99_999_999

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "project")
    other = Path.join(dir, "other_project")

    for project <- [root, other] do
      File.mkdir_p!(Path.join(project, "lib"))
      File.write!(Path.join(project, "mix.exs"), "")
    end

    files =
      for {name, project} <- [a: root, b: root, c: root, elsewhere: other], into: %{} do
        path = Path.join(project, "lib/#{name}.ex")
        File.write!(path, "saved #{name}\n")
        {name, path}
      end

    swap_dir = Path.join(dir, "swap")
    test_pid = self()
    put_env(:buffer_swap_dir, swap_dir)
    put_env(:shutdown_fn, fn status -> send(test_pid, {:shutdown, status}) end)

    %{root: root, files: files, swap_dir: swap_dir, sessions: Path.join(dir, "sessions")}
  end

  describe "while the editor runs" do
    test "a file opened in the editor writes a swap file after its debounce, and saving removes it",
         ctx do
      editor = start_editor("", swap_dir: ctx.swap_dir)
      send_ex_sync(editor, "e #{ctx.files.a}")
      buffer = active_buffer(editor)
      assert Buffer.file_path(buffer) == ctx.files.a

      send_keys_sync(editor, "iunsaved <Esc>")
      write_swap_after_debounce(buffer)

      swap_path = Swap.swap_path(ctx.files.a, swap_dir: ctx.swap_dir)
      assert {:ok, %{path: path}, "unsaved saved a\n"} = Swap.read(swap_path)
      assert path == ctx.files.a

      send_ex_sync(editor, "w")

      assert File.read!(ctx.files.a) == "unsaved saved a\n"
      refute File.exists?(swap_path)
    end

    test "a buffer that an agent tool opens keeps its unsaved edit the same way", ctx do
      # Agent tools reach buffers through this function, without the editor.
      {:ok, buffer} = Buffer.ensure_for_path(ctx.files.b)
      on_exit(fn -> stop_buffer(buffer) end)

      :ok = Buffer.replace_content(buffer, "an edit nobody reviewed yet\n", :agent)
      write_swap_after_debounce(buffer)

      assert {:ok, _meta, "an edit nobody reviewed yet\n"} =
               Swap.read(Swap.swap_path(ctx.files.b, swap_dir: ctx.swap_dir))
    end
  end

  describe "quitting" do
    test "discarding changes leaves no swap file for the next start", ctx do
      editor = start_editor("", swap_dir: ctx.swap_dir)
      send_ex_sync(editor, "e #{ctx.files.a}")
      buffer = active_buffer(editor)
      send_keys_sync(editor, "idiscarded <Esc>")
      write_swap_after_debounce(buffer)
      assert swap_files(ctx.swap_dir) != []

      send_ex_sync(editor, "qa!")

      assert_receive {:shutdown, 0}, 2_000
      assert swap_files(ctx.swap_dir) == []
      assert Recovery.scan(swap_dir: ctx.swap_dir, pid_alive?: fn _pid -> false end) == []

      # The VM stops after this point. An edit or a timer that still arrives writes nothing.
      :ok = Buffer.replace_content(buffer, "late edit\n")
      write_swap_after_debounce(buffer)
      assert swap_files(ctx.swap_dir) == []
    end

    test "quitting within the debounce of the last edit also leaves nothing", ctx do
      editor = start_editor("", swap_dir: ctx.swap_dir)
      send_ex_sync(editor, "e #{ctx.files.a}")
      buffer = active_buffer(editor)
      send_keys_sync(editor, "idiscarded <Esc>")

      send_ex_sync(editor, "qa!")
      assert_receive {:shutdown, 0}, 2_000

      # The debounce timer of the last edit fires while the VM stops.
      write_swap_after_debounce(buffer)
      assert swap_files(ctx.swap_dir) == []
    end

    test ":cq gives the changes up as well", ctx do
      editor = start_editor("", swap_dir: ctx.swap_dir)
      send_ex_sync(editor, "e #{ctx.files.a}")
      buffer = active_buffer(editor)
      send_keys_sync(editor, "idiscarded <Esc>")
      write_swap_after_debounce(buffer)

      send_ex_sync(editor, "cq")

      assert_receive {:shutdown, 1}, 2_000
      assert swap_files(ctx.swap_dir) == []
    end
  end

  describe "the next start after the editor was killed" do
    test "opening the project restores its session and recovers its unsaved text, in one step",
         ctx do
      save_session(ctx, [ctx.files.a, ctx.files.b])
      swap_a = leftover_swap(ctx, ctx.files.a, "unsaved a\n")
      swap_c = leftover_swap(ctx, ctx.files.c, "unsaved c\n")
      swap_elsewhere = leftover_swap(ctx, ctx.files.elsewhere, "unsaved elsewhere\n")

      editor = open_project(ctx)

      state =
        wait_until(editor, &match?([_, _, _], &1.workspace.buffers.list),
          max_attempts: 200,
          message: "the session and the unsaved text did not come back"
        )

      # The session comes back first: the file that had focus still has it.
      assert Buffer.file_path(state.workspace.buffers.active) == ctx.files.b
      assert buffer_text(ctx.files.a) == {"unsaved a\n", true}
      assert buffer_text(ctx.files.b) == {"saved b\n", false}
      # A file with unsaved text that the session did not hold is opened as well.
      assert buffer_text(ctx.files.c) == {"unsaved c\n", true}

      assert notice_message(editor) =~
               "Restored 2 files from last time · recovered unsaved text in 2 files"

      # Each buffer now owns its text on disk under this editor, and the dead editor's swaps are gone.
      refute File.exists?(swap_a)
      refute File.exists?(swap_c)

      assert {:ok, _meta, "unsaved a\n"} =
               Swap.read(Swap.swap_path(ctx.files.a, swap_dir: ctx.swap_dir))

      # Another project's text is never recovered into this one. It waits for its own project.
      assert Buffer.pid_for_path(ctx.files.elsewhere) == :not_found
      assert {:ok, _meta, "unsaved elsewhere\n"} = Swap.read(swap_elsewhere)
    end

    test "unsaved text of a file that is gone comes back in a buffer for its path", ctx do
      gone = Path.join(ctx.root, "lib/never_saved.ex")
      leftover_swap(ctx, gone, "typed for an hour\n")

      editor = open_project(ctx)
      wait_until(editor, &match?([_], &1.workspace.buffers.list), max_attempts: 200)

      assert buffer_text(gone) == {"typed for an hour\n", true}
      assert Buffer.file_path(active_buffer(editor)) == gone
      assert notice_message(editor) == "Recovered unsaved text in 1 file"
    end

    test "an editor started on one file recovers that file and nothing else", ctx do
      swap_b = leftover_swap(ctx, ctx.files.b, "unsaved b\n")
      leftover_swap(ctx, ctx.files.a, "unsaved a\n")

      editor =
        start_editor("",
          empty: true,
          startup_file: ctx.files.a,
          project_root: ctx.root,
          session_dir: ctx.sessions,
          swap_dir: ctx.swap_dir,
          backend: :tui
        )

      wait_until(editor, fn _state -> buffer_text(ctx.files.a) == {"unsaved a\n", true} end,
        max_attempts: 200,
        message: "the file's unsaved text did not come back"
      )

      assert Buffer.pid_for_path(ctx.files.b) == :not_found
      assert File.exists?(swap_b)
    end

    test "recovered text that the user then discards is not offered again", ctx do
      leftover_swap(ctx, ctx.files.a, "unsaved a\n")
      editor = open_project(ctx)
      wait_until(editor, &match?([_], &1.workspace.buffers.list), max_attempts: 200)

      send_ex_sync(editor, "qa!")
      assert_receive {:shutdown, 0}, 2_000

      assert swap_files(ctx.swap_dir) == []
    end
  end

  defp open_project(ctx) do
    editor =
      start_editor("",
        empty: true,
        project_root: ctx.root,
        session_dir: ctx.sessions,
        swap_dir: ctx.swap_dir,
        backend: :tui
      )

    on_exit(fn -> ctx.files |> Map.values() |> Enum.each(&stop_buffer_for/1) end)
    editor
  end

  defp save_session(ctx, files) do
    snapshot = %Snapshot{
      version: 2,
      project_root: ctx.root,
      buffers: Enum.map(files, &%BufferEntry{file: &1}),
      active_file: List.last(files)
    }

    :ok = Session.save(snapshot, session_dir: ctx.sessions, project_root: ctx.root)
  end

  # Writes the swap that a killed editor left for the file.
  defp leftover_swap(ctx, path, content) do
    opts = [swap_dir: ctx.swap_dir, os_pid: @dead_editor]
    {:ok, prepared} = Swap.prepare(path, content, opts)
    :ok = Swap.publish(prepared)
    Swap.swap_path(path, opts)
  end

  defp buffer_text(path) do
    case Buffer.pid_for_path(path) do
      {:ok, buffer} -> {Buffer.content(buffer), Buffer.dirty?(buffer)}
      :not_found -> :not_open
    end
  end

  # Fires the debounce timer by hand, then waits for the write worker and its publication.
  defp write_swap_after_debounce(buffer) do
    send(buffer, :write_swap)
    :sys.get_state(buffer)

    case :sys.get_state(buffer).swap.active do
      {_snapshot, worker, _monitor} ->
        monitor = Process.monitor(worker)
        assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 2_000
        :sys.get_state(buffer)

      nil ->
        :ok
    end

    :ok
  end

  defp swap_files(swap_dir) do
    case File.ls(swap_dir) do
      {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".swap"))
      {:error, :enoent} -> []
    end
  end

  defp stop_buffer_for(path) do
    case Buffer.pid_for_path(path) do
      {:ok, buffer} -> stop_buffer(buffer)
      :not_found -> :ok
    end
  end

  # These buffers live under the application's buffer supervisor, so the test stops them itself.
  defp stop_buffer(buffer) do
    DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, buffer)
    :ok
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:minga, key)
    # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
    Application.put_env(:minga, key, value)

    on_exit(fn ->
      case previous do
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        {:ok, value} -> Application.put_env(:minga, key, value)
        # credo:disable-for-next-line Minga.Credo.NoGlobalStateInTestCheck
        :error -> Application.delete_env(:minga, key)
      end
    end)
  end
end
