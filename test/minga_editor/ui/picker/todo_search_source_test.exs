defmodule MingaEditor.UI.Picker.TodoSearchSourceTest do
  # This suite spawns git/grep OS Ports and mutates the process-global Project workspace.
  use ExUnit.Case, async: false

  import MingaEditor.RenderPipeline.TestHelpers, only: [base_state: 1]

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Project
  alias Minga.Project.Root
  alias Minga.Test.TodoSearchPortProbe
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Effects.TodoSearch
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.UI.Picker.FileSource
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.TodoSearchSource

  setup do
    original_workspace = Project.snapshot()
    on_exit(fn -> restore_project(original_workspace) end)
    :ok
  end

  describe "parse_output/1" do
    test "parses grep path, line, and match text" do
      output = "lib/example.ex:12:  # TODO ship it\nREADME.md:4:// FIXME docs\n"

      assert TodoSearchSource.parse_output(output) == [
               %{path: "lib/example.ex", line: 12, text: "  # TODO ship it"},
               %{path: "README.md", line: 4, text: "// FIXME docs"}
             ]
    end

    test "ignores malformed and non-positive line results" do
      output = "not grep output\nfile.ex:nope:# TODO bad\nfile.ex:0:# TODO bad\n"
      assert TodoSearchSource.parse_output(output) == []
    end
  end

  describe "build_candidates/2" do
    test "creates picker items with icon, path line label, and trimmed description" do
      [item] =
        TodoSearchSource.build_candidates(
          [%{path: "lib/example.ex", line: 3, text: "  # NOTE explain"}],
          File.cwd!()
        )

      assert item.label =~ "lib/example.ex:3"
      assert item.description == "# NOTE explain"
      assert item.icon_color != nil
      assert item.id.line == 3
      assert String.ends_with?(item.id.path, "lib/example.ex")
    end

    test "empty and error results produce no items" do
      assert TodoSearchSource.build_candidates({:ok, ""}, File.cwd!()) == []
      assert TodoSearchSource.build_candidates({:error, "grep failed"}, File.cwd!()) == []
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

    test "preserves command failure presentation" do
      root_path = temporary_root()
      :ok = TodoSearchPortProbe.configure(:failure)

      assert {:error, message} = TodoSearch.run(effect(root_path, impl: TodoSearchPortProbe))

      assert message == "grep exited with status 2: probe failure"
    end

    test "marks a result stale when its revision differs from the request" do
      root = directory_root!(temporary_root())
      assert {:ok, _snapshot} = Project.activate(root)
      state = base_state(content: "scratch")
      {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
      request = TodoSearch.request(root, revision)

      result = %TodoSearch.Result{
        revision: make_ref(),
        items: [],
        candidates: [],
        meta: %{}
      }

      assert {^state, %Outcome{status: :stale, reason: :revision_mismatch}} =
               TodoSearch.apply(state, Outcome.completed(request, result))
    end

    test "marks a result stale after another picker source replaces TODO search" do
      root = directory_root!(temporary_root())
      assert {:ok, _snapshot} = Project.activate(root)
      state = base_state(content: "scratch")
      {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
      {state, _replacement_revision} = PickerUI.open_loading(state, FileSource)
      request = TodoSearch.request(root, revision)

      result = %TodoSearch.Result{
        revision: revision,
        items: [],
        candidates: [],
        meta: %{}
      }

      assert {^state, %Outcome{status: :stale, reason: :picker_closed_or_replaced}} =
               TodoSearch.apply(state, Outcome.completed(request, result))
    end

    test "rejects a result after the active workspace reroots" do
      root_a = directory_root!(temporary_root())
      root_b = directory_root!(temporary_root())
      assert {:ok, _snapshot} = Project.activate(root_a)

      state = base_state(content: "scratch")
      {state, revision} = PickerUI.open_loading(state, TodoSearchSource)
      request = TodoSearch.request(root_a, revision)
      assert {:ok, _snapshot} = Project.activate(root_b)

      result = %TodoSearch.Result{
        revision: revision,
        items: [],
        candidates: [],
        meta: %{}
      }

      assert {^state, %Outcome{status: :stale, reason: :workspace_rerooted}} =
               TodoSearch.apply(state, Outcome.completed(request, result))
    end
  end

  describe "root authorization boundary" do
    test "passes only the canonical path into Port arguments and candidate expansion" do
      container = temporary_root()
      canonical = Path.join(container, "canonical")
      alias_path = Path.join(container, "alias")
      File.mkdir_p!(canonical)
      File.ln_s!(canonical, alias_path)
      root = directory_root!(alias_path)

      assert {:ok, %TodoSearch.Result{items: [item]}} =
               TodoSearch.run(%TodoSearch{
                 root: root,
                 revision: make_ref(),
                 impl: TodoSearchPortProbe
               })

      assert_received {:todo_search_port_opened, "git",
                       ["-C", ^canonical, "rev-parse", "--is-inside-work-tree"]}

      assert item.id.path == Path.join(canonical, "lib/example.ex")
    end

    test "accepts a confirmed broad root before opening the probe Port" do
      root = %Root{kind: :directory, path: "/", broad_root_confirmed?: true}

      assert {:ok, %TodoSearch.Result{}} =
               TodoSearch.run(%TodoSearch{
                 root: root,
                 revision: make_ref(),
                 impl: TodoSearchPortProbe
               })

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

      assert EditorState.active_buffer(new_state) == 1
      assert BufferProcess.cursor(path_buffer) == {2, 0}
    end
  end

  @spec effect(String.t(), keyword()) :: TodoSearch.t()
  defp effect(root_path, opts \\ []) do
    %TodoSearch{
      root: directory_root!(root_path),
      revision: make_ref(),
      impl: Keyword.get(opts, :impl, MingaEditor.Effects.TodoSearch.Port)
    }
  end

  @spec directory_root!(String.t()) :: Root.t()
  defp directory_root!(path) do
    {:ok, root} = Root.directory(path)
    root
  end

  @spec assert_rejected_before_port(Root.t(), Root.error()) :: :ok
  defp assert_rejected_before_port(root, reason) do
    assert TodoSearch.run(%TodoSearch{
             root: root,
             revision: make_ref(),
             impl: TodoSearchPortProbe
           }) == {:error, "TODO search root rejected: #{reason}"}

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

  @spec restore_project(Minga.Project.WorkspaceSnapshot.t() | nil) :: :ok
  defp restore_project(nil) do
    Project.close()
    _ = :sys.get_state(Project)
    :ok
  end

  defp restore_project(%Minga.Project.WorkspaceSnapshot{root: root}) do
    Project.close()
    _ = :sys.get_state(Project)
    _ = Project.activate(root)
    :ok
  end
end
