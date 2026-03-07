defmodule Minga.Agent.SessionTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.Event
  alias Minga.Agent.Session

  # ── Mock provider ──────────────────────────────────────────────────────────

  defmodule MockProvider do
    @behaviour Minga.Agent.Provider

    use GenServer

    @impl Minga.Agent.Provider
    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl Minga.Agent.Provider
    def send_prompt(pid, text) do
      GenServer.cast(pid, {:prompt, text})
      :ok
    end

    @impl Minga.Agent.Provider
    def abort(pid) do
      GenServer.cast(pid, :abort)
      :ok
    end

    @impl Minga.Agent.Provider
    def new_session(pid) do
      GenServer.cast(pid, :new_session)
      :ok
    end

    @impl Minga.Agent.Provider
    def get_state(_pid) do
      {:ok, %{model: nil, is_streaming: false, token_usage: nil}}
    end

    @impl GenServer
    def init(opts) do
      subscriber = Keyword.fetch!(opts, :subscriber)
      {:ok, %{subscriber: subscriber}}
    end

    @impl GenServer
    def handle_cast({:prompt, _text}, state) do
      # Simulate: agent_start → text_delta → agent_end
      send(state.subscriber, {:agent_provider_event, %Event.AgentStart{}})

      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: "Hello "}})
      send(state.subscriber, {:agent_provider_event, %Event.TextDelta{delta: "world!"}})

      usage = %{input: 100, output: 50, cache_read: 0, cache_write: 0, cost: 0.01}
      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: usage}})

      {:noreply, state}
    end

    def handle_cast(:abort, state), do: {:noreply, state}
    def handle_cast(:new_session, state), do: {:noreply, state}
  end

  # ── Tests ───────────────────────────────────────────────────────────────────

  setup do
    {:ok, session} =
      Session.start_link(
        provider: MockProvider,
        provider_opts: []
      )

    Session.subscribe(session)

    %{session: session}
  end

  describe "initial state" do
    test "starts with idle status", %{session: session} do
      assert Session.status(session) == :idle
    end

    test "starts with empty messages", %{session: session} do
      assert Session.messages(session) == []
    end

    test "starts with zero usage", %{session: session} do
      usage = Session.usage(session)
      assert usage.input == 0
      assert usage.output == 0
      assert usage.cost == 0.0
    end
  end

  describe "send_prompt/2" do
    test "adds user message and streams response", %{session: session} do
      :ok = Session.send_prompt(session, "Hello!")

      # Allow events to process
      Process.sleep(50)

      messages = Session.messages(session)

      # Should have user message + assistant message
      assert length(messages) >= 2
      assert {:user, "Hello!"} = Enum.at(messages, 0)
      assert {:assistant, "Hello world!"} = Enum.at(messages, 1)
    end

    test "accumulates token usage", %{session: session} do
      :ok = Session.send_prompt(session, "Test")

      Process.sleep(50)

      usage = Session.usage(session)
      assert usage.input == 100
      assert usage.output == 50
      assert usage.cost == 0.01
    end

    test "broadcasts status changes", %{session: session} do
      :ok = Session.send_prompt(session, "Test")

      # Should receive status_changed events
      assert_receive {:agent_event, {:status_changed, :thinking}}, 200
      assert_receive {:agent_event, {:status_changed, :idle}}, 200
    end

    test "broadcasts text deltas", %{session: session} do
      :ok = Session.send_prompt(session, "Test")

      assert_receive {:agent_event, {:text_delta, "Hello "}}, 200
      assert_receive {:agent_event, {:text_delta, "world!"}}, 200
    end
  end

  describe "new_session/1" do
    test "clears messages and resets status", %{session: session} do
      :ok = Session.send_prompt(session, "First")
      Process.sleep(50)

      assert Session.messages(session) != []

      :ok = Session.new_session(session)

      assert Session.messages(session) == []
      assert Session.status(session) == :idle
    end

    test "resets usage counters", %{session: session} do
      :ok = Session.send_prompt(session, "Test")
      Process.sleep(50)

      :ok = Session.new_session(session)

      usage = Session.usage(session)
      assert usage.input == 0
      assert usage.cost == 0.0
    end
  end

  describe "subscribe/unsubscribe" do
    test "stops receiving events after unsubscribe", %{session: session} do
      :ok = Session.unsubscribe(session)

      :ok = Session.send_prompt(session, "Test")
      Process.sleep(50)

      refute_receive {:agent_event, _}, 100
    end
  end

  describe "toggle_tool_collapse/2" do
    test "toggles collapsed state of tool call messages", %{session: session} do
      # Manually inject a tool call via the provider event mechanism
      tool_start = %Event.ToolStart{tool_call_id: "tc1", name: "bash", args: %{}}
      send(session, {:agent_provider_event, tool_start})

      tool_end = %Event.ToolEnd{tool_call_id: "tc1", name: "bash", result: "output"}
      send(session, {:agent_provider_event, tool_end})

      Process.sleep(50)

      messages = Session.messages(session)

      tool_index =
        Enum.find_index(messages, fn
          {:tool_call, _} -> true
          _ -> false
        end)

      assert tool_index != nil

      {:tool_call, tc} = Enum.at(messages, tool_index)
      assert tc.collapsed == true

      :ok = Session.toggle_tool_collapse(session, tool_index)

      messages = Session.messages(session)
      {:tool_call, tc} = Enum.at(messages, tool_index)
      assert tc.collapsed == false
    end
  end
end
