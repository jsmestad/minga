defmodule MingaEditor.StatusBar.PlanLimitSegmentTest do
  @moduledoc """
  The near-limit modeline segment follows the route usage events the Editor recorded for the active session's contributed model.
  """
  use ExUnit.Case, async: true

  alias MingaAgent.Config
  alias MingaAgent.Credentials.Snapshot
  alias MingaAgent.InferenceRoute.StatusChangedEvent
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.ModelResolver
  alias MingaAgent.ProviderPacks.Native
  alias MingaAgent.Session.ConnectionSnapshot
  alias MingaAgent.Session.ConnectionTarget
  alias MingaAgent.Test.FixtureInferenceRoute
  alias MingaEditor.Agent.UIState
  alias MingaEditor.Handlers.EventDispatcher
  alias MingaEditor.Shell.Registry
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.Workflow, as: TraditionalWorkflow
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar
  alias MingaEditor.StatusBar.Data
  alias MingaEditor.Session.State, as: SessionState

  setup do
    events = :"plan_limit_events_#{System.unique_integer([:positive])}"
    start_supervised!({Elixir.Registry, keys: :duplicate, name: events}, id: events)
    registry = :"plan_limit_routes_#{System.unique_integer([:positive])}"
    start_supervised!({InferenceRouteRegistry, name: registry, events: events}, id: registry)
    :ok = Minga.Events.subscribe(:inference_route_status_changed, registry: events)

    {:ok, reporter} =
      InferenceRouteRegistry.register(registry,
        source: {:extension, :fixture_bridge},
        id: "fixture",
        module: FixtureInferenceRoute,
        display_name: "Fixture Route",
        short_name: "Claude"
      )

    :ok = InferenceRouteRegistry.report_status(registry, reporter, {:ready, "me@example.com"})
    assert_receive {:minga_event, :inference_route_status_changed, %StatusChangedEvent{}}

    {:ok, selection} =
      ModelResolver.resolve("fixture:fixture-model",
        backend_spec: Native.spec(),
        credential_snapshot: Snapshot.new(%{}, nil),
        config: %Config{max_tokens: 4_096},
        models: [],
        providers: [],
        inference_routes: registry
      )

    %{registry: registry, reporter: reporter, selection: selection}
  end

  test "the active contributed model shows its route's segment only at 80% or more", ctx do
    state = editor_state(ctx.selection)

    state = report(state, ctx, utilization: 0.79)
    assert plan_limit_segment(state) == nil

    state = report(state, ctx, utilization: 0.82)
    assert_receive {:debounced_render, _timer}
    assert {"Claude 82% · 5h", fg, _bg, [], :agent_pick_model} = plan_limit_segment(state)
    assert fg == state.appearance.theme.gutter.warning_fg

    state = report(state, ctx, utilization: 1.0, status: :rejected, resets_at: nil)

    assert {"Claude limit", fg, _bg, [bold: true], :agent_pick_model} =
             plan_limit_segment(state)

    assert fg == state.appearance.theme.gutter.error_fg
  end

  test "a route that stops reporting usage, or a built-in model, shows nothing", ctx do
    state = report(editor_state(ctx.selection), ctx, utilization: 0.9)
    assert plan_limit_segment(state) != nil

    :ok = InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporter, nil)
    state = receive_status(state)
    assert plan_limit_segment(state) == nil

    state = report(editor_state(nil), ctx, utilization: 0.9)
    assert plan_limit_segment(state) == nil
  end

  defp report(state, ctx, attrs) do
    window =
      Keyword.merge(
        [kind: "five_hour", utilization: 0.5, resets_at: nil, status: :warning],
        attrs
      )

    :ok = InferenceRouteRegistry.report_usage(ctx.registry, ctx.reporter, [window])
    receive_status(state)
  end

  defp receive_status(state) do
    assert_receive {:minga_event, :inference_route_status_changed, %StatusChangedEvent{} = event} =
                     msg

    EventDispatcher.dispatch(state, :inference_route_status_changed, event, msg)
  end

  defp plan_limit_segment(state) do
    %Data{common: %{status: %{modeline_segments: %{left: left, right: right}}}} =
      state |> Data.from_state() |> Data.with_modeline_segments(state.appearance.theme)

    Enum.find_value(left ++ right, fn
      %{id: :plan_limit} = s -> {s.text, s.fg, s.bg, s.style, s.target}
      _segment -> nil
    end)
  end

  defp editor_state(selection) do
    state = %EditorState{
      # A GUI backend schedules renders on a timer instead of rendering synchronously.
      frontend: %MingaEditor.State.Frontend{backend: :gui, port_manager: self()},
      workspace: %SessionState{},
      shell_runtime:
        Runtime.new(
          Registry.get(:traditional),
          %MingaEditor.Shell.Traditional.State{tab_bar: TabBar.new(Tab.new_file(1, "main.ex"))}
        )
    }

    connection = %ConnectionSnapshot{
      target: ConnectionTarget.new(self(), "conversation", nil, make_ref()),
      conversation: make_ref(),
      credential_readiness: :configured,
      model_selection: selection,
      provider_phase: :running,
      operation: :idle,
      problem: nil
    }

    TraditionalWorkflow.install_agent_ui(
      state,
      UIState.project_connection(state.workspace.agent_ui, connection)
    )
  end
end
