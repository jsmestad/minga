defmodule Minga.Agent.SlashCommandTest do
  use ExUnit.Case, async: true

  alias Minga.Agent.SlashCommand
  alias Minga.Agent.UIState
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess

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

      %{
        agent: %AgentState{
          session: session,
          status: :idle,
          panel: UIState.new(),
          error: nil,
          spinner_timer: nil,
          buffer: nil
        },
        agent_ui: UIState.new(),
        status_msg: nil,
        buffers: %{active: nil, list: [], active_index: 0}
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
      assert state.status_msg == "Commands listed in chat"
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
      assert state.status_msg != nil
    end

    test "/thinking with arg sets level (no session = status msg)" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/thinking high")
      assert state.status_msg == "No agent session"
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
      assert state.status_msg == "Commands listed in chat"
    end

    test "command parsing is case-insensitive" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/HELP")
      assert state.status_msg == "Commands listed in chat"
    end

    test "command parsing trims whitespace" do
      {:ok, state} = SlashCommand.execute(mock_state(), "/help  ")
      assert state.status_msg == "Commands listed in chat"
    end
  end
end
