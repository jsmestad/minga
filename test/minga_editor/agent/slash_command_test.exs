defmodule MingaEditor.Agent.SlashCommandTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Event
  alias MingaAgent.Session
  alias MingaEditor.Agent.SlashCommand
  alias MingaEditor.Agent.UIState
  alias MingaEditor.State, as: EditorState
  alias MingaAgent.RuntimeState
  alias MingaEditor.State.Agent, as: AgentState
  alias MingaEditor.State.AgentAccess
  alias MingaEditor.Viewport
  alias MingaEditor.VimState

  defmodule StyleProvider do
    @behaviour MingaAgent.Provider

    use GenServer

    @impl MingaAgent.Provider
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl MingaAgent.Provider
    def send_prompt(pid, text), do: GenServer.cast(pid, {:prompt, text})

    @impl MingaAgent.Provider
    def abort(_pid), do: :ok

    @impl MingaAgent.Provider
    def new_session(pid), do: GenServer.call(pid, :new_session)

    @impl MingaAgent.Provider
    def get_state(pid), do: GenServer.call(pid, :get_state)

    @impl MingaAgent.Provider
    def list_output_styles(pid), do: GenServer.call(pid, :list_output_styles)

    @impl MingaAgent.Provider
    def select_output_style(pid, name), do: GenServer.call(pid, {:select_output_style, name})

    @impl MingaAgent.Provider
    def current_output_style(pid), do: GenServer.call(pid, :current_output_style)

    @impl GenServer
    def init(opts) do
      subscriber = Keyword.fetch!(opts, :subscriber)

      styles = [
        %MingaAgent.OutputStyle{
          name: "concise",
          body: "Be concise.",
          path: "/tmp/concise.md",
          source: :global
        },
        %MingaAgent.OutputStyle{
          name: "review",
          body: "Review carefully.",
          path: "/tmp/review.md",
          source: :project
        }
      ]

      {:ok, %{subscriber: subscriber, styles: styles, current: nil}}
    end

    @impl GenServer
    def handle_call(:new_session, _from, state), do: {:reply, :ok, %{state | current: nil}}

    def handle_call(:get_state, _from, state),
      do:
        {:reply,
         {:ok, %{model: nil, is_streaming: false, token_usage: nil, output_style: state.current}},
         state}

    def handle_call(:list_output_styles, _from, state),
      do: {:reply, {:ok, state.styles, state.current}, state}

    def handle_call(:current_output_style, _from, state),
      do: {:reply, {:ok, state.current}, state}

    def handle_call({:select_output_style, nil}, _from, state),
      do: {:reply, {:ok, nil}, %{state | current: nil}}

    def handle_call({:select_output_style, name}, _from, state) do
      if Enum.any?(state.styles, &(&1.name == name)) do
        {:reply, {:ok, name}, %{state | current: name}}
      else
        {:reply, {:error, "Output style '#{name}' not found. Available styles: concise, review"},
         state}
      end
    end

    @impl GenServer
    def handle_cast({:prompt, _text}, state) do
      send(state.subscriber, {:agent_provider_event, %Event.AgentEnd{usage: nil}})
      {:noreply, state}
    end
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

    test "/style is registered and completed" do
      names = SlashCommand.commands() |> Enum.map(& &1.name)
      assert "style" in names

      completions = SlashCommand.completions("/sty") |> Enum.map(& &1.name)
      assert completions == ["style"]
    end

    test "/style lists available styles and current style" do
      {:ok, session} = Session.start_link(provider: StyleProvider, provider_opts: [])
      :sys.get_state(session)

      {:ok, state} = SlashCommand.execute(mock_state(session: session), "/style")

      assert state.shell_state.status_msg == "Current style: none"

      assert Enum.any?(Session.messages(session), fn
               {:system, text, :info} -> text =~ "Available styles" and text =~ "concise"
               _ -> false
             end)
    end

    test "/style <name> selects style and updates cached runtime" do
      {:ok, session} = Session.start_link(provider: StyleProvider, provider_opts: [])
      :sys.get_state(session)

      {:ok, state} = SlashCommand.execute(mock_state(session: session), "/style review")

      assert state.shell_state.agent.runtime.output_style == "review"
      assert state.shell_state.status_msg == "Output style: review"
      assert {:ok, "review"} = Session.current_output_style(session)
    end

    test "/style none and /style off clear selected style" do
      {:ok, session} = Session.start_link(provider: StyleProvider, provider_opts: [])
      :sys.get_state(session)
      {:ok, state} = SlashCommand.execute(mock_state(session: session), "/style review")
      assert state.shell_state.agent.runtime.output_style == "review"

      {:ok, state} = SlashCommand.execute(state, "/style none")
      assert state.shell_state.agent.runtime.output_style == nil
      assert state.shell_state.status_msg == "Output style: none"

      {:ok, state} = SlashCommand.execute(state, "/style review")
      assert state.shell_state.agent.runtime.output_style == "review"
      {:ok, state} = SlashCommand.execute(state, "/style off")
      assert state.shell_state.agent.runtime.output_style == nil
    end

    test "/style unknown returns clear error and keeps previous selection" do
      {:ok, session} = Session.start_link(provider: StyleProvider, provider_opts: [])
      :sys.get_state(session)
      {:ok, state} = SlashCommand.execute(mock_state(session: session), "/style concise")

      assert {:error, message} = SlashCommand.execute(state, "/style missing")
      assert message =~ "Output style 'missing' not found"
      assert message =~ "Available styles: concise, review"
      assert {:ok, "concise"} = Session.current_output_style(session)
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
  end
end
