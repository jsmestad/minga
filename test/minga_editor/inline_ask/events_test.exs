defmodule MingaEditor.InlineAsk.EventsTest do
  # Uses the global MingaAgent.SessionManager to verify managed session shutdown.
  use ExUnit.Case, async: false

  alias Minga.Project.FileRef
  alias MingaAgent.Session
  alias MingaAgent.SessionManager
  alias MingaEditor.InlineAsk.Events
  alias MingaEditor.Shell.Traditional.State, as: TraditionalState
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.InlineAsk

  test "text deltas append to the matching inline ask" do
    session = self()
    {state, buffer} = state_with_ask(session)

    state = Events.handle_event(state, session, {:text_delta, "hello"})

    assert active_ask(state, buffer).response == "hello"
  end

  test "prompt send errors mark the ask as failed" do
    session = self()
    {state, buffer} = state_with_ask(session)

    state = Events.handle_prompt_result(state, session, {:error, :provider_not_ready})

    assert %InlineAsk{status: :error, response: response, session_pid: nil} =
             active_ask(state, buffer)

    assert response =~ "provider_not_ready"
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

    assert %InlineAsk{status: :error, response: response, session_pid: nil} =
             active_ask(state, buffer)

    assert response =~ "provider_not_ready"
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

    assert %InlineAsk{status: :answered, response: "final answer", session_pid: nil} =
             active_ask(state, buffer)
  end

  test "error event records the message and clears session" do
    session = self()
    {state, buffer} = state_with_ask(session)

    state = Events.handle_event(state, session, {:error, "boom"})

    assert %InlineAsk{status: :error, response: "boom", session_pid: nil} =
             active_ask(state, buffer)
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

    state = %{shell_state: %TraditionalState{inline_asks: %{buffer_pid => ask}}}
    {state, buffer_pid}
  end

  defp active_ask(state, buffer_pid) do
    state |> EditorState.inline_asks() |> InlineAsk.active(buffer_pid)
  end
end
