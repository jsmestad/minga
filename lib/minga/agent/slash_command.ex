defmodule Minga.Agent.SlashCommand do
  @moduledoc """
  Slash command registry and dispatcher for the agent chat input.

  When the user types `/` at the start of input and submits, the text is
  routed here instead of being sent to the LLM. Each command is a simple
  `{description, handler_fn}` where the handler receives the editor state
  and any arguments after the command name.
  """

  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State.Agent, as: AgentState
  alias Minga.Editor.State.AgentAccess

  @typedoc "Editor state (same as EditorState.t())."
  @type state :: map()

  @typedoc "A registered slash command."
  @type command :: %{name: String.t(), description: String.t()}

  @commands [
    %{name: "clear", description: "Start a fresh session"},
    %{name: "new", description: "Start a fresh session (alias for /clear)"},
    %{name: "stop", description: "Abort the current agent operation"},
    %{name: "abort", description: "Abort the current agent operation (alias for /stop)"},
    %{name: "thinking", description: "Set thinking level: /thinking [off|low|medium|high]"},
    %{name: "model", description: "Set the model: /model <name>"},
    %{name: "help", description: "Show available slash commands"},
    %{name: "sessions", description: "Browse and switch between sessions"}
  ]

  @doc "Returns the list of all registered slash commands."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc "Returns commands whose names start with the given prefix."
  @spec completions(String.t()) :: [command()]
  def completions(prefix) when is_binary(prefix) do
    clean = String.trim_leading(prefix, "/")
    Enum.filter(@commands, fn cmd -> String.starts_with?(cmd.name, clean) end)
  end

  @doc """
  Parses and executes a slash command from raw input text.

  Returns `{:ok, state}` if the command was recognized and executed,
  or `{:error, message}` if the command is unknown.
  """
  @spec execute(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  def execute(state, "/" <> rest) do
    {cmd_name, args} = parse_command(rest)
    dispatch(state, cmd_name, args)
  end

  def execute(_state, _text), do: {:error, "Not a slash command"}

  @doc """
  Returns true if the given text is a slash command (starts with /).
  """
  @spec slash_command?(String.t()) :: boolean()
  def slash_command?("/" <> _), do: true
  def slash_command?(_), do: false

  # ── Command dispatch ────────────────────────────────────────────────────────

  @spec dispatch(state(), String.t(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp dispatch(state, "clear", _args), do: {:ok, do_clear(state)}
  defp dispatch(state, "new", _args), do: {:ok, do_clear(state)}
  defp dispatch(state, "stop", _args), do: {:ok, do_stop(state)}
  defp dispatch(state, "abort", _args), do: {:ok, do_stop(state)}
  defp dispatch(state, "thinking", args), do: {:ok, do_thinking(state, args)}
  defp dispatch(state, "model", args), do: do_model(state, args)
  defp dispatch(state, "help", _args), do: {:ok, do_help(state)}
  defp dispatch(state, "?", _args), do: {:ok, do_help(state)}
  defp dispatch(state, "sessions", _args), do: {:ok, do_sessions(state)}
  defp dispatch(_state, cmd, _args), do: {:error, "Unknown command: /#{cmd}"}

  # ── Command implementations ────────────────────────────────────────────────

  @spec do_clear(state()) :: state()
  defp do_clear(state) do
    AgentCommands.new_agent_session(state)
  end

  @spec do_stop(state()) :: state()
  defp do_stop(state) do
    AgentCommands.abort_agent(state)
  end

  @spec do_thinking(state(), String.t()) :: state()
  defp do_thinking(state, "") do
    AgentCommands.cycle_thinking_level(state)
  end

  defp do_thinking(state, level) do
    level = String.trim(level)

    if AgentAccess.session(state) do
      case Session.set_thinking_level(AgentAccess.session(state), level) do
        :ok ->
          state = AgentAccess.update_agent(state, &AgentState.set_thinking_level(&1, level))
          Session.add_system_message(AgentAccess.session(state), "Thinking: #{level}")
          %{state | status_msg: "Thinking: #{level}"}

        {:error, reason} ->
          %{state | status_msg: "Error: #{inspect(reason)}"}
      end
    else
      %{state | status_msg: "No agent session"}
    end
  end

  @spec do_model(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_model(_state, ""), do: {:error, "Usage: /model <name>"}

  defp do_model(state, model) do
    model = String.trim(model)
    state = AgentCommands.set_model(state, model)
    {:ok, state}
  end

  @spec do_help(state()) :: state()
  defp do_help(state) do
    help_text =
      @commands
      |> Enum.map_join("\n", fn cmd -> "  /#{cmd.name} — #{cmd.description}" end)

    if AgentAccess.session(state) do
      Session.add_system_message(AgentAccess.session(state), "Available commands:\n#{help_text}")
    end

    %{state | status_msg: "Commands listed in chat"}
  end

  @spec do_sessions(state()) :: state()
  defp do_sessions(state) do
    PickerUI.open(state, Minga.Picker.AgentSessionSource)
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec parse_command(String.t()) :: {String.t(), String.t()}
  defp parse_command(text) do
    text = String.trim(text)

    case String.split(text, " ", parts: 2) do
      [cmd] -> {String.downcase(cmd), ""}
      [cmd, args] -> {String.downcase(cmd), args}
    end
  end

  # Silence the "unused alias" warning; PanelState is used transitively
  # via AgentCommands which is called from dispatch.
  _ = @moduledoc && PanelState
end
