defmodule Minga.Picker.AgentSessionSourceTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Agent.View.Preview
  alias Minga.Agent.View.State, as: ViewState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.Buffers
  alias Minga.Editor.State.Windows
  alias Minga.Editor.Viewport
  alias Minga.Mode
  alias Minga.Picker.AgentSessionSource

  describe "title/0" do
    test "returns Sessions" do
      assert AgentSessionSource.title() == "Sessions"
    end
  end

  describe "preview?/0" do
    test "returns false" do
      refute AgentSessionSource.preview?()
    end
  end

  describe "candidates/1" do
    test "returns only disk candidates when no live session" do
      state = %{agent: %AgentState{session: nil}}
      candidates = AgentSessionSource.candidates(state)
      # All entries should be :disk, none {:live, _}
      Enum.each(candidates, fn {{_, tag}, _, _} ->
        assert tag == :disk
      end)
    end

    test "returns live session metadata when sessions exist" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = %{agent: %AgentState{session: pid}}
      candidates = AgentSessionSource.candidates(state)
      live = Enum.filter(candidates, fn {{_, tag}, _, _} -> match?({:live, _}, tag) end)
      assert live != []

      {_id, label, desc} = hd(live)
      assert String.contains?(label, "●")
      assert String.contains?(desc, "test-model")

      Session.unsubscribe(pid)
      stop_session(pid)
    end

    test "active session is marked with bullet" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = %{agent: %AgentState{session: pid}}
      candidates = AgentSessionSource.candidates(state)
      active = Enum.find(candidates, fn {{_, {:live, p}}, _, _} -> p == pid end)
      assert active != nil
      {_, label, _} = active
      assert String.starts_with?(label, "●")

      Session.unsubscribe(pid)
      stop_session(pid)
    end

    test "history sessions do not have bullet" do
      {:ok, pid1} = start_test_session()
      {:ok, pid2} = start_test_session()
      Session.subscribe(pid2)

      state = %{agent: %AgentState{session: pid2, session_history: [pid1]}}
      candidates = AgentSessionSource.candidates(state)

      live_history =
        Enum.filter(candidates, fn
          {{_, {:live, p}}, _, _} -> p != pid2
          _ -> false
        end)

      Enum.each(live_history, fn {_, label, _} ->
        refute String.starts_with?(label, "●")
      end)

      Session.unsubscribe(pid2)
      stop_session(pid1)
      stop_session(pid2)
    end
  end

  describe "on_select/2 with live session" do
    test "returns state unchanged when selecting current session" do
      {:ok, pid} = start_test_session()
      Session.subscribe(pid)

      state = base_state(pid)
      item = {{"some-id", {:live, pid}}, "label", "desc"}
      result = AgentSessionSource.on_select(item, state)
      assert result.agent.session == pid

      Session.unsubscribe(pid)
      stop_session(pid)
    end
  end

  describe "on_cancel/1" do
    test "returns state unchanged" do
      state = %{agent: %AgentState{session: nil}}
      assert AgentSessionSource.on_cancel(state) == state
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_test_session do
    Minga.Agent.Supervisor.start_session(
      provider: Minga.Agent.Providers.Native,
      model_name: "test-model",
      provider_opts: [
        llm_client: fn _req -> {:ok, %{status: 200, body: %{"choices" => []}}} end
      ]
    )
  end

  defp stop_session(pid) do
    Minga.Agent.Supervisor.stop_session(pid)
  end

  defp base_state(session_pid) do
    %{
      agent: %AgentState{
        session: session_pid,
        panel: PanelState.new()
      },
      agentic: %ViewState{
        active: true,
        focus: :chat,
        preview: Preview.new(),
        saved_windows: nil,
        pending_prefix: nil,
        saved_file_tree: nil
      },
      viewport: Viewport.new(24, 80),
      mode: :normal,
      mode_state: Mode.initial_state(),
      buffers: %Buffers{},
      port_manager: self(),
      windows: %Windows{}
    }
  end
end
