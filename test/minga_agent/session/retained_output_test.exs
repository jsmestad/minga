defmodule MingaAgent.Session.RetainedOutputTest do
  use Minga.Test.SessionCase, async: true

  alias MingaAgent.{ArtifactStore, ArtifactStores, ArtifactSupervisor, ToolCall, TurnUsage}
  alias MingaAgent.ArtifactStore.CaptureSpec
  alias MingaAgent.Session.Continuation
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Output.Range

  @tag :tmp_dir
  test "a reopened session reads the original tool range without confusing a different result", %{
    tmp_dir: dir
  } do
    suffix = System.unique_integer([:positive])

    opts = [
      name: Module.concat(__MODULE__, "Supervisor#{suffix}"),
      root: Path.join(dir, "artifacts"),
      quota: Module.concat(__MODULE__, "Quota#{suffix}"),
      registry: Module.concat(__MODULE__, "Registry#{suffix}"),
      store_supervisor: Module.concat(__MODULE__, "Stores#{suffix}")
    ]

    start_supervised!({ArtifactSupervisor, opts})
    {:ok, runtime} = ArtifactSupervisor.runtime(opts)
    record = "retained-output-session"
    {:ok, store} = ArtifactStores.ensure_record(record, runtime)
    capture_status = {:incomplete, :interrupted}
    bytes = "discarded heading\noriginal λ界\t  \n"
    expected = "original λ界\t  \n"

    {:ok, spec} =
      CaptureSpec.new(
        media_type: "text/plain",
        mode: :bytes,
        owner_pid: self(),
        delivery_key: {:delivery, "retained-test", "original"}
      )

    {:ok, capture} = ArtifactStore.begin(store, spec)
    {:ok, _progress} = ArtifactStore.append(store, capture, bytes)
    {:ok, %{reference: reference}} = ArtifactStore.finish(store, capture, capture_status)
    {:ok, prefix} = Range.new(:captured_prefix, :bytes, 0, byte_size(bytes), :unknown)

    {:ok, output} =
      Output.new("short preview", capture_status, prefix,
        reference: reference,
        presentation: {:truncated, :unknown}
      )

    tool = ToolCall.new("original", "shell", %{}) |> ToolCall.complete(output.view, output)

    :ok =
      SessionStore.save(
        %{
          id: record,
          timestamp: DateTime.to_iso8601(DateTime.utc_now()),
          model_name: "test-model",
          messages: [{:tool_call, tool}, {:assistant, "not a tool"}],
          message_ids: [17, 18],
          continuation: Continuation.new(),
          usage: TurnUsage.new()
        },
        dir,
        artifact_runtime: runtime
      )

    :ok = DynamicSupervisor.terminate_child(runtime.store_supervisor, store)

    session =
      start_test_session(
        provider: Minga.Test.SessionMockProvider,
        provider_opts: [],
        session_store_dir: dir,
        artifact_runtime: runtime
      )

    assert :ok = Session.load_session(session, record)
    %{connection: %{target: first_target}} = Session.editor_snapshot(session)
    assert :ok = Session.load_session(session, record)
    %{connection: %{target: target}} = Session.editor_snapshot(session)
    assert target.session == first_target.session
    assert target.session_id == first_target.session_id
    assert target.epoch != first_target.epoch
    {:ok, range} = Range.new(:requested, :bytes, 18, byte_size(expected), byte_size(bytes))

    assert {:error, :stale_target} =
             Session.read_retained_output(first_target, 17, reference, range)

    assert {:ok, %{bytes: ^expected, capture: ^capture_status, selection: ^range}} =
             Session.read_retained_output(target, 17, reference, range)

    assert {:error, :output_unavailable} =
             Session.read_retained_output(target, 18, reference, range)

    assert {:error, :output_changed} =
             Session.read_retained_output(
               target,
               17,
               %{reference | sha256: String.duplicate("0", 64)},
               range
             )

    assert {:error, :stale_target} =
             Session.read_retained_output(
               %{target | session_id: "other-record"},
               17,
               reference,
               range
             )

    assert {:error, :invalid_range} =
             Session.read_retained_output(target, 17, reference, %{range | start: nil})

    assert {:ok, %{bytes: ^expected}} =
             Session.read_retained_output(target, 17, reference, range)

    {:ok, reopened_store} = ArtifactStores.ensure_record(record, runtime)
    :ok = ArtifactStore.reconcile_snapshot_pins(reopened_store, nil)
    assert {:ok, 1} = ArtifactStore.cleanup_unreferenced(reopened_store)

    assert {:error, :expired} =
             Session.read_retained_output(target, 17, reference, range)
  end
end
