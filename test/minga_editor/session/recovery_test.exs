defmodule MingaEditor.Session.RecoveryTest do
  @moduledoc "Behavior tests for typed session recovery/restoration reads."

  use ExUnit.Case, async: true

  alias MingaEditor.Session.State, as: SessionState
  alias Minga.Session
  alias Minga.Session.Snapshot
  alias Minga.Session.Swap
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Session.Recovery
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Session, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir

  test "request has stable directory identity and bounded latest-wins policy", %{tmp_dir: dir} do
    state =
      base_state(
        backend: :tui,
        session: SessionState.new(swap_dir: dir, session_dir: dir)
      )

    request = Recovery.request(state, [swap_dir: dir], [session_dir: dir], true, true)

    assert request.resource ==
             {:session_recovery, Path.expand(dir), Path.join(Path.expand(dir), "session.json"),
              :startup_buffers}

    assert request.policy.mode == :latest_wins
    assert request.policy.max_queued == 0
  end

  test "run restores a saved session with files after a clean quit or a crash", %{tmp_dir: dir} do
    opts = [session_dir: dir, project_root: dir]
    state = base_state(backend: :tui, session: SessionState.new(session_dir: dir))
    request = Recovery.request(state, [swap_dir: nil], opts, false, true)

    for clean? <- [true, false] do
      saved = %{snapshot(clean?) | buffers: [%Minga.Session.BufferEntry{file: "/tmp/a.ex"}]}
      assert :ok = Session.save(saved, opts)

      assert Recovery.run(request.effect) ==
               {:ok,
                {:resume, %{snapshot: saved, recovered: [], held_back: [], waiting_elsewhere: 0}}}
    end

    assert :ok = Session.save(snapshot(true), opts)
    assert Recovery.run(request.effect) == {:ok, :none}
  end

  test "completed, failed, and canceled outcomes apply safely while changed config is stale", %{
    tmp_dir: dir
  } do
    session = SessionState.new(session_dir: dir)
    state = base_state(backend: :tui, session: session)
    opts = MingaEditor.Handlers.SessionHandler.project_session_opts(state)
    enabled? = MingaEditor.Handlers.SessionHandler.restore_enabled?(state)
    request = Recovery.request(state, [swap_dir: nil], opts, false, enabled?)

    resume = %{snapshot: snapshot(false), recovered: [], held_back: [], waiting_elsewhere: 0}
    completed = Outcome.completed(request, {:resume, resume})
    assert {restored, %Outcome{value: {:completed, _result}}} = Recovery.apply(state, completed)
    assert restored.session == state.session
    assert Recovery.render?(completed)

    failed = Outcome.failed(request, :worker_failed)
    assert {^state, ^failed} = Recovery.apply(state, failed)

    canceled = Outcome.canceled(request, :requested)
    assert {^state, ^canceled} = Recovery.apply(state, canceled)

    changed = %{state | session: SessionState.new(session_dir: Path.join(dir, "other"))}

    assert {^changed, %Outcome{value: {:stale, :session_configuration_changed}}} =
             Recovery.apply(changed, completed)

    workspace =
      MingaEditor.Session.State.set_buffers(state.workspace, %Buffers{
        active: self(),
        list: [self()],
        active_index: 0
      })

    workspace_changed = then(state, fn state -> %{state | workspace: workspace} end)

    assert {^workspace_changed, %Outcome{value: {:stale, :workspace_changed}}} =
             Recovery.apply(workspace_changed, completed)
  end

  describe "run/1 with swap files" do
    setup %{tmp_dir: dir} do
      swap_dir = Path.join(dir, "swap")

      [here, there] =
        for name <- ["here", "there"] do
          root = Path.join(dir, name)
          File.mkdir_p!(root)
          File.write!(Path.join(root, "mix.exs"), "")
          file = Path.join(root, "notes.txt")
          File.write!(file, "saved #{name}")
          %{root: root, file: file, swap: leftover_swap(swap_dir, file, "unsaved #{name}")}
        end

      %{swap_dir: swap_dir, here: here, there: there}
    end

    test "an editor that opened a project gets that project's text and learns that more waits",
         ctx do
      effect = effect(ctx, {:project, ctx.here.root})

      assert {:ok, {:resume, resume}} = Recovery.run(effect)

      assert %{snapshot: nil, waiting_elsewhere: 1} = resume
      assert [{%{path: path, swap_path: swap}, {:ok, path, "unsaved here"}}] = resume.recovered
      assert path == ctx.here.file

      # Reading takes nothing off the disk: a swap is removed when a buffer has taken its text over.
      assert File.exists?(swap)
      assert File.exists?(ctx.there.swap)
    end

    test "an editor started on files gets the text of those files only", ctx do
      buffer = start_supervised!({Minga.Buffer.Process, file_path: ctx.there.file})
      effect = effect(ctx, :startup_buffers, [buffer])

      assert {:ok, {:resume, resume}} = Recovery.run(effect)

      assert [{%{path: path}, {:ok, path, "unsaved there"}}] = resume.recovered
      assert path == ctx.there.file
      assert resume.waiting_elsewhere == 1
    end

    test "an editor with nothing open recovers nothing and says how much is waiting", ctx do
      assert Recovery.run(effect(ctx, :none)) ==
               {:ok,
                {:resume, %{snapshot: nil, recovered: [], held_back: [], waiting_elsewhere: 2}}}

      assert File.exists?(ctx.here.swap)
      assert File.exists?(ctx.there.swap)
    end

    test "the saved session and the unsaved text arrive together", ctx do
      session_opts = [
        session_dir: Path.join(ctx.swap_dir, "sessions"),
        project_root: ctx.here.root
      ]

      saved = %{snapshot(false) | buffers: [%Minga.Session.BufferEntry{file: ctx.here.file}]}
      assert :ok = Session.save(saved, session_opts)

      effect = %{
        effect(ctx, {:project, ctx.here.root})
        | session_opts: session_opts,
          session_enabled?: true
      }

      assert {:ok, {:resume, %{snapshot: ^saved, recovered: [_one]}}} = Recovery.run(effect)
    end

    test "text whose file was written after the swap is held back, not handed over", ctx do
      # The file was saved again after the crash, so it holds newer text than the swap.
      File.touch!(ctx.here.file, System.os_time(:second) + 60)

      assert {:ok, {:resume, resume}} = Recovery.run(effect(ctx, {:project, ctx.here.root}))

      assert resume.recovered == []
      assert [%{path: path, changed_since?: true}] = resume.held_back
      assert path == ctx.here.file
      assert File.exists?(ctx.here.swap)
    end

    test "a headless editor scans no swap files" do
      state = base_state(session: SessionState.new(swap_dir: "/tmp/x"))
      refute MingaEditor.Handlers.SessionHandler.swap_recovery_enabled?(state)
    end
  end

  test "scheduler unavailable keeps safe state" do
    state = base_state(backend: :tui, session: SessionState.new(session_dir: "/tmp/x"))

    assert Recovery.schedule(state, [swap_dir: nil], [session_dir: "/tmp/x"], false, true) ==
             state
  end

  defp effect(ctx, swap_scope, buffers \\ []) do
    %Recovery{
      swap_opts: [swap_dir: ctx.swap_dir, pid_alive?: fn _os_pid -> false end],
      session_opts: [],
      swap_enabled?: true,
      session_enabled?: false,
      swap_scope: swap_scope,
      startup_identity: {:traditional, nil, nil, buffers, List.first(buffers)}
    }
  end

  # Writes the swap that a killed editor left for the file.
  defp leftover_swap(swap_dir, path, content) do
    opts = [swap_dir: swap_dir, os_pid: 4242]
    {:ok, prepared} = Swap.prepare(path, content, opts)
    :ok = Swap.publish(prepared)
    Swap.swap_path(path, opts)
  end

  defp snapshot(clean_shutdown?) do
    %Snapshot{version: 1, buffers: [], active_file: nil, clean_shutdown: clean_shutdown?}
  end
end
