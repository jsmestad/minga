defmodule MingaEditor.Agent.ApprovedEditKeysTest do
  @moduledoc """
  After an approved agent edit, the editor keeps handling keys and the terminal
  command line stays visible below the compact Agent context overlay (#3786).
  """
  use Minga.Test.EditorCase, async: true

  alias Minga.Config.Options
  alias MingaAgent.InferenceRoute.{Message, Request, ToolCall}
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.Session
  alias MingaAgent.Test.FixtureInferenceRoute
  alias MingaEditor.Layout
  alias MingaEditor.Layout.SurfaceRegistry
  alias MingaEditor.Shell.Runtime

  @moduletag :tmp_dir
  @event_timeout 10_000

  setup_all do
    # A Native session waits for the model catalog before it starts; load it up front.
    assert [_ | _] = LLMDB.models()
    :ok
  end

  setup %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])
    registry = :"approved_edit_routes_#{suffix}"
    start_supervised!({InferenceRouteRegistry, name: registry})
    route_id = "fixture#{suffix}"
    model_id = "model#{suffix}"

    {:ok, _reporter} =
      InferenceRouteRegistry.register(
        registry,
        [
          source: {:extension, :fixture_approved_edit},
          id: route_id,
          module: FixtureInferenceRoute,
          display_name: "Fixture (subscription)",
          short_name: "Fixture"
        ],
        config: [models: [FixtureInferenceRoute.model(id: model_id)]]
      )

    options = start_supervised!({Options, name: :"approved_edit_options_#{suffix}"})
    Options.set(options, :agent_model, "#{route_id}:#{model_id}")

    path = Path.join(dir, "notes.md")
    File.write!(path, "TODO: fill in the title\n")

    {:ok, _script} =
      FixtureInferenceRoute.script(model_id, [
        {:events,
         [
           {:tool_call,
            %ToolCall{id: "tc_read", name: "read_file", arguments: %{"path" => "notes.md"}}},
           {:finish, :tool_calls}
         ]},
        {:respond, &edit_after_read/1},
        {:events, [{:text, "Replaced the TODO line."}, {:finish, :stop}]}
      ])

    ctx =
      start_editor("TODO: fill in the title\n",
        file_path: path,
        project_root: dir,
        options_server: options,
        agent_provider_module: MingaAgent.Providers.Native,
        agent_provider_opts: [
          mcp_enabled?: false,
          model_resolver_opts: [inference_routes: registry, models: [], providers: []],
          credential_opts: [credentials_reader: fn _path -> {:ok, %{}} end, env: %{}]
        ]
      )

    %{ctx: ctx}
  end

  test "keys keep dispatching after an approved edit turn", %{ctx: ctx} do
    session = run_approved_edit_turn(ctx)

    # Back on the file, the compact Agent context overlay reports the turn's activity.
    state = send_keys_sync(ctx, "<SPC>aa")
    assert Runtime.active_tab_kind(state.shell_runtime) == :file
    assert :agent_context in Enum.map(SurfaceRegistry.placements(state), & &1.surface_id)

    state = send_keys_sync(ctx, "<Esc>:")
    assert editor_mode(ctx) == :command
    assert_command_line_visible(state)

    send_keys_sync(ctx, "<Esc>")
    assert editor_mode(ctx) == :normal

    ref = Process.monitor(session)
    send_keys_sync(ctx, "<SPC>aSs")
    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, @event_timeout

    send_keys_sync(ctx, ":")
    assert editor_mode(ctx) == :command
  end

  # Opens the Agent, sends a prompt, approves the edit, and waits for the turn to settle.
  defp run_approved_edit_turn(ctx) do
    send_keys_sync(ctx, "<SPC>aa")

    state =
      wait_until(ctx, &is_pid(Runtime.active_session(&1.shell_runtime)),
        max_attempts: 500,
        message: "the Agent session did not start"
      )

    session = Runtime.active_session(state.shell_runtime)
    Session.subscribe(session)

    # The composer opens in Insert; Normal-mode Enter sends.
    send_keys_sync(ctx, "Replace the TODO line<Esc><CR>")
    assert_receive {:agent_event, ^session, {:approval_pending, _approval}}, @event_timeout

    send_keys_sync(ctx, "<Esc>y")
    assert_receive {:agent_event, ^session, {:status_changed, :idle}}, @event_timeout
    session
  end

  # No footer-band overlay may cover the status row or the command line row.
  defp assert_command_line_visible(state) do
    layout = Layout.get(state)
    {minibuffer_row, _col, _width, _height} = layout.minibuffer
    {area_row, _col, _width, area_height} = layout.editor_area
    status_row = area_row + area_height

    for %{surface_id: surface_id} <- SurfaceRegistry.placements(state),
        surface_id in [:agent_context, :notifications, :float_popup, :observatory] do
      refute SurfaceRegistry.within?(state, surface_id, minibuffer_row, 0),
             "#{surface_id} covers the command line"

      refute SurfaceRegistry.within?(state, surface_id, status_row, 0),
             "#{surface_id} covers the status row"
    end
  end

  # Answers the read with an edit that carries the read's full-source revision.
  defp edit_after_read(%Request{messages: messages}) do
    [revision] =
      messages
      |> Enum.filter(&(&1.role == :tool))
      |> Enum.flat_map(fn %Message{content: content} -> content end)
      |> Enum.flat_map(fn {:tool_result, _id, parts, _error?} -> parts end)
      |> Enum.find_value(fn
        {:text, text} -> Regex.run(~r/\b([0-9a-f]{64})\b/, text, capture: :all_but_first)
        _part -> nil
      end)

    {:events,
     [
       {:tool_call,
        %ToolCall{
          id: "tc_edit",
          name: "edit_file",
          arguments: %{
            "path" => "notes.md",
            "expected_revision" => revision,
            "edits" => [
              %{"old_text" => "TODO: fill in the title", "new_text" => "Title: Minga bridge test"}
            ]
          }
        }},
       {:finish, :tool_calls}
     ]}
  end
end
