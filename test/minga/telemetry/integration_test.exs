defmodule Minga.Telemetry.IntegrationTest do
  @moduledoc """
  Integration test verifying telemetry events fire through the actual
  keystroke-to-render critical path.

  Uses the headless editor harness (no Zig process, port_manager: nil)
  to send a real keystroke and assert telemetry events are emitted.
  """

  use Minga.Test.EditingModelCase, async: false

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Editor

  # async: false because we attach/detach global telemetry handlers.

  setup do
    # Pin vim mode (j = :move_down requires vim normal mode dispatch)
    self = self()

    # Attach a test handler that captures all minga telemetry stop events
    :telemetry.attach_many(
      "integration-test-handler",
      [
        [:minga, :input, :dispatch, :stop],
        [:minga, :command, :execute, :stop],
        [:minga, :render, :pipeline, :stop],
        [:minga, :render, :stage, :stop],
        [:minga, :port, :emit, :stop]
      ],
      fn event, measurements, metadata, _config ->
        send(self, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    {:ok, buffer} = BufferServer.start_link(content: "hello\nworld\nfoo")

    {:ok, editor} =
      Editor.start_link(
        name: :"editor_telemetry_#{:erlang.unique_integer([:positive])}",
        port_manager: nil,
        buffer: buffer,
        width: 80,
        height: 24
      )

    on_exit(fn ->
      :telemetry.detach("integration-test-handler")
    end)

    %{editor: editor, buffer: buffer}
  end

  test "keystroke fires input dispatch telemetry", %{editor: editor} do
    # Send 'j' (move down) keystroke
    send(editor, {:minga_input, {:key_press, ?j, 0}})
    _ = :sys.get_state(editor)

    assert_received {:telemetry_event, [:minga, :input, :dispatch, :stop], %{duration: duration},
                     _metadata}

    assert is_integer(duration)
    assert duration > 0
  end

  test "keystroke fires render pipeline telemetry", %{editor: editor} do
    send(editor, {:minga_input, {:key_press, ?j, 0}})
    _ = :sys.get_state(editor)

    assert_received {:telemetry_event, [:minga, :render, :pipeline, :stop], %{duration: duration},
                     %{window_count: wc}}

    assert is_integer(duration)
    assert duration > 0
    assert is_integer(wc)
  end

  test "keystroke fires per-stage render telemetry", %{editor: editor} do
    send(editor, {:minga_input, {:key_press, ?j, 0}})
    _ = :sys.get_state(editor)

    # Collect all stage events
    stages = collect_stage_events()

    stage_names = Enum.map(stages, fn {_event, _m, meta} -> meta.stage end)

    # All 7 core stages should fire (agent_content may or may not fire
    # depending on whether an agent chat window exists)
    assert :invalidation in stage_names
    assert :layout in stage_names
    assert :scroll in stage_names
    assert :content in stage_names
    assert :chrome in stage_names
    assert :compose in stage_names
    assert :emit in stage_names
  end

  test "named command fires command execute telemetry", %{editor: editor} do
    # 'j' in normal mode dispatches :move_down via the command registry
    send(editor, {:minga_input, {:key_press, ?j, 0}})
    _ = :sys.get_state(editor)

    assert_received {:telemetry_event, [:minga, :command, :execute, :stop], %{duration: duration},
                     %{command: command}}

    assert is_integer(duration)
    assert is_atom(command)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp collect_stage_events do
    collect_stage_events([])
  end

  defp collect_stage_events(acc) do
    receive do
      {:telemetry_event, [:minga, :render, :stage, :stop], measurements, metadata} ->
        collect_stage_events([{[:minga, :render, :stage, :stop], measurements, metadata} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
