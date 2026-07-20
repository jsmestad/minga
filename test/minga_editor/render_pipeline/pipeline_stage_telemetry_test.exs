defmodule MingaEditor.RenderPipeline.PipelineStageTelemetryTest do
  # Global render-stage telemetry cannot be isolated from concurrent pipeline tests.
  use ExUnit.Case, async: false

  alias Minga.Test.RecordingFrontend
  alias MingaEditor.RenderPipeline.TestHelpers

  test "render pipeline emits only live stages in order" do
    frontend =
      start_supervised!(
        {RecordingFrontend, owner: self()},
        id: {:pipeline_stage_telemetry_frontend, System.unique_integer([:positive])}
      )

    handler_id = "pipeline-stage-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:minga, :render, :stage, :stop],
        fn _event, _measurements, %{stage: stage}, recipient ->
          send(recipient, {:render_stage, stage})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    TestHelpers.base_state(port_manager: frontend)
    |> TestHelpers.run_pipeline()

    stages =
      for _ <- 1..7 do
        assert_receive {:render_stage, stage}
        stage
      end

    assert stages == [:layout, :scroll, :content, :agent_content, :chrome, :compose, :emit]
    refute_received {:render_stage, :invalidation}
  end
end
