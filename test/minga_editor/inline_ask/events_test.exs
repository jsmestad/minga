defmodule MingaEditor.InlineAsk.EventsTest do
  # Uses the global MingaAgent.SessionManager to verify managed session shutdown.
  use ExUnit.Case, async: false

  alias Minga.Project.FileRef
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaEditor.InlineAsk.Events
  alias MingaEditor.Shell.Traditional.AgentSurfaces
  alias MingaEditor.Session.State, as: SessionState
  alias MingaEditor.Shell.Runtime
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk

  test "text deltas append to the matching inline ask" do
    session = self()
    {state, buffer} = state_with_ask(session)

    state = Events.handle_event(state, session, {:text_delta, "hello"})

    assert InlineAsk.response(active_ask(state, buffer)) == "hello"
  end

  test "prompt send errors mark the ask as failed" do
    session = self()
    {state, buffer} = state_with_ask(session)

    state = Events.handle_prompt_result(state, session, {:error, :provider_not_ready})

    ask = active_ask(state, buffer)
    assert InlineAsk.failed?(ask)
    assert InlineAsk.session_pid(ask) == nil
    assert InlineAsk.response(ask) =~ "provider_not_ready"
  end

  test "prompt send errors stop managed ephemeral sessions" do
    {:ok, _session_id, session} =
      SessionManager.start_session(
        provider: Minga.Test.StubProvider,
        persist?: false,
        hooks_enabled?: false,
        provider_opts: [provider: :test, model: "test"]
      )

    on_exit(fn -> SessionManager.stop_session_by_pid(session) end)
    ref = Process.monitor(session)
    {state, buffer} = state_with_ask(session)

    state = Events.handle_prompt_result(state, session, {:error, :provider_not_ready})

    assert_receive {:DOWN, ^ref, :process, ^session, _reason}, 1_000

    ask = active_ask(state, buffer)
    assert InlineAsk.failed?(ask)
    assert InlineAsk.session_pid(ask) == nil
    assert InlineAsk.response(ask) =~ "provider_not_ready"
  end

  test "idle status finalizes with assistant response and clears session" do
    session =
      start_supervised!(
        {Session,
         provider: Minga.Test.StubProvider,
         persist?: false,
         hooks_enabled?: false,
         provider_opts: [provider: :test, model: "test"]},
        id: {:inline_events_session, make_ref()}
      )

    :sys.get_state(session)
    Session.seed_messages(session, [{:assistant, "final answer"}])
    {state, buffer} = state_with_ask(session)

    state = Events.handle_event(state, session, {:status_changed, :idle})

    ask = active_ask(state, buffer)
    assert InlineAsk.answered?(ask)
    assert InlineAsk.response(ask) == "final answer"
    assert InlineAsk.session_pid(ask) == nil
  end

  test "error event records the message and clears session" do
    session = self()
    {state, buffer} = state_with_ask(session)

    state = Events.handle_event(state, session, {:error, "boom"})

    ask = active_ask(state, buffer)
    assert InlineAsk.failed?(ask)
    assert InlineAsk.response(ask) == "boom"
    assert InlineAsk.session_pid(ask) == nil
  end

  test "events ignore foreign overlays in a polluted store" do
    session = self()

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %SessionState{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          %TraditionalState{
            agent_surfaces: %AgentSurfaces{
              asks: %{self() => %{buffer_pid: self(), session: session}}
            }
          }
        )
    }

    assert Events.handle_event(state, session, {:text_delta, "ignored"}) == state
  end

  defp state_with_ask(session_pid) do
    buffer_pid = self()

    ask =
      buffer_pid
      |> InlineAsk.new(
        %FileRef{kind: :buffer, display_name: "scratch.ex", buffer_pid: buffer_pid},
        "scratch.ex",
        0
      )
      |> InlineAsk.thinking(session_pid)

    state = %EditorState{
      frontend: %MingaEditor.State.Frontend{port_manager: nil},
      workspace: %SessionState{},
      shell_runtime:
        Runtime.new(
          Runtime.default_entry(),
          TraditionalState.activate_inline_ask(%TraditionalState{}, ask)
        )
    }

    {state, buffer_pid}
  end

  defp active_ask(state, buffer_pid) do
    state.shell_runtime.state
    |> MingaEditor.Shell.Traditional.State.inline_asks()
    |> InlineAsk.active(buffer_pid)
  end
end
