defmodule MingaAgent.ToolRouterTest do
  use ExUnit.Case, async: true

  alias MingaAgent.BufferForkStore
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.RecordingBackend
  alias MingaAgent.ProjectView.UnavailableBackend
  alias MingaAgent.ToolRouter
  alias Minga.Buffer.Fork

  setup do
    path = "/tmp/tool-router-test-#{System.unique_integer([:positive])}/lib/foo.ex"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "defmodule Foo do\n  def hello, do: :world\nend\n")

    {:ok, parent} =
      start_supervised({Minga.Buffer.Process, content: File.read!(path), file_path: path})

    {:ok, store} = start_supervised(BufferForkStore)

    on_exit(fn -> File.rm_rf!(Path.dirname(path)) end)

    %{
      parent: parent,
      store: store,
      path: path
    }
  end

  describe "context/2" do
    test "builds a context map" do
      ctx = ToolRouter.context(self(), nil)
      assert ctx.fork_store == self()
      assert ctx.changeset == nil
    end
  end

  describe "read_file/2 with fork store" do
    test "reads from fork when one exists", %{store: store, parent: parent, path: path} do
      ctx = ToolRouter.context(store, nil)

      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "modified via fork\n")

      assert {:ok, "modified via fork\n"} = ToolRouter.read_file(ctx, path)
    end

    test "returns a tagged error when the fork store dies before a read", %{
      store: store,
      parent: parent,
      path: path
    } do
      ctx = ToolRouter.context(store, nil)
      {:ok, fork_pid} = BufferForkStore.get_or_create(store, path, parent)
      Fork.replace_content(fork_pid, "forked content\n")
      Process.exit(store, :kill)

      assert {:error, {:fork_unavailable, reason}} = ToolRouter.read_file(ctx, path)
      assert reason != nil
    end

    test "reads the buffer into a session fork when none exists", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)

      {:ok, content} = ToolRouter.read_file(ctx, path)
      assert content =~ "defmodule Foo"
    end

    test "falls through to filesystem with no routing", %{path: path} do
      ctx = ToolRouter.context(nil, nil)

      assert {:ok, content} = ToolRouter.read_file(ctx, path)
      assert content =~ "defmodule Foo"
    end
  end

  describe "read_file/2 with changeset" do
    test "returns tagged errors when a dead changeset is asked to read", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      ref = Process.monitor(changeset)
      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      assert {:error, {:changeset_unavailable, reason}} = ToolRouter.read_file(ctx, path)
      assert reason != nil
    end
  end

  describe "read_file/2 with ProjectView" do
    test "surfaces backend errors without tagging them unavailable", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))

      view =
        ProjectView.new(MingaAgent.Test.ProjectView.FailingBackend, project_root, %{ref: self()},
          workspace_id: 7
        )

      ctx = ToolRouter.context(view, nil, nil)
      assert {:error, :unsupported} = ToolRouter.read_file(ctx, path)
    end
  end

  describe "conditional_mutate/4" do
    test "the routed read creates an isolated fork whose revision authorizes mutation", %{
      store: store,
      parent: parent,
      path: path
    } do
      ctx = ToolRouter.context(store, nil)
      assert BufferForkStore.get(store, path) == nil
      expected = revision(ctx, path)
      fork = BufferForkStore.get(store, path)
      assert is_pid(fork)
      original = Minga.Buffer.content(parent)

      assert :ok = ToolRouter.conditional_mutate(ctx, path, expected, {:replace, "new content\n"})
      assert Fork.content(fork) == "new content\n"
      assert Minga.Buffer.content(parent) == original
      assert File.read!(path) == original
    end

    test "commits the complete edit batch to the fork, never a prefix", %{
      store: store,
      path: path
    } do
      ctx = ToolRouter.context(store, nil)
      expected = revision(ctx, path)
      fork = BufferForkStore.get(store, path)
      original = Fork.content(fork)
      version = Fork.version(fork)

      assert {:error, {:edit_failed, 2, _}} =
               ToolRouter.conditional_mutate(
                 ctx,
                 path,
                 expected,
                 {:edit,
                  [
                    {"defmodule Foo", "defmodule Bar"},
                    {"missing", "replacement"}
                  ]}
               )

      assert Fork.content(fork) == original
      assert Fork.version(fork) == version

      assert :ok =
               ToolRouter.conditional_mutate(
                 ctx,
                 path,
                 expected,
                 {:edit,
                  [
                    {"defmodule Foo", "defmodule Bar"},
                    {":world", ":cosmos"}
                  ]}
               )

      assert Fork.content(fork) =~ "defmodule Bar"
      assert Fork.content(fork) =~ ":cosmos"
      assert Fork.version(fork) == version + 1
    end

    test "stale and missing revisions cannot modify a fork", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)
      expected = revision(ctx, path)
      assert :ok = ToolRouter.conditional_mutate(ctx, path, expected, {:replace, "newer"})

      assert {:error, :stale_revision} =
               ToolRouter.conditional_mutate(ctx, path, expected, {:replace, "stale"})

      assert {:error, :revision_required} =
               ToolRouter.conditional_mutate(ctx, path, nil, {:replace, "unchecked"})

      assert Fork.content(BufferForkStore.get(store, path)) == "newer"
    end

    test "a first mutation without a read cannot write the parent buffer", %{
      store: store,
      parent: parent,
      path: path
    } do
      original = Minga.Buffer.content(parent)
      ctx = ToolRouter.context(store, nil)
      assert {:error, _} = ToolRouter.conditional_mutate(ctx, path, nil, {:replace, "unchecked"})
      assert Minga.Buffer.content(parent) == original
      assert File.read!(path) == original
    end

    test "opening a buffer cannot replace a changeset draft or resurrect its deletion", %{
      store: store,
      path: path
    } do
      root = Path.dirname(path)
      changeset = start_supervised!({MingaAgent.Changeset.Server, project_root: root})
      context = ToolRouter.context(store, changeset)

      for {operation, index} <- Enum.with_index([{:replace, "draft"}, :delete]) do
        target = Path.join(root, "opened-later-#{index}.txt")
        File.write!(target, "original")
        expected = revision(context, target)
        assert :ok = ToolRouter.conditional_mutate(context, target, expected, operation)

        buffer =
          start_supervised!(
            Supervisor.child_spec({Minga.Buffer.Process, file_path: target},
              id: {:opened_later, index}
            )
          )

        assert {:error, _} =
                 ToolRouter.conditional_mutate(
                   context,
                   target,
                   expected,
                   {:replace, "stale overwrite"}
                 )

        expected_content =
          case operation do
            {:replace, content} -> {:ok, content}
            :delete -> {:error, :deleted}
          end

        assert ToolRouter.read_file(context, target) == expected_content
        assert Minga.Buffer.content(buffer) == "original"
        assert File.read!(target) == "original"
      end
    end

    test "a dead fork store never permits direct writes", %{store: store, path: path} do
      ctx = ToolRouter.context(store, nil)
      expected = revision(ctx, path)
      ref = Process.monitor(store)
      Process.exit(store, :kill)
      assert_receive {:DOWN, ^ref, :process, ^store, _}

      assert {:error, {:fork_unavailable, _}} =
               ToolRouter.conditional_mutate(ctx, path, expected, {:replace, "new"})

      assert File.read!(path) =~ "defmodule Foo"
    end

    test "no editable owner returns an error, not filesystem passthrough", %{path: path} do
      unmanaged = Path.join(Path.dirname(path), "unmanaged.txt")
      File.write!(unmanaged, "original")

      for ctx <- [ToolRouter.context(nil, nil), ToolRouter.context(self(), nil)] do
        assert {:error, _} =
                 ToolRouter.conditional_mutate(ctx, unmanaged, :absent, {:create, "new"})
      end

      assert File.read!(unmanaged) == "original"
    end

    test "dead changesets reject replacement, edit, create, and deletion", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))
      changeset = start_supervised!({MingaAgent.Changeset.Server, project_root: project_root})
      ctx = ToolRouter.context(nil, nil, changeset)
      expected = revision(ctx, path)
      ref = Process.monitor(changeset)
      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _}

      for {expectation, operation} <- [
            {expected, {:replace, "new"}},
            {expected, {:edit, [{"defmodule Foo", "defmodule Bar"}]}},
            {:absent, {:create, "new"}},
            {expected, :delete}
          ] do
        assert {:error, {:changeset_unavailable, _}} =
                 ToolRouter.conditional_mutate(ctx, path, expectation, operation)
      end

      assert File.read!(path) =~ "defmodule Foo"
    end

    test "ProjectView operation errors remain explicit", %{path: path} do
      root = Path.dirname(Path.dirname(path))
      {:ok, view} = UnavailableBackend.create(root, [])
      ctx = ToolRouter.context(view, nil, nil)

      assert {:error, :write_failed} =
               ToolRouter.conditional_mutate(ctx, path, :absent, {:create, "new"})

      assert {:error, :edit_failed} =
               ToolRouter.conditional_mutate(ctx, path, "revision", {:edit, [{"old", "new"}]})

      assert {:error, :delete_failed} =
               ToolRouter.conditional_mutate(ctx, path, "revision", :delete)
    end
  end

  describe "changeset-only routing" do
    test "filesystem_path_result returns overlay-relative paths for isolated file state", %{
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      overlay_dir = MingaAgent.Changeset.overlay_path(changeset)

      assert :ok =
               ToolRouter.conditional_mutate(
                 ctx,
                 path,
                 revision(ctx, path),
                 {:replace, "draft\n"}
               )

      assert {:ok, root_resolved} = ToolRouter.filesystem_path_result(ctx, ".")
      assert root_resolved == overlay_dir
      assert {:ok, resolved} = ToolRouter.filesystem_path_result(ctx, path)
      assert resolved == Path.join(overlay_dir, "lib/foo.ex")
      assert File.read!(resolved) == "draft\n"

      assert :ok = ToolRouter.conditional_mutate(ctx, path, revision(ctx, path), :delete)
      assert {:ok, deleted_resolved} = ToolRouter.filesystem_path_result(ctx, path)
      assert deleted_resolved == Path.join(overlay_dir, "lib/foo.ex")
      refute File.exists?(deleted_resolved)
    end

    test "list_directory sees changeset writes and tombstones", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)

      assert :ok =
               ToolRouter.conditional_mutate(
                 ctx,
                 Path.join(project_root, "lib/new.txt"),
                 :absent,
                 {:create, "new\n"}
               )

      assert :ok = ToolRouter.conditional_mutate(ctx, path, revision(ctx, path), :delete)

      assert {:ok, entries} = ToolRouter.list_directory(ctx, Path.join(project_root, "lib"))
      assert %{name: "new.txt", type: :file} in entries
      refute Enum.any?(entries, &(&1.name == "foo.ex"))
    end
  end

  describe "search_context/2" do
    test "uses the validated path for direct execution and filtering", %{path: path} do
      ctx = ToolRouter.context(nil, nil)

      assert {:ok, search} = ToolRouter.search_context(ctx, path)
      assert search.exec_path == path
      assert search.filter_root == path
    end

    test "uses ProjectView working dir for execution and validated path for filtering", %{
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))
      {:ok, view} = ProjectView.overlay(project_root)
      ctx = ToolRouter.context(view, nil, nil)
      overlay_dir = ProjectView.working_dir(view)

      assert {:ok, search} = ToolRouter.search_context(ctx, Path.join(project_root, "lib"))
      assert search.exec_path == Path.join(overlay_dir, "lib")
      assert search.filter_root == Path.join(project_root, "lib")
    end

    test "uses changeset overlay dir for execution and validated path for filtering", %{
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      overlay_dir = MingaAgent.Changeset.overlay_path(changeset)

      assert {:ok, search} = ToolRouter.search_context(ctx, Path.join(project_root, "lib"))
      assert search.exec_path == Path.join(overlay_dir, "lib")
      assert search.filter_root == Path.join(project_root, "lib")
    end

    test "materializes fork drafts into changeset search and command views", %{
      store: store,
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(store, changeset)
      original = File.read!(path)

      assert :ok =
               ToolRouter.conditional_mutate(
                 ctx,
                 path,
                 revision(ctx, path),
                 {:replace, "fork draft needle\n"}
               )

      assert File.read!(path) == original
      assert {:ok, search} = ToolRouter.search_context(ctx, Path.join(project_root, "lib"))
      assert File.read!(Path.join(search.exec_path, "foo.ex")) == "fork draft needle\n"

      assert {:ok, resolved} = ToolRouter.filesystem_path_result(ctx, path)
      assert File.read!(resolved) == "fork draft needle\n"

      assert {:ok, cwd} = ToolRouter.working_dir_result(ctx)
      assert File.read!(Path.join(cwd, "lib/foo.ex")) == "fork draft needle\n"
    end
  end

  describe "directory and environment projections" do
    test "ProjectView APIs project one successful resolution per call", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))
      working_dir = Path.join(project_root, "project-view")
      env = [{"ROUTED", "true"}]

      {:ok, view} =
        RecordingBackend.create(project_root,
          parent: self(),
          working_dir: working_dir,
          env: env
        )

      ctx = ToolRouter.context(view, nil, nil)

      assert ToolRouter.filesystem_path(ctx, path) == Path.join(working_dir, "lib/foo.ex")
      assert_received {:project_view_call, :prepare_working_dir}
      refute_received {:project_view_call, :prepare_working_dir}

      assert {:ok, resolved_path} = ToolRouter.filesystem_path_result(ctx, path)
      assert resolved_path == Path.join(working_dir, "lib/foo.ex")
      assert_received {:project_view_call, :prepare_working_dir}
      refute_received {:project_view_call, :prepare_working_dir}

      assert ToolRouter.working_dir(ctx) == working_dir
      assert_received {:project_view_call, :prepare_working_dir}
      refute_received {:project_view_call, :prepare_working_dir}

      assert ToolRouter.working_dir_result(ctx) == {:ok, working_dir}
      assert_received {:project_view_call, :prepare_working_dir}
      refute_received {:project_view_call, :prepare_working_dir}

      assert ToolRouter.command_env(ctx) == env
      assert_received {:project_view_call, :command_env}
      refute_received {:project_view_call, :command_env}

      assert ToolRouter.command_env_result(ctx) == {:ok, env}
      assert_received {:project_view_call, :command_env}
      refute_received {:project_view_call, :command_env}
    end

    test "compatibility APIs collapse routing failure without changing tagged results", %{
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))
      {:ok, view} = UnavailableBackend.create(project_root, workspace_id: 7)
      ctx = ToolRouter.context(view, nil, nil)

      assert ToolRouter.filesystem_path(ctx, path) == path

      assert ToolRouter.filesystem_path_result(ctx, path) ==
               {:error, {:project_view_unavailable, {:working_dir_failed, :working_dir_failed}}}

      assert ToolRouter.working_dir(ctx) == nil

      assert ToolRouter.working_dir_result(ctx) ==
               {:error, {:project_view_unavailable, {:working_dir_failed, :working_dir_failed}}}

      assert ToolRouter.command_env(ctx) == []

      assert ToolRouter.command_env_result(ctx) ==
               {:error, {:project_view_unavailable, {:command_env_failed, :command_env_failed}}}
    end

    test "passthrough keeps absent directory and empty environment distinct from failure", %{
      path: path
    } do
      ctx = ToolRouter.context(nil, nil)

      assert ToolRouter.filesystem_path(ctx, path) == path
      assert ToolRouter.filesystem_path_result(ctx, path) == {:ok, path}
      assert ToolRouter.working_dir(ctx) == nil
      assert ToolRouter.working_dir_result(ctx) == {:ok, nil}
      assert ToolRouter.command_env(ctx) == []
      assert ToolRouter.command_env_result(ctx) == {:ok, []}
    end

    test "changeset projections resolve the same paths and environment", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      expected_path = Path.join(MingaAgent.Changeset.overlay_path(changeset), "lib/foo.ex")

      assert ToolRouter.filesystem_path(ctx, path) == expected_path
      assert ToolRouter.filesystem_path_result(ctx, path) == {:ok, expected_path}

      working_dir = ToolRouter.working_dir(ctx)
      assert ToolRouter.working_dir_result(ctx) == {:ok, working_dir}

      env = ToolRouter.command_env(ctx)
      assert ToolRouter.command_env_result(ctx) == {:ok, env}
    end

    test "compatibility lookups do not materialize live buffer forks", %{
      store: store,
      path: path
    } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(store, changeset)
      original = File.read!(path)

      assert :ok =
               ToolRouter.conditional_mutate(
                 ctx,
                 path,
                 revision(ctx, path),
                 {:replace, "uncommitted fork draft\n"}
               )

      resolved_path = ToolRouter.filesystem_path(ctx, path)
      assert ToolRouter.working_dir(ctx) == Path.dirname(Path.dirname(resolved_path))
      assert File.read!(resolved_path) == original

      assert {:ok, ^resolved_path} = ToolRouter.filesystem_path_result(ctx, path)
      assert File.read!(resolved_path) == "uncommitted fork draft\n"
    end

    test "dead routing dependencies remain tagged for execution and collapsed for compatibility",
         %{
           path: path
         } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(nil, nil, changeset)
      :ok = :sys.suspend(changeset)

      task =
        Task.async(fn ->
          receive do
            :resolve -> ToolRouter.filesystem_path_result(ctx, path)
          end
        end)

      :erlang.trace(task.pid, true, [:send])
      send(task.pid, :resolve)

      assert_receive {:trace, task_pid, :send, {:"$gen_call", _from, :materialize_for_command},
                      ^changeset}

      assert task_pid == task.pid

      ref = Process.monitor(changeset)
      Process.exit(changeset, :kill)
      assert_receive {:DOWN, ^ref, :process, ^changeset, _reason}

      assert {:error, filesystem_reason} = Task.await(task)
      assert filesystem_reason != nil
      assert ToolRouter.filesystem_path(ctx, path) == path

      assert ToolRouter.working_dir(ctx) == nil
      assert {:error, working_dir_reason} = ToolRouter.working_dir_result(ctx)
      assert working_dir_reason != nil
      assert ToolRouter.command_env(ctx) == []
      assert {:error, {:changeset_unavailable, _reason}} = ToolRouter.command_env_result(ctx)
    end

    test "a dead fork store blocks execution preparation without blocking compatibility lookups",
         %{
           store: store,
           path: path
         } do
      project_root = Path.dirname(Path.dirname(path))

      {:ok, changeset} =
        start_supervised({MingaAgent.Changeset.Server, project_root: project_root})

      ctx = ToolRouter.context(store, changeset)
      ref = Process.monitor(store)
      Process.exit(store, :kill)
      assert_receive {:DOWN, ^ref, :process, ^store, _reason}

      assert is_binary(ToolRouter.filesystem_path(ctx, path))
      assert is_binary(ToolRouter.working_dir(ctx))
      assert is_list(ToolRouter.command_env(ctx))

      assert {:error, {:fork_unavailable, _reason}} =
               ToolRouter.filesystem_path_result(ctx, path)

      assert {:error, {:fork_unavailable, _reason}} = ToolRouter.working_dir_result(ctx)
      assert {:error, {:fork_unavailable, _reason}} = ToolRouter.search_context(ctx, path)
    end
  end

  describe "working_dir/1" do
    test "returns nil with no changeset" do
      ctx = ToolRouter.context(nil, nil)
      assert nil == ToolRouter.working_dir(ctx)
    end

    test "materializes project views before returning a tool working directory", %{path: path} do
      project_root = Path.dirname(Path.dirname(path))
      File.write!(Path.join(project_root, "README.md"), "readme\n")
      {:ok, view} = ProjectView.overlay(project_root)
      ctx = ToolRouter.context(view, nil, nil)
      overlay_dir = ProjectView.working_dir(view)

      refute File.exists?(Path.join(overlay_dir, "README.md"))
      assert {:ok, ^overlay_dir} = ToolRouter.working_dir_result(ctx)
      assert File.read!(Path.join(overlay_dir, "README.md")) == "readme\n"
    end
  end

  describe "active?/1" do
    test "returns false with nil context" do
      ctx = ToolRouter.context(nil, nil)
      refute ToolRouter.active?(ctx)
    end

    test "returns true with active fork store", %{store: store} do
      ctx = ToolRouter.context(store, nil)
      assert ToolRouter.active?(ctx)
    end
  end

  describe "has_forks?/1" do
    test "returns false with no fork store" do
      ctx = ToolRouter.context(nil, nil)
      refute ToolRouter.has_forks?(ctx)
    end

    test "returns false when fork store is empty", %{store: store} do
      ctx = ToolRouter.context(store, nil)
      refute ToolRouter.has_forks?(ctx)
    end

    test "returns true when forks exist", %{store: store, parent: parent, path: path} do
      ctx = ToolRouter.context(store, nil)
      BufferForkStore.get_or_create(store, path, parent)
      assert ToolRouter.has_forks?(ctx)
    end
  end

  defp revision(context, path) do
    retained = MingaAgent.Test.RetainedContextFixture.new(Path.dirname(path), "router-revision")

    assert {:ok, output} =
             ToolRouter.capture_file(context, path, retained.artifact_store, retained.capture_key)

    assert MingaAgent.Tool.Output.Revision.full_source?(output.revision)
    MingaAgent.Tool.Output.Revision.token(output.revision)
  end
end
