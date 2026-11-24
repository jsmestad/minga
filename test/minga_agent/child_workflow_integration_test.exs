defmodule MingaAgent.ChildWorkflowIntegrationTest do
  @moduledoc """
  Parent and child agent workflow over a real Git worktree.

  A reader child and a writer child both complete. The writer's committed and untracked changes are collected on its handle, then three-way merged into the parent's changeset while the parent has its own edits to the same file.
  """

  # Real Git commands spawn OS processes, and Changeset.create/1 uses the global agent supervisor.
  use ExUnit.Case, async: false

  alias MingaAgent.Changeset
  alias MingaAgent.SessionManager
  alias MingaAgent.Subagent.Handle

  @moduletag timeout: 30_000

  @base_app "defmodule App do\n  def hello, do: :world\n  def bye, do: :later\nend\n"
  @child_app "defmodule App do\n  def hello, do: :updated\n  def bye, do: :later\nend\n"
  @helper "defmodule Helper do\n  def assist, do: :ok\nend\n"

  setup do
    tmp = Path.join(System.tmp_dir!(), "minga-e2e-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "lib"))

    git!(tmp, ["init"])
    # Disable inherited hooks and signing so the fixture does not depend on the host's git setup.
    hooks_dir = Path.join(tmp, ".git/hooks-disabled")
    File.mkdir_p!(hooks_dir)
    git!(tmp, ["config", "core.hooksPath", hooks_dir])
    git!(tmp, ["config", "user.name", "Minga Test"])
    git!(tmp, ["config", "user.email", "test@example.com"])
    git!(tmp, ["config", "commit.gpgsign", "false"])

    File.write!(Path.join(tmp, "lib/app.ex"), @base_app)
    git!(tmp, ["add", "."])
    git!(tmp, ["commit", "-m", "initial"])
    base_sha = tmp |> git!(["rev-parse", "HEAD"]) |> String.trim()

    wt_path = tmp <> "-child-writer"
    git!(tmp, ["worktree", "add", "-b", "child-writer", wt_path, base_sha])

    # The child commits one edit and leaves its new file untracked.
    File.write!(Path.join(wt_path, "lib/app.ex"), @child_app)
    git!(wt_path, ["commit", "-am", "child edit"])
    File.write!(Path.join(wt_path, "lib/helper.ex"), @helper)

    session_supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, manager} =
      SessionManager.start_link(
        name: :"e2e_manager_#{System.unique_integer([:positive])}",
        session_supervisor: session_supervisor,
        child_limit: 5
      )

    Process.unlink(manager)

    on_exit(fn ->
      if Process.alive?(manager), do: GenServer.stop(manager)
      git!(tmp, ["worktree", "remove", "--force", wt_path])
      File.rm_rf!(wt_path)
      File.rm_rf!(tmp)
    end)

    {:ok, changeset} = Changeset.create(tmp)
    on_exit(fn -> if Process.alive?(changeset), do: Changeset.discard(changeset) end)

    %{tmp: tmp, base_sha: base_sha, wt_path: wt_path, manager: manager, changeset: changeset}
  end

  describe "two-child workflow" do
    test "the parent collects both results and merges the writer's work around its own edit",
         ctx do
      parent_pid = start_parent(ctx.manager)
      reader = start_child(ctx.manager, parent_pid, "review the code")
      writer = start_child(ctx.manager, parent_pid, "implement", writer_opts(ctx))

      assert writer.worktree_path == ctx.wt_path
      assert reader.worktree_path == nil

      :ok =
        Changeset.write_file(
          ctx.changeset,
          "lib/app.ex",
          String.replace(@base_app, ":later", ":soon")
        )

      finish(ctx.manager, reader)
      finish(ctx.manager, writer)

      assert {:ok, %Handle{status: :completed, changes: nil}} =
               SessionManager.get_child_result(ctx.manager, reader.session_id)

      assert {:ok, %Handle{status: :completed, changes: changes}} =
               SessionManager.get_child_result(ctx.manager, writer.session_id)

      assert Enum.sort(changes) == [{:added, "lib/helper.ex"}, {:modified, "lib/app.ex"}]

      assert {:ok, applied} =
               SessionManager.integrate_child_changes(
                 ctx.manager,
                 writer.session_id,
                 ctx.changeset
               )

      assert Enum.sort(applied) == ["lib/app.ex", "lib/helper.ex"]

      assert {:ok, "defmodule App do\n  def hello, do: :updated\n  def bye, do: :soon\nend\n"} =
               Changeset.read_file(ctx.changeset, "lib/app.ex")

      assert {:ok, @helper} = Changeset.read_file(ctx.changeset, "lib/helper.ex")
    end

    test "an edit to the same line conflicts, writes nothing and keeps both sides", ctx do
      parent_pid = start_parent(ctx.manager)
      writer = start_child(ctx.manager, parent_pid, "implement", writer_opts(ctx))
      parent_edit = String.replace(@base_app, ":world", ":diverged")
      :ok = Changeset.write_file(ctx.changeset, "lib/app.ex", parent_edit)
      finish(ctx.manager, writer)

      assert {:conflict,
              %{conflicts: [{"lib/app.ex", {:merge_conflict, _hunks}}], clean: ["lib/helper.ex"]}} =
               SessionManager.integrate_child_changes(
                 ctx.manager,
                 writer.session_id,
                 ctx.changeset
               )

      assert {:ok, ^parent_edit} = Changeset.read_file(ctx.changeset, "lib/app.ex")
      assert {:error, _} = Changeset.read_file(ctx.changeset, "lib/helper.ex")
      assert File.read!(Path.join(ctx.wt_path, "lib/app.ex")) == @child_app
      assert File.read!(Path.join(ctx.wt_path, "lib/helper.ex")) == @helper
    end

    test "a read-only child has nothing to integrate", ctx do
      parent_pid = start_parent(ctx.manager)
      reader = start_child(ctx.manager, parent_pid, "just reading")
      finish(ctx.manager, reader)

      assert {:error, :no_changes} =
               SessionManager.integrate_child_changes(
                 ctx.manager,
                 reader.session_id,
                 ctx.changeset
               )
    end
  end

  @spec session_opts() :: keyword()
  defp session_opts, do: [provider: Minga.Test.StubProvider, provider_opts: [], persist?: false]

  @spec writer_opts(map()) :: keyword()
  defp writer_opts(ctx), do: [worktree_path: ctx.wt_path, worktree_base_sha: ctx.base_sha]

  @spec start_parent(GenServer.server()) :: pid()
  defp start_parent(manager) do
    {:ok, _id, pid} = SessionManager.start_session(manager, session_opts())
    pid
  end

  @spec start_child(GenServer.server(), pid(), String.t(), keyword()) :: Handle.t()
  defp start_child(manager, parent_pid, task, opts \\ []) do
    {:ok, handle} =
      SessionManager.start_background_subagent(
        manager,
        parent_pid,
        task,
        [session_opts: session_opts()] ++ opts
      )

    handle
  end

  @spec finish(GenServer.server(), Handle.t()) :: :ok
  defp finish(manager, %Handle{} = handle) do
    ref = Process.monitor(handle.pid)
    SessionManager.stop_session(manager, handle.session_id)
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    :sys.get_state(manager)
    :ok
  end

  @spec git!(String.t(), [String.t()]) :: String.t()
  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
