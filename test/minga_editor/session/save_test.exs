defmodule MingaEditor.Session.SaveTest do
  @moduledoc "Behavior tests for bounded, coalescing session saves."

  use ExUnit.Case, async: true

  alias Minga.Session
  alias Minga.Session.Snapshot
  alias MingaEditor.Effect.Outcome
  alias MingaEditor.Session.Save

  import MingaEditor.RenderPipeline.TestHelpers

  @moduletag :tmp_dir

  test "request uses stable session-file identity and one coalesced follow-up", %{tmp_dir: dir} do
    request = Save.request(snapshot(false), session_dir: dir)

    assert request.resource == {:editor_session, Path.join(Path.expand(dir), "session.json")}
    assert request.policy.mode == :coalescing
    assert request.policy.max_queued == 1
  end

  test "coalescing retains the newest immutable snapshot", %{tmp_dir: dir} do
    older = Save.request(snapshot(false), session_dir: dir)
    newer = Save.request(snapshot(true), session_dir: dir)

    coalesced = older.handler.coalesce(older.effect, newer.effect)
    assert coalesced.snapshot.clean_shutdown
  end

  test "run writes a loadable session and completed/canceled/stale application is state-neutral",
       %{
         tmp_dir: dir
       } do
    request = Save.request(snapshot(false), session_dir: dir)
    assert Save.run(request.effect) == {:ok, :saved}
    assert {:ok, %Snapshot{clean_shutdown: false}} = Session.load(session_dir: dir)

    state = base_state()

    for outcome <- [
          Outcome.completed(request, :ok),
          Outcome.canceled(request, :requested),
          Outcome.stale(Outcome.completed(request, :ok), :superseded)
        ] do
      assert {^state, ^outcome} = Save.apply(state, outcome)
      refute Save.render?(outcome)
    end
  end

  test "failed and admission-failed saves preserve editor state" do
    state = base_state()
    request = Save.request(snapshot(false), session_dir: "/dev/null/not-a-directory")
    outcome = Outcome.failed(request, :eacces)

    assert {^state, ^outcome} = Save.apply(state, outcome)
    assert Save.schedule(state, snapshot(false), session_dir: "/tmp/session") == state
  end

  defp snapshot(clean_shutdown?) do
    %Snapshot{version: 1, buffers: [], active_file: nil, clean_shutdown: clean_shutdown?}
  end
end
