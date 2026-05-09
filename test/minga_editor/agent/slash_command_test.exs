defmodule MingaEditor.Agent.SlashCommandTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Session
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defmodule NoopProvider do
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
    def get_state(_pid), do: {:ok, %{model: nil, is_streaming: false, token_usage: nil}}

    @impl GenServer
    def init(_opts), do: {:ok, %{}}
  end

  defp start_session do
    start_supervised!({Session, provider: NoopProvider, provider_opts: []})
  end

  describe "slash_command?/1" do
    test "returns true for slash-prefixed text" do
      assert SlashCommand.slash_command?("/help")
      assert SlashCommand.slash_command?("/clear")
      assert SlashCommand.slash_command?("/")
    end

    test "returns false for non-slash text" do
      refute SlashCommand.slash_command?("hello")
      refute SlashCommand.slash_command?("")
      refute SlashCommand.slash_command?("not /a command")
    end
  end

  describe "commands/0" do
    test "returns a list of command maps" do
      cmds = SlashCommand.commands()
      assert is_list(cmds)

      assert Enum.all?(cmds, fn cmd ->
               Map.has_key?(cmd, :name) and Map.has_key?(cmd, :description)
             end)
    end

    test "includes core commands" do
      names = SlashCommand.commands() |> Enum.map(& &1.name)
      assert "clear" in names
      assert "help" in names
      assert "stop" in names
      assert "thinking" in names
      assert "model" in names
      assert "plan" in names
      assert "exec" in names
    end
  end

  describe "completions/1" do
    test "returns all commands for empty prefix" do
      all = SlashCommand.completions("")
      assert length(all) == length(SlashCommand.commands())
    end

    test "filters by prefix" do
      matches = SlashCommand.completions("/cl")
      names = Enum.map(matches, & &1.name)
      assert "clear" in names
      refute "help" in names
    end

    test "handles prefix with leading slash" do
      matches = SlashCommand.completions("/he")
      names = Enum.map(matches, & &1.name)
      assert "help" in names
    end

    test "returns empty list for no match" do
      assert SlashCommand.completions("/zzz") == []
    end
  end

  describe "execute/2" do
    # Build a minimal state that the slash commands can work with
    defp mock_state(opts \\ []) do
      session = Keyword.get(opts, :session)

      tab =
        MingaEditor.State.Tab.new_agent(1, "Agent") |> MingaEditor.State.Tab.set_session(session)

      %EditorState{
        port_manager: nil,
        shell: MingaEditor.Shell.Traditional,
        workspace: %MingaEditor.Workspace.State{
          viewport: Viewport.new(24, 80),
          editing: VimState.new(),
          agent_ui: UIState.new()
        },
        shell_state: %MingaEditor.Shell.Traditional.State{
          status_msg: nil,
          tab_bar: MingaEditor.State.TabBar.new(tab),
          agent: %AgentState{
            runtime: %RuntimeState{status: :idle},
            error: nil,
            spinner_timer: nil,
            buffer: nil
          }
        }
      }
    end

    test "returns error for non-slash input" do
      assert {:error, "Not a slash command"} = SlashCommand.execute(mock_state(), "hello")
    end

    test "returns error for unknown command" do
      assert {:error, "Unknown command: /foobar"} = SlashCommand.execute(mock_state(), "/foobar")
    end

    test "/help returns ok and sets status message" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/help")
      assert state.shell_state.status_msg == "Commands listed in chat"
    end

    test "/stop aborts agent (no-op without session)" do
      {:ok, _state} = SlashCommand.execute(mock_state(), "/stop")
    end

    test "/abort is an alias for /stop" do
      {:ok, _state} = SlashCommand.execute(mock_state(), "/abort")
    end

    test "/clear without session starts a new session" do
      {:ok, _state} = SlashCommand.execute(mock_state(), "/clear")
    end

    test "/new is an alias for /clear" do
      {:ok, _state} = SlashCommand.execute(mock_state(), "/new")
    end

    test "/thinking without args cycles level (no session = status msg)" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/thinking")
      assert state.shell_state.status_msg != nil
    end

    test "/thinking with arg sets level (no session = status msg)" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/thinking high")
      assert state.shell_state.status_msg == "No agent session"
    end

    test "/model without name returns error" do
      assert {:error, "Usage: /model <name>"} = SlashCommand.execute(mock_state(), "/model")
    end

    test "/model with name sets model (triggers restart)" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/model gpt-4o")
      assert AgentAccess.panel(state).model_name == "gpt-4o"
    end

    test "/? is an alias for /help" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/?")
      assert state.shell_state.status_msg == "Commands listed in chat"
    end

    test "command parsing is case-insensitive" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/HELP")
      assert state.shell_state.status_msg == "Commands listed in chat"
    end

    test "command parsing trims whitespace" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/help  ")
      assert state.shell_state.status_msg == "Commands listed in chat"
    end

    test "/plan enters plan mode for the active session" do
      session = start_session()
      {:ok, state} = SlashCommand.execute(mock_state(session: session), "/plan")

      assert Session.status(session) == :plan
      assert state.shell_state.status_msg == "Plan mode enabled"
      assert state.shell_state.agent.runtime.status == :plan

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Plan mode" and text =~ "/exec"
               _ -> false
             end)
    end

    test "/exec leaves plan mode for the active session" do
      session = start_session()
      :ok = Session.enter_plan(session)
      {:ok, state} = SlashCommand.execute(mock_state(session: session), "/exec")

      assert Session.status(session) == :idle
      assert state.shell_state.status_msg == "Execution mode enabled"
      assert state.shell_state.agent.runtime.status == :idle

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Execution mode" and text =~ "/plan"
               _ -> false
             end)
    end

    test "/skill:plan is rewritten to enter real plan mode" do
      session = start_session()
      {:ok, _state} = SlashCommand.execute(mock_state(session: session), "/skill:plan")
      assert Session.status(session) == :plan
    end

    test "/skill:off:plan leaves plan mode" do
      session = start_session()
      :ok = Session.enter_plan(session)
      {:ok, _state} = SlashCommand.execute(mock_state(session: session), "/skill:off:plan")
      assert Session.status(session) == :idle
    end

    test "/plan without an active session returns a clear error" do
      assert {:error, "No active agent session"} = SlashCommand.execute(mock_state(), "/plan")
    end
  end
end
