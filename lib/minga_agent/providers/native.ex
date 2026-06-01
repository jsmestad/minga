# credo:disable-for-this-file Credo.Check.Refactor.Nesting

defmodule MingaAgent.Providers.Native do
  @moduledoc """
  Native Elixir agent provider backed by ReqLLM.

  Runs entirely inside the BEAM with no external dependencies. Supports any
  provider that ReqLLM supports (Anthropic, OpenAI, Ollama, Groq, Bedrock,
  etc.) by accepting a model string like `"anthropic:claude-sonnet-4-20250514"`.

  The provider manages conversation history via `ReqLLM.Context`, executes
  tools locally, and emits `Agent.Event` structs to its subscriber (the
  `Agent.Session`) for rendering in the chat panel.

  ## Architecture

  When `send_prompt/2` is called, the provider spawns a linked `Task` to run
  the agent turn loop. The loop:

  1. Calls `ReqLLM.stream_text/3` with the conversation history and tools
  2. Uses `StreamResponse.process_stream/2` with callbacks to emit events
     in real time as chunks arrive
  3. If the response contains tool calls, executes each tool, appends results
     to the conversation context, and loops back to step 1
  4. If no tool calls, the turn is complete

  The task sends events to the GenServer via `send/2`, and the GenServer
  forwards them to the subscriber. This keeps the GenServer responsive for
  abort and state queries while streaming is in progress.
  """

  @behaviour MingaAgent.Provider

  use GenServer

  alias Minga.Buffer
  alias MingaAgent.Compaction
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.ContextArtifact
  alias MingaAgent.CostCalculator
  alias MingaAgent.Event
  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.Hooks.Dispatcher, as: HookDispatcher
  alias MingaAgent.Hooks.PostToolUsePayload
  alias MingaAgent.Hooks.PreCompactPayload
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result, as: HookResult
  alias MingaAgent.Hooks.Registry, as: HookRegistry
  alias MingaAgent.Instructions
  alias MingaAgent.InternalState
  alias MingaAgent.MCP.Registry, as: MCPRegistry
  alias MingaAgent.MCP.ServerConfig, as: MCPServerConfig
  alias MingaAgent.MCP.ServerRegistry, as: MCPServerRegistry
  alias MingaAgent.Memory
  alias MingaAgent.ModelCatalog
  alias MingaAgent.ModelLimits
  alias MingaAgent.ProjectView
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.ToolRouter
  alias MingaAgent.Retry
  alias MingaAgent.Session
  alias MingaAgent.Skills
  alias MingaAgent.TokenEstimator
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Executor, as: ToolExecutor
  alias MingaAgent.Tool.PlanMode
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.Tool.Spec, as: ToolSpec
  alias MingaAgent.Tools
  alias MingaAgent.Tools.Notebook
  alias MingaAgent.Tools.Shell
  alias MingaAgent.Tools.Todo
  alias Minga.Config
  alias ReqLLM.Context

  # Thinking levels and cycle order (not config-driven; mode-specific constants).

  @thinking_levels %{
    "off" => nil,
    "low" => :low,
    "medium" => :medium,
    "high" => :high
  }

  @thinking_cycle ["off", "low", "medium", "high"]

  defmodule LoopCtx do
    @moduledoc false
    @enforce_keys [
      :provider_pid,
      :model,
      :config,
      :tools,
      :project_root,
      :thinking_level,
      :max_tokens,
      :max_retries,
      :llm_client,
      :hook_runner,
      :max_turns,
      :max_cost
    ]
    defstruct [
      :provider_pid,
      :model,
      :config,
      :tools,
      :project_root,
      :project_view,
      :fork_store,
      :changeset,
      :thinking_level,
      :max_tokens,
      :max_retries,
      :llm_client,
      :hook_runner,
      :max_turns,
      :max_cost,
      :session_pid,
      turn_count: 0,
      session_cost: 0.0
    ]

    @type t :: %__MODULE__{
            provider_pid: pid(),
            model: String.t(),
            config: MingaAgent.Config.t(),
            tools: [term()],
            project_root: String.t(),
            project_view: ProjectView.t() | nil,
            fork_store: pid() | nil,
            changeset: pid() | nil,
            thinking_level: String.t(),
            max_tokens: pos_integer(),
            max_retries: non_neg_integer(),
            llm_client: term(),
            hook_runner: MingaAgent.Providers.Native.hook_runner(),
            max_turns: pos_integer(),
            max_cost: float() | nil,
            session_pid: pid() | nil,
            turn_count: non_neg_integer(),
            session_cost: float()
          }
  end

  @typedoc "Captures the immutable parameters for one agent turn loop invocation."
  @type loop_ctx :: LoopCtx.t()

  @typedoc "Function that performs the LLM streaming call."
  @type llm_client :: (String.t(), [ReqLLM.Message.t()], keyword() ->
                         {:ok, ReqLLM.StreamResponse.t()} | {:error, term()})

  @typedoc "Function that executes a matching hook."
  @type hook_runner :: (MingaAgent.Hooks.Hook.t(), PreToolUsePayload.t() -> HookResult.t())

  @typedoc "Internal state for the native provider."
  @type state :: %{
          subscriber: pid(),
          model: String.t(),
          config: AgentConfig.t(),
          context: Context.t(),
          tools: [term()],
          project_root: String.t(),
          project_view: ProjectView.t() | nil,
          thinking_level: String.t(),
          max_tokens: pos_integer(),
          max_retries: non_neg_integer(),
          llm_client: llm_client(),
          hook_runner: hook_runner(),
          task: Task.t() | nil,
          streaming: boolean(),
          interrupted: boolean(),
          last_user_prompt: String.t() | nil,
          active_skills: [Skills.skill()],
          internal_state: InternalState.t(),
          max_turns: pos_integer(),
          max_cost: float() | nil,
          session_cost: float(),
          fork_store: pid() | nil,
          changeset: pid() | nil,
          base_tools: [term()],
          mcp_tools: [term()],
          internal_tools: [term()],
          custom_tools?: boolean(),
          configured_mcp_configs: [MCPServerConfig.t()],
          mcp_configs: [MCPServerConfig.t()],
          mcp_client_opts: keyword(),
          mcp_enabled_override: boolean() | nil,
          mcp_errors: %{String.t() => String.t()},
          mcp_registry: MCPRegistry.t() | nil,
          read_only?: boolean(),
          tool_allowlist: :all | [String.t()],
          tool_workers: %{reference() => pid()}
        }

  # ── Provider callbacks ──────────────────────────────────────────────────────

  @impl MingaAgent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MingaAgent.Provider
  @spec send_prompt(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def send_prompt(pid, text) when is_binary(text) do
    GenServer.call(pid, {:send_prompt, text})
  end

  @impl MingaAgent.Provider
  @spec abort(GenServer.server()) :: :ok
  def abort(pid) do
    GenServer.call(pid, :abort)
  end

  @impl MingaAgent.Provider
  @spec new_session(GenServer.server()) :: :ok | {:error, term()}
  def new_session(pid) do
    GenServer.call(pid, :new_session)
  end

  @impl MingaAgent.Provider
  @spec seed_messages(GenServer.server(), [MingaAgent.Message.t()]) :: :ok | {:error, term()}
  def seed_messages(pid, messages) when is_list(messages) do
    GenServer.call(pid, {:seed_messages, messages})
  end

  @impl MingaAgent.Provider
  @spec get_state(GenServer.server()) ::
          {:ok, MingaAgent.Provider.session_state()} | {:error, term()}
  def get_state(pid) do
    GenServer.call(pid, :get_state)
  end

  @impl MingaAgent.Provider
  @spec set_thinking_level(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_thinking_level(pid, level) when is_binary(level) do
    GenServer.call(pid, {:set_thinking_level, level})
  end

  @impl MingaAgent.Provider
  @spec cycle_thinking_level(GenServer.server()) :: {:ok, term()} | {:error, term()}
  def cycle_thinking_level(pid) do
    GenServer.call(pid, :cycle_thinking_level)
  end

  @impl MingaAgent.Provider
  @spec get_available_models(GenServer.server()) :: {:ok, [map()]} | {:error, term()}
  def get_available_models(pid) do
    GenServer.call(pid, :get_available_models, 10_000)
  end

  @doc "Manually triggers context compaction."
  @spec compact(GenServer.server()) :: {:ok, String.t()} | {:error, String.t()}
  def compact(pid) do
    GenServer.call(pid, :compact, 30_000)
  end

  @impl MingaAgent.Provider
  @spec cycle_model(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def cycle_model(pid) do
    GenServer.call(pid, :cycle_model)
  end

  @impl MingaAgent.Provider
  @spec set_model(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_model(pid, model) when is_binary(model) do
    GenServer.call(pid, {:set_model, model})
  end

  @doc "Continues from an interrupted stream, asking the model to pick up where it left off."
  @spec continue(GenServer.server()) :: :ok | {:error, term()}
  def continue(pid) do
    GenServer.call(pid, :continue)
  end

  @doc "Refreshes the project view and rebuilds file tools around the new overlay."
  @spec refresh_project_view(GenServer.server(), ProjectView.t() | nil) :: :ok | {:error, term()}
  def refresh_project_view(pid, project_view) do
    GenServer.call(pid, {:refresh_project_view, project_view})
  end

  @doc "Returns the current tool list registered with this provider."
  @spec tools(GenServer.server()) :: [ReqLLM.Tool.t()]
  def tools(pid) do
    GenServer.call(pid, :tools)
  end

  @doc "Returns the PID of the fork store, or nil if not active."
  @spec fork_store(GenServer.server()) :: pid() | nil
  def fork_store(pid) do
    GenServer.call(pid, :fork_store)
  end

  @doc "Returns the agent hooks from the provider's config."
  @spec agent_hooks(GenServer.server()) :: [MingaAgent.Hooks.Hook.t()]
  def agent_hooks(pid) do
    GenServer.call(pid, :agent_hooks)
  end

  @doc "Returns the project view associated with this provider, or nil."
  @spec project_view(GenServer.server()) :: ProjectView.t() | nil
  def project_view(pid) do
    GenServer.call(pid, :project_view)
  end

  @doc "Returns the changeset PID, or nil."
  @spec changeset(GenServer.server()) :: pid() | nil
  def changeset(pid) do
    GenServer.call(pid, :changeset)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl GenServer
  @spec init(keyword()) :: {:ok, state()}
  def init(opts) do
    config = Keyword.get(opts, :config) || AgentConfig.resolve()

    subscriber = Keyword.fetch!(opts, :subscriber)
    model = Keyword.get(opts, :model, config.model)
    thinking_level = Keyword.get(opts, :thinking_level, "off")
    project_root = Keyword.get(opts, :project_root) || detect_project_root()
    project_view = Keyword.get(opts, :project_view)

    max_tokens = Keyword.get(opts, :max_tokens, config.max_tokens)
    max_retries = Keyword.get(opts, :max_retries, config.max_retries)
    max_turns = Keyword.get(opts, :max_turns, config.max_turns)
    read_only? = Keyword.get(opts, :read_only?, false)
    config = disable_hooks_for_read_only(config, read_only?)
    {config, ext_mcp_servers} = merge_extension_components(config, read_only?)
    max_cost = Keyword.get(opts, :max_cost, config.max_cost)
    llm_client = Keyword.get(opts, :llm_client, ReqLLMAdapter.default_client())
    hook_runner = Keyword.get(opts, :hook_runner, &CommandRunner.run_pre_tool_use/2)
    provider_pid = self()

    {fork_store, changeset} =
      init_fork_store_and_changeset(project_view, project_root, opts)

    tool_context =
      native_tool_context(project_root, project_view, fork_store, changeset, subscriber)

    base_tools =
      Keyword.get(opts, :tools) ||
        registry_tools(tool_context, config, hook_runner)

    base_tools = filter_base_tools_for_read_only(base_tools, read_only?)

    custom_tools? = Keyword.has_key?(opts, :tools)
    active_skills = load_active_skills(project_root, Keyword.get(opts, :active_skill_names, []))
    internal_tools = if read_only?, do: [], else: build_internal_tools(provider_pid)

    configured_mcp_configs = configured_mcp_servers(opts, config, subscriber, read_only?)

    mcp_configs =
      configured_mcp_configs ++ filter_ext_mcp_servers(ext_mcp_servers, opts, read_only?)

    mcp_configs = deduplicate_mcp_configs(mcp_configs)

    mcp_client_opts = mcp_client_opts(opts)
    mcp_enabled_override = Keyword.get(opts, :mcp_enabled?, nil)
    mcp_registry = mcp_registry_for(mcp_configs)
    mcp_tools = mcp_meta_tools_for(mcp_configs, provider_pid)

    tool_allowlist = Keyword.get(opts, :tool_allowlist, :all)

    tools =
      (base_tools ++ mcp_tools ++ internal_tools)
      |> filter_tool_allowlist(tool_allowlist)

    system_prompt = build_system_prompt(project_root, active_skills)
    context = Context.new([Context.system(system_prompt)])

    # Resolve API key from credentials (env var or credentials file).
    # If found in the file but not in the env, set the env var so ReqLLM
    # picks it up automatically. Tests can disable this to avoid mutating
    # process-wide environment state.
    unless Keyword.get(opts, :skip_api_key_env, false) or ReqLLMAdapter.openai_codex_model?(model) do
      ReqLLMAdapter.ensure_api_key_in_env(model)
    end

    state = %{
      subscriber: subscriber,
      model: model,
      config: config,
      context: context,
      tools: tools,
      project_root: project_root,
      thinking_level: thinking_level,
      max_tokens: max_tokens,
      max_retries: max_retries,
      llm_client: llm_client,
      hook_runner: hook_runner,
      task: nil,
      streaming: false,
      interrupted: false,
      last_user_prompt: nil,
      active_skills: active_skills,
      internal_state: InternalState.new(),
      max_turns: max_turns,
      max_cost: max_cost,
      session_cost: 0.0,
      fork_store: fork_store,
      changeset: changeset,
      project_view: project_view,
      base_tools: base_tools,
      mcp_tools: mcp_tools,
      internal_tools: internal_tools,
      custom_tools?: custom_tools?,
      configured_mcp_configs: configured_mcp_configs,
      mcp_configs: mcp_configs,
      mcp_client_opts: mcp_client_opts,
      mcp_enabled_override: mcp_enabled_override,
      mcp_errors: %{},
      mcp_registry: mcp_registry,
      read_only?: read_only?,
      tool_allowlist: tool_allowlist,
      tool_workers: %{}
    }

    Minga.Events.subscribe(:agent_mcp_servers_changed)
    Minga.Log.info(:agent, "[Agent.Native] started with model=#{model} root=#{project_root}")

    {:ok, state}
  end

  @spec native_tool_context(
          String.t(),
          ProjectView.t() | nil,
          pid() | nil,
          pid() | nil,
          pid() | nil
        ) :: ToolContext.t()
  defp native_tool_context(project_root, project_view, fork_store, changeset, parent_session) do
    ToolContext.new(
      project_root: project_root,
      project_view: project_view,
      fork_store: fork_store,
      changeset: changeset,
      metadata: %{parent_session: parent_session}
    )
  end

  @spec registry_tools(ToolContext.t(), AgentConfig.t(), hook_runner()) :: [ReqLLM.Tool.t()]
  defp registry_tools(%ToolContext{} = tool_context, %AgentConfig{} = config, hook_runner) do
    ToolRegistry.all()
    |> Enum.map(&registry_tool(&1, tool_context, config, hook_runner))
  end

  @spec registry_tool(ToolSpec.t(), ToolContext.t(), AgentConfig.t(), hook_runner()) ::
          ReqLLM.Tool.t()
  defp registry_tool(%ToolSpec{} = spec, %ToolContext{} = tool_context, config, hook_runner) do
    ReqLLM.Tool.new!(
      name: spec.name,
      description: spec.description,
      parameter_schema: spec.parameter_schema,
      provider_options: %{minga_registry_tool: true, source: inspect(spec.source)},
      callback: fn args ->
        ToolExecutor.execute_approved(spec, args || %{}, :exec,
          config: config,
          hook_runner: hook_runner,
          tool_context: tool_context
        )
      end
    )
  end

  @spec disable_hooks_for_read_only(AgentConfig.t(), boolean()) :: AgentConfig.t()
  defp disable_hooks_for_read_only(%AgentConfig{} = config, true),
    do: AgentConfig.without_hooks(config)

  defp disable_hooks_for_read_only(%AgentConfig{} = config, false), do: config

  @spec merge_extension_components(AgentConfig.t(), boolean()) ::
          {AgentConfig.t(), [MCPServerConfig.t()]}
  defp merge_extension_components(config, true), do: {config, []}

  defp merge_extension_components(config, false) do
    config = %{config | agent_hooks: merge_agent_hooks(config.agent_hooks, HookRegistry.all())}
    {config, MCPServerRegistry.configs()}
  end

  @spec merge_agent_hooks([MingaAgent.Hooks.Hook.t()], [MingaAgent.Hooks.Hook.t()]) ::
          [MingaAgent.Hooks.Hook.t()]
  defp merge_agent_hooks(config_hooks, registry_hooks) do
    (config_hooks ++ registry_hooks)
    |> Enum.uniq_by(&hook_key/1)
  end

  @spec hook_key(MingaAgent.Hooks.Hook.t()) :: term()
  defp hook_key(hook) do
    {hook.event, hook.type, hook.tool_pattern, hook.command, hook.module, hook.function,
     hook.extension_source, hook.extension_module}
  end

  @spec filter_ext_mcp_servers([MCPServerConfig.t()], keyword(), boolean()) ::
          [MCPServerConfig.t()]
  defp filter_ext_mcp_servers(_servers, _opts, true), do: []
  defp filter_ext_mcp_servers([], _opts, _read_only?), do: []

  defp filter_ext_mcp_servers(servers, opts, false) do
    if mcp_extension_enabled?(opts), do: servers, else: []
  end

  @spec refresh_mcp_contributions(map()) :: map()
  defp refresh_mcp_contributions(%{read_only?: true} = state), do: state

  defp refresh_mcp_contributions(state) do
    configs =
      state
      |> configured_mcp_servers_from_state()
      |> Kernel.++(extension_mcp_servers_from_state(state))
      |> deduplicate_mcp_configs()

    if configs == state.mcp_configs do
      state
    else
      cleanup_mcp(state.mcp_registry)

      mcp_registry = mcp_registry_for(configs)
      mcp_tools = mcp_meta_tools_for(configs, self())

      %{
        state
        | mcp_configs: configs,
          mcp_registry: mcp_registry,
          mcp_tools: mcp_tools,
          mcp_errors: %{},
          tools:
            (state.base_tools ++ mcp_tools ++ state.internal_tools)
            |> filter_tool_allowlist(state.tool_allowlist)
      }
    end
  end

  @spec extension_mcp_servers_from_state(map()) :: [MCPServerConfig.t()]
  defp extension_mcp_servers_from_state(state) do
    if state.read_only? do
      []
    else
      case state.mcp_enabled_override do
        false -> []
        true -> MCPServerRegistry.configs()
        nil -> if Minga.Extensions.MCP.enabled?(), do: MCPServerRegistry.configs(), else: []
      end
    end
  end

  @spec configured_mcp_servers_from_state(map()) :: [MCPServerConfig.t()]
  defp configured_mcp_servers_from_state(state), do: state.configured_mcp_configs

  @spec deduplicate_mcp_configs([MCPServerConfig.t()]) :: [MCPServerConfig.t()]
  defp deduplicate_mcp_configs(configs) do
    {deduped, _seen} =
      Enum.reduce(configs, {[], MapSet.new()}, fn config, {acc, seen} ->
        if MapSet.member?(seen, config.name) do
          Minga.Log.warning(
            :agent,
            "[Agent.Native] duplicate MCP server name ignored: #{config.name}"
          )

          {acc, seen}
        else
          {[config | acc], MapSet.put(seen, config.name)}
        end
      end)

    Enum.reverse(deduped)
  end

  @spec init_fork_store_and_changeset(ProjectView.t() | nil, String.t(), keyword()) ::
          {pid() | nil, pid() | nil}
  defp init_fork_store_and_changeset(%ProjectView{}, _project_root, _opts), do: {nil, nil}

  defp init_fork_store_and_changeset(_project_view, project_root, opts) do
    {:ok, fork_store} = GenServer.start(MingaAgent.BufferForkStore, :ok)
    Process.monitor(fork_store)
    changeset = maybe_create_changeset(project_root, opts)
    {fork_store, changeset}
  end

  @spec maybe_create_changeset(String.t(), keyword()) :: pid() | nil
  defp maybe_create_changeset(project_root, opts) do
    if Keyword.get(opts, :changeset, false) do
      case MingaAgent.Changeset.create(project_root) do
        {:ok, cs} ->
          Process.monitor(cs)
          cs

        {:error, reason} ->
          Minga.Log.warning(
            :agent,
            "[Agent.Native] changeset creation failed: #{inspect(reason)}"
          )

          nil
      end
    end
  end

  @spec filter_base_tools_for_read_only([ReqLLM.Tool.t()], boolean()) :: [ReqLLM.Tool.t()]
  defp filter_base_tools_for_read_only(base_tools, true),
    do: Enum.filter(base_tools, &Tools.read_only_name?/1)

  defp filter_base_tools_for_read_only(base_tools, false), do: base_tools

  @spec filter_tool_allowlist([ReqLLM.Tool.t()], :all | [String.t()]) :: [ReqLLM.Tool.t()]
  defp filter_tool_allowlist(tools, :all) when is_list(tools), do: tools

  defp filter_tool_allowlist(tools, allowlist) when is_list(tools) and is_list(allowlist) do
    Enum.filter(tools, &(&1.name in allowlist))
  end

  @impl GenServer
  def handle_call({:send_prompt, _text}, _from, %{streaming: true} = state) do
    {:reply, {:error, :already_streaming}, state}
  end

  def handle_call({:send_prompt, content}, _from, state) do
    # Append user message to context.
    # content is either a string or a list of ContentPart (for multi-modal).
    context = Context.append(state.context, Context.user(content))

    state = %{
      state
      | context: context,
        streaming: true,
        interrupted: false,
        last_user_prompt: content
    }

    # Notify subscriber that agent is starting
    notify(state.subscriber, %Event.AgentStart{})

    # Check cost budget before starting
    if over_budget?(state) do
      notify(state.subscriber, %Event.Error{
        message: cost_limit_message(state.session_cost, state.max_cost)
      })

      {:reply, {:error, :cost_limit_reached}, %{state | context: context}}
    else
      # Spawn the agent turn loop in a linked task
      lctx = %LoopCtx{
        provider_pid: self(),
        session_pid: state.subscriber,
        model: state.model,
        config: state.config,
        tools: state.tools,
        project_root: state.project_root,
        project_view: state.project_view,
        fork_store: state.fork_store,
        changeset: state.changeset,
        thinking_level: state.thinking_level,
        max_tokens: state.max_tokens,
        max_retries: state.max_retries,
        llm_client: state.llm_client,
        hook_runner: state.hook_runner,
        max_turns: state.max_turns,
        max_cost: state.max_cost,
        session_cost: state.session_cost
      }

      task =
        Task.async(fn ->
          run_agent_loop(lctx, context)
        end)

      state = %{state | task: task}

      {:reply, :ok, state}
    end
  end

  def handle_call(:abort, _from, %{task: nil} = state) do
    stop_registered_tool_workers(state.tool_workers)
    {:reply, :ok, %{state | tool_workers: %{}}}
  end

  def handle_call(:abort, _from, state) do
    # Use a short timeout instead of :brutal_kill so the StreamServer
    # (which traps exits) can terminate cleanly via its terminate/2
    # callback. :brutal_kill sends an untrappable :kill signal that
    # causes OTP to log the StreamServer's state as an [error].
    stop_registered_tool_workers(state.tool_workers)
    Task.shutdown(state.task, 150)
    state = %{state | task: nil, streaming: false, tool_workers: %{}}
    Minga.Log.info(:agent, "[Agent.Native] aborted current operation")
    {:reply, :ok, state}
  end

  def handle_call(:continue, _from, %{streaming: true} = state) do
    {:reply, {:error, "Already streaming"}, state}
  end

  def handle_call(:continue, _from, %{interrupted: false} = state) do
    {:reply, {:error, "No interrupted response to continue from"}, state}
  end

  def handle_call(:continue, _from, state) do
    # Send a continuation prompt that tells the model to pick up where it left off
    continuation =
      "Your previous response was interrupted mid-stream. Please continue from where you left off. Do not repeat what you already said."

    context = Context.append(state.context, Context.user(continuation))
    state = %{state | context: context, streaming: true, interrupted: false}

    notify(state.subscriber, %Event.AgentStart{})

    lctx = %LoopCtx{
      provider_pid: self(),
      session_pid: state.subscriber,
      model: state.model,
      config: state.config,
      tools: state.tools,
      project_root: state.project_root,
      project_view: state.project_view,
      fork_store: state.fork_store,
      changeset: state.changeset,
      thinking_level: state.thinking_level,
      max_tokens: state.max_tokens,
      max_retries: state.max_retries,
      llm_client: state.llm_client,
      hook_runner: state.hook_runner,
      max_turns: state.max_turns,
      max_cost: state.max_cost,
      session_cost: state.session_cost
    }

    task = Task.async(fn -> run_agent_loop(lctx, context) end)
    state = %{state | task: task}

    {:reply, :ok, state}
  end

  def handle_call({:activate_skill, name}, _from, state) do
    already_active = Enum.any?(state.active_skills, &(&1.name == name))

    if already_active do
      {:reply, {:error, "Skill '#{name}' is already active"}, state}
    else
      case Skills.find(name, state.project_root) do
        {:ok, skill} ->
          active = state.active_skills ++ [skill]
          state = rebuild_system_prompt(%{state | active_skills: active})
          Minga.Log.info(:agent, "[Agent.Native] activated skill: #{name}")
          {:reply, {:ok, skill}, state}

        :not_found ->
          {:reply, {:error, "Skill '#{name}' not found"}, state}
      end
    end
  end

  def handle_call({:deactivate_skill, name}, _from, state) do
    active = Enum.reject(state.active_skills, &(&1.name == name))

    if length(active) == length(state.active_skills) do
      {:reply, {:error, "Skill '#{name}' is not active"}, state}
    else
      state = rebuild_system_prompt(%{state | active_skills: active})
      Minga.Log.info(:agent, "[Agent.Native] deactivated skill: #{name}")
      {:reply, :ok, state}
    end
  end

  def handle_call(:list_skills, _from, state) do
    all = Skills.discover(state.project_root)
    active_names = Enum.map(state.active_skills, & &1.name)
    {:reply, {:ok, all, active_names}, state}
  end

  def handle_call({:seed_messages, messages}, _from, state) do
    context = Enum.reduce(messages, state.context, &append_seed_message/2)
    {:reply, :ok, %{state | context: context}}
  end

  def handle_call(:new_session, _from, state) do
    # Gracefully stop any running task and registered workers (see :abort handler comment)
    stop_registered_tool_workers(state.tool_workers)

    if state.task do
      Task.shutdown(state.task, 150)
    end

    system_prompt = build_system_prompt(state.project_root, state.active_skills)
    context = Context.new([Context.system(system_prompt)])

    state = %{
      state
      | context: context,
        task: nil,
        streaming: false,
        session_cost: 0.0,
        tool_workers: %{}
    }

    Minga.Log.info(:agent, "[Agent.Native] new session started")

    {:reply, :ok, state}
  end

  def handle_call(:tools, _from, state) do
    {:reply, state.tools, state}
  end

  def handle_call(:fork_store, _from, state) do
    {:reply, state.fork_store, state}
  end

  def handle_call(:agent_hooks, _from, state) do
    {:reply, state.config.agent_hooks, state}
  end

  def handle_call(:project_view, _from, state) do
    {:reply, state.project_view, state}
  end

  def handle_call(:changeset, _from, state) do
    {:reply, state.changeset, state}
  end

  def handle_call(:get_state, _from, state) do
    system_prompt = system_prompt_from_context(state.context)

    session_state = %{
      model: %{
        id: state.model,
        name: state.model,
        provider: "native"
      },
      is_streaming: state.streaming,
      token_usage: nil,
      system_prompt: system_prompt,
      thinking_level: state.thinking_level,
      active_skill_names: Enum.map(state.active_skills, & &1.name),
      project_root: state.project_root,
      mcp_status: mcp_status(state)
    }

    {:reply, {:ok, session_state}, state}
  end

  def handle_call({:set_thinking_level, level}, _from, state) do
    if valid_thinking_level?(level) do
      Minga.Log.info(:agent, "[Agent.Native] thinking level set to #{level}")
      {:reply, :ok, %{state | thinking_level: level}}
    else
      {:reply,
       {:error,
        "unknown thinking level: #{level}. Valid: #{inspect(Map.keys(@thinking_levels))}"}, state}
    end
  end

  def handle_call(:cycle_thinking_level, _from, state) do
    current_index = Enum.find_index(@thinking_cycle, &(&1 == state.thinking_level)) || 0
    next_index = rem(current_index + 1, length(@thinking_cycle))
    next_level = Enum.at(@thinking_cycle, next_index)

    Minga.Log.info(:agent, "[Agent.Native] thinking level cycled to #{next_level}")
    {:reply, {:ok, %{"level" => next_level}}, %{state | thinking_level: next_level}}
  end

  def handle_call(:get_available_models, _from, state) do
    models = ModelCatalog.available_models(state.model)
    {:reply, {:ok, models}, state}
  end

  def handle_call(:compact, _from, %{streaming: true} = state) do
    {:reply, {:error, "Cannot compact while streaming"}, state}
  end

  def handle_call(:compact, _from, state) do
    case dispatch_pre_compact(state.context, state.config) do
      :ok ->
        compact_opts = [
          model: state.model,
          llm_client: summary_client(state.llm_client, state.config)
        ]

        case Compaction.compact(state.context, compact_opts) do
          {:compacted, new_context, summary_info} ->
            notify(state.subscriber, %Event.TextDelta{delta: "\n📦 #{summary_info}\n"})
            {:reply, {:ok, summary_info}, %{state | context: new_context}}

          {:ok, _context} ->
            {:reply, {:ok, "Context is already small enough, no compaction needed."}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _result} ->
        {:reply, {:error, "compaction blocked by hook"}, state}
    end
  end

  def handle_call(:summarize, _from, %{streaming: true} = state) do
    {:reply, {:error, "Cannot summarize while streaming"}, state}
  end

  def handle_call(:summarize, _from, state) do
    messages = state.context.messages

    if ContextArtifact.summarizable?(messages) do
      result = generate_and_save_summary(state, messages)
      {:reply, result, state}
    else
      {:reply, {:error, "Nothing to summarize (session too short)"}, state}
    end
  end

  def handle_call(:cycle_model, _from, state) do
    model_list = config_model_list(state.config)

    if model_list == [] do
      {:reply, {:error, "No model rotation configured. Set :agent_models in your config."}, state}
    else
      {next_model, next_thinking} = parse_model_entry(next_in_cycle(model_list, state.model))
      thinking_level = next_thinking || state.thinking_level

      new_state = %{
        state
        | model: next_model,
          thinking_level: thinking_level
      }

      total = length(model_list)
      index = Enum.find_index(model_list, &String.starts_with?(&1, next_model)) || 0

      response = %{
        "model" => next_model,
        "index" => index + 1,
        "total" => total,
        "thinking_level" => thinking_level
      }

      {:reply, {:ok, response}, new_state}
    end
  end

  def handle_call({:set_model, model}, _from, state) do
    Minga.Log.info(:agent, "[Agent.Native] model set to #{model}")
    {:reply, :ok, %{state | model: model}}
  end

  def handle_call(:list_mcp_tools, _from, state) do
    {reply, state} = with_enabled_mcp(state, &list_mcp_tools_for_agent/1)
    {:reply, reply, state}
  end

  def handle_call({:call_mcp_tool, server_name, tool_name, args}, _from, state) do
    {reply, state} =
      with_enabled_mcp(state, &call_mcp_tool_for_agent(&1, server_name, tool_name, args || %{}))

    {:reply, reply, state}
  end

  def handle_call({:refresh_project_view, project_view}, _from, state) do
    base_tools = refresh_base_tools(state, project_view)
    tools = base_tools ++ state.mcp_tools ++ state.internal_tools
    {:reply, :ok, %{state | project_view: project_view, base_tools: base_tools, tools: tools}}
  end

  def handle_call({:update_internal_state, fun}, _from, state) when is_function(fun, 1) do
    new_internal = fun.(state.internal_state)
    {:reply, :ok, %{state | internal_state: new_internal}}
  end

  def handle_call(:get_internal_state, _from, state) do
    {:reply, {:ok, state.internal_state}, state}
  end

  def handle_call(:get_budget, _from, state) do
    budget = %{
      session_cost: state.session_cost,
      max_cost: state.max_cost,
      max_turns: state.max_turns
    }

    {:reply, {:ok, budget}, state}
  end

  def handle_call({:register_tool_workers, workers}, _from, state) when is_list(workers) do
    tool_workers =
      Enum.reduce(workers, state.tool_workers, fn {monitor_ref, pid}, acc ->
        Map.put(acc, monitor_ref, pid)
      end)

    {:reply, :ok, %{state | tool_workers: tool_workers}}
  end

  def handle_call({:set_max_cost, amount}, _from, state) when is_number(amount) and amount > 0 do
    Minga.Log.info(:agent, "[Agent.Native] cost budget set to $#{Float.round(amount + 0.0, 2)}")
    {:reply, :ok, %{state | max_cost: amount + 0.0}}
  end

  def handle_call({:set_max_cost, nil}, _from, state) do
    Minga.Log.info(:agent, "[Agent.Native] cost budget disabled")
    {:reply, :ok, %{state | max_cost: nil}}
  end

  @impl GenServer
  def handle_info({:minga_event, :agent_mcp_servers_changed, _payload}, state) do
    {:noreply, refresh_mcp_contributions(state)}
  end

  def handle_info({:agent_event, event}, state) do
    # Forwarded from the task
    notify(state.subscriber, event)
    {:noreply, state}
  end

  def handle_info({:agent_context_update, context}, state) do
    # Task finished a turn and is sending us the updated context
    {:noreply, %{state | context: context}}
  end

  def handle_info({:agent_turn_cost, cost}, state) when is_number(cost) do
    {:noreply, %{state | session_cost: state.session_cost + cost}}
  end

  def handle_info({:stream_interrupted, _partial_text}, state) do
    {:noreply, %{state | interrupted: true}}
  end

  def handle_info({:unregister_tool_workers, monitor_refs}, state) when is_list(monitor_refs) do
    {:noreply, %{state | tool_workers: Map.drop(state.tool_workers, monitor_refs)}}
  end

  def handle_info({ref, :ok}, %{task: %Task{ref: ref}} = state) do
    # Task completed normally
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | task: nil, streaming: false, tool_workers: %{}}}
  end

  def handle_info({ref, {:error, :stream_interrupted}}, %{task: %Task{ref: ref}} = state) do
    # Stream was interrupted but partial response was preserved
    Process.demonitor(ref, [:flush])
    stop_registered_tool_workers(state.tool_workers)
    {:noreply, %{state | task: nil, streaming: false, interrupted: true, tool_workers: %{}}}
  end

  def handle_info({ref, {:error, :turn_limit_reached}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stop_registered_tool_workers(state.tool_workers)
    {:noreply, %{state | task: nil, streaming: false, interrupted: true, tool_workers: %{}}}
  end

  def handle_info({ref, {:error, :cost_limit_reached}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stop_registered_tool_workers(state.tool_workers)
    {:noreply, %{state | task: nil, streaming: false, tool_workers: %{}}}
  end

  def handle_info({ref, {:error, {:reported, _reason}}}, %{task: %Task{ref: ref}} = state) do
    # The agent loop already logged this error and emitted Error + AgentEnd via
    # reported_error/3. Just clean up; re-emitting here would show the error
    # twice in the transcript.
    Process.demonitor(ref, [:flush])
    stop_registered_tool_workers(state.tool_workers)
    {:noreply, %{state | task: nil, streaming: false, tool_workers: %{}}}
  end

  def handle_info({ref, {:error, reason}}, %{task: %Task{ref: ref}} = state) do
    # Safety net: an error reached the Task without the loop reporting it.
    Process.demonitor(ref, [:flush])
    stop_registered_tool_workers(state.tool_workers)
    formatted = format_error(reason)
    Minga.Log.error(:agent, "[Agent.Native] agent loop error: #{formatted}")
    notify(state.subscriber, %Event.Error{message: formatted})
    notify(state.subscriber, %Event.AgentEnd{usage: nil})
    {:noreply, %{state | task: nil, streaming: false, tool_workers: %{}}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # Task crashed
    stop_registered_tool_workers(state.tool_workers)
    Minga.Log.error(:agent, "[Agent.Native] agent task crashed: #{inspect(reason)}")
    notify(state.subscriber, %Event.Error{message: "Agent task crashed: #{inspect(reason)}"})
    notify(state.subscriber, %Event.AgentEnd{usage: nil})
    {:noreply, %{state | task: nil, streaming: false, tool_workers: %{}}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{fork_store: pid} = state)
      when is_pid(pid) do
    Minga.Log.warning(
      :agent,
      "[Agent.Native] fork store crashed, continuing without fork isolation"
    )

    {:noreply, rebuild_tools(%{state | fork_store: nil})}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{changeset: pid} = state)
      when is_pid(pid) do
    Minga.Log.warning(
      :agent,
      "[Agent.Native] changeset crashed, continuing without filesystem isolation"
    )

    {:noreply, rebuild_tools(%{state | changeset: nil})}
  end

  def handle_info({:mcp_client_down, pid, server_name, reason}, state) when is_pid(pid) do
    case MCPRegistry.server_for_pid(state.mcp_registry, pid) do
      ^server_name ->
        message =
          "MCP server #{server_name} stopped: #{inspect(reason)}. Built-in tools remain available."

        Minga.Log.warning(:agent, "[Agent.Native] #{message}")
        notify(state.subscriber, %Event.Error{message: message})
        {:noreply, remove_mcp_server_tools(state, server_name)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when is_pid(pid) do
    case MCPRegistry.server_for_pid(state.mcp_registry, pid) do
      server_name when is_binary(server_name) ->
        message =
          "MCP server #{server_name} crashed: #{inspect(reason)}. Built-in tools remain available."

        Minga.Log.warning(:agent, "[Agent.Native] #{message}")
        notify(state.subscriber, %Event.Error{message: message})
        {:noreply, remove_mcp_server_tools(state, server_name)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    stop_registered_tool_workers(state.tool_workers)
    cleanup_fork_store(state.fork_store)
    cleanup_changeset(state.changeset, reason)
    cleanup_mcp(state.mcp_registry)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec configured_mcp_servers(keyword(), AgentConfig.t(), pid(), boolean()) :: [
          MCPServerConfig.t()
        ]
  defp configured_mcp_servers(_opts, _config, _subscriber, true), do: []

  defp configured_mcp_servers(opts, config, subscriber, false) do
    if mcp_extension_enabled?(opts) do
      server_configs = Keyword.get(opts, :mcp_servers, config.mcp_servers)

      case MCPServerConfig.normalize_list(server_configs) do
        {:ok, normalized} ->
          normalized

        {:error, reason} ->
          notify(subscriber, %Event.Error{message: "MCP config error: #{reason}"})
          []
      end
    else
      []
    end
  end

  @spec mcp_extension_enabled?(keyword()) :: boolean()
  defp mcp_extension_enabled?(opts) do
    Keyword.get_lazy(opts, :mcp_enabled?, fn -> Minga.Extensions.MCP.enabled?() end)
  end

  @spec mcp_registry_for([MCPServerConfig.t()]) :: MCPRegistry.t() | nil
  defp mcp_registry_for([]), do: nil
  defp mcp_registry_for(_configs), do: MCPRegistry.new()

  @spec mcp_meta_tools_for([MCPServerConfig.t()], pid()) :: [ReqLLM.Tool.t()]
  defp mcp_meta_tools_for([], _provider_pid), do: []
  defp mcp_meta_tools_for(_configs, provider_pid), do: build_mcp_meta_tools(provider_pid)

  @spec mcp_status(map()) :: [map()]
  defp mcp_status(state) do
    Enum.map(state.mcp_configs, fn config ->
      status = mcp_server_status(state, config.name)

      %{
        "name" => config.name,
        "source" => format_mcp_source(config.source),
        "status" => Atom.to_string(status),
        "error" => Map.get(state.mcp_errors, config.name)
      }
    end)
  end

  @spec format_mcp_source(
          MCPServerConfig.t()
          | Minga.Extension.ContributionCleanup.contribution_source()
        ) ::
          String.t()
  defp format_mcp_source(%MCPServerConfig{source: source}), do: format_mcp_source(source)
  defp format_mcp_source(:config), do: "config"
  defp format_mcp_source(:builtin), do: "builtin"
  defp format_mcp_source({:extension, name}), do: "extension:#{name}"

  @spec mcp_server_status(map(), String.t()) :: :not_started | :running | :errored
  defp mcp_server_status(state, server_name) do
    case {Map.has_key?(state.mcp_errors, server_name),
          MCPRegistry.client_for_server(state.mcp_registry, server_name)} do
      {true, _client} -> :errored
      {false, {:ok, _pid}} -> :running
      {false, :error} -> :not_started
    end
  end

  @spec mcp_client_opts(keyword()) :: keyword()
  defp mcp_client_opts(opts) do
    [
      transport: Keyword.get(opts, :mcp_transport, MingaAgent.MCP.StdioTransport),
      transport_opts: Keyword.get(opts, :mcp_transport_opts, []),
      notify_pid: self(),
      request_timeout: Keyword.get(opts, :mcp_request_timeout, 5_000)
    ]
  end

  @spec build_mcp_meta_tools(pid()) :: [ReqLLM.Tool.t()]
  defp build_mcp_meta_tools(provider_pid) when is_pid(provider_pid) do
    [
      ReqLLM.Tool.new!(
        name: "list_mcp_tools",
        description:
          "List available tools from configured MCP servers on demand. Use this when built-in tools do not cover the capability you need. This starts MCP servers lazily and returns server names, tool names, and short descriptions without adding every MCP tool to the system prompt.",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _args -> GenServer.call(provider_pid, :list_mcp_tools, :infinity) end
      ),
      ReqLLM.Tool.new!(
        name: "call_mcp_tool",
        description:
          "Call a tool from a configured MCP server by server name and tool name. Use list_mcp_tools first if you do not know the available server and tool names. MCP tool calls use the same approval flow as other destructive tools and default to ask approval.",
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "server" => %{"type" => "string", "description" => "Configured MCP server name"},
            "tool" => %{
              "type" => "string",
              "description" => "Original MCP tool name from that server"
            },
            "arguments" => %{
              "type" => "object",
              "description" => "Arguments to pass to the MCP tool"
            }
          },
          "required" => ["server", "tool"]
        },
        callback: fn args ->
          GenServer.call(
            provider_pid,
            {:call_mcp_tool, args["server"], args["tool"], Map.get(args, "arguments", %{})},
            :infinity
          )
        end
      )
    ]
  end

  @spec with_enabled_mcp(map(), (map() -> {{:ok, term()} | {:error, term()}, map()})) ::
          {{:ok, term()} | {:error, term()}, map()}
  defp with_enabled_mcp(state, fun) when is_function(fun, 1) do
    if mcp_enabled_for_state?(state) do
      fun.(state)
    else
      {{:error, "MCP extension is disabled"}, disable_mcp_in_state(state)}
    end
  end

  @spec mcp_enabled_for_state?(map()) :: boolean()
  defp mcp_enabled_for_state?(%{mcp_enabled_override: override}) when is_boolean(override),
    do: override

  defp mcp_enabled_for_state?(_state), do: Minga.Extensions.MCP.enabled?()

  @spec disable_mcp_in_state(map()) :: map()
  defp disable_mcp_in_state(state) do
    cleanup_mcp(state.mcp_registry)

    tools = Enum.reject(state.tools, &(&1.name in ["list_mcp_tools", "call_mcp_tool"]))

    %{state | mcp_configs: [], mcp_registry: nil, mcp_tools: [], mcp_errors: %{}, tools: tools}
  end

  @spec list_mcp_tools_for_agent(map()) :: {{:ok, term()} | {:error, term()}, map()}
  defp list_mcp_tools_for_agent(%{mcp_configs: []} = state), do: {{:ok, []}, state}

  defp list_mcp_tools_for_agent(state) do
    {servers, failures, state} = ensure_all_mcp_servers(state)

    tool_entries =
      Enum.flat_map(servers, fn {server_name, client} ->
        list_mcp_client_tools(server_name, client)
      end)

    failure_entries =
      Enum.map(failures, fn {server_name, reason} ->
        %{"server" => server_name, "error" => reason}
      end)

    reply = list_mcp_tools_reply(tool_entries, failure_entries)

    {reply, state}
  end

  @spec list_mcp_tools_reply([map()], [map()]) :: {:ok, term()} | {:error, String.t()}
  defp list_mcp_tools_reply([], []), do: {:ok, "No MCP tools are available."}

  defp list_mcp_tools_reply([], failures) do
    message =
      failures
      |> Enum.map_join("; ", fn %{"server" => server_name, "error" => reason} ->
        "#{server_name}: #{reason}"
      end)

    {:error, "MCP servers failed to start: #{message}"}
  end

  defp list_mcp_tools_reply(tools, failures), do: {:ok, failures ++ tools}

  @spec list_mcp_client_tools(String.t(), pid()) :: [map()]
  defp list_mcp_client_tools(server_name, client) do
    case MingaAgent.MCP.Client.list_tools(client) do
      {:ok, tools} ->
        Enum.map(tools, fn tool ->
          %{
            "server" => server_name,
            "name" => tool.name,
            "description" => String.split(tool.description, "\n") |> List.first() || ""
          }
        end)

      {:error, reason} ->
        [%{"server" => server_name, "error" => format_error(reason)}]
    end
  end

  @spec call_mcp_tool_for_agent(map(), term(), term(), term()) ::
          {{:ok, term()} | {:error, term()}, map()}
  defp call_mcp_tool_for_agent(state, server_name, tool_name, args)
       when is_binary(server_name) and is_binary(tool_name) and is_map(args) do
    case ensure_mcp_server(state, server_name) do
      {{:ok, client}, state} ->
        {MingaAgent.MCP.Client.call_tool(client, tool_name, args), state}

      {{:error, reason}, state} ->
        {{:error, reason}, state}
    end
  end

  defp call_mcp_tool_for_agent(state, _server_name, _tool_name, _args) do
    {{:error, "call_mcp_tool requires string server, string tool, and object arguments"}, state}
  end

  @spec ensure_all_mcp_servers(map()) ::
          {[{String.t(), pid()}], [{String.t(), String.t()}], map()}
  defp ensure_all_mcp_servers(state) do
    Enum.reduce(state.mcp_configs, {[], [], state}, fn config, {servers, failures, state} ->
      case ensure_mcp_server(state, config.name) do
        {{:ok, client}, state} -> {[{config.name, client} | servers], failures, state}
        {{:error, reason}, state} -> {servers, [{config.name, reason} | failures], state}
      end
    end)
    |> then(fn {servers, failures, state} ->
      {Enum.reverse(servers), Enum.reverse(failures), state}
    end)
  end

  @spec ensure_mcp_server(map(), String.t()) :: {{:ok, pid()} | {:error, String.t()}, map()}
  defp ensure_mcp_server(state, server_name) do
    case Enum.find(state.mcp_configs, &(&1.name == server_name)) do
      nil ->
        {{:error, "Unknown MCP server #{server_name}"}, state}

      config ->
        case MCPRegistry.ensure_server(
               state.mcp_registry || MCPRegistry.new(),
               config,
               state.subscriber,
               state.mcp_client_opts
             ) do
          {:ok, registry, client} ->
            errors = Map.delete(state.mcp_errors, config.name)
            {{:ok, client}, %{state | mcp_registry: registry, mcp_errors: errors}}

          {:error, reason} ->
            {{:error, reason}, put_in(state, [:mcp_errors, config.name], reason)}
        end
    end
  end

  @spec remove_mcp_server_tools(map(), String.t()) :: map()
  defp remove_mcp_server_tools(state, server_name) do
    {registry, _removed_tool_names} = MCPRegistry.remove_server(state.mcp_registry, server_name)

    %{
      state
      | mcp_registry: registry,
        mcp_errors: Map.put(state.mcp_errors, server_name, "stopped")
    }
  end

  @spec rebuild_tools(map()) :: map()
  defp rebuild_tools(state) do
    base_tools =
      state.project_root
      |> native_tool_context(
        state.project_view,
        state.fork_store,
        state.changeset,
        state.subscriber
      )
      |> registry_tools(state.config, state.hook_runner)

    base_tool_names = MapSet.new(Enum.map(base_tools, & &1.name))
    internal_tools = build_internal_tools(self())
    internal_tool_names = MapSet.new(Enum.map(internal_tools, & &1.name))

    mcp_tools =
      Enum.reject(state.tools, fn tool ->
        MapSet.member?(base_tool_names, tool.name) or
          MapSet.member?(internal_tool_names, tool.name)
      end)

    %{state | tools: base_tools ++ mcp_tools ++ internal_tools}
  end

  # ── Terminate cleanup ──────────────────────────────────────────────────────

  @spec cleanup_fork_store(pid() | nil) :: :ok
  defp cleanup_fork_store(nil), do: :ok

  defp cleanup_fork_store(fs) when is_pid(fs) do
    if Process.alive?(fs) do
      results = MingaAgent.BufferForkStore.merge_all_keep_failed(fs)

      Enum.each(results, fn
        {_path, :ok} ->
          :ok

        {p, {:conflict, _}} ->
          Minga.Log.warning(:agent, "[Agent.Native] fork merge conflict on #{p}")

        {p, {:error, r}} ->
          Minga.Log.warning(:agent, "[Agent.Native] fork merge failed for #{p}: #{inspect(r)}")
      end)

      if Enum.all?(results, fn {_path, result} -> result == :ok end) do
        MingaAgent.BufferForkStore.stop(fs)
      else
        Minga.Log.warning(
          :agent,
          "[Agent.Native] preserving failed fork drafts after merge cleanup"
        )
      end
    end

    :ok
  end

  @spec cleanup_changeset(pid() | nil, term()) :: :ok
  defp cleanup_changeset(nil, _reason), do: :ok

  defp cleanup_changeset(cs, reason) when is_pid(cs) do
    if Process.alive?(cs) do
      if reason == :normal or reason == :shutdown do
        merge_changeset(cs)
      else
        MingaAgent.Changeset.discard(cs)
      end
    end

    :ok
  end

  @spec cleanup_mcp(MCPRegistry.t() | nil) :: :ok
  defp cleanup_mcp(registry), do: MCPRegistry.stop_all(registry)

  @spec merge_changeset(pid()) :: :ok
  defp merge_changeset(cs) do
    case MingaAgent.Changeset.merge(cs) do
      :ok ->
        Minga.Log.info(:agent, "[Agent.Native] changeset merged successfully")

      {:conflict, _details} ->
        Minga.Log.warning(
          :agent,
          "[Agent.Native] changeset merge found conflicts; discarding legacy changeset"
        )

        MingaAgent.Changeset.discard(cs)

      {:error, merge_reason} ->
        Minga.Log.warning(
          :agent,
          "[Agent.Native] changeset merge failed: #{inspect(merge_reason)}"
        )
    end
  end

  # ── Agent turn loop (runs in a Task) ────────────────────────────────────────

  @spec run_agent_loop(loop_ctx(), Context.t()) :: :ok | {:error, term()}
  defp run_agent_loop(lctx, context) do
    case check_safety_limits(lctx) do
      :ok ->
        do_agent_loop(lctx, context)

      {:turn_limit, message} ->
        send(lctx.provider_pid, {:agent_event, %Event.TextDelta{delta: "\n\n⚠️ #{message}"}})

        send(
          lctx.provider_pid,
          {:agent_event, %Event.TurnLimitReached{current: lctx.turn_count, limit: lctx.max_turns}}
        )

        send(lctx.provider_pid, {:agent_event, %Event.AgentEnd{usage: nil}})
        {:error, :turn_limit_reached}

      {:cost_limit, message} ->
        send(lctx.provider_pid, {:agent_event, %Event.TextDelta{delta: "\n\n⚠️ #{message}"}})
        send(lctx.provider_pid, {:agent_event, %Event.AgentEnd{usage: nil}})
        {:error, :cost_limit_reached}
    end
  end

  @spec check_safety_limits(loop_ctx()) ::
          :ok | {:turn_limit, String.t()} | {:cost_limit, String.t()}
  defp check_safety_limits(%LoopCtx{turn_count: tc, max_turns: mt}) when tc >= mt do
    {:turn_limit, "Turn limit reached (#{tc}/#{mt}). Use /continue to resume."}
  end

  defp check_safety_limits(%LoopCtx{} = lctx) do
    if over_budget?(lctx) do
      {:cost_limit, cost_limit_message(lctx.session_cost, lctx.max_cost)}
    else
      :ok
    end
  end

  @spec do_agent_loop(loop_ctx(), Context.t()) :: :ok | {:error, term()}
  defp do_agent_loop(lctx, context) do
    case ReqLLMAdapter.validate_model(lctx.model) do
      :ok -> do_agent_loop_validated(lctx, context)
      {:error, message, reason} -> reported_error(lctx.provider_pid, message, reason)
    end
  end

  @spec do_agent_loop_validated(loop_ctx(), Context.t()) :: :ok | {:error, term()}
  defp do_agent_loop_validated(lctx, context) do
    # Check if context needs compaction before the API call
    context = maybe_compact_context(lctx, context)

    stream_opts =
      ReqLLMAdapter.stream_opts(
        lctx.model,
        lctx.tools,
        lctx.thinking_level,
        lctx.max_tokens,
        lctx.config
      )

    # Emit pre-send token estimate so the context bar updates before the API call
    emit_context_usage(lctx, context)

    on_retry = fn attempt, delay_ms, reason ->
      delay_s = Float.round(delay_ms / 1000, 1)

      send(
        lctx.provider_pid,
        {:agent_event,
         %Event.TextDelta{
           delta:
             "\n⏳ #{reason} — retrying in #{delay_s}s (attempt #{attempt}/#{lctx.max_retries})...\n"
         }}
      )
    end

    result =
      Retry.with_retry(
        fn ->
          ReqLLMAdapter.stream(lctx.llm_client, lctx.model, context.messages, stream_opts)
        end,
        max_retries: lctx.max_retries,
        on_retry: on_retry
      )

    case result do
      {:ok, stream_response} ->
        process_and_continue(lctx, context, stream_response)

      {:error, reason} ->
        reported_error(lctx.provider_pid, format_error(reason), reason)
    end
  rescue
    e ->
      reported_error(lctx.provider_pid, Exception.message(e), e)
  catch
    # HTTP client or session process may die mid-stream. Targeted catch
    # per AGENTS.md rule 4.
    :exit, reason ->
      reported_error(lctx.provider_pid, inspect(reason), reason)
  end

  # Processes a stream response and decides whether to continue (tool calls) or finish.
  @spec process_and_continue(loop_ctx(), Context.t(), ReqLLM.StreamResponse.t()) ::
          :ok | {:error, term()}
  defp process_and_continue(lctx, context, stream_response) do
    callbacks = [
      on_text: fn text ->
        send(lctx.provider_pid, {:agent_event, %Event.TextDelta{delta: text}})
      end,
      on_thinking: fn text ->
        send(lctx.provider_pid, {:agent_event, %Event.ThinkingDelta{delta: text}})
      end,
      on_tool_call: fn chunk ->
        send(
          lctx.provider_pid,
          {:agent_event,
           %Event.ToolStart{
             tool_call_id: chunk.id,
             name: chunk.name,
             args: chunk.arguments
           }}
        )
      end
    ]

    case ReqLLMAdapter.process_stream(stream_response, callbacks) do
      {:ok, %{tool_calls: tool_calls, text: text, usage: usage}} ->
        dispatch_result(lctx, context, tool_calls, text, usage)

      {:error, reason, partial_text} ->
        handle_stream_error(lctx, context, partial_text, reason)
    end
  end

  # When a stream drops mid-response, preserve whatever text was received.
  # If we got meaningful partial text, save it in context so the user can
  # /continue from where it left off instead of losing everything.
  @spec handle_stream_error(loop_ctx(), Context.t(), String.t(), term()) :: {:error, term()}
  defp handle_stream_error(lctx, context, partial_text, reason) do
    if partial_text != "" and String.length(partial_text) > 10 do
      # Preserve the partial response in context
      partial_msg = Context.assistant(partial_text <> "\n\n[response interrupted]")
      updated_context = Context.append(context, partial_msg)
      send(lctx.provider_pid, {:agent_context_update, updated_context})
      send(lctx.provider_pid, {:stream_interrupted, partial_text})

      send(
        lctx.provider_pid,
        {:agent_event,
         %Event.TextDelta{
           delta:
             "\n\n⚠️ Stream interrupted: #{format_error(reason)}. " <>
               "Partial response preserved. Use /continue to resume."
         }}
      )

      send(
        lctx.provider_pid,
        {:agent_event, %Event.AgentEnd{usage: nil}}
      )

      {:error, :stream_interrupted}
    else
      reported_error(lctx.provider_pid, format_error(reason), reason)
    end
  end

  @spec dispatch_result(loop_ctx(), Context.t(), [map()], String.t(), map() | nil) ::
          :ok | {:error, term()}
  defp dispatch_result(lctx, context, [] = _tool_calls, text, usage) do
    # No tool calls: final answer
    updated_context = Context.append(context, Context.assistant(text))
    send(lctx.provider_pid, {:agent_context_update, updated_context})

    normalized = normalize_usage(usage, lctx.model)
    report_turn_cost(lctx, normalized)

    send(
      lctx.provider_pid,
      {:agent_event, %Event.AgentEnd{usage: normalized}}
    )

    :ok
  end

  defp dispatch_result(lctx, context, tool_calls, text, usage) do
    # Has tool calls: execute tools and continue the loop
    reqllm_tool_calls =
      Enum.map(tool_calls, fn tc ->
        ReqLLMAdapter.assistant_tool_call(tc.id, tc.name, tc.arguments)
      end)

    assistant_msg = Context.assistant(text, tool_calls: reqllm_tool_calls)
    context = Context.append(context, assistant_msg)

    context = execute_tools(lctx, context, tool_calls, lctx.tools)

    # Inject any steering messages queued by the user while tools were executing.
    context = inject_steering_messages(lctx, context)

    send(lctx.provider_pid, {:agent_context_update, context})

    # Track cost from this turn and increment turn count for safety checks
    normalized = normalize_usage(usage, lctx.model)
    turn_cost = turn_cost_from_usage(normalized)
    report_turn_cost(lctx, normalized)

    lctx = %{
      lctx
      | turn_count: lctx.turn_count + 1,
        session_cost: lctx.session_cost + turn_cost
    }

    # Continue the loop with updated context and incremented turn count
    run_agent_loop(lctx, context)
  end

  # Dequeues any steering messages from the Session and appends them to the
  # LLM context so the model sees them on its next turn. Returns the context
  # unchanged when there are no pending steering messages or no session_pid.
  @spec inject_steering_messages(loop_ctx(), Context.t()) :: Context.t()
  defp inject_steering_messages(%{session_pid: nil}, context), do: context

  defp inject_steering_messages(lctx, context) do
    # Use a short timeout: Session.dequeue_steering is a simple queue pop and
    # should respond in microseconds. 200ms guards against a slow/dead session
    # without blocking the agent loop meaningfully.
    steering =
      try do
        GenServer.call(lctx.session_pid, :dequeue_steering, 200)
      catch
        # Session may die between loop iterations. Targeted catch per
        # AGENTS.md rule 4.
        :exit, _ -> []
      end

    if steering == [] do
      context
    else
      combined = Session.combine_queue_entries_to_text(steering)
      Context.append(context, Context.user(combined))
    end
  end

  @spec execute_tools(loop_ctx(), Context.t(), [map()], [ReqLLM.Tool.t()]) :: Context.t()
  defp execute_tools(lctx, context, tool_calls, available_tools) do
    initial_mode = approval_mode(lctx.config)

    baselines = capture_tool_baselines(tool_calls, lctx)

    {approval_baselines, concurrent_baselines} =
      Enum.split_with(baselines, fn {_index, tool_call, _before_content} ->
        tool_requires_approval?(tool_call, lctx.config, initial_mode)
      end)

    concurrent_tasks =
      start_concurrent_tool_tasks(lctx, concurrent_baselines, available_tools, initial_mode)

    try do
      approval_results =
        Enum.map(approval_baselines, fn {index, tool_call, before_content} ->
          {index,
           execute_tool_call(lctx, tool_call, before_content, available_tools, initial_mode)}
        end)

      concurrent_results = await_concurrent_tool_tasks(lctx.provider_pid, concurrent_tasks)

      (approval_results ++ concurrent_results)
      |> Enum.sort_by(fn {index, _result} -> index end)
      |> Enum.reduce(context, fn {_index, result}, ctx ->
        Context.append(ctx, tool_result_message(result))
      end)
    after
      cleanup_concurrent_tool_tasks(lctx.provider_pid, concurrent_tasks)
    end
  end

  @typep approval_mode :: :none | :ask | :ask_all
  @typep tool_baseline :: {non_neg_integer(), map(), String.t() | nil}
  @typep unstarted_tool_task ::
           {non_neg_integer(), map(), pid(), reference(), reference(), reference()}
  @typep tool_task :: {non_neg_integer(), map(), pid(), reference(), reference()}
  @typep tool_execution_result :: %{
           required(:tool_call) => map(),
           required(:result_text) => String.t(),
           required(:is_error) => boolean()
         }

  @spec capture_tool_baselines([map()], loop_ctx()) :: [tool_baseline()]
  defp capture_tool_baselines(tool_calls, lctx) do
    tool_calls
    |> Enum.with_index()
    |> Enum.map(fn {tool_call, index} ->
      {index, tool_call, capture_file_before(lctx, tool_call)}
    end)
  end

  @spec start_concurrent_tool_tasks(
          loop_ctx(),
          [tool_baseline()],
          [ReqLLM.Tool.t()],
          approval_mode()
        ) :: [tool_task()]
  defp start_concurrent_tool_tasks(lctx, baselines, available_tools, approval_mode) do
    parent = self()

    tasks =
      Enum.map(baselines, fn {index, tool_call, before_content} ->
        result_ref = make_ref()
        start_ref = make_ref()

        pid =
          spawn_link(fn ->
            receive do
              {^start_ref, :run} ->
                result =
                  execute_tool_call(
                    lctx,
                    tool_call,
                    before_content,
                    available_tools,
                    approval_mode
                  )

                send(parent, {result_ref, :tool_result, result})
            end
          end)

        monitor_ref = Process.monitor(pid)

        {index, tool_call, pid, monitor_ref, result_ref, start_ref}
      end)

    start_registered_tool_tasks(lctx.provider_pid, tasks)
  end

  @spec start_registered_tool_tasks(pid(), [unstarted_tool_task()]) :: [tool_task()]
  defp start_registered_tool_tasks(provider_pid, tasks) do
    case register_tool_workers(provider_pid, tasks) do
      :ok ->
        Enum.map(tasks, fn {index, tool_call, pid, monitor_ref, result_ref, start_ref} ->
          Process.unlink(pid)
          send(pid, {start_ref, :run})
          {index, tool_call, pid, monitor_ref, result_ref}
        end)

      {:error, reason} ->
        cleanup_unstarted_tool_tasks(provider_pid, tasks)
        exit({:tool_worker_registration_failed, reason})
    end
  catch
    kind, reason ->
      cleanup_unstarted_tool_tasks(provider_pid, tasks)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @spec await_concurrent_tool_tasks(pid(), [tool_task()]) :: [
          {non_neg_integer(), tool_execution_result()}
        ]
  defp await_concurrent_tool_tasks(provider_pid, tasks) do
    Enum.map(tasks, fn {index, tool_call, _pid, monitor_ref, result_ref} ->
      {index, await_tool_process(provider_pid, tool_call, monitor_ref, result_ref)}
    end)
  end

  @spec register_tool_workers(pid(), [unstarted_tool_task()]) :: :ok | {:error, term()}
  defp register_tool_workers(provider_pid, tasks) do
    workers =
      Enum.map(tasks, fn {_index, _tool_call, pid, monitor_ref, _result_ref, _start_ref} ->
        {monitor_ref, pid}
      end)

    GenServer.call(provider_pid, {:register_tool_workers, workers})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec cleanup_unstarted_tool_tasks(pid(), [unstarted_tool_task()]) :: :ok
  defp cleanup_unstarted_tool_tasks(provider_pid, tasks) do
    monitor_refs =
      Enum.map(tasks, fn {_index, _tool_call, pid, monitor_ref, _result_ref, _start_ref} ->
        Process.unlink(pid)
        Process.demonitor(monitor_ref, [:flush])
        stop_tool_worker(pid)
        monitor_ref
      end)

    unregister_tool_workers(provider_pid, monitor_refs)
    :ok
  end

  @spec cleanup_concurrent_tool_tasks(pid(), [tool_task()]) :: :ok
  defp cleanup_concurrent_tool_tasks(provider_pid, tasks) do
    monitor_refs =
      Enum.map(tasks, fn {_index, _tool_call, pid, monitor_ref, _result_ref} ->
        Process.unlink(pid)
        Process.demonitor(monitor_ref, [:flush])
        stop_tool_worker(pid)
        monitor_ref
      end)

    unregister_tool_workers(provider_pid, monitor_refs)
    :ok
  end

  @spec unregister_tool_workers(pid(), [reference()]) :: :ok
  defp unregister_tool_workers(_provider_pid, []), do: :ok

  defp unregister_tool_workers(provider_pid, monitor_refs) do
    send(provider_pid, {:unregister_tool_workers, monitor_refs})
    :ok
  end

  @spec stop_registered_tool_workers(%{reference() => pid()}) :: :ok
  defp stop_registered_tool_workers(tool_workers) when is_map(tool_workers) do
    Enum.each(tool_workers, fn {_monitor_ref, pid} ->
      stop_tool_worker(pid)
    end)

    :ok
  end

  @spec stop_tool_worker(pid()) :: :ok
  defp stop_tool_worker(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  @spec await_tool_process(pid(), map(), reference(), reference()) :: tool_execution_result()
  defp await_tool_process(provider_pid, tool_call, monitor_ref, result_ref) do
    receive do
      {^result_ref, :tool_result, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        receive_tool_result_after_down(provider_pid, tool_call, result_ref, reason)
    end
  end

  @spec receive_tool_result_after_down(pid(), map(), reference(), term()) ::
          tool_execution_result()
  defp receive_tool_result_after_down(provider_pid, tool_call, result_ref, reason) do
    receive do
      {^result_ref, :tool_result, result} ->
        result
    after
      0 ->
        tool_task_failed(provider_pid, tool_call, reason)
    end
  end

  @spec tool_task_failed(pid(), map(), term()) :: tool_execution_result()
  defp tool_task_failed(provider_pid, tool_call, reason) do
    result_text = "Tool task failed: #{inspect(reason)}"
    emit_tool_end(provider_pid, tool_call, result_text, true)
    %{tool_call: tool_call, result_text: result_text, is_error: true}
  end

  @spec execute_tool_call(
          loop_ctx(),
          map(),
          String.t() | nil,
          [ReqLLM.Tool.t()],
          approval_mode()
        ) :: tool_execution_result()
  defp execute_tool_call(lctx, tool_call, before_content, available_tools, approval_mode) do
    tool_context =
      native_tool_context(
        lctx.project_root,
        lctx.project_view,
        lctx.fork_store,
        lctx.changeset,
        lctx.session_pid
      )

    {result_text, is_error, _new_mode, post_dispatched?} =
      execute_with_approval(
        lctx.provider_pid,
        lctx.session_pid,
        tool_call,
        available_tools,
        approval_mode,
        lctx.config,
        lctx.hook_runner,
        tool_context
      )

    emit_tool_end(lctx.provider_pid, tool_call, result_text, is_error)

    unless post_dispatched? do
      dispatch_post_tool_use(tool_call, result_text, is_error, lctx.config)
    end

    maybe_emit_file_changed(lctx, tool_call, before_content, is_error)

    %{tool_call: tool_call, result_text: result_text, is_error: is_error}
  rescue
    e ->
      result_text = "Tool '#{tool_call.name}' crashed: #{Exception.message(e)}"
      emit_tool_end(lctx.provider_pid, tool_call, result_text, true)
      %{tool_call: tool_call, result_text: result_text, is_error: true}
  catch
    kind, reason ->
      result_text = "Tool '#{tool_call.name}' failed: #{inspect({kind, reason})}"
      emit_tool_end(lctx.provider_pid, tool_call, result_text, true)
      %{tool_call: tool_call, result_text: result_text, is_error: true}
  end

  @spec emit_tool_end(pid(), map(), String.t(), boolean()) :: :ok
  defp emit_tool_end(provider_pid, tool_call, result_text, is_error) do
    send(
      provider_pid,
      {:agent_event,
       %Event.ToolEnd{
         tool_call_id: tool_call.id,
         name: tool_call.name,
         result: result_text,
         is_error: is_error
       }}
    )

    :ok
  end

  @spec tool_result_message(tool_execution_result()) :: ReqLLM.Message.t()
  defp tool_result_message(%{tool_call: tool_call, result_text: result_text, is_error: is_error}) do
    meta = if is_error, do: %{is_error: true}, else: %{}
    Context.tool_result_message(tool_call.name, tool_call.id, result_text, meta)
  end

  @spec execute_with_approval(
          pid(),
          pid() | nil,
          map(),
          [ReqLLM.Tool.t()],
          approval_mode(),
          AgentConfig.t(),
          hook_runner(),
          ToolContext.t()
        ) ::
          {String.t(), boolean(), approval_mode(), boolean()}
  defp execute_with_approval(
         provider_pid,
         session_pid,
         tool_call,
         available_tools,
         mode,
         config,
         hook_runner,
         tool_context
       ) do
    args = tool_call.arguments || %{}

    if plan_mode_blocks_tool?(session_pid, tool_call.name, args) do
      message = PlanMode.refusal_message(tool_call.name)
      emit_plan_mode_refusal(session_pid, message)
      {message, true, mode, false}
    else
      # Per-tool permissions override the global approval mode.
      case tool_permission(tool_call.name, config) do
        :allow ->
          {result, is_error, post_dispatched?} =
            run_single_tool(
              tool_call,
              available_tools,
              provider_pid,
              session_pid,
              config,
              hook_runner,
              tool_context
            )

          {result, is_error, mode, post_dispatched?}

        :deny ->
          {"Tool '#{tool_call.name}' is denied by per-tool permissions", true, mode, false}

        :ask ->
          request_approval(
            provider_pid,
            session_pid,
            tool_call,
            available_tools,
            mode,
            config,
            hook_runner,
            tool_context
          )

        nil ->
          # No per-tool override; fall through to registry/default policy and global approval mode.
          case registered_tool_approval(tool_call.name) do
            :deny ->
              {"Tool '#{tool_call.name}' is denied by registry policy", true, mode, false}

            _approval ->
              execute_with_global_mode(
                provider_pid,
                session_pid,
                tool_call,
                available_tools,
                mode,
                config,
                hook_runner,
                tool_context
              )
          end
      end
    end
  end

  @spec execute_with_global_mode(
          pid(),
          pid() | nil,
          map(),
          [ReqLLM.Tool.t()],
          approval_mode(),
          AgentConfig.t(),
          hook_runner(),
          ToolContext.t()
        ) ::
          {String.t(), boolean(), approval_mode(), boolean()}
  defp execute_with_global_mode(
         provider_pid,
         session_pid,
         tool_call,
         available_tools,
         :none,
         config,
         hook_runner,
         tool_context
       ) do
    {result, is_error, post_dispatched?} =
      run_single_tool(
        tool_call,
        available_tools,
        provider_pid,
        session_pid,
        config,
        hook_runner,
        tool_context
      )

    {result, is_error, :none, post_dispatched?}
  end

  defp execute_with_global_mode(
         provider_pid,
         session_pid,
         tool_call,
         available_tools,
         :ask_all,
         config,
         hook_runner,
         tool_context
       ) do
    request_approval(
      provider_pid,
      session_pid,
      tool_call,
      available_tools,
      :ask_all,
      config,
      hook_runner,
      tool_context
    )
  end

  defp execute_with_global_mode(
         provider_pid,
         session_pid,
         tool_call,
         available_tools,
         :ask,
         config,
         hook_runner,
         tool_context
       ) do
    if global_mode_requires_approval?(tool_call, :ask) do
      request_approval(
        provider_pid,
        session_pid,
        tool_call,
        available_tools,
        :ask,
        config,
        hook_runner,
        tool_context
      )
    else
      {result, is_error, post_dispatched?} =
        run_single_tool(
          tool_call,
          available_tools,
          provider_pid,
          session_pid,
          config,
          hook_runner,
          tool_context
        )

      {result, is_error, :ask, post_dispatched?}
    end
  end

  @spec tool_requires_approval?(map(), AgentConfig.t(), approval_mode()) :: boolean()
  defp tool_requires_approval?(tool_call, config, mode) do
    case tool_permission(tool_call.name, config) do
      :ask -> true
      :allow -> false
      :deny -> false
      nil -> global_mode_requires_approval?(tool_call, mode)
    end
  end

  @spec global_mode_requires_approval?(map(), approval_mode()) :: boolean()
  defp global_mode_requires_approval?(_tool_call, :none), do: false
  defp global_mode_requires_approval?(_tool_call, :ask_all), do: true

  defp global_mode_requires_approval?(tool_call, :ask) do
    registered_tool_approval(tool_call.name) == :ask or
      Tools.destructive?(tool_call.name, tool_call.arguments || %{})
  end

  @spec registered_tool_approval(String.t()) :: ToolSpec.approval_level() | nil
  defp registered_tool_approval(tool_name) do
    case ToolRegistry.lookup(tool_name) do
      {:ok, %ToolSpec{approval_level: approval}} -> approval
      :error -> nil
    end
  end

  # Looks up per-tool permission from config. Returns :allow, :deny, :ask, or nil
  # (no override for this tool).
  @spec tool_permission(String.t(), AgentConfig.t()) :: :allow | :deny | :ask | nil
  defp tool_permission(tool_name, config) do
    case config.tool_permissions do
      nil ->
        nil

      permissions when is_map(permissions) ->
        case Map.get(permissions, tool_name) do
          :allow -> :allow
          :deny -> :deny
          :ask -> :ask
          "allow" -> :allow
          "deny" -> :deny
          "ask" -> :ask
          _ -> nil
        end
    end
  end

  @spec approval_mode(AgentConfig.t()) :: approval_mode()
  defp approval_mode(config) do
    case config.tool_approval do
      :none -> :none
      :all -> :ask_all
      :destructive -> :ask
    end
  end

  @spec request_approval(
          pid(),
          pid() | nil,
          map(),
          [ReqLLM.Tool.t()],
          approval_mode(),
          AgentConfig.t(),
          hook_runner(),
          ToolContext.t()
        ) ::
          {String.t(), boolean(), approval_mode(), boolean()}
  defp request_approval(
         provider_pid,
         session_pid,
         tool_call,
         available_tools,
         mode,
         config,
         hook_runner,
         tool_context
       ) do
    # Send approval request through the event pipeline (Task → Provider → Session)
    send(
      provider_pid,
      {:agent_event,
       %Event.ToolApproval{
         tool_call_id: tool_call.id,
         name: tool_call.name,
         args: tool_call.arguments,
         reply_to: self()
       }}
    )

    # Block until the user responds (or timeout after 5 minutes)
    receive do
      {:tool_approval_response, _tool_call_id, :approve} ->
        {result, is_error, post_dispatched?} =
          run_single_tool(
            tool_call,
            available_tools,
            provider_pid,
            session_pid,
            config,
            hook_runner,
            tool_context
          )

        {result, is_error, mode, post_dispatched?}

      {:tool_approval_response, _tool_call_id, :reject} ->
        {"Tool rejected by user", true, mode, false}
    after
      config.approval_timeout_ms ->
        {"Tool approval timed out", true, mode, false}
    end
  end

  @file_tools ~w(edit_file multi_edit_file apply_diff write_file delete_file)

  @spec capture_file_before(loop_ctx(), map()) :: String.t() | nil
  defp capture_file_before(%LoopCtx{} = lctx, %{name: name, arguments: %{"path" => path}})
       when name in @file_tools do
    case read_tool_file_content(lctx, path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp capture_file_before(_lctx, _tool_call), do: nil

  @spec maybe_emit_file_changed(loop_ctx(), map(), String.t() | nil, boolean()) :: :ok
  defp maybe_emit_file_changed(
         %LoopCtx{} = lctx,
         %{name: "delete_file", arguments: %{"path" => path}} = tool_call,
         before_content,
         false
       )
       when is_binary(before_content) do
    resolved_path = file_changed_path(lctx, path)
    after_content = read_deleted_tool_content(lctx, path)

    if is_binary(after_content) and after_content != before_content do
      send(
        lctx.provider_pid,
        {:agent_event,
         %Event.ToolFileChanged{
           tool_call_id: tool_call.id,
           path: resolved_path,
           before_content: before_content,
           after_content: after_content
         }}
      )
    end

    :ok
  end

  defp maybe_emit_file_changed(%LoopCtx{} = lctx, tool_call, before_content, false)
       when is_binary(before_content) and tool_call.name in @file_tools do
    path = tool_call.arguments["path"]
    resolved_path = file_changed_path(lctx, path)

    case read_tool_file_content(lctx, path) do
      {:ok, after_content} when after_content != before_content ->
        send(
          lctx.provider_pid,
          {:agent_event,
           %Event.ToolFileChanged{
             tool_call_id: tool_call.id,
             path: resolved_path,
             before_content: before_content,
             after_content: after_content
           }}
        )

      _ ->
        :ok
    end
  end

  defp maybe_emit_file_changed(_lctx, _tool_call, _before_content, _is_error), do: :ok

  @spec tool_routing_configured?(loop_ctx()) :: boolean()
  defp tool_routing_configured?(%LoopCtx{} = lctx),
    do: ToolRouter.routing_configured?(tool_router_context(lctx))

  @spec tool_router_context(loop_ctx()) :: ToolRouter.context()
  defp tool_router_context(%LoopCtx{
         project_view: project_view,
         fork_store: fork_store,
         changeset: changeset
       }) do
    ToolRouter.context(project_view, fork_store, changeset)
  end

  @spec file_changed_path(loop_ctx(), String.t()) :: String.t()
  defp file_changed_path(%LoopCtx{} = lctx, path) do
    if lctx.project_view do
      case ToolRouter.filesystem_path_result(tool_router_context(lctx), path) do
        {:ok, filesystem_path} -> filesystem_path
        {:error, _} -> resolved_tool_path(lctx.project_root, path)
      end
    else
      resolved_tool_path(lctx.project_root, path)
    end
  end

  @spec read_deleted_tool_content(loop_ctx(), String.t()) :: String.t() | nil
  defp read_deleted_tool_content(%LoopCtx{} = lctx, path) do
    if tool_routing_configured?(lctx) do
      absolute_path = resolved_tool_path(lctx.project_root, path)

      case ToolRouter.read_file(tool_router_context(lctx), absolute_path) do
        {:ok, content} -> content
        {:error, _} -> ""
      end
    else
      read_deleted_tool_content(Path.expand(path, lctx.project_root))
    end
  end

  @spec read_deleted_tool_content(String.t()) :: String.t() | nil
  defp read_deleted_tool_content(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, :enoent} -> ""
      {:error, _} -> nil
    end
  end

  @spec read_tool_file_content(loop_ctx(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_tool_file_content(%LoopCtx{} = lctx, path) do
    if tool_routing_configured?(lctx) do
      absolute_path = resolved_tool_path(lctx.project_root, path)
      ToolRouter.read_file(tool_router_context(lctx), absolute_path)
    else
      read_tool_file_content_direct(Path.expand(path, lctx.project_root))
    end
  end

  @spec read_tool_file_content_direct(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_tool_file_content_direct(path) do
    case Buffer.pid_for_path(path) do
      {:ok, pid} -> {:ok, Buffer.content(pid)}
      :not_found -> read_tool_file_content_from_disk(path)
    end
  catch
    :exit, _ -> read_tool_file_content_from_disk(path)
  end

  @spec read_tool_file_content_from_disk(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp read_tool_file_content_from_disk(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec resolved_tool_path(String.t(), String.t()) :: String.t()
  defp resolved_tool_path(project_root, path), do: Path.expand(path, project_root)

  # Re-checks plan mode after approval: the user may have entered /plan between
  # the approval prompt and the approval response.
  @spec run_single_tool(
          map(),
          [ReqLLM.Tool.t()],
          pid(),
          pid() | nil,
          AgentConfig.t(),
          hook_runner(),
          ToolContext.t()
        ) ::
          {String.t(), boolean(), boolean()}
  defp run_single_tool(
         tool_call,
         available_tools,
         provider_pid,
         session_pid,
         config,
         hook_runner,
         tool_context
       ) do
    args = tool_call.arguments || %{}

    if plan_mode_blocks_tool?(session_pid, tool_call.name, args) do
      message = PlanMode.refusal_message(tool_call.name)
      emit_plan_mode_refusal(session_pid, message)
      {message, true, false}
    else
      run_single_tool_unchecked(
        tool_call,
        available_tools,
        provider_pid,
        config,
        hook_runner,
        tool_context
      )
    end
  end

  @spec run_single_tool_unchecked(
          map(),
          [ReqLLM.Tool.t()],
          pid(),
          AgentConfig.t(),
          hook_runner(),
          ToolContext.t()
        ) :: {String.t(), boolean(), boolean()}
  defp run_single_tool_unchecked(
         tool_call,
         available_tools,
         provider_pid,
         config,
         hook_runner,
         tool_context
       ) do
    case Enum.find(available_tools, fn t -> t.name == tool_call.name end) do
      nil ->
        {"Tool '#{tool_call.name}' not found", true, false}

      tool ->
        if registry_tool?(tool) do
          execute_registry_tool(tool_call, provider_pid, config, hook_runner, tool_context)
        else
          case dispatch_pre_tool_use(tool_call, config, hook_runner, provider_pid) do
            :ok -> tuple_with_post_flag(execute_found_tool(tool, tool_call, provider_pid), false)
            {:error, %HookResult{} = result} -> {HookResult.message(result), true, false}
          end
        end
    end
  end

  @spec registry_tool?(ReqLLM.Tool.t()) :: boolean()
  defp registry_tool?(%ReqLLM.Tool{provider_options: %{minga_registry_tool: true}}), do: true
  defp registry_tool?(_tool), do: false

  @spec execute_registry_tool(map(), pid(), AgentConfig.t(), hook_runner(), ToolContext.t()) ::
          {String.t(), boolean(), boolean()}
  defp execute_registry_tool(tool_call, provider_pid, config, hook_runner, tool_context) do
    args = tool_call.arguments || %{}
    tool_context = tool_context_with_call_metadata(tool_context, tool_call, provider_pid)

    case ToolRegistry.lookup(tool_call.name) do
      {:ok, spec} ->
        spec
        |> ToolExecutor.execute_approved(args, :exec,
          config: config,
          hook_runner: hook_runner,
          tool_context: tool_context
        )
        |> format_executor_result()

      :error ->
        {"Tool '#{tool_call.name}' not found", true, true}
    end
  end

  @spec tool_context_with_call_metadata(ToolContext.t(), map(), pid()) :: ToolContext.t()
  defp tool_context_with_call_metadata(
         %ToolContext{} = context,
         %{name: "shell"} = tool_call,
         provider_pid
       ) do
    shell_output_callback = fn chunk ->
      send(
        provider_pid,
        {:agent_event,
         %Event.ToolUpdate{
           tool_call_id: tool_call.id,
           name: "shell",
           partial_result: chunk
         }}
      )

      :ok
    end

    %{
      context
      | metadata: Map.put(context.metadata, :shell_output_callback, shell_output_callback)
    }
  end

  defp tool_context_with_call_metadata(%ToolContext{} = context, _tool_call, _provider_pid),
    do: context

  @spec format_executor_result({:ok, term()} | {:error, term()}) ::
          {String.t(), boolean(), boolean()}
  defp format_executor_result({:ok, result}), do: {format_tool_result(result), false, true}
  defp format_executor_result({:error, reason}), do: {format_error(reason), true, true}

  @spec tuple_with_post_flag({String.t(), boolean()}, boolean()) ::
          {String.t(), boolean(), boolean()}
  defp tuple_with_post_flag({result, is_error}, post_dispatched?),
    do: {result, is_error, post_dispatched?}

  @spec dispatch_pre_tool_use(map(), AgentConfig.t(), hook_runner(), pid()) ::
          :ok | {:error, HookResult.t()}
  defp dispatch_pre_tool_use(tool_call, config, hook_runner, provider_pid) do
    payload = PreToolUsePayload.new(tool_call)

    case HookDispatcher.pre_tool_use(config.agent_hooks, payload, runner: hook_runner) do
      :ok ->
        :ok

      {:error, result} = error ->
        emit_hook_veto(provider_pid, result)
        error
    end
  end

  @spec dispatch_post_tool_use(map(), String.t(), boolean(), AgentConfig.t()) :: :ok
  defp dispatch_post_tool_use(tool_call, result_text, is_error, config) do
    payload =
      PostToolUsePayload.new(
        to_string(tool_call.id),
        to_string(tool_call.name),
        tool_call.arguments || %{},
        result_text,
        is_error
      )

    HookDispatcher.post_tool_use(config.agent_hooks, PostToolUsePayload.to_map(payload))
  rescue
    e -> Minga.Log.warning(:agent, "PostToolUse hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason -> Minga.Log.warning(:agent, "PostToolUse hook dispatch failed: #{inspect(reason)}")
  end

  @spec dispatch_pre_compact(Context.t(), AgentConfig.t()) :: :ok | {:error, HookResult.t()}
  defp dispatch_pre_compact(context, config) do
    message_count = length(context.messages)
    payload = PreCompactPayload.new(message_count)
    HookDispatcher.pre_compact(config.agent_hooks, PreCompactPayload.to_map(payload))
  rescue
    e ->
      Minga.Log.warning(:agent, "PreCompact hook dispatch failed: #{Exception.message(e)}")
      {:error, HookResult.dispatch_error(Exception.message(e))}
  catch
    _, reason ->
      Minga.Log.warning(:agent, "PreCompact hook dispatch failed: #{inspect(reason)}")
      {:error, HookResult.dispatch_error(inspect(reason))}
  end

  @spec emit_hook_veto(pid(), HookResult.t()) :: :ok
  defp emit_hook_veto(provider_pid, %HookResult{} = result) do
    send(provider_pid, {:agent_event, %Event.Error{message: HookResult.message(result)}})
    :ok
  end

  @spec plan_mode_blocks_tool?(pid() | nil, String.t(), map()) :: boolean()
  defp plan_mode_blocks_tool?(session_pid, name, args) when is_pid(session_pid) do
    session_in_plan_mode?(session_pid) and PlanMode.blocked?(name, args)
  end

  defp plan_mode_blocks_tool?(_session_pid, _name, _args), do: false

  @spec session_in_plan_mode?(pid()) :: boolean()
  defp session_in_plan_mode?(session_pid) when is_pid(session_pid) do
    case Process.info(session_pid, :dictionary) do
      {:dictionary, dict} ->
        Keyword.get(dict, :"$initial_call") == {Session, :init, 1} and
          Session.status(session_pid) == :plan

      nil ->
        false
    end
  catch
    :exit, _ -> false
  end

  @spec emit_plan_mode_refusal(pid(), String.t()) :: :ok
  defp emit_plan_mode_refusal(session_pid, message) when is_pid(session_pid) do
    send(
      session_pid,
      {:agent_provider_event, %Event.SystemMessage{message: message, level: :info}}
    )

    :ok
  end

  @spec execute_found_tool(ReqLLM.Tool.t(), map(), pid() | nil) :: {String.t(), boolean()}
  defp execute_found_tool(_tool, %{name: "shell"} = tool_call, provider_pid)
       when is_pid(provider_pid) do
    run_shell_with_streaming(tool_call, provider_pid)
  end

  defp execute_found_tool(tool, tool_call, _provider_pid) do
    case ReqLLM.Tool.execute(tool, tool_call.arguments) do
      {:ok, result} -> {format_tool_result(result), false}
      {:error, reason} -> {format_error(reason), true}
    end
  end

  # Runs the shell tool with incremental output streaming via ToolUpdate events.
  @spec run_shell_with_streaming(map(), pid()) :: {String.t(), boolean()}
  defp run_shell_with_streaming(tool_call, provider_pid) do
    flush_before_shell()
    args = tool_call.arguments
    root = detect_project_root()
    timeout_secs = min(args["timeout"] || 30, 300)

    on_output = fn chunk ->
      send(
        provider_pid,
        {:agent_event,
         %Event.ToolUpdate{
           tool_call_id: tool_call.id,
           name: "shell",
           partial_result: chunk
         }}
      )

      :ok
    end

    case Shell.execute(args["command"], root, timeout_secs, on_output: on_output) do
      {:ok, result} -> {result, false}
      {:error, reason} -> {reason, true}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  # Checks if context needs compaction and performs it, notifying the subscriber.
  @spec maybe_compact_context(loop_ctx(), Context.t()) :: Context.t()
  defp maybe_compact_context(lctx, context) do
    case dispatch_pre_compact(context, lctx.config) do
      :ok ->
        do_maybe_compact(lctx, context)

      {:error, _result} ->
        context
    end
  end

  @spec do_maybe_compact(loop_ctx(), Context.t()) :: Context.t()
  defp do_maybe_compact(lctx, context) do
    compact_opts = [
      model: lctx.model,
      llm_client: summary_client(lctx.llm_client, lctx.config)
    ]

    case Compaction.maybe_compact(context, compact_opts) do
      {:compacted, new_context, summary_info} ->
        send(
          lctx.provider_pid,
          {:agent_event, %Event.TextDelta{delta: "\n📦 #{summary_info}\n"}}
        )

        send(lctx.provider_pid, {:agent_context_update, new_context})
        new_context

      {:ok, context} ->
        context
    end
  end

  # Wraps the streaming LLM client into a simpler function that returns {:ok, text}.
  # Used by the Compaction module which doesn't need streaming.
  # Makes a synchronous LLM call (no streaming, no tool calls).
  # Used for meta-operations like summarization.
  @spec call_llm_sync(llm_client(), String.t(), [map()], keyword(), AgentConfig.t()) ::
          {:ok, String.t()} | {:error, term()}
  @spec generate_and_save_summary(state(), [map()]) ::
          {:ok, String.t(), String.t()} | {:error, String.t()}
  defp generate_and_save_summary(state, messages) do
    summary_messages = messages ++ [Context.user(ContextArtifact.summary_prompt())]

    case call_llm_sync(
           state.llm_client,
           state.model,
           summary_messages,
           [max_tokens: 4096],
           state.config
         ) do
      {:ok, summary_text} ->
        case ContextArtifact.save(summary_text, project_root: state.project_root) do
          {:ok, path} -> {:ok, summary_text, path}
          {:error, reason} -> {:error, "Summary generated but save failed: #{reason}"}
        end

      {:error, reason} ->
        {:error, "Failed to generate summary: #{format_error(reason)}"}
    end
  end

  defp call_llm_sync(llm_client, model, messages, opts, config) do
    ReqLLMAdapter.call_sync(llm_client, model, messages, opts, config)
  end

  @spec summary_client(llm_client(), AgentConfig.t()) :: Compaction.summary_fn()
  defp summary_client(llm_client, config) do
    ReqLLMAdapter.summary_client(llm_client, config)
  end

  @spec refresh_base_tools(state(), ProjectView.t() | nil) :: [ReqLLM.Tool.t()]
  defp refresh_base_tools(%{custom_tools?: true, base_tools: base_tools}, _project_view) do
    base_tools
  end

  defp refresh_base_tools(
         %{
           project_root: project_root,
           fork_store: fork_store,
           changeset: changeset,
           subscriber: subscriber,
           config: config,
           hook_runner: hook_runner
         },
         project_view
       ) do
    project_root
    |> native_tool_context(project_view, fork_store, changeset, subscriber)
    |> registry_tools(config, hook_runner)
  end

  # Builds tools that interact with the provider's internal state (todo, notebook).
  # These are created in init with a closure over the provider PID.
  #
  # NOTE: Tool callbacks close over `provider_pid` and make GenServer.call back
  # to the provider. This works because tools run in a spawned Task, not in the
  # provider's own process. If the provider ever awaits the task synchronously
  # (blocking its mailbox), these calls will deadlock.
  @spec build_internal_tools(pid()) :: [ReqLLM.Tool.t()]
  defp build_internal_tools(provider_pid) do
    [
      ReqLLM.Tool.new!(
        name: "todo_write",
        description: """
        Create or update a task checklist for tracking multi-step work.
        Each task has a description and status (pending, in_progress, done).
        Use this to plan before executing, and update status as you complete tasks.
        """,
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "tasks" => %{
              "type" => "array",
              "description" => "List of tasks",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "id" => %{"type" => "string", "description" => "Short task ID"},
                  "description" => %{"type" => "string", "description" => "What to do"},
                  "status" => %{
                    "type" => "string",
                    "enum" => ["pending", "in_progress", "done"],
                    "description" => "Task status (default: pending)"
                  }
                },
                "required" => ["description"]
              }
            }
          },
          "required" => ["tasks"]
        },
        callback: fn args -> Todo.write(provider_pid, args["tasks"] || []) end
      ),
      ReqLLM.Tool.new!(
        name: "todo_read",
        description: "Read the current task checklist to see what's done and what remains.",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _args -> Todo.read(provider_pid) end
      ),
      ReqLLM.Tool.new!(
        name: "notebook_write",
        description: """
        Write planning notes, intermediate reasoning, or working state to a
        scratchpad. Content is not shown to the user. Use this for complex
        multi-step reasoning or to track state across tool calls.
        """,
        parameter_schema: %{
          "type" => "object",
          "properties" => %{
            "content" => %{
              "type" => "string",
              "description" => "The content to write to the notebook (replaces previous content)"
            }
          },
          "required" => ["content"]
        },
        callback: fn args -> Notebook.write(provider_pid, args["content"] || "") end
      ),
      ReqLLM.Tool.new!(
        name: "notebook_read",
        description: "Read the current scratchpad notes.",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _args -> Notebook.read(provider_pid) end
      )
    ]
  end

  @spec append_seed_message(MingaAgent.Message.t(), Context.t()) :: Context.t()
  defp append_seed_message({:user, text}, context) when is_binary(text),
    do: Context.append(context, Context.user(text))

  defp append_seed_message({:user, text, _attachments}, context) when is_binary(text),
    do: Context.append(context, Context.user(text))

  defp append_seed_message({:assistant, text}, context) when is_binary(text),
    do: Context.append(context, Context.assistant(text))

  defp append_seed_message(_message, context), do: context

  @spec system_prompt_from_context(Context.t()) :: String.t() | nil
  defp system_prompt_from_context(%Context{
         messages: [%ReqLLM.Message{role: :system, content: content} | _messages]
       }) do
    text_from_content(content)
  end

  defp system_prompt_from_context(_context), do: nil

  @spec text_from_content(String.t() | [term()]) :: String.t() | nil
  defp text_from_content(content) when is_binary(content), do: content

  defp text_from_content(content) when is_list(content) do
    content
    |> Enum.map(&content_part_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  @spec content_part_text(term()) :: String.t()
  defp content_part_text(%{text: text}) when is_binary(text), do: text
  defp content_part_text(_part), do: ""

  @spec load_active_skills(String.t(), [String.t()]) :: [Skills.skill()]
  defp load_active_skills(_project_root, []), do: []

  defp load_active_skills(project_root, names) do
    names
    |> Enum.uniq()
    |> Enum.flat_map(&load_active_skill(project_root, &1))
  end

  @spec load_active_skill(String.t(), String.t()) :: [Skills.skill()]
  defp load_active_skill(project_root, name) do
    case Skills.find(name, project_root) do
      {:ok, skill} -> [skill]
      :not_found -> []
    end
  end

  @spec build_system_prompt(String.t(), [Skills.skill()]) :: String.t()
  defp build_system_prompt(project_root, active_skills) do
    base = resolve_base_prompt(project_root)
    instructions = Instructions.assemble(project_root)
    memory = Memory.for_prompt()
    skills_section = Skills.format_for_prompt(active_skills)
    append = read_config_string(:agent_append_system_prompt)

    parts =
      [base, instructions, memory, skills_section, append]
      |> Enum.reject(&(is_nil(&1) or &1 == ""))
      |> Enum.join("\n\n")

    parts
  end

  @default_system_prompt_template """
  You are an AI coding assistant inside Minga, a modal text editor.

  <tools>
  read_file: Read file contents. Supports offset/limit for partial reads.
  write_file: Create/overwrite files. Auto-creates parent dirs.
  edit_file: Find-and-replace exact text. Read file first for exact match.
  apply_diff: Apply unified diffs to a file. Use for large or multi-hunk edits.
  list_directory: List entries at a path.
  find: Find files by name/glob. Prefer over shell+find.
  grep: Search file contents by pattern. Prefer over shell+grep.
  shell: Run shell commands in project root. Timeout: 30s.
  </tools>

  multi_edit_file: Apply multiple edits to one file in a single call.

  <rules>
  - Always read a file before editing it. old_text must match exactly.
  - Prefer apply_diff for large changes that are easiest to express as unified diff hunks.
  - Prefer multi_edit_file when making several exact replacements in the same file.
  - Use find for file discovery, grep for content search.
  - Verify changes by reading the result or running tests.
  - Be concise. Show file paths clearly.
  </rules>
  """

  # Returns the base system prompt: either from config or the default template.
  # Config value can be a string prompt or a file path.
  @spec resolve_base_prompt(String.t()) :: String.t()
  defp resolve_base_prompt(project_root) do
    custom = read_config_string(:agent_system_prompt)

    base =
      if custom != "" do
        resolve_prompt_value(custom, project_root)
      else
        @default_system_prompt_template
      end

    # Always append environment info
    base <>
      "\n## Environment\n\n" <>
      "- Project root: #{project_root}\n" <>
      "- Current time: #{DateTime.utc_now() |> DateTime.to_iso8601()}"
  end

  # If the value looks like a file path, read it. Otherwise return as-is.
  @spec resolve_prompt_value(String.t(), String.t()) :: String.t()
  defp resolve_prompt_value(value, project_root) do
    expanded = expand_path(value, project_root)

    if File.regular?(expanded) do
      File.read!(expanded)
    else
      value
    end
  end

  @spec expand_path(String.t(), String.t()) :: String.t()
  defp expand_path("~/" <> rest, _project_root) do
    Path.join(System.user_home!(), rest)
  end

  defp expand_path(path, project_root) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(project_root, path)
    end
  end

  @spec read_config_string(atom()) :: String.t()
  defp read_config_string(key) do
    case Config.get(key) do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  @spec config_model_list(AgentConfig.t()) :: [String.t()]
  defp config_model_list(%AgentConfig{models: models}) when is_list(models), do: models
  defp config_model_list(_config), do: []

  # Works with both LoopCtx and state since both have max_cost/session_cost fields.
  @spec over_budget?(LoopCtx.t() | state()) :: boolean()
  defp over_budget?(%{max_cost: nil}), do: false

  defp over_budget?(%{max_cost: max_cost, session_cost: session_cost})
       when is_number(max_cost) do
    session_cost >= max_cost
  end

  @spec cost_limit_message(float(), float() | nil) :: String.t()
  defp cost_limit_message(session_cost, max_cost) do
    formatted_spent = :erlang.float_to_binary(session_cost, decimals: 2)
    formatted_limit = :erlang.float_to_binary(max_cost || 0.0, decimals: 2)

    "Session cost limit reached ($#{formatted_spent} / $#{formatted_limit}). " <>
      "Raise the limit with /budget <amount> or start a new session."
  end

  @spec turn_cost_from_usage(Event.token_usage() | nil) :: float()
  defp turn_cost_from_usage(nil), do: 0.0
  defp turn_cost_from_usage(%MingaAgent.TurnUsage{cost: cost}) when is_number(cost), do: cost

  @spec report_turn_cost(loop_ctx(), Event.token_usage() | nil) :: :ok
  defp report_turn_cost(_lctx, nil), do: :ok

  defp report_turn_cost(lctx, %MingaAgent.TurnUsage{cost: cost})
       when is_number(cost) and cost > 0 do
    send(lctx.provider_pid, {:agent_turn_cost, cost})
    :ok
  end

  defp report_turn_cost(_lctx, _usage), do: :ok

  # Finds the next entry in the cycle after the current model.
  @spec next_in_cycle([String.t()], String.t()) :: String.t()
  defp next_in_cycle(model_list, current_model) do
    current_index =
      Enum.find_index(model_list, &String.starts_with?(&1, current_model)) || -1

    next_index = rem(current_index + 1, length(model_list))
    Enum.at(model_list, next_index)
  end

  # Parses "provider:model:thinking_level" or "provider:model" into {model_str, thinking | nil}.
  @spec parse_model_entry(String.t()) :: {String.t(), String.t() | nil}
  defp parse_model_entry(entry) do
    parts = String.split(entry, ":")

    case Enum.reverse(parts) do
      [thinking | reversed_model_parts] when reversed_model_parts != [] ->
        if valid_thinking_level?(thinking) do
          model = reversed_model_parts |> Enum.reverse() |> Enum.join(":")
          {model, thinking}
        else
          {entry, nil}
        end

      _ ->
        {entry, nil}
    end
  end

  @spec valid_thinking_level?(String.t()) :: boolean()
  defp valid_thinking_level?(level), do: Map.has_key?(@thinking_levels, level)

  @spec detect_project_root() :: String.t()
  # Rebuilds the system prompt with current active skills and replaces it
  # in the context's first message.
  @spec rebuild_system_prompt(state()) :: state()
  defp rebuild_system_prompt(state) do
    new_prompt = build_system_prompt(state.project_root, state.active_skills)
    messages = state.context.messages

    updated_messages =
      case messages do
        [%{role: :system} | rest] ->
          [Context.system(new_prompt) | rest]

        other ->
          [Context.system(new_prompt) | other]
      end

    %{state | context: %{state.context | messages: updated_messages}}
  end

  defdelegate detect_project_root, to: Minga.Project, as: :resolve_root

  # Estimates token usage for the current context and emits a ContextUsage event.
  # The model name is stripped of the provider prefix for ModelLimits lookup.
  @spec emit_context_usage(loop_ctx(), Context.t()) :: :ok
  defp emit_context_usage(lctx, context) do
    estimated = TokenEstimator.estimate(context.messages)
    model_name = strip_provider_prefix(lctx.model)
    context_limit = ModelLimits.context_limit(model_name)

    send(
      lctx.provider_pid,
      {:agent_event,
       %Event.ContextUsage{
         estimated_tokens: estimated,
         context_limit: context_limit
       }}
    )

    :ok
  end

  defdelegate strip_provider_prefix(model), to: MingaAgent.Config

  @spec emit_error_and_end(pid(), String.t()) :: :ok
  defp emit_error_and_end(provider_pid, message) do
    send(provider_pid, {:agent_event, %Event.Error{message: message}})
    send(provider_pid, {:agent_event, %Event.AgentEnd{usage: nil}})
    :ok
  end

  # Reports an error that occurred inside the agent loop: logs the raw detail
  # for the Messages panel, emits Error + AgentEnd to the UI, and returns a
  # `{:reported, reason}` sentinel. The Task-completion handler matches that
  # sentinel and skips re-emitting, so a single failure surfaces exactly once
  # in the transcript instead of twice.
  @spec reported_error(pid(), String.t(), term()) :: {:error, {:reported, term()}}
  defp reported_error(provider_pid, message, reason) do
    Minga.Log.error(:agent, "[Agent.Native] agent loop error: #{message}")
    emit_error_and_end(provider_pid, message)
    {:error, {:reported, reason}}
  end

  @spec normalize_usage(map() | nil, String.t()) :: Event.token_usage() | nil
  defp normalize_usage(nil, _model), do: nil

  defp normalize_usage(usage, model) when is_map(usage) do
    normalized = %MingaAgent.TurnUsage{
      input: Map.get(usage, :input_tokens, 0) || Map.get(usage, :input, 0),
      output: Map.get(usage, :output_tokens, 0) || Map.get(usage, :output, 0),
      cache_read: Map.get(usage, :cache_read_input_tokens, 0) || Map.get(usage, :cache_read, 0),
      cache_write:
        Map.get(usage, :cache_creation_input_tokens, 0) || Map.get(usage, :cache_write, 0),
      cost: Map.get(usage, :total_cost, 0.0) || 0.0
    }

    {provider_atom, model_id} = parse_model_string(model)
    CostCalculator.ensure_cost(normalized, model_id, provider_atom)
  end

  @spec parse_model_string(String.t()) :: {atom(), String.t()}
  defp parse_model_string(model) do
    case String.split(model, ":", parts: 2) do
      [provider, id] -> {String.to_existing_atom(provider), id}
      _ -> {:unknown, model}
    end
  rescue
    ArgumentError -> {:unknown, model}
  end

  @spec format_tool_result(term()) :: String.t()
  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: JSON.encode!(result)

  defp format_tool_result(result), do: inspect(result)

  @spec format_error(term()) :: String.t()
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(%{message: msg}) when is_binary(msg), do: msg
  defp format_error(%{"message" => msg}) when is_binary(msg), do: msg

  defp format_error(:invalid_format) do
    ~s|Invalid model format. Expected "provider:model" (e.g., "anthropic:claude-sonnet-4"), | <>
      "got a bare model name without a provider prefix."
  end

  defp format_error(reason), do: inspect(reason)

  @spec notify(pid(), Event.t()) :: Event.t()
  defp notify(subscriber, event) do
    send(subscriber, {:agent_provider_event, event})
    event
  end

  # Saves all dirty file-backed buffers to disk before running shell commands.
  # Build tools read from the filesystem, not from buffer memory, so in-memory
  # edits must be flushed for the build to see them.
  @spec flush_before_shell() :: :ok
  defp flush_before_shell do
    if Config.get(:agent_flush_before_shell) do
      {saved, warnings} = Minga.Buffer.save_all_dirty()

      if saved > 0 do
        Minga.Log.debug(:agent, "Flushed #{saved} dirty buffer(s) to disk before shell command")
      end

      for warning <- warnings do
        Minga.Log.warning(:agent, "Pre-shell flush: #{warning}")
      end

      :ok
    else
      :ok
    end
  rescue
    # Config not available (headless/test mode)
    _ -> :ok
  end
end
