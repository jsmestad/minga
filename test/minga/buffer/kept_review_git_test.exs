defmodule Minga.Buffer.KeptReviewGitTest do
  # The fixtures and proof worker run the real Git CLI.
  use ExUnit.Case, async: false

  alias Minga.Buffer
  alias Minga.Buffer.EditSource
  alias Minga.Buffer.KeptReview.GitEvidence
  alias Minga.Events
  alias Minga.Git.Buffer, as: GitBuffer
  alias Minga.Git.Repo
  alias Minga.Git.Stub, as: GitStub
  alias Minga.Git.System, as: GitSystem

  @moduletag :tmp_dir
  @moduletag timeout: 15_000

  @git_env [
    {"GIT_CONFIG_NOSYSTEM", "1"},
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@test.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@test.com"}
  ]

  setup %{tmp_dir: root} do
    root = Path.expand(root)
    path = Path.join(root, "owned.txt")
    git!(root, ["init", "-q", "-b", "main"])
    File.write!(path, "a\nb\n")
    git!(root, ["add", "owned.txt"])
    git!(root, ["commit", "-qm", "initial"])
    assert {:ok, {git_root, _, _}} = Minga.Git.System.review_baseline(path)
    events = :"kept_review_git_events_#{System.unique_integer([:positive, :monotonic])}"
    start_supervised!({Events, name: events})
    Events.subscribe(:buffer_review_changed, registry: events)
    repo = start_supervised!({Repo, git_root: git_root, events_registry: events})
    refresh(repo, git_root)
    %{root: git_root, path: path, swap_dir: Path.join(root, "swap"), events: events, repo: repo}
  end

  test "a partial commit clears only the included human row after undo eviction", ctx do
    buffer = start_buffer(ctx)

    git =
      start_supervised!(
        {GitBuffer,
         git_root: ctx.root, file_path: ctx.path, backend: GitSystem, initial_content: "a\nb\n"}
      )

    apply_edit(buffer, {0, 0}, 1, "A", EditSource.user())
    apply_edit(buffer, {1, 0}, 1, "B", EditSource.user())
    :ok = Buffer.move_to(buffer, {2, 0})

    for _ <- 1..1_000 do
      :ok = Buffer.break_undo_coalescing(buffer)
      :ok = Buffer.insert_text(buffer, "x")
    end

    assert :ok = Buffer.save(buffer)
    :ok = GitBuffer.observe(git, buffer, Buffer.file_observation(buffer), :cached_head)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    %{review_lease: before_commit} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:you, {0, 0}, 0}, {:you, {1, 0}, 1}]} =
             Buffer.render_review_regions(buffer, before_commit, [{0, 1}])

    stage_bytes(ctx, "A\nb\n")
    git!(ctx.root, ["commit", "-qm", "Only one human row"])
    :ok = GitBuffer.observe(git, buffer, Buffer.file_observation(buffer), :refresh_head)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}

    assert %{review_lease: partial, review_damage: {:since, ^before_commit, [{0, 0}]}} =
             Buffer.renderer_consume(buffer)

    assert {:ok, [{:you, {1, 0}, 1}]} = Buffer.render_review_regions(buffer, partial, [{0, 1}])
    assert Buffer.author_at(buffer, {0, 0}) == :you
    assert Buffer.content(buffer) == "A\nB\n" <> String.duplicate("x", 1_000)

    apply_edit(buffer, {0, 0}, 1, "!", EditSource.user())
    %{review_lease: edited} = Buffer.renderer_consume(buffer)

    assert {:ok, [{:you, {0, 0}, 0}, {:you, {1, 0}, 1}]} =
             Buffer.render_review_regions(buffer, edited, [{0, 1}])
  end

  test "a prefix commit missed while closed retires only its mark, then the EOF commit retires the gap",
       ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 0}, 1, "A", "prefix")
    replace(buffer, {1, 1}, 1, "", "eof")
    assert :ok = Buffer.save(buffer)

    assert {:ok, target, {:minga, "review"}, 2} =
             Buffer.prepare_review(buffer, {:task, {:minga, "review"}})

    assert :ok = Buffer.decide_review(buffer, target, :keep)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
    assert kept(buffer) == [{:kept, {0, 0}, 0}, {:kept, {1, 1}, 1}]
    assert :ok = GenServer.stop(buffer)

    stage_bytes(ctx, "A\nb\n")
    git!(ctx.root, ["commit", "-qm", "same message"])
    git!(ctx.root, ["commit", "-q", "--allow-empty", "-m", "same message"])
    refresh(ctx.repo, ctx.root)

    reopened = start_buffer(ctx)

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^reopened}},
                   4_000

    assert kept(reopened) == [{:kept, {1, 1}, 1}]
    assert Buffer.content(reopened) == "A\nb"
    refute Buffer.dirty?(reopened)
    assert File.read!(ctx.path) == "A\nb"

    git!(ctx.root, ["add", "owned.txt"])
    git!(ctx.root, ["commit", "-qm", "same message"])
    refresh(ctx.repo, ctx.root)

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^reopened}},
                   4_000

    assert kept(reopened) == []
    assert Buffer.author_at(reopened, {0, 0}) == {:minga, "review"}
    assert Buffer.content(reopened) == "A\nb"
    refute Buffer.dirty?(reopened)
  end

  test "a commit made after observing Git and before publishing Keep is still included", ctx do
    caller = self()

    observe = fn path, dirty? ->
      capture = GitEvidence.capture(path, dirty?, &GitSystem.review_baseline/1)
      send(caller, {:keeping, self(), capture})

      receive do
        :publish_keep -> capture
      after
        5_000 -> exit(:test_gate_not_released)
      end
    end

    buffer = start_buffer(ctx, keep_observer: observe)
    replace(buffer, {0, 0}, 1, "A", "prefix")
    assert :ok = Buffer.save(buffer)
    assert {:ok, target, {:minga, "review"}, 1} = Buffer.prepare_review(buffer, :latest)
    request = Buffer.request_keep(buffer, target)
    assert_receive {:keeping, worker, {{_, "owned.txt", {"refs/heads/main", _, _}}, nil}}, 2_000

    git!(ctx.root, ["add", "owned.txt"])
    git!(ctx.root, ["commit", "-qm", "included while observing"])
    refresh(ctx.repo, ctx.root)
    send(worker, :publish_keep)

    assert {:reply, :ok} = :gen_server.receive_response(request, 2_000)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}},
                   4_000

    assert kept(buffer) == []
    assert Buffer.content(buffer) == "A\nb\n"
    assert Buffer.author_at(buffer, {0, 0}) == {:minga, "review"}
  end

  test "saving the same bytes with a new origin does not conflate two projections", ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 1}, 0, "X", "first")
    assert :ok = Buffer.save(buffer)
    keep_at(buffer, 1)

    apply_edit(buffer, {0, 1}, 1, "", EditSource.user())
    replace(buffer, {0, 1}, 0, "X", "second")
    assert :ok = Buffer.save(buffer)
    keep_at(buffer, 1)
    assert kept(buffer) == [{:kept, {0, 1}, 0}]

    git!(ctx.root, ["add", "owned.txt"])
    git!(ctx.root, ["commit", "-qm", "include saved bytes"])
    refresh(ctx.repo, ctx.root)

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}},
                   4_000

    assert kept(buffer) == []
    assert Buffer.content(buffer) == "aX\nb\n"
  end

  test "a new save gives an already-kept origin its changed surrounding context", ctx do
    buffer = start_buffer(ctx)
    replace(buffer, {0, 1}, 0, "X", "insertion")
    assert :ok = Buffer.save(buffer)
    keep_at(buffer, 1)
    apply_edit(buffer, {0, 0}, 1, "z", EditSource.user())
    assert :ok = Buffer.save(buffer)
    assert kept(buffer) == [{:kept, {0, 1}, 0}]

    stage_bytes(ctx, "z\nb\n")
    git!(ctx.root, ["commit", "-qm", "only the human edit"])
    git!(ctx.root, ["add", "owned.txt"])
    git!(ctx.root, ["commit", "-qm", "include the kept edit"])
    refresh(ctx.repo, ctx.root)

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}},
                   4_000

    assert kept(buffer) == []
    assert Buffer.content(buffer) == "zX\nb\n"
  end

  test "untasked insertion and EOF deletion retire as exact sources", ctx do
    buffer = start_buffer(ctx)
    agent = EditSource.from_undo_source(:agent)
    apply_edit(buffer, {0, 1}, 0, "X", agent)
    apply_edit(buffer, {1, 1}, 1, "", agent)
    assert :ok = Buffer.save(buffer)
    keep_at(buffer, 1)
    keep_at(buffer, 4)
    assert kept(buffer) == [{:kept, {0, 1}, 0}, {:kept, {1, 1}, 1}]

    git!(ctx.root, ["add", "owned.txt"])
    git!(ctx.root, ["commit", "-qm", "untasked edits"])
    refresh(ctx.repo, ctx.root)

    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}},
                   4_000

    assert kept(buffer) == []
    assert Buffer.content(buffer) == "aX\nb"
  end

  test "a Git change observed before publication invalidates a previously completed proof", ctx do
    caller = self()

    observe = fn path, ledger, cache ->
      case GitEvidence.prove(path, ledger, cache) do
        {:ok, [_ | _], _} = result ->
          send(caller, {:proof_ready, self()})

          receive do
            :publish_proof -> result
          after
            5_000 -> exit(:test_gate_not_released)
          end

        result ->
          send(caller, {:proof_without_match, self()})
          result
      end
    end

    git!(ctx.root, ["branch", "alternate"])
    buffer = start_buffer(ctx, kept_proof_observer: observe)
    replace(buffer, {0, 1}, 0, "X", "pending")
    assert :ok = Buffer.save(buffer)
    keep_at(buffer, 1)
    assert_receive {:proof_without_match, _}, 2_000
    git!(ctx.root, ["add", "owned.txt"])
    git!(ctx.root, ["commit", "-qm", "proves Keep on main"])
    refresh(ctx.repo, ctx.root)
    assert_receive {:proof_ready, worker}, 3_000

    git!(ctx.root, ["symbolic-ref", "HEAD", "refs/heads/alternate"])
    GitStub.set_branch(ctx.root, "alternate")
    refresh(ctx.repo, ctx.root)
    assert %{kept_proof: {^worker, _, _, _, _, true}} = :sys.get_state(buffer)

    send(worker, :publish_proof)
    assert_receive {:proof_without_match, _}, 3_000
    assert kept(buffer) == [{:kept, {0, 1}, 0}]
    assert Buffer.content(buffer) == "aX\nb\n"
  end

  defp keep_at(buffer, point) do
    assert {:ok, target, _, 1} = Buffer.prepare_review(buffer, {:at_byte, point})
    assert :ok = Buffer.decide_review(buffer, target, :keep)
    assert_receive {:minga_event, :buffer_review_changed, %Events.BufferEvent{buffer: ^buffer}}
  end

  defp start_buffer(ctx, extras \\ []) do
    observe = fn path, dirty? ->
      GitEvidence.capture(path, dirty?, &GitSystem.review_baseline/1)
    end

    extra = Keyword.put_new(extras, :keep_observer, observe)
    opts = [file_path: ctx.path, swap_dir: ctx.swap_dir, events_registry: ctx.events] ++ extra
    start_supervised!({Buffer, opts}, id: make_ref(), restart: :temporary)
  end

  defp replace(buffer, point, length, bytes, step) do
    apply_edit(buffer, point, length, bytes, EditSource.minga("review", step))
  end

  defp apply_edit(buffer, point, length, bytes, source) do
    assert {:ok, _} =
             Buffer.Process.replace_byte_range_if_version(
               buffer,
               Buffer.version(buffer),
               point,
               length,
               bytes,
               source
             )
  end

  defp kept(buffer) do
    %{review_lease: lease} = Buffer.renderer_consume(buffer)
    assert {:ok, regions} = Buffer.render_review_regions(buffer, lease, [{0, 2}])
    Enum.filter(regions, &match?({:kept, _, _}, &1))
  end

  defp refresh(repo, root) do
    oid = root |> git!(["rev-parse", "HEAD"]) |> String.trim()
    GitStub.set_head_commit(root, oid, "same message")
    Repo.refresh(repo)
    assert :ok = Repo.await_refresh(repo)
  end

  defp stage_bytes(ctx, bytes) do
    source = Path.join(ctx.root, "index-input")
    File.write!(source, bytes)
    oid = ctx.root |> git!(["hash-object", "-w", source]) |> String.trim()
    git!(ctx.root, ["update-index", "--cacheinfo", "100644,#{oid},owned.txt"])
  end

  defp git!(root, args) do
    {output, status} =
      System.cmd("git", ["-C", root | args], env: @git_env, stderr_to_stdout: true)

    assert status == 0, output
    output
  end
end
