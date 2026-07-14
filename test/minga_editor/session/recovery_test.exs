defmodule MingaEditor.Session.RecoveryTest do
  @moduledoc "Behavior tests for typed session recovery/restoration reads."

  use ExUnit.Case, async: true

  alias Minga.Session
  alias Minga.Session.Snapshot
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Session.Recovery
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.State.Session, as: SessionState

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir

  test "request has stable directory identity and bounded latest-wins policy", %{tmp_dir: dir} do
    state = %{
      base_state()
      | backend: :tui,
        session: SessionState.new(swap_dir: dir, session_dir: dir)
    }

    request = Recovery.request(state, [swap_dir: dir], [session_dir: dir], true, true)

    assert request.resource ==
             {:session_recovery, Path.expand(dir), Path.join(Path.expand(dir), "session.json")}

    assert request.policy.mode == :latest_wins
    assert request.policy.max_queued == 0
  end

  test "run loads only an unclean session and otherwise completes safely", %{tmp_dir: dir} do
    unclean = snapshot(false)
    assert :ok = Session.save(unclean, session_dir: dir)

    state = %{base_state() | backend: :tui, session: SessionState.new(session_dir: dir)}
    request = Recovery.request(state, [swap_dir: nil], [session_dir: dir], false, true)
    assert Recovery.run(request.effect) == {:ok, {:restore, unclean}}

    assert :ok = Session.save(snapshot(true), session_dir: dir)
    assert Recovery.run(request.effect) == {:ok, :none}
  end

  test "completed, failed, and canceled outcomes apply safely while changed config is stale", %{
    tmp_dir: dir
  } do
    session = SessionState.new(session_dir: dir)
    state = %{base_state() | backend: :tui, session: session}
    request = Recovery.request(state, [swap_dir: nil], [session_dir: dir], false, true)

    completed = Outcome.completed(request, {:restore, snapshot(false)})
    assert {restored, %Outcome{status: :completed}} = Recovery.apply(state, completed)
    assert restored.session == state.session
    assert Recovery.render?(completed)

    failed = Outcome.failed(request, :worker_failed)
    assert {^state, ^failed} = Recovery.apply(state, failed)

    canceled = Outcome.canceled(request, :requested)
    assert {^state, ^canceled} = Recovery.apply(state, canceled)

    changed = %{state | session: SessionState.new(session_dir: Path.join(dir, "other"))}

    assert {^changed, %Outcome{status: :stale, reason: :session_configuration_changed}} =
             Recovery.apply(changed, completed)

    workspace =
      MingaEditor.Session.State.set_buffers(state.workspace, %Buffers{
        active: self(),
        list: [self()],
        active_index: 0
      })

    workspace_changed = EditorState.set_workspace(state, workspace)

    assert {^workspace_changed, %Outcome{status: :stale, reason: :workspace_changed}} =
             Recovery.apply(workspace_changed, completed)
  end

  test "scheduler unavailable keeps safe state" do
    state = %{base_state() | backend: :tui, session: SessionState.new(session_dir: "/tmp/x")}

    assert Recovery.schedule(state, [swap_dir: nil], [session_dir: "/tmp/x"], false, true) ==
             state
  end

  defp snapshot(clean_shutdown?) do
    %Snapshot{version: 1, buffers: [], active_file: nil, clean_shutdown: clean_shutdown?}
  end
end
