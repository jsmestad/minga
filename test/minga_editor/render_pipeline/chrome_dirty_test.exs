defmodule MingaEditor.RenderPipeline.ChromeDirtyTest do
  use ExUnit.Case, async: true

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Test.RecordingFrontend
  alias MingaEditor.Extension.Sidebar
  alias MingaEditor.RenderPipeline.Input
  alias MingaEditor.RenderPipeline.TestHelpers
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Traditional.SidebarWorkflow

  setup do
    table = Module.concat(__MODULE__, "Sidebar#{System.unique_integer([:positive])}")
    start_supervised!({Sidebar, name: table, notify: false})

    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:chrome_dirty_frontend, System.unique_integer([:positive])}
      )

    Process.put(:chrome_dirty_frontend, frontend)
    %{sidebar_registry: table}
  end

  defp base_state(opts \\ []) do
    TestHelpers.base_state(Keyword.put(opts, :port_manager, Process.get(:chrome_dirty_frontend)))
  end

  describe "chrome_fingerprint/1" do
    test "same input produces same fingerprint" do
      state = base_state()
      input = Input.from_editor_state(state)

      fp1 = Input.chrome_fingerprint(input)
      fp2 = Input.chrome_fingerprint(input)

      assert fp1 == fp2
    end

    test "changing vim mode changes fingerprint" do
      state = base_state()
      input = Input.from_editor_state(state)
      fp_normal = Input.chrome_fingerprint(input)

      # Simulate mode change
      ws = input.workspace
      editing = %{ws.editing | mode: :insert}
      input2 = %{input | workspace: %{ws | editing: editing}}
      fp_insert = Input.chrome_fingerprint(input2)

      assert fp_normal != fp_insert
    end

    test "changing theme changes fingerprint" do
      state = base_state()
      input = Input.from_editor_state(state)
      fp_before = Input.chrome_fingerprint(input)

      input2 = %{input | theme: MingaEditor.UI.Theme.get!(:one_light)}
      fp_after = Input.chrome_fingerprint(input2)

      assert fp_before != fp_after
    end

    test "saving a dirty buffer changes fingerprint without changing buffer version" do
      dir =
        Path.join(System.tmp_dir!(), "minga-chrome-save-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      path = Path.join(dir, "saved.ex")
      File.write!(path, "defmodule Saved do\nend\n")

      state = base_state(content: File.read!(path))
      buf = state.workspace.buffers.active
      :ok = BufferProcess.save_as(buf, path)
      :ok = BufferProcess.insert_text(buf, "# dirty\n")
      version_before = BufferProcess.version(buf)
      fp_dirty = state |> Input.from_editor_state() |> Input.chrome_fingerprint()

      :ok = BufferProcess.save(buf)
      version_after = BufferProcess.version(buf)
      fp_clean = state |> Input.from_editor_state() |> Input.chrome_fingerprint()

      assert version_after == version_before
      assert fp_dirty != fp_clean
    end

    test "moving cursor changes fingerprint" do
      state = base_state()
      buf = state.workspace.buffers.active

      input1 = Input.from_editor_state(state)
      fp1 = Input.chrome_fingerprint(input1)

      # Move cursor in the buffer
      Minga.Buffer.move_to(buf, {1, 0})

      input2 = Input.from_editor_state(state)
      fp2 = Input.chrome_fingerprint(input2)

      assert fp1 != fp2
    end

    test "changing file tree changes fingerprint" do
      state = base_state()
      input = Input.from_editor_state(state)
      fp1 = Input.chrome_fingerprint(input)

      # Simulate file tree focus change
      ws = input.workspace
      ft = %{ws.file_tree | focused: true}
      input2 = %{input | workspace: %{ws | file_tree: ft}}
      fp2 = Input.chrome_fingerprint(input2)

      assert fp1 != fp2
    end

    test "sidebar registry snapshot and visibility changes change fingerprint", %{
      sidebar_registry: table
    } do
      assert :ok =
               Sidebar.register(table, {:extension, :outline}, %{
                 id: "outline",
                 display_name: "Outline",
                 visible?: true,
                 preferred_width: 25,
                 semantic_kind: "outline",
                 snapshot: [rows: [%{id: "a", text: "alpha"}]]
               })

      state = base_state(sidebar_registry: table)
      fp_visible = state |> Input.from_editor_state() |> Input.chrome_fingerprint()

      assert :ok = Sidebar.set_visible(table, {:extension, :outline}, "outline", false)
      fp_hidden = state |> Input.from_editor_state() |> Input.chrome_fingerprint()
      assert fp_visible != fp_hidden

      assert :ok =
               Sidebar.publish_snapshot(table, {:extension, :outline}, "outline",
                 rows: [%{id: "a", text: "beta"}]
               )

      fp_snapshot = state |> Input.from_editor_state() |> Input.chrome_fingerprint()
      assert fp_hidden != fp_snapshot
    end

    test "second frame rebuilds chrome after a sidebar snapshot changes", %{
      sidebar_registry: table
    } do
      # The frontend renders sidebar rows natively from the registry snapshot; the
      # BEAM no longer paints sidebar cells into chrome.file_tree. The surviving
      # cross-frame behavior is that a snapshot change invalidates the chrome
      # fingerprint, forcing a rebuild so the next frame re-emits sidebar metadata.
      assert :ok =
               Sidebar.register(table, {:extension, :outline}, %{
                 id: "outline",
                 display_name: "Outline",
                 visible?: true,
                 preferred_width: 25,
                 semantic_kind: "outline",
                 snapshot: [rows: [%{id: "a", text: "alpha"}]]
               })

      state = base_state(sidebar_registry: table)
      state1 = TestHelpers.run_pipeline(state)
      fingerprint1 = :sys.get_state(state1.renderer).caches.chrome_prev_fingerprint

      assert :ok =
               Sidebar.publish_snapshot(table, {:extension, :outline}, "outline",
                 rows: [%{id: "a", text: "beta"}]
               )

      state2 = TestHelpers.run_pipeline(state1)
      fingerprint2 = :sys.get_state(state2.renderer).caches.chrome_prev_fingerprint

      assert fingerprint2 != fingerprint1
    end

    test "shell-owned chrome state changes fingerprint through shell hook" do
      state = base_state()
      input = Input.from_editor_state(state)
      fp1 = Input.chrome_fingerprint(input)

      state =
        SidebarWorkflow.replace_git_status(state, %{
          repo_state: :normal,
          branch: "main",
          ahead: 0,
          behind: 0,
          entries: []
        })

      input2 = Input.from_editor_state(state)
      fp2 = Input.chrome_fingerprint(input2)

      assert fp1 != fp2
    end

    test "unchanged input between frames produces stable fingerprint" do
      state = base_state()
      input = Input.from_editor_state(state)

      # Simulate two frames with no state changes
      fp_frame1 = Input.chrome_fingerprint(input)
      fp_frame2 = Input.chrome_fingerprint(input)

      assert fp_frame1 == fp_frame2
    end
  end

  describe "chrome skip integration" do
    test "second render with unchanged state skips chrome rebuild" do
      state = base_state()

      # First render: builds chrome fresh in renderer-owned state.
      state1 = TestHelpers.run_pipeline(state)
      cache1 = :sys.get_state(state1.renderer).caches
      fp_after_first = cache1.chrome_prev_fingerprint
      chrome_after_first = cache1.chrome_prev_result

      assert fp_after_first != nil, "fingerprint should be cached after first render"
      assert chrome_after_first != nil, "chrome result should be cached after first render"

      # Second render: must thread state1 so caches survive between frames.
      state2 = TestHelpers.run_pipeline(state1)
      cache2 = :sys.get_state(state2.renderer).caches
      fp_after_second = cache2.chrome_prev_fingerprint
      chrome_after_second = cache2.chrome_prev_result

      assert fp_after_second == fp_after_first,
             "fingerprint should be stable across unchanged frames"

      assert chrome_after_second === chrome_after_first
    end

    test "render after cursor move rebuilds chrome" do
      state = base_state()
      buf = state.workspace.buffers.active

      # First render.
      state1 = TestHelpers.run_pipeline(state)
      fp_before = :sys.get_state(state1.renderer).caches.chrome_prev_fingerprint

      # Move cursor (changes status bar data).
      Minga.Buffer.move_to(buf, {1, 0})

      # Second render with caches from first frame so fingerprint comparison works.
      state2 = TestHelpers.run_pipeline(state1)
      fp_after = :sys.get_state(state2.renderer).caches.chrome_prev_fingerprint

      assert fp_before != fp_after, "cursor move should change chrome fingerprint"
    end

    test "render after active buffer changes rebuilds status bar data" do
      dir =
        Path.join(System.tmp_dir!(), "minga-chrome-dirty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      first_path = Path.join(dir, "first.ex")
      second_path = Path.join(dir, "second.ex")
      File.write!(first_path, "defmodule First do\nend\n")
      File.write!(second_path, "defmodule Second do\nend\n")

      state = base_state(content: File.read!(first_path))
      first_buf = state.workspace.buffers.active
      :ok = BufferProcess.save_as(first_buf, first_path)
      {:ok, second_buf} = BufferProcess.start_link(content: File.read!(second_path))
      :ok = BufferProcess.save_as(second_buf, second_path)

      state1 = TestHelpers.run_pipeline(state)
      fp_before = :sys.get_state(state1.renderer).caches.chrome_prev_fingerprint

      switched =
        put_in(state1.workspace.buffers, %{
          state1.workspace.buffers
          | active: second_buf,
            list: [first_buf, second_buf],
            active_index: 1
        })
        |> update_in([Access.key!(:workspace)], fn workspace ->
          SessionState.activate_buffer(workspace, workspace.buffers)
        end)

      state2 = TestHelpers.run_pipeline(switched)
      renderer_cache = :sys.get_state(state2.renderer).caches
      fp_after = renderer_cache.chrome_prev_fingerprint
      {:buffer, status_bar_data} = renderer_cache.chrome_prev_result.status_bar_data

      assert fp_before != fp_after
      assert status_bar_data.file_name == "second.ex"
    end
  end
end
