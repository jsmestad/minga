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
  alias Minga.Agent.Memory
  alias Minga.Agent.Session
  alias Minga.Agent.SessionExport
  alias Minga.Agent.Skills
  alias Minga.Agent.UIState
  alias Minga.Config.Options
  alias Minga.Editor.Commands.Agent, as: AgentCommands
  alias Minga.Editor.PickerUI
  alias Minga.Editor.State.AgentAccess

  @typedoc "Editor state (same as EditorState.t())."
  @type state :: map()

  alias Minga.Agent.SlashCommand.Command

  @typedoc "A registered slash command."
  @type command :: Command.t()

  @commands [
    %Command{name: "clear", description: "Start a fresh session"},
    %Command{name: "new", description: "Start a fresh session (alias for /clear)"},
    %Command{name: "stop", description: "Abort the current agent operation"},
    %Command{name: "abort", description: "Abort the current agent operation (alias for /stop)"},
    %Command{
      name: "thinking",
      description: "Set thinking level: /thinking [off|low|medium|high]"
    },
    %Command{name: "model", description: "Set the model: /model <name>"},
    %Command{name: "help", description: "Show available slash commands"},
    %Command{name: "sessions", description: "Browse and switch between sessions"},
    %Command{
      name: "auth",
      description: "Manage API keys: /auth, /auth <provider>, /auth revoke <provider>"
    },
    %Command{
      name: "instructions",
      description: "Show which AGENTS.md instruction files are loaded"
    },
    %Command{
      name: "system-prompt",
      description: "Show the current assembled system prompt"
    },
    %Command{
      name: "budget",
      description: "Show or set session cost budget: /budget, /budget <amount>, /budget off"
    },
    %Command{
      name: "compact",
      description: "Compact conversation context (summarize older turns)"
    },
    %Command{name: "continue", description: "Continue from an interrupted stream response"},
    %Command{
      name: "export",
      description: "Export session to Markdown (default) or HTML (/export html)"
    },
    %Command{name: "skills", description: "List all available skills"},
    %Command{
      name: "skill",
      description: "Activate a skill: /skill:name, deactivate: /skill:off:name"
    },
    %Command{
      name: "summarize",
      description: "Generate a context artifact from this session for future use"
    },
    %Command{
      name: "remember",
      description: "Save a learning to persistent memory: /remember <text>"
    },
    %Command{name: "memory", description: "Show the current memory file contents"},
    %Command{name: "forget", description: "Clear the persistent memory file"},
    %Command{name: "branch", description: "Branch at a turn: /branch <turn_number>"},
    %Command{name: "branches", description: "List all conversation branches"},
    %Command{name: "switch", description: "Switch to a branch: /switch <branch_number>"}
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
  defp dispatch(state, "budget", args), do: do_budget(state, args)
  defp dispatch(state, "compact", _args), do: do_compact(state)
  defp dispatch(state, "continue", _args), do: do_continue(state)
  defp dispatch(state, "export", "html"), do: do_export(state, :html)
  defp dispatch(state, "export", _args), do: do_export(state, :markdown)
  defp dispatch(state, "skills", _args), do: {:ok, do_skills(state)}
  defp dispatch(state, "summarize", _args), do: do_summarize(state)
  defp dispatch(state, "remember", args), do: do_remember(state, args)
  defp dispatch(state, "memory", _args), do: {:ok, do_memory(state)}
  defp dispatch(state, "forget", _args), do: do_forget(state)
  defp dispatch(state, "branch", args), do: do_branch(state, args)
  defp dispatch(state, "branches", _args), do: do_branches(state)
  defp dispatch(state, "switch", args), do: do_switch_branch(state, args)

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
          state = AgentAccess.update_agent_ui(state, &UIState.set_thinking_level(&1, level))
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

    endpoint_info = format_endpoint_info()

    message =
      "API key status:\n#{lines}#{endpoint_info}\n\nUse /auth <provider> <key> to add a key.\nUse /auth revoke <provider> to remove one."

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

    endpoint = active_endpoint_display()

    summary_parts = [
      "**Base prompt:** #{if custom_base == "", do: "(default)", else: "custom"}",
      if(instructions,
        do: "**Instructions:** #{String.length(instructions)} chars from AGENTS.md files",
        else: nil
      ),
      if(append != "", do: "**Append:** #{String.length(append)} chars from config", else: nil),
      if(endpoint, do: "**API endpoint:** #{endpoint}", else: nil)
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

  @spec do_budget(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_budget(state, "") do
    with {:ok, provider} <- require_provider(state),
         {:ok, budget} <- GenServer.call(provider, :get_budget) do
      {:ok, emit_system_message(state, format_budget_status(budget))}
    end
  end

  defp do_budget(state, "off") do
    with {:ok, provider} <- require_provider(state) do
      :ok = GenServer.call(provider, {:set_max_cost, nil})
      {:ok, emit_system_message(state, "Cost budget disabled.")}
    end
  end

  defp do_budget(state, amount_str) do
    with {:ok, provider} <- require_provider(state),
         {amount, _} when amount > 0 <-
           Float.parse(String.trim(amount_str) |> String.trim_leading("$")) do
      :ok = GenServer.call(provider, {:set_max_cost, amount})
      formatted = :erlang.float_to_binary(amount, decimals: 2)
      {:ok, emit_system_message(state, "Cost budget set to $#{formatted} for this session.")}
    else
      {:error, _} = err -> err
      _ -> {:error, "Invalid amount. Use /budget <number> (e.g., /budget 5.00)"}
    end
  end

  @spec require_provider(state()) :: {:ok, pid()} | {:error, String.t()}
  defp require_provider(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      {:ok, get_provider(session)}
    else
      {:error, "No active agent session"}
    end
  end

  @spec format_budget_status(map()) :: String.t()
  defp format_budget_status(budget) do
    spent = :erlang.float_to_binary(budget.session_cost, decimals: 2)

    limit_text =
      case budget.max_cost do
        nil -> "no limit"
        amount -> "$#{:erlang.float_to_binary(amount + 0.0, decimals: 2)}"
      end

    "Session budget:\n" <>
      "  Spent: $#{spent}\n" <>
      "  Limit: #{limit_text}\n" <>
      "  Max turns per prompt: #{budget.max_turns}\n\n" <>
      "Use /budget <amount> to set a limit, /budget off to disable."
  end

  # Gets the provider pid from the session. Used for direct GenServer calls
  # to provider-specific features (budget, etc.) that aren't in the Provider behaviour.
  # Consider adding get_budget/1 and set_budget/2 to the Provider behaviour
  # so slash commands don't need to reach past the Session abstraction.
  @spec get_provider(pid()) :: pid() | nil
  defp get_provider(session_pid) do
    # The session stores the provider pid in its state. We need to access it.
    # Since Session doesn't expose this directly, we'll use the session's internal
    # forwarding. For now, we add a get_provider call to Session.
    Session.get_provider(session_pid)
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

  @spec do_remember(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_remember(_state, ""), do: {:error, "Usage: /remember <text to remember>"}

  defp do_remember(state, text) do
    case Memory.append(text) do
      :ok ->
        {:ok, emit_system_message(state, "Saved to memory: #{String.trim(text)}")}

      {:error, reason} ->
        {:error, "Failed to save memory: #{inspect(reason)}"}
    end
  end

  @spec do_memory(state()) :: state()
  defp do_memory(state) do
    emit_system_message(state, Memory.summary())
  end

  @spec do_forget(state()) :: {:ok, state()} | {:error, String.t()}
  defp do_forget(state) do
    case Memory.clear() do
      :ok -> {:ok, emit_system_message(state, "Memory cleared.")}
      {:error, reason} -> {:error, "Failed to clear memory: #{inspect(reason)}"}
    end
  end

  @spec do_branch(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_branch(_state, ""), do: {:error, "Usage: /branch <turn_number>"}

  defp do_branch(state, args) do
    with {:ok, session} <- require_session(state),
         {:ok, turn_index} <- parse_int(args, "Invalid turn number. Use /branch <number>"),
         {:ok, message} <- Session.branch_at(session, turn_index) do
      {:ok, emit_system_message(state, message)}
    end
  end

  @spec do_branches(state()) :: {:ok, state()}
  defp do_branches(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      {:ok, listing} = Session.list_branches(session)
      {:ok, emit_system_message(state, "Branches:\n#{listing}")}
    else
      {:ok, emit_system_message(state, "No active agent session")}
    end
  end

  @spec do_switch_branch(state(), String.t()) :: {:ok, state()} | {:error, String.t()}
  defp do_switch_branch(_state, ""), do: {:error, "Usage: /switch <branch_number>"}

  defp do_switch_branch(state, args) do
    with {:ok, session} <- require_session(state),
         {:ok, idx} <- parse_int(args, "Invalid branch number. Use /branches to list.") do
      case Session.switch_branch(session, idx) do
        :ok -> {:ok, emit_system_message(state, "Switched to branch #{idx}.")}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec require_session(state()) :: {:ok, pid()} | {:error, String.t()}
  defp require_session(state) do
    session = AgentAccess.session(state)

    if is_pid(session) do
      {:ok, session}
    else
      {:error, "No active agent session"}
    end
  end

  @spec parse_int(String.t(), String.t()) :: {:ok, integer()} | {:error, String.t()}
  defp parse_int(str, error_message) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> {:ok, n}
      :error -> {:error, error_message}
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

  @spec active_endpoint_display() :: String.t() | nil
  defp active_endpoint_display do
    env = System.get_env("MINGA_API_BASE_URL")
    if env && env != "", do: "#{env} (env)", else: active_endpoint_from_config()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @spec active_endpoint_from_config() :: String.t() | nil
  defp active_endpoint_from_config do
    global = read_config_string(:agent_api_base_url)
    if global != "", do: global, else: nil
  end

  @spec format_endpoint_info() :: String.t()
  defp format_endpoint_info do
    parts =
      []
      |> maybe_add_env_endpoint()
      |> maybe_add_per_provider_endpoints()
      |> maybe_add_global_endpoint()

    case parts do
      [] -> ""
      _ -> "\n\n" <> Enum.join(parts, "\n")
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end

  @spec maybe_add_env_endpoint([String.t()]) :: [String.t()]
  defp maybe_add_env_endpoint(parts) do
    case System.get_env("MINGA_API_BASE_URL") do
      env when is_binary(env) and env != "" -> parts ++ ["  Endpoint (env): #{env}"]
      _ -> parts
    end
  end

  @spec maybe_add_per_provider_endpoints([String.t()]) :: [String.t()]
  defp maybe_add_per_provider_endpoints(parts) do
    case Options.get(:agent_api_endpoints) do
      m when is_map(m) and map_size(m) > 0 ->
        lines = Enum.map_join(m, "\n", fn {p, u} -> "    #{p}: #{u}" end)
        parts ++ ["  Endpoints (per-provider):\n#{lines}"]

      _ ->
        parts
    end
  rescue
    _ -> parts
  catch
    :exit, _ -> parts
  end

  @spec maybe_add_global_endpoint([String.t()]) :: [String.t()]
  defp maybe_add_global_endpoint(parts) do
    global = read_config_string(:agent_api_base_url)

    case {global, parts} do
      {"", _} -> parts
      {url, []} -> parts ++ ["  Endpoint: #{url}"]
      {url, _} -> parts ++ ["  Endpoint (global fallback): #{url}"]
    end
  end

  @spec parse_command(String.t()) :: {String.t(), String.t()}
  defp parse_command(text) do
    text = String.trim(text)

    case String.split(text, " ", parts: 2) do
      [cmd] -> {String.downcase(cmd), ""}
      [cmd, args] -> {String.downcase(cmd), args}
    end
  end

  # Silence the "unused alias" warning; UIState is used transitively
  # via AgentCommands which is called from dispatch.
  _ = @moduledoc && UIState
end
