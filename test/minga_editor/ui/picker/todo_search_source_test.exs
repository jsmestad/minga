defmodule MingaEditor.UI.Picker.TodoSearchSourceTest do
  # This suite spawns git/grep OS Ports and mutates the process-global Project workspace.
  use ExUnit.Case, async: false

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Project.WorkspaceSnapshot
  alias Minga.Test.TodoSearchPortProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.PickerUI
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.TodoSearchSource
  alias MingaEditor.UI.Picker.Source

  setup do
    original_workspace = Project.snapshot()
    on_exit(fn -> restore_project(original_workspace) end)
    :ok
  end

  test "does not advertise generic async fetching and keeps fallback candidates inert" do
    context = Context.from_editor_state(base_state(content: "scratch"))

    refute Source.async?(TodoSearchSource)
    assert TodoSearchSource.candidates(context) == []
  end

  describe "parse_output/2" do
    test "parses NUL-framed git and recursive grep records with newlines in paths" do
      git_output = "lib/a:b\nc.ex\012\0  # TODO ship it\n"
      grep_output = "/workspace/a:b\nc.ex\0" <> "4:// FIXME docs\n"

      assert TodoSearchSource.parse_output(git_output, :git) ==
               {[%{path: "lib/a:b\nc.ex", line: 12, text: "  # TODO ship it"}], false}

      assert TodoSearchSource.parse_output(grep_output, :grep) ==
               {[%{path: "/workspace/a:b\nc.ex", line: 4, text: "// FIXME docs"}], false}
    end

    test "ignores malformed and non-positive line results" do
      output = "bad\0nope\0# TODO bad\nfile.ex\00\0# TODO bad\n"
      assert TodoSearchSource.parse_output(output, :git) == {[], false}
    end

    test "caps parsed matches and reports truncation" do
      output = Enum.map_join(1..1_001, fn line -> "file.ex\0#{line}\0# TODO item\n" end)

      assert {markers, true} = TodoSearchSource.parse_output(output, :git)
      assert length(markers) == TodoSearchSource.max_results()
    end
  end

  describe "build_candidates/2" do
    test "creates authorized picker items and rejects candidates outside the captured Root" do
      root_path = temporary_root()
      file = Path.join(root_path, "lib/example.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "# NOTE explain\n")
      root = directory_root!(root_path)

      markers = [
        %{path: "lib/example.ex", line: 1, text: "  # NOTE explain"},
        %{path: "/etc/passwd", line: 1, text: "# TODO forged"},
        %{path: "../outside.ex", line: 1, text: "# TODO escaped"}
      ]

      assert [item] = TodoSearchSource.build_candidates(markers, root)
      assert item.label =~ "lib/example.ex:1"
      assert item.description == "# NOTE explain"
      assert item.icon_color != nil
      assert {:ok, canonical_file} = Root.canonical_path(file)
      assert item.id == %{path: canonical_file, line: 1, index: 0}
    end

    test "empty results produce no items" do
      assert TodoSearchSource.build_candidates([], directory_root!(temporary_root())) == []
    end
  end

  describe "scheduled search" do
    test "finds TODOs in a git repository" do
      root_path = temporary_root()
      File.mkdir_p!(Path.join(root_path, "lib"))
      file = Path.join(root_path, "lib/example.ex")
      File.write!(file, "# TODO ship it\n")
      {"", 0} = System.cmd("git", ["-C", root_path, "init", "-q"])
      {"", 0} = System.cmd("git", ["-C", root_path, "add", "."])

      assert {:ok, %TodoSearch.Result{items: [item]}} = TodoSearch.run(effect(root_path))
      assert item.description == "# TODO ship it"
    end

    test "falls back to grep outside a git repository" do
      root_path = temporary_root()
      file = Path.join(root_path, "example.ex")
      File.write!(file, "# FIXME outside git\n")

      assert {:ok, %TodoSearch.Result{items: [item]}} = TodoSearch.run(effect(root_path))
      assert item.description == "# FIXME outside git"
    end

    test "newline-containing filenames cannot forge an absolute candidate" do
      root_path = temporary_root()
      forged_path = Path.join([root_path, "prefix\n", "etc", "passwd:1:# TODO forged"])
      File.mkdir_p!(Path.dirname(forged_path))
      File.write!(forged_path, "# TODO real match\n")

      assert {:ok, %TodoSearch.Result{items: [item]}} = TodoSearch.run(effect(root_path))
      assert {:ok, canonical_forged_path} = Root.canonical_path(forged_path)
      assert item.id.path == canonical_forged_path
      refute item.id.path == "/etc/passwd"
    end

    test "preserves command failure presentation" do
      root_path = temporary_root()
      :ok = TodoSearchPortProbe.configure(:failure)

      assert {:error, message} = TodoSearch.run(effect(root_path, impl: TodoSearchPortProbe))
      assert message == "grep exited with status 2: probe failure"
    end

    test "surfaces the match cap in result metadata" do
      root_path = temporary_root()
      file = Path.join(root_path, "lib/example.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "# TODO probe\n")

      output =
        Enum.map_join(1..1_001, fn line -> "lib/example.ex\0#{line}\0# TODO probe\n" end)

      :ok = TodoSearchPortProbe.configure({:search_output, output})

      assert {:ok, %TodoSearch.Result{items: items, meta: meta}} =
               TodoSearch.run(effect(root_path, impl: TodoSearchPortProbe))

      assert length(items) == TodoSearchSource.max_results()
      assert meta == %{status: "Results truncated to #{TodoSearchSource.max_results()}"}
    end
  end

  describe "stale outcome safety" do
    test "applies completed and failed outcomes in the captured workspace activation" do
      {snapshot, state, revision, request} = live_request()
      assert Project.snapshot().activation_id == snapshot.activation_id

      assert {completed_state, %Outcome{value: {:completed, _result}}} =
               TodoSearch.apply(state, Outcome.completed(request, result(revision)))

      refute completed_state == state

      assert {failed_state, %Outcome{value: {:failed, _reason}}} =
               TodoSearch.apply(state, Outcome.failed(request, "probe failure"))

      refute failed_state == state
    end

    test "marks completed and failed outcomes stale after rerooting" do
      {_snapshot, state, revision, request} = live_request()
      assert {:ok, _snapshot} = Project.activate(directory_root!(temporary_root()))

      assert_stale_pair(state, request, revision, :workspace_rerooted)
    end

    test "marks completed and failed outcomes stale after picker replacement" do
      {_snapshot, state, revision, request} = live_request()
      {replaced_state, _replacement_revision} = PickerUI.open_loading(state, FileSource)

      assert_stale_pair(replaced_state, request, revision, :picker_closed_or_replaced)
    end

    test "marks completed and failed outcomes stale after the picker revision changes" do
      {_snapshot, state, revision, request} = live_request()
      {newer_state, _new_revision} = PickerUI.open_loading(state, TodoSearchSource)

      assert_stale_pair(newer_state, request, revision, :picker_closed_or_replaced)
    end

    test "marks a completed result stale when its carried revision differs" do
      {_snapshot, state, _revision, request} = live_request()

      assert {^state, %Outcome{value: {:stale, :revision_mismatch}}} =
               TodoSearch.apply(state, Outcome.completed(request, result(make_ref())))
    end

    test "rejects completed and failed outcomes after an A to B to A activation cycle" do
      {snapshot_a, state, revision, request} = live_request()
      root_a = snapshot_a.root
      assert {:ok, _snapshot_b} = Project.activate(directory_root!(temporary_root()))
      assert {:ok, snapshot_a2} = Project.activate(root_a)
      assert snapshot_a2.root == root_a
      assert snapshot_a2.activation_id > snapshot_a.activation_id

      assert_stale_pair(state, request, revision, :workspace_rerooted)
    end
  end

  describe "root authorization boundary" do
    test "passes only the canonical path into Port arguments and candidate authorization" do
      container = temporary_root()
      target_path = Path.join(container, "canonical")
      alias_path = Path.join(container, "alias")
      file = Path.join(target_path, "lib/example.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "# TODO probe\n")
      File.ln_s!(target_path, alias_path)
      root = directory_root!(alias_path)
      {:ok, canonical_root} = Root.canonical_path(target_path)
      {:ok, canonical_file} = Root.canonical_path(file)

      assert {:ok, %TodoSearch.Result{items: [item]}} =
               TodoSearch.run(todo_effect(root, TodoSearchPortProbe))

      assert_received {:todo_search_port_opened, "git",
                       ["-C", ^canonical_root, "rev-parse", "--is-inside-work-tree"]}

      assert item.id.path == canonical_file
    end

    test "accepts a confirmed broad root before opening the probe Port" do
      root = %Root{kind: :directory, path: "/", broad_root_confirmed?: true}

      assert {:ok, %TodoSearch.Result{}} = TodoSearch.run(todo_effect(root, TodoSearchPortProbe))

      assert_received {:todo_search_port_opened, "git",
                       ["-C", "/", "rev-parse", "--is-inside-work-tree"]}
    end

    test "rejects broad roots without confirmation before a Port opens" do
      root = %Root{kind: :directory, path: "/", broad_root_confirmed?: false}
      assert_rejected_before_port(root, :broad_root_confirmation_required)
    end

    test "rejects invalid broad-root confirmation before a Port opens" do
      root_path = temporary_root()
      root = %Root{kind: :directory, path: root_path, broad_root_confirmed?: :invalid}
      assert_rejected_before_port(root, :invalid_broad_root_confirmation)
    end

    test "rejects file-scoped roots before a Port opens" do
      file = Path.join(temporary_root(), "file.ex")
      File.write!(file, "# TODO not recursive\n")
      assert_rejected_before_port(Root.file(file), :not_a_directory_root)
    end

    test "rejects roots that stop being directories before a Port opens" do
      root_path = temporary_root()
      root = directory_root!(root_path)
      File.rm_rf!(root_path)
      File.write!(root_path, "not a directory")
      assert_rejected_before_port(root, :not_a_directory)
    end

    test "rejects roots whose canonical target changed before a Port opens" do
      container = temporary_root()
      root_path = Path.join(container, "captured")
      replacement = Path.join(container, "replacement")
      File.mkdir_p!(root_path)
      File.mkdir_p!(replacement)
      root = directory_root!(root_path)
      File.rm_rf!(root_path)
      File.ln_s!(replacement, root_path)
      assert_rejected_before_port(root, :root_changed)
    end
  end

  describe "on_select/2" do
    test "switches to the matching buffer and moves to the requested line" do
      path =
        Path.join(System.tmp_dir!(), "minga-todo-search-#{System.unique_integer([:positive])}.ex")

      File.write!(path, "first\nsecond\nthird\n")
      on_exit(fn -> File.rm(path) end)

      state = base_state(content: "scratch")
      path_buffer = start_supervised!({BufferProcess, file_path: path})
      state = MingaEditor.Handlers.BufferRegistry.add_buffer(state, path_buffer)
      state = MingaEditor.BufferActivation.activate(state, 0)

      item = %Item{id: %{path: path, line: 3}, label: "todo"}
      new_state = TodoSearchSource.on_select(item, state)

      assert new_state.workspace.buffers.active_index == 1
      assert BufferProcess.cursor(path_buffer) == {2, 0}
    end
  end

  @spec live_request() :: {WorkspaceSnapshot.t(), EditorState.t(), reference(), term()}
  defp live_request do
    root = directory_root!(temporary_root())
    assert {:ok, snapshot} = Project.activate(root)
    state = base_state(content: "scratch")
    {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
    {snapshot, state, revision, TodoSearch.request(snapshot, revision)}
  end

  @spec result(reference()) :: TodoSearch.Result.t()
  defp result(revision) do
    %TodoSearch.Result{revision: revision, items: [], candidates: [], meta: %{}}
  end

  @spec assert_stale_pair(EditorState.t(), term(), reference(), atom()) :: :ok
  defp assert_stale_pair(state, request, revision, reason) do
    assert {^state, %Outcome{value: {:stale, ^reason}}} =
             TodoSearch.apply(state, Outcome.completed(request, result(revision)))

    assert {^state, %Outcome{value: {:stale, ^reason}}} =
             TodoSearch.apply(state, Outcome.failed(request, "probe failure"))

    :ok
  end

  @spec effect(String.t(), keyword()) :: TodoSearch.t()
  defp effect(root_path, opts \\ []) do
    todo_effect(
      directory_root!(root_path),
      Keyword.get(opts, :impl, MingaEditor.Effects.TodoSearch.Port)
    )
  end

  @spec todo_effect(Root.t(), module()) :: TodoSearch.t()
  defp todo_effect(root, impl) do
    %TodoSearch{root: root, activation_id: 1, revision: make_ref(), impl: impl}
  end

  @spec directory_root!(String.t()) :: Root.t()
  defp directory_root!(path) do
    {:ok, root} = Root.directory(path)
    root
  end

  @spec assert_rejected_before_port(Root.t(), Root.error()) :: :ok
  defp assert_rejected_before_port(root, reason) do
    assert TodoSearch.run(todo_effect(root, TodoSearchPortProbe)) ==
             {:error, "TODO search root rejected: #{reason}"}

    refute_received {:todo_search_port_opened, _command, _args}
    :ok
  end

  @spec temporary_root() :: String.t()
  defp temporary_root do
    root_path =
      Path.join(System.tmp_dir!(), "minga-todo-effect-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root_path)
    on_exit(fn -> File.rm_rf(root_path) end)
    root_path
  end

  @spec restore_project(WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end
end
