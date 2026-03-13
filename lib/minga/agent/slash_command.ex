defmodule Minga.Agent.SlashCommand do
  @moduledoc """
  Slash command registry and dispatcher for the agent chat input.

  When the user types `/` at the start of input and submits, the text is
  routed here instead of being sent to the LLM. Each command is a simple
  `{description, handler_fn}` where the handler receives the editor state
  and any arguments after the command name.
  """

  alias Minga.Agent.Credentials
  alias Minga.Agent.Instructions
  alias Minga.Agent.PanelState
  alias Minga.Agent.Session
  alias Minga.Agent.SessionExport
  alias Minga.Agent.Skills
  alias Minga.Config.Options
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
    %{name: "sessions", description: "Browse and switch between sessions"},
    %{
      name: "auth",
      description: "Manage API keys: /auth, /auth <provider>, /auth revoke <provider>"
    },
    %{
      name: "instructions",
      description: "Show which AGENTS.md instruction files are loaded"
    },
    %{
      name: "system-prompt",
      description: "Show the current assembled system prompt"
    },
    %{name: "compact", description: "Compact conversation context (summarize older turns)"},
    %{name: "continue", description: "Continue from an interrupted stream response"},
    %{name: "export", description: "Export session to Markdown (default) or HTML (/export html)"},
    %{name: "skills", description: "List all available skills"},
    %{name: "skill", description: "Activate a skill: /skill:name, deactivate: /skill:off:name"},
    %{
      name: "summarize",
      description: "Generate a context artifact from this session for future use"
    }
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
  defp dispatch(state, "auth", args), do: {:ok, do_auth(state, args)}
  defp dispatch(state, "instructions", _args), do: {:ok, do_instructions(state)}
  defp dispatch(state, "system-prompt", _args), do: {:ok, do_system_prompt(state)}
  defp dispatch(state, "compact", _args), do: do_compact(state)
  defp dispatch(state, "continue", _args), do: do_continue(state)
  defp dispatch(state, "export", "html"), do: do_export(state, :html)
  defp dispatch(state, "export", _args), do: do_export(state, :markdown)
  defp dispatch(state, "skills", _args), do: {:ok, do_skills(state)}
  defp dispatch(state, "summarize", _args), do: do_summarize(state)

  # /skill:name activates, /skill:off:name deactivates
  defp dispatch(state, cmd, _args) when is_binary(cmd) do
    case parse_skill_command(cmd) do
      {:activate, name} -> do_activate_skill(state, name)
      {:deactivate, name} -> do_deactivate_skill(state, name)
      :not_skill -> {:error, "Unknown command: /#{cmd}"}
    end
  end

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

  # ── Auth command ─────────────────────────────────────────────────────────────

  @spec do_auth(state(), String.t()) :: state()
  defp do_auth(state, "") do
    # No args: show status for all providers
    statuses = Credentials.status()

    lines =
      Enum.map_join(statuses, "\n", fn s ->
        icon = if s.configured, do: "✓", else: "✗"
        source_hint = if s.source, do: " (#{s.source})", else: ""
        "  #{icon} #{String.capitalize(s.provider)}#{source_hint}"
      end)

    message =
      "API key status:\n#{lines}\n\nUse /auth <provider> <key> to add a key.\nUse /auth revoke <provider> to remove one."

    emit_system_message(state, message)
  end

  defp do_auth(state, args) do
    parts = String.split(String.trim(args), " ", parts: 3)

    case parts do
      ["revoke", provider] ->
        do_auth_revoke(state, String.downcase(provider))

      ["revoke"] ->
        emit_system_message(
          state,
          "Usage: /auth revoke <provider>\nProviders: #{Enum.join(Credentials.known_providers(), ", ")}"
        )

      [provider, key] ->
        do_auth_store(state, String.downcase(provider), key)

      [provider] ->
        emit_system_message(
          state,
          "Usage: /auth #{provider} <api-key>\nPaste your API key after the provider name."
        )

      _ ->
        emit_system_message(
          state,
          "Usage: /auth [provider] [key]\nProviders: #{Enum.join(Credentials.known_providers(), ", ")}"
        )
    end
  end

  @spec do_auth_store(state(), String.t(), String.t()) :: state()
  defp do_auth_store(state, provider, key) do
    case validate_and_store(provider, key) do
      :ok ->
        emit_system_message(
          state,
          "✓ #{String.capitalize(provider)} API key saved. It will be used for new sessions."
        )

      {:error, :unknown_provider} ->
        emit_system_message(
          state,
          "Unknown provider: #{provider}\nKnown providers: #{Enum.join(Credentials.known_providers(), ", ")}"
        )

      {:error, reason} ->
        emit_system_message(state, "✗ Failed to save key: #{inspect(reason)}")
    end
  end

  @spec validate_and_store(String.t(), String.t()) :: :ok | {:error, term()}
  defp validate_and_store(provider, key) do
    if provider in Credentials.known_providers() do
      case Credentials.store(provider, key) do
        :ok ->
          set_env_for_provider(provider, key)
          :ok

        error ->
          error
      end
    else
      {:error, :unknown_provider}
    end
  end

  # Sets the env var for a provider so the current session picks it up immediately.
  @spec set_env_for_provider(String.t(), String.t()) :: :ok
  defp set_env_for_provider(provider, key) do
    case Credentials.env_var_for(provider) do
      nil -> :ok
      var_name -> System.put_env(var_name, key)
    end

    :ok
  end

  @spec do_auth_revoke(state(), String.t()) :: state()
  defp do_auth_revoke(state, provider) do
    if provider in Credentials.known_providers() do
      case Credentials.revoke(provider) do
        :ok ->
          emit_system_message(
            state,
            "✓ #{String.capitalize(provider)} API key removed from credentials file.\nNote: if the key is also set via environment variable (#{Credentials.env_var_for(provider)}), it will still be used."
          )

        {:error, reason} ->
          emit_system_message(state, "✗ Failed to revoke key: #{inspect(reason)}")
      end
    else
      emit_system_message(
        state,
        "Unknown provider: #{provider}\nKnown providers: #{Enum.join(Credentials.known_providers(), ", ")}"
      )
    end
  end

  @spec do_instructions(state()) :: state()
  @spec do_system_prompt(state()) :: state()
  defp do_system_prompt(state) do
    # Rebuild the system prompt from the same logic the provider uses.
    # This gives a faithful view of what the model sees.
    root = detect_project_root()
    instructions = Instructions.assemble(root)

    custom_base = read_config_string(:agent_system_prompt)
    append = read_config_string(:agent_append_system_prompt)

    summary_parts = [
      "**Base prompt:** #{if custom_base == "", do: "(default)", else: "custom"}",
      if(instructions,
        do: "**Instructions:** #{String.length(instructions)} chars from AGENTS.md files",
        else: nil
      ),
      if(append != "", do: "**Append:** #{String.length(append)} chars from config", else: nil)
    ]

    summary = Enum.reject(summary_parts, &is_nil/1) |> Enum.join("\n")

    emit_system_message(
      state,
      "System prompt assembly:\n\n#{summary}\n\nUse /instructions to see loaded instruction files."
    )
  end

  @spec read_config_string(atom()) :: String.t()
  defp read_config_string(key) do
    case Options.get(key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  @spec do_compact(state()) :: {:ok, state()} | {:error, String.t()}
  @spec do_continue(state()) :: {:ok, state()} | {:error, String.t()}
  defp do_continue(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      case Session.continue(session) do
        :ok ->
          {:ok, emit_system_message(state, "Continuing from interrupted response...")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No active agent session"}
    end
  end

  @spec do_export(state(), :markdown | :html) :: {:ok, state()} | {:error, String.t()}
  defp do_export(state, format) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      messages = Session.messages(session)
      root = detect_project_root()

      model = read_config_string(:agent_model)
      model = if model == "", do: "unknown", else: model

      case SessionExport.export_to_file(messages,
             project_root: root,
             model: model,
             format: format
           ) do
        {:ok, path} ->
          relative = Path.relative_to(path, root)
          {:ok, emit_system_message(state, "Session exported to ./#{relative}")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No active agent session"}
    end
  end

  @spec parse_skill_command(String.t()) ::
          {:activate, String.t()} | {:deactivate, String.t()} | :not_skill
  defp parse_skill_command(cmd) do
    case String.split(cmd, ":", parts: 3) do
      ["skill", "off", name] when name != "" -> {:deactivate, name}
      ["skill", name] when name != "" -> {:activate, name}
      _ -> :not_skill
    end
  end

  @spec do_skills(state()) :: state()
  defp do_skills(state) do
    root = detect_project_root()
    summary = Skills.summary(root)
    emit_system_message(state, summary)
  end

  @spec do_activate_skill(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_activate_skill(state, name) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      case Session.activate_skill(session, name) do
        {:ok, skill} ->
          {:ok, emit_system_message(state, "Loaded skill: #{skill.name} — #{skill.description}")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No active agent session"}
    end
  end

  @spec do_deactivate_skill(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_deactivate_skill(state, name) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      case Session.deactivate_skill(session, name) do
        :ok ->
          {:ok, emit_system_message(state, "Deactivated skill: #{name}")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No active agent session"}
    end
  end

  @spec do_summarize(state()) :: {:ok, state()} | {:error, String.t()}
  defp do_summarize(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      case Session.summarize(session) do
        {:ok, _summary_text, path} ->
          root = detect_project_root()
          relative = Path.relative_to(path, root)

          {:ok,
           emit_system_message(
             state,
             "Context artifact saved to #{relative}\nUse @#{relative} in a new session to carry this context forward."
           )}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No active agent session"}
    end
  end

  defp do_compact(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      case Session.compact(session) do
        {:ok, info} ->
          {:ok, %{state | status_msg: info}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "No active agent session"}
    end
  end

  defp do_instructions(state) do
    root = detect_project_root()
    summary = Instructions.summary(root)
    emit_system_message(state, summary)
  end

  @spec detect_project_root() :: String.t()
  defp detect_project_root do
    case Minga.Project.root() do
      nil -> File.cwd!()
      root -> root
    end
  rescue
    _ -> File.cwd!()
  catch
    :exit, _ -> File.cwd!()
  end

  @spec emit_system_message(state(), String.t()) :: state()
  defp emit_system_message(state, message) do
    if AgentAccess.session(state) do
      Session.add_system_message(AgentAccess.session(state), message)
    end

    %{state | status_msg: String.slice(message, 0, 80)}
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
