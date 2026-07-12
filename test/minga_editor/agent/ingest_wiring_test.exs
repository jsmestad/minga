defmodule MingaEditor.Agent.IngestWiringTest do
  @moduledoc """
  End-to-end wiring for the agent stream coalescer (#2289).

  Proves the live Editor boots a `MingaEditor.Agent.Ingest` process and that a
  `{:agent_stream_batch, session, batch}` message addressed to the active agent
  session is applied once via `Agent.Events.handle_batch/2` (transcript version
  bumped, no crash). The coalescing contract itself is covered by the cheaper
  `MingaEditor.Agent.IngestTest`; this is a thin wiring smoke test.
  """

  use Minga.Test.EditorCase, async: true, rendering: :disabled

  alias MingaAgent.Session
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.State.Tab
  alias MingaEditor.State.TabBar

  @moduletag :tmp_dir

  defmodule QuietProvider do
    @moduledoc false
    @behaviour MingaAgent.Provider
    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(_pid, _text), do: :ok

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(_pid), do: :ok

    @impl MingaAgent.Provider
    def seed_messages(_pid, _messages), do: :ok

    @impl MingaAgent.Provider
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @impl GenServer
    def init(_opts), do: {:ok, %{}}
  end

  defp fake_session do
    start_supervised!({Session, provider: QuietProvider, provider_opts: []})
  end

  test "the editor boots an ingest process", %{tmp_dir: dir} do
    ctx = start_editor("hello", project_root: dir)

    assert is_pid(EditorState.agent_ingest(editor_state(ctx)))
    assert Process.alive?(EditorState.agent_ingest(editor_state(ctx)))
  end

  test "a stream batch for the active session is applied once", %{tmp_dir: dir} do
    ctx = start_editor("hello", project_root: dir)
    session = fake_session()

    # Make `session` the active agent so the batch routes to handle_batch/2.
    :sys.replace_state(ctx.editor, fn state ->
      agent_tab = Tab.new_agent(99, "Agent") |> Tab.set_session(session)
      tb = TabBar.new(agent_tab)
      {tb, ws} = TabBar.add_workspace(tb, "Agent", session)
      tb = TabBar.move_tab_to_workspace(tb, 99, ws.id) |> Map.put(:active_id, 99)

      EditorState.set_tab_bar(state, tb)
    end)

    state = editor_state(ctx)
    assert AgentAccess.session(state) == session
    version_before = AgentAccess.panel(state).message_version

    send(ctx.editor, {:agent_stream_batch, session, [{:text_delta, "world"}]})
    state = editor_state(ctx)

    assert AgentAccess.panel(state).message_version == version_before + 1
  end
end
