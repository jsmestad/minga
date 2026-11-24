# credo:disable-for-this-file Credo.Check.Refactor.Nesting

defmodule MingaAgent.Providers.Native do
  @moduledoc """
  Native Elixir agent provider backed by ReqLLM.

  It runs entirely inside the BEAM and supports any ReqLLM-backed provider
  that has an installed exact text route. Session resolves a model, protocol,
  endpoint, credential identity, reasoning policy, limits, and capabilities
  before this provider starts. Native executes that immutable selection without
  reparsing a model name.

  The provider consumes immutable Session-owned continuation snapshots, executes
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

  alias Minga.Git
  alias MingaAgent.ArtifactStore
  alias MingaAgent.Compaction
  alias MingaAgent.Config, as: AgentConfig
  alias MingaAgent.CostCalculator
  alias MingaAgent.Event
  alias MingaAgent.Hooks.CommandRunner
  alias MingaAgent.InferenceRoute.ConversationRef
  alias MingaAgent.InferenceRoute.PlanWindow
  alias MingaAgent.InferenceRoute.Status, as: InferenceRouteStatus
  alias MingaAgent.InferenceRoute.Spec, as: InferenceRouteSpec
  alias MingaAgent.InferenceRouteRegistry
  alias MingaAgent.Hooks.Dispatcher, as: HookDispatcher
  alias MingaAgent.Hooks.PostToolUsePayload
  alias MingaAgent.Hooks.PreCompactPayload
  alias MingaAgent.Hooks.PreToolUsePayload
  alias MingaAgent.Hooks.Result, as: HookResult
  alias MingaAgent.Hooks.Registry, as: HookRegistry
  alias MingaAgent.Instructions
  alias MingaAgent.MCP.Registry, as: MCPRegistry
  alias MingaAgent.MCP.ServerConfig, as: MCPServerConfig
  alias MingaAgent.MCP.ServerRegistry, as: MCPServerRegistry
  alias MingaAgent.ModelResolver
  alias MingaAgent.ModelSelection
  alias MingaAgent.ModelSelection.Policy.RequestCapacity
  alias MingaAgent.ProjectView
  alias MingaAgent.Providers.Native.ExecutionState
  alias MingaAgent.Providers.Native.LoopCtx
  alias MingaAgent.Providers.Native.OutputHydration
  alias MingaAgent.Providers.Native.ReqLLMAdapter
  alias MingaAgent.Providers.Native.SystemPrompt
  alias MingaAgent.Providers.Native.ToolResultBound
  alias MingaAgent.Providers.Native.UsageLimitSignal
  alias MingaAgent.Redaction
  alias MingaAgent.Retry
  alias MingaAgent.Session
  alias MingaAgent.Session.Dispatch
  alias MingaAgent.Session.Outcome
  alias MingaAgent.Session.Request
  alias MingaAgent.Session.Prefix
  alias MingaAgent.Session.PrefixStore
  alias MingaAgent.Session.PortableHistory
  alias MingaAgent.Credentials
  alias MingaAgent.Skills
  alias MingaAgent.TokenEstimator
  alias MingaAgent.UsageLimit
  alias MingaAgent.Tool.Output
  alias MingaAgent.Tool.Invocation
  alias MingaAgent.Tool.Limitation
  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Context, as: ToolContext
  alias MingaAgent.Tool.Executor, as: ToolExecutor
  alias MingaAgent.Tool.Registry, as: ToolRegistry
  alias MingaAgent.Tool.Spec, as: ToolSpec
  alias MingaAgent.Tools
  alias MingaAgent.Tools.ProcessBackend.System, as: SystemProcessBackend
  alias Minga.Config
  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart
  alias Minga.Log
  alias ReqLLM.Tool

  @typedoc "Captures the immutable parameters for one agent turn loop invocation."
  @type loop_ctx :: LoopCtx.t()

  @type llm_client :: (LLMDB.Model.t(), [ReqLLM.Message.t()], keyword() ->
                         {:ok, ReqLLM.StreamResponse.t()} | {:error, term()})

  @typedoc "Function that executes a matching hook."
  @type hook_runner :: (MingaAgent.Hooks.Hook.t(), PreToolUsePayload.t() -> HookResult.t())

  @typedoc "Counts candidate Apple prefixes in one helper start without generating."
  @type apple_counter :: ([String.t()], [[non_neg_integer()]], [Tool.t()], pos_integer() ->
                            {:ok, MingaAgent.Providers.Apple.prefix_counts()} | {:error, term()})

  @typedoc "Internal state for the native provider."
  @type state :: %{
          subscriber: pid(),
          subscriber_ref: reference(),
          linked_parent: pid() | nil,
          config: AgentConfig.t(),
          selection: ModelSelection.t(),
          session_manager: pid() | nil,
          execution: ExecutionState.t(),
          tools: [term()],
          project_root: String.t(),
          project_view: ProjectView.t() | nil,
          owned_project_view?: boolean(),
          max_retries: non_neg_integer(),
          credential_opts: keyword(),
          authentication: MingaAgent.Credentials.Binding.t() | nil,
          local_registration: %{base: reference(), mcp: reference()},
          registry_revision: reference() | :unknown,
          schema_cache: {[Tool.t()], [map()]} | nil,
          prefix_candidate: Prefix.t() | :unknown,
          prefix_preview: map() | nil,
          apple_counter: apple_counter(),
          prefix_fit: {binary(), SystemPrompt.fit()} | nil,
          llm_client: llm_client(),
          hook_runner: hook_runner(),
          active_skills: [Skills.skill()],
          max_turns: pos_integer(),
          max_cost: float() | nil,
          session_cost: float(),
          fork_store: pid() | nil,
          changeset: pid() | nil,
          base_tools: [term()],
          mcp_tools: [term()],
          tool_metadata: map(),
          custom_tool_declarations: [Tool.t() | ToolSpec.t()],
          custom_tools?: boolean(),
          configured_mcp_configs: [MCPServerConfig.t()],
          mcp_configs: [MCPServerConfig.t()],
          mcp_client_opts: keyword(),
          mcp_enabled_override: boolean() | nil,
          mcp_errors: %{String.t() => String.t()},
          mcp_registry: MCPRegistry.t() | nil,
          read_only?: boolean(),
          tool_allowlist: :all | [String.t()],
          inference_routes: GenServer.server()
        }

  # ── Provider callbacks ──────────────────────────────────────────────────────

  @impl MingaAgent.Provider
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl MingaAgent.Provider
  @spec send_prompt(GenServer.server(), Request.t()) :: :ok | {:error, term()}
  def send_prompt(pid, %Request{} = request) do
    GenServer.call(pid, {:send_prompt, request})
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

  @doc "Manually compacts an immutable continuation snapshot."
  @spec compact(GenServer.server(), [ReqLLM.Message.t()]) ::
          {:ok, [ReqLLM.Message.t()], String.t()} | {:error, String.t()}
  @impl MingaAgent.Provider
  def compact(pid, messages) when is_list(messages) do
    GenServer.call(pid, {:compact, messages}, 30_000)
  end

  @doc "Compacts messages only when they exceed the configured context threshold."
  @spec compact(GenServer.server(), [ReqLLM.Message.t()], keyword()) ::
          {:ok, [ReqLLM.Message.t()], String.t()} | {:error, String.t()}
  def compact(pid, messages, opts) when is_list(messages) and is_list(opts) do
    GenServer.call(pid, {:compact, messages, opts}, 30_000)
  end

  @impl MingaAgent.Provider
  @spec set_model(GenServer.server(), ModelSelection.t()) :: :ok | {:error, term()}
  def set_model(pid, %ModelSelection{} = selection) do
    GenServer.call(pid, {:set_model, selection})
  end

  @impl MingaAgent.Provider

  @doc "Continues from an interrupted stream using a Session-owned request snapshot."
  @spec continue(GenServer.server(), Request.t()) :: :ok | {:error, term()}
  def continue(pid, %Request{} = request) do
    GenServer.call(pid, {:continue, request})
  end

  @doc "Refreshes the project view used for tool execution."
  @spec refresh_project_view(GenServer.server(), ProjectView.t() | nil) :: :ok | {:error, term()}
  def refresh_project_view(pid, project_view) do
    GenServer.call(pid, {:refresh_project_view, project_view})
  end

  @doc "Returns the current tool list registered with this provider."
  @spec tools(GenServer.server()) :: [Tool.t()]
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
    Process.flag(:trap_exit, true)
    linked_parent = linked_parent_pid()
    config = Keyword.get(opts, :config) || AgentConfig.resolve()

    subscriber = Keyword.fetch!(opts, :subscriber)
    model = Keyword.get(opts, :model, config.model)
    requested_thinking = Keyword.get(opts, :thinking_level)
    selection = initial_selection!(opts, config, model, requested_thinking)
    requested_view = Keyword.get(opts, :project_view)
    project_root = session_project_root(requested_view, opts)

    max_retries = Keyword.get(opts, :max_retries, config.max_retries)
    max_turns = Keyword.get(opts, :max_turns, config.max_turns)
    read_only? = Keyword.get(opts, :read_only?, false)
    config = disable_hooks_for_read_only(config, read_only?)
    {config, registry_mcp_servers} = merge_extension_components(config, read_only?)
    max_cost = Keyword.get(opts, :max_cost, config.max_cost)
    llm_client = Keyword.get(opts, :llm_client, ReqLLMAdapter.default_client())
    hook_runner = Keyword.get(opts, :hook_runner, &CommandRunner.run_pre_tool_use/2)
    provider_pid = self()

    {project_view, fork_store, changeset} = init_edit_view(requested_view, project_root)

    tool_metadata = %{
      parent_session: subscriber,
      session_checklist?: Keyword.get(opts, :session_checklist?, false),
      shell_output_callback: Keyword.get(opts, :shell_output_callback),
      process_backend: Keyword.get(opts, :process_backend, SystemProcessBackend),
      tool_registry: Keyword.get(opts, :tool_registry, ToolRegistry)
    }

    custom_tools = Keyword.get(opts, :tools)
    custom_tools? = is_list(custom_tools)

    custom_tool_declarations =
      if custom_tools?,
        do: Enum.map(custom_tools, &normalize_tool_declaration/1),
        else: []

    base_tools =
      if custom_tools? do
        Enum.map(custom_tool_declarations, &ReqLLMAdapter.tool(&1, :local))
      else
        registry_tools(project_root, tool_metadata)
      end

    base_tools = filter_base_tools_for_read_only(base_tools, read_only?)
    active_skills = load_active_skills(project_root, Keyword.get(opts, :active_skill_names, []))

    configured_mcp_configs = configured_mcp_servers(opts, config, subscriber, read_only?)
    config = %{config | mcp_servers: configured_mcp_configs}

    mcp_configs =
      MCPServerRegistry.resolve_configs(configured_mcp_configs,
        registry_configs: filter_registry_mcp_servers(registry_mcp_servers, opts, read_only?)
      )

    mcp_client_opts = mcp_client_opts(opts)
    mcp_enabled_override = Keyword.get(opts, :mcp_enabled?, nil)
    mcp_registry = mcp_registry_for(mcp_configs)
    mcp_tools = mcp_meta_tools_for(mcp_configs, provider_pid)

    tool_allowlist = Keyword.get(opts, :tool_allowlist, :all)

    tools =
      (base_tools ++ mcp_tools)
      |> filter_tool_allowlist(tool_allowlist)

    subscriber_ref = Process.monitor(subscriber)

    state = %{
      subscriber: subscriber,
      subscriber_ref: subscriber_ref,
      linked_parent: linked_parent,
      selection: selection,
      config: config,
      execution: ExecutionState.idle(),
      tools: tools,
      project_root: project_root,
      max_retries: max_retries,
      credential_opts: Keyword.get(opts, :credential_opts, []),
      inference_routes: inference_route_registry(opts),
      authentication: nil,
      local_registration: %{base: make_ref(), mcp: make_ref()},
      registry_revision: :unknown,
      schema_cache: nil,
      prefix_candidate: :unknown,
      prefix_preview: nil,
      apple_counter:
        Keyword.get(opts, :apple_counter, &MingaAgent.Providers.Apple.count_prefixes/4),
      prefix_fit: nil,
      llm_client: llm_client,
      hook_runner: hook_runner,
      active_skills: active_skills,
      max_turns: max_turns,
      max_cost: max_cost,
      session_cost: 0.0,
      fork_store: fork_store,
      changeset: changeset,
      project_view: project_view,
      owned_project_view?: requested_view == nil,
      base_tools: base_tools,
      mcp_tools: mcp_tools,
      custom_tools?: custom_tools?,
      custom_tool_declarations: custom_tool_declarations,
      configured_mcp_configs: configured_mcp_configs,
      mcp_configs: mcp_configs,
      mcp_client_opts: mcp_client_opts,
      mcp_enabled_override: mcp_enabled_override,
      mcp_errors: %{},
      mcp_registry: mcp_registry,
      session_manager: Keyword.get(opts, :session_manager),
      read_only?: read_only?,
      tool_allowlist: tool_allowlist,
      tool_metadata: tool_metadata
    }

    Minga.Events.subscribe(:agent_mcp_servers_changed)
    Minga.Events.subscribe(:agent_tools_changed)
    Log.info(:agent, "[Agent.Native] started with model=#{model} root=#{project_root}")

    {:ok, state}
  end

  @spec native_tool_context(
          String.t(),
          ProjectView.t() | nil,
          pid() | nil,
          pid() | nil,
          map(),
          ModelSelection.image_tool_result_delivery()
        ) :: ToolContext.t()
  defp native_tool_context(
         project_root,
         project_view,
         fork_store,
         changeset,
         metadata,
         image_tool_result_delivery
       ) do
    ToolContext.new(
      project_root: project_root,
      project_view: project_view,
      fork_store: fork_store,
      changeset: changeset,
      metadata: metadata,
      image_tool_result_delivery: image_tool_result_delivery
    )
  end

  @spec normalize_tool_declaration(Tool.t() | ToolSpec.t()) :: ToolSpec.t()
  defp normalize_tool_declaration(%ToolSpec{} = spec), do: spec
  defp normalize_tool_declaration(%Tool{} = tool), do: ToolRegistry.from_req_tool(tool)

  @spec registry_tools(String.t(), map()) :: [Tool.t()]
  defp registry_tools(project_root, %{tool_registry: table} = metadata) do
    table
    |> ToolRegistry.all()
    |> registry_tool_declarations(project_root, metadata)
  end

  @spec registry_tool_declarations([ToolSpec.t()], String.t(), map()) :: [Tool.t()]
  defp registry_tool_declarations(specs, project_root, metadata) do
    specs
    |> filter_session_tools(metadata)
    |> filter_git_tools(project_root)
    |> Enum.map(&ReqLLMAdapter.tool(&1, :registry))
  end

  @spec filter_session_tools([ToolSpec.t()], map()) :: [ToolSpec.t()]
  defp filter_session_tools(specs, %{session_checklist?: true}), do: specs

  defp filter_session_tools(specs, _metadata),
    do: Enum.reject(specs, &(&1.name in ["todo_read", "todo_write"]))

  @spec filter_git_tools([ToolSpec.t()], String.t()) :: [ToolSpec.t()]
  defp filter_git_tools(specs, project_root) do
    case Git.root_for(project_root) do
      {:ok, _git_root} -> specs
      :not_git -> Enum.reject(specs, &(&1.category == :git))
    end
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

  @spec filter_registry_mcp_servers([MCPServerConfig.t()], keyword(), boolean()) ::
          [MCPServerConfig.t()]
  defp filter_registry_mcp_servers(_servers, _opts, true), do: []
  defp filter_registry_mcp_servers([], _opts, _read_only?), do: []

  defp filter_registry_mcp_servers(servers, opts, false) do
    if mcp_extension_enabled?(opts), do: servers, else: []
  end

  @spec refresh_mcp_contributions(map(), map()) :: map()
  defp refresh_mcp_contributions(state, payload)
  defp refresh_mcp_contributions(%{read_only?: true} = state, _payload), do: state

  defp refresh_mcp_contributions(state, payload) do
    configs =
      state
      |> configured_mcp_servers_from_state()
      |> MCPServerRegistry.resolve_configs(
        registry_configs: registry_mcp_servers_from_state(state)
      )

    if configs == state.mcp_configs do
      state
    else
      maybe_notify_mcp_source_removed(state, configs, payload)
      cleanup_mcp(state.mcp_registry)

      mcp_registry = mcp_registry_for(configs)
      mcp_tools = mcp_meta_tools_for(configs, self())

      %{
        state
        | mcp_configs: configs,
          mcp_registry: mcp_registry,
          mcp_tools: mcp_tools,
          mcp_errors: %{},
          local_registration: %{state.local_registration | mcp: make_ref()},
          tools:
            (state.base_tools ++ mcp_tools)
            |> filter_tool_allowlist(state.tool_allowlist)
      }
    end
  end

  @spec maybe_notify_mcp_source_removed(map(), [MCPServerConfig.t()], map()) :: :ok
  defp maybe_notify_mcp_source_removed(state, configs, %{source: source}) do
    had_source? = Enum.any?(state.mcp_configs, &(&1.source == source))
    has_source? = Enum.any?(configs, &(&1.source == source))

    if had_source? and not has_source? do
      message =
        "MCP source #{format_mcp_source(source)} unloaded; stopped its clients and refreshed MCP tools."

      Log.info(:agent, "[Agent.Native] #{message}")
      notify(state.subscriber, %Event.SystemMessage{message: message, level: :info})
    end

    :ok
  end

  defp maybe_notify_mcp_source_removed(_state, _configs, _payload), do: :ok

  @spec registry_mcp_servers_from_state(map()) :: [MCPServerConfig.t()]
  defp registry_mcp_servers_from_state(state) do
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

  # A supplied project view is the session's file owner, so its root is the
  # single root every tool resolves against. Without a view, the caller's
  # explicit root wins over the global project and the launch directory.
  @spec session_project_root(ProjectView.t() | nil, keyword()) :: String.t()
  defp session_project_root(%ProjectView{project_root: root}, _opts), do: root

  defp session_project_root(nil, opts) do
    Keyword.get(opts, :project_root) || detect_project_root() || File.cwd!()
  end

  @spec init_edit_view(ProjectView.t() | nil, String.t()) ::
          {ProjectView.t(), pid() | nil, pid() | nil}
  defp init_edit_view(%ProjectView{} = view, _project_root), do: {view, nil, nil}

  defp init_edit_view(nil, project_root) do
    case ProjectView.overlay(project_root) do
      {:ok, %ProjectView{ref: %{fork_store: fork_store, changeset: changeset}} = view} ->
        Process.monitor(fork_store)
        Process.monitor(changeset)
        {view, fork_store, changeset}

      {:error, reason} ->
        raise "agent editable view unavailable: #{inspect(reason)}"
    end
  end

  @spec filter_base_tools_for_read_only([Tool.t()], boolean()) :: [Tool.t()]
  defp filter_base_tools_for_read_only(base_tools, true),
    do: Enum.filter(base_tools, &Tools.read_only_name?/1)

  defp filter_base_tools_for_read_only(base_tools, false), do: base_tools

  @spec filter_tool_allowlist([Tool.t()], :all | [String.t()]) :: [Tool.t()]
  defp filter_tool_allowlist(tools, :all) when is_list(tools), do: tools

  defp filter_tool_allowlist(tools, allowlist) when is_list(tools) and is_list(allowlist) do
    Enum.filter(tools, &(&1.name in allowlist))
  end

  @spec validate_request_capabilities(state(), Request.t()) :: :ok | {:error, term()}
  defp validate_request_capabilities(
         state,
         %Request{epoch_id: id, prefix: %Prefix{epoch_id: id, schemas: schemas}} = request
       ) do
    with :ok <- validate_tool_capability(state.selection, schemas),
         :ok <- validate_image_capability(state.selection, request.messages) do
      validate_video_capability(state.selection, request.messages)
    end
  end

  defp validate_request_capabilities(_state, %Request{}),
    do:
      {:error,
       {:portable_context_transition_required,
        "The request has unknown prefix evidence. Retain the saved conversation or use /new for a fresh conversation."}}

  @spec validate_tool_capability(ModelSelection.t(), [term()]) :: :ok | {:error, String.t()}
  defp validate_tool_capability(_selection, []), do: :ok

  defp validate_tool_capability(%ModelSelection{} = selection, _tools) do
    if ModelSelection.tools?(selection) do
      :ok
    else
      {:error,
       "#{selection.route.display_name} on #{selection.route.execution.wire_protocol} does not explicitly support tools. Choose a tool-capable route."}
    end
  end

  @spec validate_image_capability(ModelSelection.t(), [ReqLLM.Message.t()]) ::
          :ok | {:error, String.t()}
  defp validate_image_capability(%ModelSelection{} = selection, messages) do
    if request_contains_image?(messages) and not ModelSelection.images?(selection) do
      {:error,
       "#{selection.route.display_name} on #{selection.route.execution.wire_protocol} does not explicitly support image input. Choose an image-capable route."}
    else
      :ok
    end
  end

  @spec request_contains_image?([ReqLLM.Message.t()]) :: boolean()
  defp request_contains_image?(messages) do
    Enum.any?(messages, fn
      %ReqLLM.Message{content: content} -> image_content?(content)
      _other -> false
    end)
  end

  @spec image_content?(term()) :: boolean()
  defp image_content?(content) when is_list(content) do
    Enum.any?(content, &match?(%ContentPart{type: type} when type in [:image, :image_url], &1))
  end

  defp image_content?(_content), do: false

  @spec validate_video_capability(ModelSelection.t(), [ReqLLM.Message.t()]) ::
          :ok | {:error, String.t()}
  defp validate_video_capability(selection, messages) do
    if not video_input_supported?(selection) and
         Enum.any?(messages, fn message ->
           Enum.any?(message.content, &match?(%ContentPart{type: :video_url}, &1))
         end),
       do:
         {:error,
          "#{selection.route.display_name} cannot receive this conversation's video attachments. Keep the current model or choose a video-capable route."},
       else: :ok
  end

  @spec video_input_supported?(ModelSelection.t()) :: boolean()
  defp video_input_supported?(%ModelSelection{
         route: %{
           execution: %{wire_protocol: "google_generate_content"},
           metadata: %{modalities: modalities}
         }
       })
       when is_map(modalities) do
    inputs = Map.get(modalities, :input, Map.get(modalities, "input", []))
    is_list(inputs) and (:video in inputs or "video" in inputs)
  end

  defp video_input_supported?(_selection), do: false

  @spec validate_file_capability(ModelSelection.t(), [ReqLLM.Message.t()]) ::
          :ok | {:error, String.t()}
  defp validate_file_capability(
         %ModelSelection{route: %{execution: %{wire_protocol: protocol}}},
         _messages
       )
       when protocol in [
              "anthropic_messages",
              "openai_responses",
              "openai_codex_responses",
              "google_generate_content"
            ],
       do: :ok

  defp validate_file_capability(
         %ModelSelection{
           route: %{request_provider: :openrouter, execution: %{wire_protocol: "openai_chat"}}
         },
         _messages
       ),
       do: :ok

  defp validate_file_capability(_selection, messages),
    do: ReqLLM.Provider.Defaults.validate_image_only_attachments(Context.new(messages))

  @spec validate_retained_history(Prefix.t(), [ReqLLM.Message.t()]) :: :ok | {:error, String.t()}
  defp validate_retained_history(%Prefix{identity: %{native_contract: :unknown}}, messages) do
    case PortableHistory.convert(messages, :retain) do
      {:ok, _portable, _counts} -> :ok
      {:error, reason} -> {:error, PortableHistory.message(reason)}
    end
  end

  defp validate_retained_history(_prefix, _messages), do: :ok

  @impl GenServer
  def handle_call({:send_prompt, %Request{} = request}, _from, state) do
    cond do
      ExecutionState.active?(state.execution) ->
        {:reply, {:error, :already_streaming}, state}

      over_budget?(state) ->
        notify(state.subscriber, request.request_id, %Event.Error{
          message: cost_limit_message(state.session_cost, state.max_cost)
        })

        {:reply, {:error, :cost_limit_reached}, state}

      true ->
        case validate_request_capabilities(state, request) do
          :ok ->
            {:reply, :ok, start_agent_turn(state, request)}

          {:error, message} ->
            {:reply, {:error, message}, state}
        end
    end
  end

  def handle_call(:abort, _from, state) do
    {execution, task, workers} = ExecutionState.abort(state.execution)
    stop_registered_tool_workers(workers)

    if task do
      # Use a short timeout instead of :brutal_kill so the StreamServer
      # (which traps exits) can terminate cleanly via its terminate/2 callback.
      Task.shutdown(task, 150)
    end

    Log.info(:agent, "[Agent.Native] aborted current operation")
    {:reply, :ok, %{state | execution: execution}}
  end

  def handle_call({:continue, %Request{} = request}, _from, state) do
    if ExecutionState.active?(state.execution) do
      {:reply, {:error, "Already streaming"}, state}
    else
      case validate_request_capabilities(state, request) do
        :ok ->
          {:reply, :ok, start_agent_turn(state, request)}

        {:error, message} ->
          {:reply, {:error, message}, state}
      end
    end
  end

  def handle_call({:preview_prefix, _token, _operation}, _from, %{prefix_preview: %{}} = state),
    do: {:reply, {:error, :prefix_transition_active}, state}

  def handle_call({:preview_prefix, token, operation}, {owner, _}, %{subscriber: owner} = state)
      when is_reference(token) do
    {operation, questions?} =
      case operation do
        {:with_questions, operation} -> {operation, true}
        operation -> {operation, false}
      end

    selection = prefix_selection(state.selection, operation)

    with {:ok, current} <- refresh_tool_registry_contributions(state),
         {:ok, active_skills, result} <- preview_skills(current, operation),
         {:ok, authentication} <-
           Credentials.bind_request(
             selection.credential,
             current.authentication,
             current.credential_opts
           ),
         identity = ModelSelection.replay_identity(selection, authentication.identity),
         {schemas, current} = current_prefix_schemas(current),
         schemas = schemas |> model_schemas(selection) |> question_schemas(questions?),
         {:ok, fit, current} <- fit_system_prompt(current, active_skills, selection, schemas),
         {:ok, candidate} <-
           PrefixStore.candidate(
             current.prefix_candidate,
             fit.text,
             schemas,
             identity,
             Enum.map(active_skills, & &1.name),
             fit.omitted
           ) do
      preview = %{
        token: token,
        owner: owner,
        selection: selection,
        active_skills: active_skills,
        authentication: authentication,
        prefix: candidate
      }

      {:reply, {:ok, candidate, token, result}, %{current | prefix_preview: preview}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:preview_prefix, _token, _operation}, _from, state),
    do: {:reply, {:error, :not_session_owner}, state}

  def handle_call(
        {:validate_prefix_preview, token, messages},
        {owner, _},
        %{prefix_preview: %{token: token, owner: owner} = preview} = state
      ) do
    result =
      with :ok <- validate_tool_capability(preview.selection, preview.prefix.schemas),
           :ok <- validate_image_capability(preview.selection, messages),
           :ok <- validate_video_capability(preview.selection, messages),
           :ok <- validate_file_capability(preview.selection, messages) do
        validate_retained_history(preview.prefix, messages)
      end

    {:reply, result, state}
  end

  def handle_call({:commit_prefix_preview, token}, {owner, _}, state),
    do: commit_prefix_preview(state, token, owner)

  def handle_call({:dispatch_auth, %Prefix{identity: identity}, _retained?}, _from, state) do
    with {:ok, authentication} <-
           Credentials.bind_request(
             state.selection.credential,
             state.authentication,
             state.credential_opts
           ),
         current_identity =
           ModelSelection.replay_identity(state.selection, authentication.identity),
         true <-
           current_identity == identity or
             Prefix.requalifies_replay_identity?(identity, current_identity) do
      {:reply, {:ok, authentication.material}, %{state | authentication: authentication}}
    else
      false ->
        {:reply,
         {:error,
          {:portable_context_transition_required,
           "Authentication or exact native replay support changed or is unknown. Retain this record or use /new for a fresh conversation."}},
         state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:dispatch_auth, :unknown, _retained?}, _from, state),
    do:
      {:reply, {:error, {:portable_context_transition_required, :historical_identity_unknown}},
       state}

  def handle_call({:resolve_local_tool, name}, _from, state) do
    result =
      case Enum.find(state.tools, &(&1.name == name)) do
        nil ->
          {:error, {:tool_not_found, name}}

        tool ->
          case ReqLLMAdapter.declaration(tool) do
            %{source: {:local, ^name}} = declaration ->
              spec = local_spec(tool)

              registration =
                if Enum.any?(state.mcp_tools, &(&1.name == name)),
                  do: state.local_registration.mcp,
                  else: state.local_registration.base

              {:ok, spec, {registration, name}, declaration}

            _registry_tool ->
              {:error, {:tool_not_local, name}}
          end
      end

    {:reply, result, state}
  end

  def handle_call(:list_skills, _from, state) do
    all = Skills.discover(state.project_root)
    active_names = Enum.map(state.active_skills, & &1.name)
    {:reply, {:ok, all, active_names}, state}
  end

  def handle_call(:new_session, _from, %{prefix_preview: %{}} = state),
    do: {:reply, {:error, :prefix_transition_active}, state}

  def handle_call(:new_session, _from, state) do
    # Gracefully stop any running task and registered workers (see :abort handler comment)
    {execution, task, workers} = ExecutionState.abort(state.execution)
    stop_registered_tool_workers(workers)
    if task, do: Task.shutdown(task, 150)

    state = %{
      state
      | execution: execution,
        session_cost: 0.0,
        prefix_preview: nil
    }

    Log.info(:agent, "[Agent.Native] new session started")

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
    system_prompt =
      state.project_root
      |> system_prompt_parts(state.active_skills, state.selection)
      |> SystemPrompt.text()

    selection = state.selection

    session_state = %{
      model: %{
        id: ModelSelection.id(selection),
        name: selection.route.display_name,
        provider: selection.route.model_provider
      },
      model_selection: selection,
      is_streaming: ExecutionState.active?(state.execution),
      token_usage: nil,
      system_prompt: system_prompt,
      thinking_level: selection.policy.reasoning.effort,
      active_skill_names: Enum.map(state.active_skills, & &1.name),
      project_root: state.project_root,
      mcp_status: mcp_status(state)
    }

    {:reply, {:ok, session_state}, state}
  end

  def handle_call({:set_thinking_level, _level}, _from, %{prefix_preview: %{}} = state),
    do: {:reply, {:error, :prefix_transition_active}, state}

  def handle_call({:set_thinking_level, level}, _from, state) do
    if ExecutionState.request_active?(state.execution) do
      {:reply, {:error, :request_active}, state}
    else
      case ModelSelection.with_reasoning(state.selection, level) do
        {:ok, selection} ->
          Log.info(:agent, "[Agent.Native] thinking level set to #{level}")
          {:reply, :ok, %{state | selection: selection}}

        {:error, message} ->
          {:reply, {:error, message}, state}
      end
    end
  end

  def handle_call(:cycle_thinking_level, _from, %{prefix_preview: %{}} = state),
    do: {:reply, {:error, :prefix_transition_active}, state}

  def handle_call(:cycle_thinking_level, _from, state) do
    if ExecutionState.request_active?(state.execution) do
      {:reply, {:error, :request_active}, state}
    else
      options = state.selection.policy.reasoning.options
      current_effort = state.selection.policy.reasoning.effort
      current_index = Enum.find_index(options, &(&1 == current_effort)) || 0
      next_level = Enum.at(options, rem(current_index + 1, length(options)))
      {:ok, selection} = ModelSelection.with_reasoning(state.selection, next_level)

      Log.info(:agent, "[Agent.Native] thinking level cycled to #{next_level}")
      {:reply, {:ok, %{"level" => next_level}}, %{state | selection: selection}}
    end
  end

  def handle_call(:get_available_models, _from, state) do
    candidates = ModelResolver.candidates(config: state.config, current: state.selection)
    {:reply, {:ok, candidates}, state}
  end

  def handle_call(
        {:compact, _messages},
        _from,
        %{selection: %{policy: %{compaction: :unsupported}}} = state
      ) do
    {:reply, {:error, compaction_unsupported_message(state.selection)}, state}
  end

  def handle_call({:compact, _messages}, _from, state) when state.execution.tag == :active do
    {:reply, {:error, "Cannot compact while streaming"}, state}
  end

  def handle_call({:compact, messages}, _from, state) when is_list(messages) do
    context = Context.new(messages)

    case dispatch_pre_compact(context, state.config) do
      :ok ->
        compact_opts = [
          model: state.selection.request_model,
          context_limit: state.selection.policy.limits.context,
          llm_client: summary_client(state)
        ]

        case Compaction.compact(context, compact_opts) do
          {:compacted, new_context, summary_info} ->
            {:reply, {:ok, new_context.messages, summary_info}, state}

          {:ok, unchanged} ->
            {:reply,
             {:ok, unchanged.messages, "Context is already small enough, no compaction needed."},
             state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:error, _result} ->
        {:reply, {:error, "compaction blocked by hook"}, state}
    end
  end

  def handle_call(
        {:compact, _messages, _opts},
        _from,
        %{selection: %{policy: %{compaction: :unsupported}}} = state
      ) do
    {:reply, {:error, compaction_unsupported_message(state.selection)}, state}
  end

  def handle_call({:compact, _messages, _opts}, _from, state)
      when state.execution.tag == :active do
    {:reply, {:error, "Cannot compact while streaming"}, state}
  end

  def handle_call({:compact, messages, opts}, _from, state)
      when is_list(messages) and is_list(opts) do
    threshold = Keyword.get(opts, :threshold, state.config.compaction_threshold)

    if is_nil(threshold) do
      {:reply, {:ok, messages, "Context compaction is disabled."}, state}
    else
      context = Context.new(messages)

      case dispatch_pre_compact(context, state.config) do
        :ok ->
          compact_opts = [
            model: state.selection.request_model,
            context_limit: state.selection.policy.limits.context,
            llm_client: summary_client(state),
            threshold: threshold,
            keep_recent: Keyword.get(opts, :keep_recent, state.config.compaction_keep_recent)
          ]

          case maybe_compact_with_opts(context, compact_opts) do
            {:compacted, new_context, summary_info} ->
              {:reply, {:ok, new_context.messages, summary_info}, state}

            {:ok, unchanged} ->
              {:reply,
               {:ok, unchanged.messages, "Context is already below the compaction threshold."},
               state}

            {:error, _reason} = error ->
              {:reply, error, state}
          end

        {:error, _result} ->
          {:reply, {:error, "compaction blocked by hook"}, state}
      end
    end
  end

  def handle_call({:set_model, %ModelSelection{}}, _from, %{prefix_preview: %{}} = state),
    do: {:reply, {:error, :prefix_transition_active}, state}

  def handle_call({:set_model, %ModelSelection{} = selection}, _from, state) do
    if ExecutionState.request_active?(state.execution) do
      {:reply, {:error, :request_active}, state}
    else
      route = selection.route

      Log.info(
        :agent,
        "[Agent.Native] model route set to #{route.model_provider}:#{route.model_id} via #{route.execution.wire_protocol}"
      )

      {:reply, :ok, %{state | selection: selection}}
    end
  end

  def handle_call({:set_model, _unresolved}, _from, state) do
    {:reply, {:error, :selection_resolution_required}, state}
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

  def handle_call({:refresh_project_view, view}, _from, %{project_view: view} = state),
    do: {:reply, :ok, state}

  def handle_call({:refresh_project_view, nil}, _from, %{owned_project_view?: true} = state),
    do: {:reply, :ok, state}

  def handle_call({:refresh_project_view, _view}, _from, state)
      when state.execution.tag == :active,
      do: {:reply, {:error, :request_active}, state}

  def handle_call({:refresh_project_view, project_view}, _from, state) do
    case refresh_edit_view(state, project_view) do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_budget, _from, state) do
    budget = %{
      session_cost: state.session_cost,
      max_cost: state.max_cost,
      max_turns: state.max_turns
    }

    {:reply, {:ok, budget}, state}
  end

  def handle_call({:register_tool_workers, worker_pids}, _from, state)
      when is_list(worker_pids) do
    case register_session_effect_workers(state, worker_pids) do
      :ok ->
        Enum.each(worker_pids, &Process.link/1)
        execution = ExecutionState.register_workers(state.execution, worker_pids)
        {:reply, :ok, %{state | execution: execution}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:set_max_cost, amount}, _from, state) when is_number(amount) and amount > 0 do
    Log.info(:agent, "[Agent.Native] cost budget set to $#{Float.round(amount + 0.0, 2)}")
    {:reply, :ok, %{state | max_cost: amount + 0.0}}
  end

  def handle_call({:set_max_cost, nil}, _from, state) do
    Log.info(:agent, "[Agent.Native] cost budget disabled")
    {:reply, :ok, %{state | max_cost: nil}}
  end

  @spec start_agent_turn(state(), Request.t()) :: state()
  defp start_agent_turn(state, request) do
    notify(state.subscriber, request.request_id, %Event.AgentStart{})

    loop_context = %LoopCtx{
      provider_pid: self(),
      request: request,
      history_projection: portable_request_history(request, state.prefix_candidate),
      session_pid: state.subscriber,
      selection: state.selection,
      config: state.config,
      tools: ReqLLMAdapter.advertised_tools(request.prefix),
      project_root: state.project_root,
      project_view: state.project_view,
      fork_store: state.fork_store,
      changeset: state.changeset,
      tool_metadata: state.tool_metadata,
      max_retries: state.max_retries,
      llm_client: state.llm_client,
      hook_runner: state.hook_runner,
      max_turns: state.max_turns,
      max_cost: state.max_cost,
      session_cost: state.session_cost,
      inference_routes: state.inference_routes
    }

    task = Task.async(fn -> run_agent_loop(loop_context, :initial) end)
    execution = ExecutionState.start(state.execution, task, request)
    %{state | execution: execution}
  end

  @spec handle_cast({:discard_prefix_preview, reference(), pid()}, state()) :: {:noreply, state()}
  @impl GenServer
  def handle_cast({:discard_prefix_preview, token, owner}, state) do
    case state.prefix_preview do
      %{token: ^token, owner: ^owner} -> {:noreply, %{state | prefix_preview: nil}}
      _stale -> {:noreply, state}
    end
  end

  @impl GenServer
  def handle_info({:minga_event, :agent_mcp_servers_changed, payload}, state) do
    {:noreply, refresh_mcp_contributions(state, payload)}
  end

  def handle_info({:minga_event, :agent_tools_changed, _payload}, state) do
    case refresh_tool_registry_contributions(state) do
      {:ok, current} -> {:noreply, current}
      {:error, _unavailable} -> {:noreply, state}
    end
  end

  def handle_info({:agent_event, request_id, event}, state) when is_binary(request_id) do
    notify(state.subscriber, request_id, event)
    {:noreply, state}
  end

  def handle_info({:agent_turn_cost, cost}, state) when is_number(cost) do
    {:noreply, %{state | session_cost: state.session_cost + cost}}
  end

  def handle_info({:unregister_tool_workers, worker_pids}, state) when is_list(worker_pids) do
    Enum.each(worker_pids, &Process.unlink/1)
    execution = ExecutionState.unregister_workers(state.execution, worker_pids)
    {:noreply, %{state | execution: execution}}
  end

  def handle_info({ref, :ok}, state) when is_reference(ref) do
    if ref == ExecutionState.task_ref(state.execution) do
      Process.demonitor(ref, [:flush])
      {:noreply, %{state | execution: ExecutionState.complete(state.execution)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    if ref == ExecutionState.task_ref(state.execution) do
      Process.demonitor(ref, [:flush])
      handle_task_error(state, reason)
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, state) when is_pid(pid) do
    cond do
      pid == ExecutionState.task_pid(state.execution) ->
        {:noreply, state}

      pid == state.linked_parent ->
        {:stop, reason, state}

      true ->
        execution = ExecutionState.remove_worker(state.execution, pid)
        {:noreply, %{state | execution: execution}}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, subscriber, reason},
        %{subscriber: subscriber, subscriber_ref: ref} = state
      ) do
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    stop_reason = if reason in [:normal, :shutdown], do: :normal, else: {:session_down, reason}
    {execution, _task, _workers} = ExecutionState.abort(state.execution)
    {:stop, stop_reason, %{state | execution: execution}}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) when is_pid(pid) do
    if pid == ExecutionState.task_pid(state.execution) do
      stop_registered_tool_workers(ExecutionState.workers(state.execution))
      Log.error(:agent, "[Agent.Native] agent task crashed: #{inspect(reason)}")
      notify_active(state, %Event.Error{message: "Agent task crashed: #{inspect(reason)}"})
      notify_active(state, %Event.AgentEnd{usage: nil})
      {:noreply, %{state | execution: ExecutionState.complete(state.execution)}}
    else
      handle_non_task_down(state, pid, reason)
    end
  end

  def handle_info({:mcp_client_down, pid, server_name, reason}, state) when is_pid(pid) do
    case MCPRegistry.server_for_pid(state.mcp_registry, pid) do
      ^server_name ->
        message =
          "MCP server #{server_name} stopped: #{format_error(reason)}. Built-in tools remain available."

        Log.warning(:agent, "[Agent.Native] #{message}")
        notify_lifecycle(state.subscriber, %Event.Error{message: message})
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
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    cleanup_edit_view(state, reason)
    cleanup_mcp(state.mcp_registry)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── Task result dispatch ──────────────────────────────────────────────────

  @spec handle_task_error(state(), term()) :: {:noreply, state()}
  defp handle_task_error(state, :stream_interrupted) do
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    {:noreply, %{state | execution: ExecutionState.interrupt(state.execution)}}
  end

  defp handle_task_error(state, :turn_limit_reached) do
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    {:noreply, %{state | execution: ExecutionState.interrupt(state.execution)}}
  end

  defp handle_task_error(state, :cost_limit_reached) do
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    {:noreply, %{state | execution: ExecutionState.complete(state.execution)}}
  end

  defp handle_task_error(state, {:reported, _reason}) do
    # The agent loop already logged this error and emitted Error + AgentEnd via
    # reported_error/3. Just clean up; re-emitting here would show the error
    # twice in the transcript.
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    {:noreply, %{state | execution: ExecutionState.complete(state.execution)}}
  end

  defp handle_task_error(state, reason) do
    # Safety net: an error reached the Task without the loop reporting it.
    stop_registered_tool_workers(ExecutionState.workers(state.execution))
    formatted = format_error(reason)
    Log.error(:agent, "[Agent.Native] agent loop error: #{formatted}")
    notify_active(state, %Event.Error{message: formatted})
    notify_active(state, %Event.AgentEnd{usage: nil})
    {:noreply, %{state | execution: ExecutionState.complete(state.execution)}}
  end

  @spec handle_non_task_down(state(), pid(), term()) :: {:noreply, state()}
  defp handle_non_task_down(%{fork_store: pid} = state, pid, _reason) when is_pid(pid) do
    Log.warning(
      :agent,
      "[Agent.Native] fork store crashed; file mutations remain unavailable"
    )

    {:noreply, rebuild_tools(%{state | fork_store: nil})}
  end

  defp handle_non_task_down(%{changeset: pid} = state, pid, _reason) when is_pid(pid) do
    Log.warning(
      :agent,
      "[Agent.Native] changeset crashed; file mutations remain unavailable"
    )

    {:noreply, rebuild_tools(%{state | changeset: nil})}
  end

  defp handle_non_task_down(state, pid, reason) do
    case MCPRegistry.server_for_pid(state.mcp_registry, pid) do
      server_name when is_binary(server_name) ->
        message =
          "MCP server #{server_name} crashed: #{format_error(reason)}. Built-in tools remain available."

        Log.warning(:agent, "[Agent.Native] #{message}")
        notify_lifecycle(state.subscriber, %Event.Error{message: message})
        {:noreply, remove_mcp_server_tools(state, server_name)}

      _other ->
        {:noreply, state}
    end
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

  @spec mcp_meta_tools_for([MCPServerConfig.t()], pid()) :: [Tool.t()]
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
  defp format_mcp_source({:bundle, name}), do: "bundle:#{name}"
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

  @spec build_mcp_meta_tools(pid()) :: [Tool.t()]
  defp build_mcp_meta_tools(provider_pid) when is_pid(provider_pid) do
    [
      Tool.new!(
        name: "list_mcp_tools",
        description:
          "List available tools from configured MCP servers on demand. Use this when built-in tools do not cover the capability you need. This starts MCP servers lazily and returns server names, tool names, and short descriptions without adding every MCP tool to the system prompt.",
        parameter_schema: %{"type" => "object", "properties" => %{}},
        callback: fn _args -> GenServer.call(provider_pid, :list_mcp_tools, :infinity) end
      ),
      Tool.new!(
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
            "description" =>
              tool.description |> String.split("\n") |> List.first() |> redacted_mcp_description()
          }
        end)

      {:error, reason} ->
        [%{"server" => server_name, "error" => format_error(reason)}]
    end
  end

  @spec redacted_mcp_description(String.t() | nil) :: String.t()
  defp redacted_mcp_description(nil), do: ""
  defp redacted_mcp_description(description), do: Redaction.redact_string(description)

  @spec redact_mcp_tool_reply({:ok, term()} | {:error, term()}) ::
          {:ok, term()} | {:error, term()}
  defp redact_mcp_tool_reply({:ok, result}), do: {:ok, Redaction.redact_term(result)}
  defp redact_mcp_tool_reply({:error, reason}), do: {:error, Redaction.format_error(reason)}

  @spec call_mcp_tool_for_agent(map(), term(), term(), term()) ::
          {{:ok, term()} | {:error, term()}, map()}
  defp call_mcp_tool_for_agent(state, server_name, tool_name, args)
       when is_binary(server_name) and is_binary(tool_name) and is_map(args) do
    case ensure_mcp_server(state, server_name) do
      {{:ok, client}, state} ->
        {client |> MingaAgent.MCP.Client.call_tool(tool_name, args) |> redact_mcp_tool_reply(),
         state}

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
      state
      |> refresh_base_tools()
      |> filter_base_tools_for_read_only(state.read_only?)

    tools =
      (base_tools ++ state.mcp_tools)
      |> filter_tool_allowlist(state.tool_allowlist)

    %{state | base_tools: base_tools, tools: tools}
  end

  # ── Terminate cleanup ──────────────────────────────────────────────────────

  @spec cleanup_edit_view(state(), term()) :: :ok
  defp cleanup_edit_view(%{owned_project_view?: false}, _reason), do: :ok

  defp cleanup_edit_view(%{project_view: view}, reason) when reason in [:normal, :shutdown] do
    case ProjectView.promote(view, :project_root) do
      :ok ->
        ProjectView.close(view)

      {:conflict, details} ->
        Log.warning(
          :agent,
          "[Agent.Native] preserving editable view after merge conflict: #{inspect(details)}"
        )

      {:error, error} ->
        Log.warning(
          :agent,
          "[Agent.Native] preserving editable view after publication failure: #{inspect(error)}"
        )
    end

    :ok
  end

  defp cleanup_edit_view(%{project_view: view}, _reason) do
    case ProjectView.discard(view) do
      :ok ->
        ProjectView.close(view)

      {:error, error} ->
        Log.warning(:agent, "[Agent.Native] editable view cleanup failed: #{inspect(error)}")
    end

    :ok
  end

  @spec refresh_edit_view(state(), ProjectView.t() | nil) :: {:ok, state()} | {:error, term()}
  defp refresh_edit_view(%{owned_project_view?: true} = state, nil), do: {:ok, state}
  defp refresh_edit_view(%{project_view: view} = state, view), do: {:ok, state}

  defp refresh_edit_view(state, nil) do
    {view, fork_store, changeset} = init_edit_view(nil, state.project_root)

    install_refreshed_view(%{
      state
      | project_view: view,
        owned_project_view?: true,
        fork_store: fork_store,
        changeset: changeset
    })
  end

  defp refresh_edit_view(state, view) do
    with :ok <- release_owned_edit_view(state) do
      install_refreshed_view(%{
        state
        | project_view: view,
          owned_project_view?: false,
          fork_store: nil,
          changeset: nil
      })
    end
  end

  @spec install_refreshed_view(state()) :: {:ok, state()}
  defp install_refreshed_view(state) do
    base_tools =
      state
      |> refresh_base_tools()
      |> filter_base_tools_for_read_only(state.read_only?)

    tools =
      (base_tools ++ state.mcp_tools)
      |> filter_tool_allowlist(state.tool_allowlist)

    {:ok, %{state | base_tools: base_tools, tools: tools}}
  end

  @spec release_owned_edit_view(state()) :: :ok | {:error, term()}
  defp release_owned_edit_view(%{owned_project_view?: false}), do: :ok
  defp release_owned_edit_view(%{project_view: view}), do: ProjectView.close(view)

  @spec cleanup_mcp(MCPRegistry.t() | nil) :: :ok
  defp cleanup_mcp(registry), do: MCPRegistry.stop_all(registry)

  # ── Agent turn loop (runs in a Task) ────────────────────────────────────────

  @spec run_agent_loop(loop_ctx(), Dispatch.source()) :: :ok | {:error, term()}
  defp run_agent_loop(lctx, source) do
    case check_safety_limits(lctx) do
      :ok ->
        do_agent_loop(lctx, source)

      {:turn_limit, message} ->
        emit(lctx, %Event.TextDelta{delta: "\n\n⚠️ #{message}"})
        emit(lctx, %Event.TurnLimitReached{current: lctx.turn_count, limit: lctx.max_turns})
        emit(lctx, %Event.AgentEnd{usage: nil})
        {:error, :turn_limit_reached}

      {:cost_limit, message} ->
        emit(lctx, %Event.TextDelta{delta: "\n\n⚠️ #{message}"})
        emit(lctx, %Event.AgentEnd{usage: nil})
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

  @spec do_agent_loop(loop_ctx(), Dispatch.source()) :: :ok | {:error, term()}
  defp do_agent_loop(lctx, source) do
    case ReqLLMAdapter.validate_selection(lctx.selection) do
      :ok -> do_agent_loop_validated(lctx, source)
      {:error, message, reason} -> reported_error(lctx, message, reason)
    end
  end

  @spec do_agent_loop_validated(loop_ctx(), Dispatch.source()) :: :ok | {:error, term()}
  defp do_agent_loop_validated(lctx, source) do
    execute_stream_request(lctx, source)
  rescue
    e ->
      reported_error(lctx, Exception.message(e), e)
  catch
    :exit, reason ->
      reported_error(lctx, inspect(reason), reason)
  end

  @spec execute_stream_request(loop_ctx(), Dispatch.source()) :: :ok | {:error, term()}
  defp execute_stream_request(lctx, source) do
    on_retry = fn attempt, delay_ms, reason ->
      delay_s = Float.round(delay_ms / 1000, 1)

      emit(lctx, %Event.TextDelta{
        delta:
          "\n⏳ #{reason} — retrying in #{delay_s}s (attempt #{attempt}/#{lctx.max_retries})...\n"
      })
    end

    result =
      Retry.with_retry(
        fn -> dispatch_stream(lctx, source) end,
        max_retries: lctx.max_retries,
        on_retry: on_retry
      )

    case result do
      {:ok, {context, stream_response}} ->
        process_and_continue(lctx, context, stream_response)

      {:error, {:artifact_integrity_error, reason} = error} ->
        reported_error(
          lctx,
          "Retained image integrity check failed: #{inspect(reason)}",
          error
        )

      {:error, {:outbound_history_invalid, reason} = error} ->
        reported_error(
          lctx,
          "Conversation history cannot be sent to this model: #{inspect(reason)}",
          error
        )

      {:error, reason} ->
        reported_error(lctx, format_error(reason), reason)
    end
  end

  @spec dispatch_stream(loop_ctx(), Dispatch.source()) ::
          {:ok, {Context.t(), ReqLLM.StreamResponse.t()}} | {:error, term()}
  defp dispatch_stream(lctx, source) do
    with {:ok, attempt, canonical_messages} <- begin_native_dispatch(lctx, source),
         {:ok, messages} <- prepare_outbound_messages(lctx, canonical_messages),
         {:ok, auth_opts} <-
           GenServer.call(
             lctx.provider_pid,
             {:dispatch_auth, lctx.request.prefix, lctx.turn_count > 0}
           ),
         {:ok, stream_opts} <-
           ReqLLMAdapter.stream_opts(
             lctx.selection,
             lctx.tools,
             lctx.config,
             auth_opts
           ),
         context = Context.new(canonical_messages),
         :ok <- emit_context_usage(lctx, context),
         stream_opts = prepared_stream_opts(lctx, attempt, stream_opts),
         {:ok, stream_response} <-
           ReqLLMAdapter.stream(
             lctx.llm_client,
             lctx.selection.request_model,
             messages,
             stream_opts
           ) do
      {:ok, {context, stream_response}}
    end
  end

  @spec begin_native_dispatch(loop_ctx(), Dispatch.source()) ::
          {:ok, Dispatch.t(), [ReqLLM.Message.t()]} | {:error, term()}
  defp begin_native_dispatch(lctx, source) do
    GenServer.call(
      lctx.session_pid,
      {:begin_native_dispatch, lctx.request.request_id, source},
      30_000
    )
  catch
    :exit, _reason -> {:error, {:request_admission_refused, :session_unavailable}}
  end

  @spec prepare_outbound_messages(loop_ctx(), [ReqLLM.Message.t()]) ::
          {:ok, [ReqLLM.Message.t()]} | {:error, term()}
  defp prepare_outbound_messages(lctx, canonical_messages) do
    case outbound_messages(lctx, canonical_messages) do
      {:ok, messages} -> {:ok, messages}
      {:error, {:artifact_integrity_error, _reason}} = error -> error
      {:error, reason} -> {:error, {:outbound_history_invalid, reason}}
    end
  end

  @spec prepared_stream_opts(loop_ctx(), Dispatch.t(), keyword()) :: keyword()
  defp prepared_stream_opts(
         %{selection: %{route: %{request_provider: :apple}}} = lctx,
         attempt,
         opts
       ) do
    limits = lctx.selection.policy.limits

    admission = fn digest, tokens, prefix, cap, context ->
      measurement = {:provider_count, tokens, prefix}
      evidence = RequestCapacity.assess(limits, measurement, {:encoded, cap}, context)

      authorize_prepared_dispatch(lctx.session_pid, attempt, digest, evidence)
    end

    opts |> Keyword.delete(:cache) |> Keyword.put(:apple_admission, admission)
  end

  # A contributed route receives its registry and the Session-owned identity of this exact dispatch.
  defp prepared_stream_opts(
         %{selection: %{route: %{request_provider: :contributed}}} = lctx,
         attempt,
         opts
       ) do
    # validate_request_capabilities/2 admits only epoch-matched requests, so this identity is complete.
    {:ok, conversation} =
      ConversationRef.new(
        session_id: session_id(lctx.session_pid),
        owner: lctx.session_pid,
        epoch_id: attempt.epoch_id,
        conversation_revision: attempt.revision,
        request_id: attempt.request_id,
        purpose: :turn
      )

    opts
    |> Keyword.put(:minga_conversation, conversation)
    |> Keyword.put(:minga_reasoning, lctx.selection.policy.reasoning.effort)
    |> Keyword.put(:inference_routes, lctx.inference_routes)
  end

  defp prepared_stream_opts(_lctx, _attempt, opts), do: opts

  @spec session_id(pid()) :: String.t() | nil
  defp session_id(session) when is_pid(session) do
    Session.session_id(session)
  catch
    :exit, _reason -> nil
  end

  @spec authorize_prepared_dispatch(pid(), Dispatch.t(), binary(), RequestCapacity.t()) ::
          :ok | {:error, term()}
  defp authorize_prepared_dispatch(session, attempt, digest, evidence) do
    GenServer.call(session, {:assess_native_dispatch, attempt, digest, evidence}, 30_000)
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  @spec outbound_messages(loop_ctx(), [ReqLLM.Message.t()]) ::
          {:ok, [ReqLLM.Message.t()]} | {:error, term()}
  defp outbound_messages(lctx, messages) do
    with {:ok, messages} <- project_request_history(lctx.history_projection, messages) do
      delivery = ModelSelection.image_tool_result_delivery(lctx.selection)

      case project_outbound_messages(lctx, messages, delivery, nil) do
        :unchanged -> {:ok, messages}
        result -> result
      end
    end
  end

  @spec portable_request_history(Request.t(), Prefix.t() | :unknown) ::
          :unchanged | {:ok, non_neg_integer(), [ReqLLM.Message.t()]} | {:error, term()}
  defp portable_request_history(%Request{messages: messages}, %Prefix{
         identity: %{native_contract: :unknown}
       }) do
    retained_count = length(messages) - 1

    case PortableHistory.convert(Enum.take(messages, retained_count), :retain) do
      {:ok, portable, _counts} -> {:ok, retained_count, portable}
      {:error, reason} -> {:error, {:portable_history_incompatible, reason}}
    end
  end

  defp portable_request_history(_request, _current_prefix), do: :unchanged

  @spec project_request_history(term(), [ReqLLM.Message.t()]) ::
          {:ok, [ReqLLM.Message.t()]} | {:error, term()}
  defp project_request_history(:unchanged, messages), do: {:ok, messages}

  defp project_request_history({:ok, count, portable}, messages),
    do: {:ok, Enum.concat(portable, Enum.drop(messages, count))}

  defp project_request_history({:error, _reason} = error, _messages), do: error

  @spec project_outbound_messages(
          loop_ctx(),
          [ReqLLM.Message.t()],
          ModelSelection.image_tool_result_delivery(),
          ArtifactStore.server() | nil
        ) :: :unchanged | {:ok, [ReqLLM.Message.t()]} | {:error, OutputHydration.error_reason()}
  defp project_outbound_messages(_lctx, [], _delivery, _store), do: :unchanged

  defp project_outbound_messages(lctx, [message | rest], delivery, store) do
    with {:ok, store} <- outbound_artifact_store(lctx, message, delivery, store),
         {:ok, hydrated} <- OutputHydration.hydrate(message, store, delivery) do
      projected = ReqLLMAdapter.request_message(hydrated)

      case project_outbound_messages(lctx, rest, delivery, store) do
        :unchanged when projected === message -> :unchanged
        :unchanged -> {:ok, [projected | rest]}
        {:ok, projected_rest} -> {:ok, [projected | projected_rest]}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec outbound_artifact_store(
          loop_ctx(),
          ReqLLM.Message.t(),
          ModelSelection.image_tool_result_delivery(),
          ArtifactStore.server() | nil
        ) :: {:ok, ArtifactStore.server() | nil} | {:error, OutputHydration.error_reason()}
  defp outbound_artifact_store(lctx, message, :supported, nil) do
    if OutputHydration.required?(message) do
      case Session.artifact_store(lctx.session_pid) do
        {:ok, store} -> {:ok, store}
        {:error, reason} -> {:error, {:artifact_integrity_error, reason}}
      end
    else
      {:ok, nil}
    end
  end

  defp outbound_artifact_store(_lctx, _message, _delivery, store), do: {:ok, store}

  # Processes a stream response and decides whether to continue (tool calls) or finish.
  @spec process_and_continue(loop_ctx(), Context.t(), ReqLLM.StreamResponse.t()) ::
          :ok | {:error, term()}
  defp process_and_continue(lctx, context, stream_response) do
    callbacks = [
      on_text: fn text ->
        emit(lctx, %Event.TextDelta{delta: text})
      end,
      on_thinking: fn text ->
        emit(lctx, %Event.ThinkingDelta{delta: text})
      end
    ]

    case ReqLLMAdapter.process_stream(stream_response, callbacks) do
      {:ok, %ReqLLMAdapter.TurnResult{} = turn_result} ->
        dispatch_result(lctx, context, turn_result)

      {:error, reason, partial_text} ->
        handle_stream_error(lctx, partial_text, reason)
    end
  end

  # Streamed text is already projected to the user. Do not append an incomplete
  # assistant response to the model context as if it were a completed turn.
  @spec handle_stream_error(loop_ctx(), String.t(), term()) :: {:error, term()}
  defp handle_stream_error(lctx, _partial_text, {:incomplete_response, finish_reason}) do
    emit(lctx, %Event.TextDelta{
      delta:
        "\n\nProvider response incomplete (#{inspect(finish_reason)}). " <>
          "No assistant turn was added. Use /continue to resume."
    })

    emit(lctx, %Event.AgentEnd{usage: nil})
    {:error, :stream_interrupted}
  end

  defp handle_stream_error(
         lctx,
         partial_text,
         %ReqLLM.Error.API.Stream{cause: {:request_admission_refused, _reason} = refusal}
       ),
       do: handle_stream_error(lctx, partial_text, refusal)

  defp handle_stream_error(lctx, partial_text, reason) do
    if partial_text != "" and String.length(partial_text) > 10 do
      emit(lctx, %Event.TextDelta{
        delta:
          "\n\n⚠️ Stream interrupted: #{format_error(reason)}. " <>
            "Partial response preserved. Use /continue to resume."
      })

      emit(lctx, %Event.AgentEnd{usage: nil})
      {:error, :stream_interrupted}
    else
      reported_error(lctx, format_error(reason), reason)
    end
  end

  @spec dispatch_result(loop_ctx(), Context.t(), ReqLLMAdapter.turn_result()) ::
          :ok | {:error, term()}
  defp dispatch_result(
         lctx,
         context,
         %ReqLLMAdapter.TurnResult{
           message: assistant_message,
           tool_calls: [],
           usage: usage
         }
       ) do
    updated_context = Context.append(context, assistant_message)
    normalized = normalize_usage(usage, lctx.selection)
    report_turn_cost(lctx, normalized)
    outcome = Outcome.new(lctx.request, updated_context.messages)
    emit(lctx, %Event.AgentEnd{usage: normalized, outcome: outcome})
    :ok
  end

  defp dispatch_result(
         lctx,
         context,
         %ReqLLMAdapter.TurnResult{
           message: assistant_message,
           tool_calls: tool_calls,
           usage: usage
         }
       ) do
    updated_context = Context.append(context, assistant_message)
    normalized = normalize_usage(usage, lctx.selection)
    turn_cost = turn_cost_from_usage(normalized)
    report_turn_cost(lctx, normalized)

    with {:ok, checkpoint_id} <-
           checkpoint_tool_group(lctx, updated_context.messages, tool_calls),
         :ok <- emit_tool_starts(lctx, tool_calls),
         :ok <- execute_tools(lctx, checkpoint_id, tool_calls) do
      lctx = %{
        lctx
        | turn_count: lctx.turn_count + 1,
          session_cost: lctx.session_cost + turn_cost
      }

      run_agent_loop(lctx, {:checkpoint, checkpoint_id})
    else
      {:error, reason} ->
        reported_error(lctx, "Durable tool execution failed: #{inspect(reason)}", reason)
    end
  end

  @spec emit_tool_starts(loop_ctx(), [ReqLLMAdapter.tool_call()]) :: :ok
  defp emit_tool_starts(lctx, tool_calls) do
    Enum.each(tool_calls, fn tool_call ->
      emit(lctx, %Event.ToolStart{
        tool_call_id: tool_call.id,
        name: tool_call.name,
        args: tool_call.arguments || %{}
      })
    end)

    :ok
  end

  @spec checkpoint_tool_group(loop_ctx(), [ReqLLM.Message.t()], [ReqLLMAdapter.ToolCall.t()]) ::
          {:ok, String.t()} | {:error, term()}
  defp checkpoint_tool_group(lctx, messages, tool_calls) when is_pid(lctx.session_pid) do
    calls =
      Enum.map(tool_calls, fn tool_call ->
        %{
          tool_call_id: to_string(tool_call.id),
          name: tool_call.name,
          arguments: tool_call.arguments || %{}
        }
      end)

    GenServer.call(
      lctx.session_pid,
      {:checkpoint_tool_group, lctx.request.request_id, messages, calls},
      30_000
    )
  catch
    :exit, reason -> {:error, {:checkpoint_call_failed, reason}}
  end

  defp checkpoint_tool_group(_lctx, _messages, _tool_calls),
    do: {:error, :missing_session_checkpoint_owner}

  # Maximum concurrent read-only tool tasks.
  @max_concurrent_reads 8
  # Per-tool-call timeout in milliseconds (5 minutes).
  @tool_call_timeout_ms 300_000

  @spec execute_tools(
          loop_ctx(),
          String.t(),
          [ReqLLMAdapter.ToolCall.t()]
        ) ::
          :ok | {:error, term()}
  defp execute_tools(lctx, checkpoint_id, tool_calls) do
    initial_mode = approval_mode(lctx.config)
    indexed_calls = Enum.with_index(tool_calls)

    # Approval-gated calls need user interaction and are sequential relative
    # to each other. Everything else uses effect-aware grouping (consecutive
    # reads concurrent, mutating calls sequential). Both pipelines run in
    # parallel so allowed tools start while approval is pending.
    {approval_calls, effect_calls} =
      Enum.split_with(indexed_calls, fn {tool_call, _index} ->
        tool_call.name == "ask_user" or
          tool_requires_approval?(tool_call, lctx, initial_mode)
      end)

    runs = group_by_effect(effect_calls, lctx, initial_mode)

    effect_task =
      if runs != [] do
        Task.async(fn -> execute_effect_runs(lctx, checkpoint_id, runs, []) end)
      end

    try do
      approval_result = execute_approval_calls(lctx, checkpoint_id, approval_calls)

      with {:ok, _} <- approval_result do
        if effect_task do
          Task.await(effect_task, :infinity)
        else
          :ok
        end
      end
    after
      if effect_task, do: Task.shutdown(effect_task, :brutal_kill)
    end
  end

  @spec execute_approval_calls(loop_ctx(), String.t(), [indexed_tool_call()]) ::
          {:ok, [{non_neg_integer(), tool_execution_result()}]} | {:error, term()}
  defp execute_approval_calls(_lctx, _checkpoint_id, []), do: {:ok, []}

  defp execute_approval_calls(lctx, checkpoint_id, calls) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, results} ->
      case execute_sequential_tool_task(lctx, checkpoint_id, call) do
        {_index, %{persistence_error: reason}} -> {:halt, {:error, reason}}
        result -> {:cont, {:ok, [result | results]}}
      end
    end)
  end

  @typep effect_run ::
           {:concurrent, [indexed_tool_call()]}
           | {:sequential, indexed_tool_call()}

  @spec group_by_effect([indexed_tool_call()], loop_ctx(), approval_mode()) :: [effect_run()]
  defp group_by_effect(indexed_calls, lctx, initial_mode) do
    indexed_calls
    |> Enum.reduce([], fn {tool_call, _index} = indexed, acc ->
      if tool_call_sequential?(tool_call, lctx, initial_mode) do
        [{:sequential, indexed} | acc]
      else
        case acc do
          [{:concurrent, batch} | rest] -> [{:concurrent, [indexed | batch]} | rest]
          _other -> [{:concurrent, [indexed]} | acc]
        end
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn
      {:concurrent, batch} -> {:concurrent, Enum.reverse(batch)}
      {:sequential, _call} = run -> run
    end)
  end

  @spec tool_call_sequential?(ReqLLMAdapter.ToolCall.t(), loop_ctx(), approval_mode()) ::
          boolean()
  defp tool_call_sequential?(tool_call, lctx, initial_mode) do
    tool_call.name == "ask_user" or
      tool_requires_approval?(tool_call, lctx, initial_mode) or
      tool_effect_sequential?(tool_call.name, lctx)
  end

  @spec tool_effect_sequential?(String.t(), loop_ctx()) :: boolean()
  defp tool_effect_sequential?(tool_name, lctx) do
    registry = Map.get(lctx.tool_metadata, :tool_registry, ToolRegistry)

    case ToolRegistry.lookup(registry, tool_name) do
      {:ok, %ToolSpec{} = spec} -> ToolSpec.sequential?(spec)
      :error -> false
    end
  end

  @spec execute_effect_runs(
          loop_ctx(),
          String.t(),
          [effect_run()],
          [{non_neg_integer(), tool_execution_result()}]
        ) :: :ok | {:error, term()}
  defp execute_effect_runs(_lctx, _checkpoint_id, [], results) do
    case Enum.find(results, fn {_index, result} -> Map.has_key?(result, :persistence_error) end) do
      nil -> :ok
      {_index, result} -> {:error, result.persistence_error}
    end
  end

  defp execute_effect_runs(lctx, checkpoint_id, [{:concurrent, batch} | rest], results) do
    # Cap the batch to @max_concurrent_reads parallel workers.
    batch_results = execute_concurrent_batch(lctx, checkpoint_id, batch)

    case Enum.find(batch_results, fn {_i, r} -> Map.has_key?(r, :persistence_error) end) do
      nil -> execute_effect_runs(lctx, checkpoint_id, rest, results ++ batch_results)
      {_index, result} -> {:error, result.persistence_error}
    end
  end

  defp execute_effect_runs(lctx, checkpoint_id, [{:sequential, call} | rest], results) do
    result = execute_sequential_tool_task(lctx, checkpoint_id, call)

    case result do
      {_index, %{persistence_error: reason}} -> {:error, reason}
      _ -> execute_effect_runs(lctx, checkpoint_id, rest, [result | results])
    end
  end

  @spec execute_concurrent_batch(loop_ctx(), String.t(), [indexed_tool_call()]) ::
          [{non_neg_integer(), tool_execution_result()}]
  defp execute_concurrent_batch(lctx, checkpoint_id, batch) do
    # Chunk into sub-batches of @max_concurrent_reads to enforce the concurrency
    # limit while keeping model order within each chunk.
    batch
    |> Enum.chunk_every(@max_concurrent_reads)
    |> Enum.flat_map(fn chunk ->
      tasks = start_concurrent_tool_tasks(lctx, checkpoint_id, chunk)

      try do
        await_concurrent_tool_tasks(lctx, tasks)
      after
        cleanup_concurrent_tool_tasks(lctx.provider_pid, tasks)
      end
    end)
  end

  @spec execute_sequential_tool_task(loop_ctx(), String.t(), indexed_tool_call()) ::
          {non_neg_integer(), tool_execution_result()}
  defp execute_sequential_tool_task(lctx, checkpoint_id, call) do
    tasks = start_concurrent_tool_tasks(lctx, checkpoint_id, [call])

    try do
      [result] = await_concurrent_tool_tasks(lctx, tasks)
      result
    after
      cleanup_concurrent_tool_tasks(lctx.provider_pid, tasks)
    end
  end

  @typep approval_mode :: :none | :ask | :ask_all
  @typep indexed_tool_call :: {ReqLLMAdapter.ToolCall.t(), non_neg_integer()}
  @typep unstarted_tool_task ::
           {non_neg_integer(), map(), pid(), reference(), reference(), reference()}
  @typep tool_task :: {non_neg_integer(), map(), pid(), reference(), reference()}
  @typep tool_execution_result :: %{
           required(:tool_call) => map(),
           required(:result_text) => String.t(),
           required(:output) => Output.t(),
           required(:is_error) => boolean(),
           optional(:outcome) => MingaAgent.ToolCall.outcome(),
           optional(:reason) => MingaAgent.ToolCall.terminal_reason(),
           optional(:mutation) => MingaAgent.Tool.FileMutationResult.t() | nil,
           optional(:persistence_error) => term()
         }

  @typep formatted_tool_result ::
           {String.t(), MingaAgent.ToolCall.outcome(), MingaAgent.ToolCall.terminal_reason(),
            boolean(), Output.t() | nil}
  @typep approved_tool_result ::
           formatted_tool_result()
           | {formatted_tool_result(), MingaAgent.Tool.FileMutationResult.t()}

  @spec start_concurrent_tool_tasks(
          loop_ctx(),
          String.t(),
          [indexed_tool_call()]
        ) :: [tool_task()]
  defp start_concurrent_tool_tasks(
         lctx,
         checkpoint_id,
         calls
       ) do
    parent = self()

    tasks =
      Enum.map(calls, fn {tool_call, index} ->
        result_ref = make_ref()
        start_ref = make_ref()

        pid =
          spawn_link(fn ->
            receive do
              {^start_ref, :run} ->
                result = execute_tool_call(lctx, checkpoint_id, tool_call)

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

  @spec await_concurrent_tool_tasks(loop_ctx(), [tool_task()]) :: [
          {non_neg_integer(), tool_execution_result()}
        ]
  defp await_concurrent_tool_tasks(lctx, tasks) do
    Enum.map(tasks, fn {index, tool_call, _pid, monitor_ref, result_ref} ->
      {index, await_tool_process(lctx, tool_call, monitor_ref, result_ref)}
    end)
  end

  @spec register_session_effect_workers(state(), [pid()]) :: :ok | {:error, term()}
  defp register_session_effect_workers(%{session_manager: nil}, _worker_pids), do: :ok

  defp register_session_effect_workers(state, worker_pids) do
    MingaAgent.SessionManager.register_effect_workers(
      state.session_manager,
      state.subscriber,
      self(),
      worker_pids
    )
  catch
    :exit, reason -> {:error, {:session_manager_unavailable, reason}}
  end

  @spec register_tool_workers(pid(), [unstarted_tool_task()]) :: :ok | {:error, term()}
  defp register_tool_workers(provider_pid, tasks) do
    worker_pids =
      Enum.map(tasks, fn {_index, _tool_call, pid, _monitor_ref, _result_ref, _start_ref} ->
        pid
      end)

    GenServer.call(provider_pid, {:register_tool_workers, worker_pids})
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec cleanup_unstarted_tool_tasks(pid(), [unstarted_tool_task()]) :: :ok
  defp cleanup_unstarted_tool_tasks(provider_pid, tasks) do
    worker_pids =
      Enum.map(tasks, fn {_index, _tool_call, pid, monitor_ref, _result_ref, _start_ref} ->
        Process.unlink(pid)
        Process.demonitor(monitor_ref, [:flush])
        stop_tool_worker(pid)
        pid
      end)

    unregister_tool_workers(provider_pid, worker_pids)
    :ok
  end

  @spec cleanup_concurrent_tool_tasks(pid(), [tool_task()]) :: :ok
  defp cleanup_concurrent_tool_tasks(provider_pid, tasks) do
    worker_pids =
      Enum.map(tasks, fn {_index, _tool_call, pid, monitor_ref, _result_ref} ->
        Process.unlink(pid)
        Process.demonitor(monitor_ref, [:flush])
        stop_tool_worker(pid)
        pid
      end)

    unregister_tool_workers(provider_pid, worker_pids)
    :ok
  end

  @spec unregister_tool_workers(pid(), [pid()]) :: :ok
  defp unregister_tool_workers(_provider_pid, []), do: :ok

  defp unregister_tool_workers(provider_pid, worker_pids) do
    send(provider_pid, {:unregister_tool_workers, worker_pids})
    :ok
  end

  @spec stop_registered_tool_workers(MapSet.t(pid())) :: :ok
  defp stop_registered_tool_workers(tool_workers) do
    monitors =
      Enum.map(tool_workers, fn pid ->
        Process.unlink(pid)
        {pid, Process.monitor(pid)}
      end)

    Enum.each(monitors, fn {pid, _ref} -> Process.exit(pid, :kill) end)

    Enum.each(monitors, fn {pid, ref} ->
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      end
    end)

    :ok
  end

  @spec linked_parent_pid() :: pid() | nil
  defp linked_parent_pid do
    case Process.get(:"$ancestors") do
      [pid | _ancestors] when is_pid(pid) -> pid
      [name | _ancestors] when is_atom(name) -> Process.whereis(name)
      _ancestors -> nil
    end
  end

  @spec stop_tool_worker(pid()) :: :ok
  defp stop_tool_worker(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :kill)
    end

    :ok
  end

  @spec await_tool_process(loop_ctx(), map(), reference(), reference()) :: tool_execution_result()
  defp await_tool_process(lctx, tool_call, monitor_ref, result_ref) do
    receive do
      {^result_ref, :tool_result, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, _pid, reason} ->
        receive_tool_result_after_down(lctx, tool_call, result_ref, reason)
    after
      @tool_call_timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        tool_task_failed(lctx, tool_call, :timeout)
    end
  end

  @spec receive_tool_result_after_down(loop_ctx(), map(), reference(), term()) ::
          tool_execution_result()
  defp receive_tool_result_after_down(lctx, tool_call, result_ref, reason) do
    receive do
      {^result_ref, :tool_result, result} ->
        result
    after
      0 ->
        tool_task_failed(lctx, tool_call, reason)
    end
  end

  @spec tool_task_failed(loop_ctx(), map(), term()) :: tool_execution_result()
  defp tool_task_failed(_lctx, tool_call, reason) do
    result_text =
      "Tool task failed before its terminal outcome could be persisted: #{inspect(reason)}"

    %{
      tool_call: tool_call,
      result_text: result_text,
      output: deterministic_output(result_text),
      is_error: true,
      persistence_error: {:tool_task_exit, reason}
    }
  end

  @spec execute_tool_call(
          loop_ctx(),
          String.t(),
          map()
        ) :: tool_execution_result()
  defp execute_tool_call(lctx, checkpoint_id, tool_call) do
    tool_call = Map.put(tool_call, :effect_checkpoint_id, checkpoint_id)

    result =
      try do
        tool_context =
          native_tool_context(
            lctx.project_root,
            lctx.project_view,
            lctx.fork_store,
            lctx.changeset,
            lctx.tool_metadata,
            ModelSelection.image_tool_result_delivery(lctx.selection)
          )

        execution = execute_with_approval(lctx, tool_call, tool_context)

        {{result_text, outcome, reason, post_dispatched?, output}, mutation} =
          case execution do
            {formatted, %MingaAgent.Tool.FileMutationResult{} = receipt} -> {formatted, receipt}
            formatted -> {formatted, nil}
          end

        output = output || deterministic_output(result_text)
        is_error = outcome != :complete

        unless post_dispatched? do
          dispatch_post_tool_use(tool_call, result_text, is_error, output, lctx.config)
        end

        %{
          tool_call: tool_call,
          result_text: result_text,
          output: output,
          is_error: is_error,
          mutation: mutation,
          outcome: outcome,
          reason: reason
        }
      rescue
        e ->
          result_text = "Tool '#{tool_call.name}' failed after admission; outcome is unknown."

          %{
            tool_call: tool_call,
            result_text: result_text,
            output: deterministic_output(result_text),
            is_error: true,
            persistence_error: {:tool_execution_exception, Exception.message(e)}
          }
      catch
        :throw, {:effect_admission_failed, reason} ->
          result_text = "Tool admission failed: #{inspect(reason)}"

          %{
            tool_call: tool_call,
            result_text: result_text,
            output: deterministic_output(result_text),
            is_error: true,
            persistence_error: {:effect_admission_failed, reason}
          }

        :throw, {:tool_storage_failed, reason} ->
          result_text = "Tool storage failed: #{inspect(reason)}"

          %{
            tool_call: tool_call,
            result_text: result_text,
            output: deterministic_output(result_text),
            is_error: true,
            persistence_error: {:tool_storage_failed, reason}
          }

        kind, reason ->
          result_text = "Tool '#{tool_call.name}' failed after admission; outcome is unknown."

          %{
            tool_call: tool_call,
            result_text: result_text,
            output: deterministic_output(result_text),
            is_error: true,
            persistence_error: {:tool_execution_throw, kind, inspect(reason)}
          }
      end

    case result do
      %{persistence_error: _reason} ->
        result

      %{tool_call: tool_call} ->
        {store, change} =
          capture_file_change(lctx, checkpoint_id, tool_call, Map.get(result, :mutation))

        message = tool_result_message(result)

        completion =
          {:complete_tool_effect, lctx.request.request_id, checkpoint_id, to_string(tool_call.id),
           message, change}

        case persist_tool_execution_result(lctx, completion, 3) do
          :ok ->
            emit_receipt_preview(lctx, tool_call, Map.get(result, :mutation))
            emit_tool_end(lctx, tool_call, result)
            result

          {:error, {:tool_outcome_call_failed, _reason} = reason} ->
            Map.put(result, :persistence_error, reason)

          {:error, reason} ->
            MingaAgent.Session.FileChange.release_delivery(store, change)
            Map.put(result, :persistence_error, reason)
        end
    end
  end

  @spec capture_file_change(
          loop_ctx(),
          String.t(),
          map(),
          MingaAgent.Tool.FileMutationResult.t() | nil
        ) ::
          {GenServer.server() | nil, MingaAgent.Session.FileChange.t() | nil}
  defp capture_file_change(_lctx, _checkpoint, _tool_call, nil), do: {nil, nil}

  defp capture_file_change(lctx, checkpoint, tool_call, mutation) do
    store =
      case Session.artifact_store(lctx.session_pid) do
        {:ok, store} -> store
        {:error, _reason} -> nil
      end

    identity = {lctx.request.request_id, checkpoint, to_string(tool_call.id)}
    {store, MingaAgent.Session.FileChange.capture(store, identity, mutation)}
  end

  @spec persist_tool_execution_result(loop_ctx(), tuple(), pos_integer()) ::
          :ok | {:error, term()}
  defp persist_tool_execution_result(lctx, completion, attempts_left) do
    response = GenServer.call(lctx.session_pid, completion, 30_000)

    case response do
      :ok ->
        :ok

      {:error, _reason} when attempts_left > 1 ->
        persist_tool_execution_result(lctx, completion, attempts_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _reason when attempts_left > 1 ->
      persist_tool_execution_result(lctx, completion, attempts_left - 1)

    :exit, reason ->
      {:error, {:tool_outcome_call_failed, reason}}
  end

  @spec emit_tool_end(loop_ctx(), map(), tool_execution_result()) :: :ok
  defp emit_tool_end(lctx, tool_call, result) do
    emit(lctx, %Event.ToolEnd{
      tool_call_id: tool_call.id,
      name: tool_call.name,
      result: result.result_text,
      output: result.output,
      outcome: result.outcome,
      reason: result.reason,
      is_error: result.outcome != :complete
    })
  end

  @spec tool_result_message(tool_execution_result()) :: ReqLLM.Message.t()
  defp tool_result_message(%{
         tool_call: tool_call,
         result_text: result_text,
         output: output,
         outcome: outcome,
         reason: reason
       }) do
    meta = %{is_error: outcome != :complete, output: output, tool_outcome: outcome}
    meta = tool_result_reason(meta, reason)
    Context.tool_result_message(tool_call.name, tool_call.id, result_text, meta)
  end

  defp tool_result_reason(meta, nil), do: meta

  defp tool_result_reason(meta, :approval_timeout),
    do: Map.put(meta, :tool_outcome_reason, :approval_timeout)

  @spec execute_with_approval(
          loop_ctx(),
          map(),
          ToolContext.t()
        ) :: approved_tool_result()
  defp execute_with_approval(lctx, tool_call, tool_context) do
    invocation = Invocation.new(lctx.request, tool_call.effect_checkpoint_id, tool_call)

    case GenServer.call(lctx.session_pid, {:prepare_tool_invocation, invocation}) do
      {:ok, :ready} -> execute_live_tool(lctx, tool_call, invocation, tool_context)
      {:ok, :approval_required} -> request_approval(lctx, tool_call, invocation, tool_context)
      {:refused, reason} -> {"Tool refused: #{inspect(reason)}", :denied, nil, false, nil}
      {:error, reason} -> throw({:effect_admission_failed, reason})
    end
  end

  # Scheduling hints only. Session re-reads authoritative policy after all waits.
  @spec tool_requires_approval?(map(), loop_ctx(), approval_mode()) :: boolean()
  defp tool_requires_approval?(tool_call, lctx, mode) do
    case tool_permission(tool_call.name, lctx.config) do
      :ask -> true
      :allow -> false
      :deny -> false
      nil -> global_mode_requires_approval?(tool_call, lctx, mode)
    end
  end

  @spec global_mode_requires_approval?(map(), loop_ctx(), approval_mode()) :: boolean()
  defp global_mode_requires_approval?(_tool_call, _lctx, :none), do: false
  defp global_mode_requires_approval?(_tool_call, _lctx, :ask_all), do: true

  defp global_mode_requires_approval?(tool_call, lctx, :ask) do
    registered_tool_approval(tool_call.name, lctx) == :ask or
      Tools.destructive?(
        tool_call.name,
        tool_call.arguments || %{},
        lctx.config.destructive_tools
      )
  end

  @spec registered_tool_approval(String.t(), loop_ctx()) :: ToolSpec.approval_level() | nil
  defp registered_tool_approval(tool_name, lctx) do
    case GenServer.call(lctx.provider_pid, {:resolve_local_tool, tool_name}) do
      {:ok, %ToolSpec{} = spec, _registration, _declaration} ->
        spec_approval(spec)

      {:error, {:tool_not_found, ^tool_name}} ->
        nil

      {:error, {:tool_not_local, ^tool_name}} ->
        registry = Map.get(lctx.tool_metadata, :tool_registry, ToolRegistry)

        case ToolRegistry.lookup(registry, tool_name) do
          {:ok, %ToolSpec{} = spec} -> spec_approval(spec)
          :error -> nil
        end
    end
  end

  @spec spec_approval(ToolSpec.t()) :: ToolSpec.approval_level() | nil
  defp spec_approval(%ToolSpec{source: :builtin}), do: nil
  defp spec_approval(%ToolSpec{source: {:bundle, _name}}), do: nil
  defp spec_approval(%ToolSpec{approval_level: approval}), do: approval

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
          loop_ctx(),
          map(),
          Invocation.t(),
          ToolContext.t()
        ) :: approved_tool_result()
  defp request_approval(lctx, tool_call, invocation, tool_context) do
    # Send approval request through the event pipeline (Task → Provider → Session)
    send_agent_event(lctx.provider_pid, lctx.request, %Event.ToolApproval{
      tool_call_id: tool_call.id,
      name: tool_call.name,
      args: tool_call.arguments,
      reply_to: self()
    })

    call_id = tool_call.id

    # Block until the user responds (or timeout after 5 minutes)
    receive do
      {:tool_approval_response, ^call_id, :approve} ->
        execute_live_tool(lctx, tool_call, invocation, tool_context)

      {:tool_approval_response, ^call_id, :reject} ->
        {"Tool rejected by user", :denied, nil, false, nil}

      {:tool_approval_response, ^call_id, {:reject, message}} ->
        {message, :denied, nil, false, nil}
    after
      lctx.config.approval_timeout_ms ->
        {"Tool approval timed out", :error, :approval_timeout, false, nil}
    end
  end

  @spec execute_live_tool(loop_ctx(), map(), Invocation.t(), ToolContext.t()) ::
          approved_tool_result()
  defp execute_live_tool(lctx, tool_call, invocation, tool_context) do
    tool_context =
      tool_context_with_call_metadata(tool_context, tool_call, lctx.provider_pid, lctx.request)

    {result, mutation} =
      ToolExecutor.execute_session(lctx.session_pid, invocation,
        config: lctx.config,
        hook_runner: lctx.hook_runner,
        tool_context: tool_context,
        dispatch_post_hook: false
      )

    formatted = format_executor_result(result, tool_result_bound(lctx.selection))
    if mutation, do: {formatted, mutation}, else: formatted
  end

  @spec emit_receipt_preview(loop_ctx(), map(), MingaAgent.Tool.FileMutationResult.t() | nil) ::
          :ok
  defp emit_receipt_preview(
         lctx,
         tool_call,
         %MingaAgent.Tool.FileMutationResult{
           path: path,
           receipt: %{before: before_content, after: after_content}
         }
       )
       when before_content != after_content do
    emit(lctx, %Event.ToolFileChanged{
      tool_call_id: tool_call.id,
      path: path,
      before_content: before_content,
      after_content: after_content
    })
  end

  defp emit_receipt_preview(_lctx, _tool_call, _mutation), do: :ok

  @spec tool_context_with_call_metadata(ToolContext.t(), map(), pid(), Request.t()) ::
          ToolContext.t()
  defp tool_context_with_call_metadata(
         %ToolContext{} = context,
         %{name: "shell"} = tool_call,
         provider_pid,
         request
       ) do
    shell_output_callback = fn chunk ->
      send_agent_event(provider_pid, request, %Event.ToolUpdate{
        tool_call_id: tool_call.id,
        name: "shell",
        partial_result: chunk
      })
    end

    %{
      context
      | metadata: Map.put(context.metadata, :shell_output_callback, shell_output_callback)
    }
  end

  defp tool_context_with_call_metadata(
         %ToolContext{} = context,
         _tool_call,
         _provider_pid,
         _request
       ),
       do: context

  # One ordinary read must leave Apple room for the rest of a read-then-edit turn.
  @apple_tool_result_bytes 2_048

  @spec tool_result_bound(ModelSelection.t()) :: ToolResultBound.t()
  defp tool_result_bound(%ModelSelection{route: %{request_provider: :apple}}),
    do: {:bytes, @apple_tool_result_bytes}

  defp tool_result_bound(%ModelSelection{}), do: :unbounded

  @spec format_executor_result(ToolExecutor.result(), ToolResultBound.t()) ::
          formatted_tool_result()
  defp format_executor_result({:storage_error, reason}, _bound),
    do: throw({:tool_storage_failed, reason})

  defp format_executor_result({:ok, %Output{} = output}, bound),
    do: {format_output(output, bound), :complete, nil, false, output}

  defp format_executor_result({:error, %Output{} = output}, bound),
    do: {format_output(output, bound), :error, nil, false, output}

  defp format_executor_result({:error, %Limitation{} = limitation}, bound),
    do: {ToolResultBound.limit(Limitation.message(limitation), bound), :error, nil, false, nil}

  defp format_executor_result({:ok, result}, bound),
    do: {ToolResultBound.limit(format_tool_result(result), bound), :complete, nil, false, nil}

  defp format_executor_result({:error, {kind, _detail} = reason}, bound)
       when kind in [:tool_refused, :tool_denied, :hook_veto],
       do: {ToolResultBound.limit(format_error(reason), bound), :denied, nil, false, nil}

  defp format_executor_result({:error, reason}, bound),
    do: {ToolResultBound.limit(format_error(reason), bound), :error, nil, false, nil}

  # The revision line stays intact after a bounded view so a truncated read can still be edited.
  @spec format_output(Output.t(), ToolResultBound.t()) :: String.t()
  defp format_output(
         %Output{capture: :complete, revision: %MingaAgent.Tool.Output.Revision{} = revision} =
           output,
         bound
       ) do
    view = ToolResultBound.limit(output.view, bound)

    if MingaAgent.Tool.Output.Revision.full_source?(revision) do
      view <> "\n[expected_revision: #{MingaAgent.Tool.Output.Revision.token(revision)}]"
    else
      view <> "\n[range revision only; read the complete file before mutation]"
    end
  end

  defp format_output(%Output{} = output, bound), do: ToolResultBound.limit(output.view, bound)

  @spec deterministic_output(String.t()) :: Output.t()
  defp deterministic_output(text) when is_binary(text) do
    {:ok, selection} = Range.new(:full, :bytes, 0, byte_size(text), byte_size(text))
    {:ok, output} = Output.new(text, :complete, selection)
    output
  end

  @spec dispatch_post_tool_use(
          map(),
          String.t(),
          boolean(),
          Output.t(),
          AgentConfig.t()
        ) :: :ok
  defp dispatch_post_tool_use(tool_call, result_text, is_error, output, config) do
    payload =
      PostToolUsePayload.new(
        to_string(tool_call.id),
        to_string(tool_call.name),
        tool_call.arguments || %{},
        result_text,
        is_error,
        output
      )

    HookDispatcher.post_tool_use(config.agent_hooks, PostToolUsePayload.to_map(payload))
  rescue
    e -> Log.warning(:agent, "PostToolUse hook dispatch failed: #{Exception.message(e)}")
  catch
    _, reason -> Log.warning(:agent, "PostToolUse hook dispatch failed: #{inspect(reason)}")
  end

  @spec dispatch_pre_compact(Context.t(), AgentConfig.t()) :: :ok | {:error, HookResult.t()}
  defp dispatch_pre_compact(context, config) do
    message_count = Enum.count(context.messages)
    payload = PreCompactPayload.new(message_count)
    HookDispatcher.pre_compact(config.agent_hooks, PreCompactPayload.to_map(payload))
  rescue
    e ->
      Log.warning(:agent, "PreCompact hook dispatch failed: #{Exception.message(e)}")
      {:error, HookResult.dispatch_error(Exception.message(e))}
  catch
    _, reason ->
      Log.warning(:agent, "PreCompact hook dispatch failed: #{inspect(reason)}")
      {:error, HookResult.dispatch_error(inspect(reason))}
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  @spec initial_selection!(keyword(), AgentConfig.t(), String.t(), String.t() | nil) ::
          ModelSelection.t()
  defp initial_selection!(opts, config, model, requested_thinking) do
    case Keyword.get(opts, :model_selection) do
      %ModelSelection{} = selection when requested_thinking == nil ->
        selection

      %ModelSelection{} ->
        raise ArgumentError, "Pass reasoning policy in model_selection, not thinking_level"

      nil ->
        resolve_legacy_initial_selection!(opts, config, model, requested_thinking)
    end
  end

  @spec resolve_legacy_initial_selection!(
          keyword(),
          AgentConfig.t(),
          String.t(),
          String.t() | nil
        ) :: ModelSelection.t()
  defp resolve_legacy_initial_selection!(opts, config, model, requested_thinking) do
    resolver_opts =
      opts
      |> Keyword.get(:model_resolver_opts, [])
      |> Keyword.put_new(:config, config)
      |> Keyword.put_new(:credential_snapshot, MingaAgent.Credentials.snapshot())

    case ModelResolver.resolve(model, resolver_opts) do
      {:ok, selection} -> apply_initial_reasoning!(selection, requested_thinking)
      {:error, reason} -> raise ArgumentError, ModelResolver.message(reason)
    end
  end

  @spec apply_initial_reasoning!(ModelSelection.t(), String.t() | nil) :: ModelSelection.t()
  defp apply_initial_reasoning!(selection, nil), do: selection

  defp apply_initial_reasoning!(selection, requested_thinking) do
    case ModelSelection.with_reasoning(selection, requested_thinking) do
      {:ok, selection} -> selection
      {:error, message} -> raise ArgumentError, message
    end
  end

  @spec summary_client(state()) :: Compaction.summary_fn()
  defp summary_client(state) do
    authentication = fn ->
      with %Credentials.Binding{identity: expected} <- state.authentication,
           {:ok, binding} <-
             Credentials.bind_request(
               state.selection.credential,
               state.authentication,
               state.credential_opts
             ),
           true <- binding.identity == expected do
        {:ok, binding.material}
      else
        _unknown_or_changed ->
          {:error, {:portable_context_transition_required, :authentication_continuity_unknown}}
      end
    end

    ReqLLMAdapter.summary_client(
      state.llm_client,
      state.selection,
      state.config,
      authentication,
      summary_request_opts(state)
    )
  end

  # A compaction summary is an isolated query: a contributed route gets a fresh `:summary` identity per request.
  @spec summary_request_opts(state()) :: (-> keyword())
  defp summary_request_opts(%{selection: %{route: %{request_provider: :contributed}}} = state) do
    fn ->
      {:ok, conversation} =
        ConversationRef.new(
          session_id: nil,
          owner: state.subscriber,
          epoch_id: summary_epoch(state.prefix_candidate),
          conversation_revision: nil,
          request_id: make_ref(),
          purpose: :summary
        )

      [
        minga_conversation: conversation,
        minga_reasoning: state.selection.policy.reasoning.effort,
        inference_routes: state.inference_routes
      ]
    end
  end

  defp summary_request_opts(_state), do: fn -> [] end

  @spec summary_epoch(Prefix.t() | :unknown) :: String.t() | nil
  defp summary_epoch(%Prefix{epoch_id: epoch_id}) when is_binary(epoch_id), do: epoch_id
  defp summary_epoch(_prefix), do: nil

  @spec compaction_unsupported_message(ModelSelection.t()) :: String.t()
  defp compaction_unsupported_message(selection),
    do:
      "#{selection.route.display_name} does not compact history. Start a new conversation to clear its context."

  @spec inference_route_registry(keyword()) :: GenServer.server()
  defp inference_route_registry(opts) do
    opts
    |> Keyword.get(:model_resolver_opts, [])
    |> Keyword.get(:inference_routes, MingaAgent.InferenceRouteRegistry)
  end

  @spec maybe_compact_with_opts(Context.t(), keyword()) ::
          {:compacted, Context.t(), String.t()} | {:ok, Context.t()} | {:error, String.t()}
  defp maybe_compact_with_opts(context, opts) do
    if Keyword.get(opts, :threshold) == nil do
      {:ok, context}
    else
      Compaction.maybe_compact(context, opts)
    end
  end

  @spec refresh_tool_registry_contributions(state()) :: {:ok, state()} | {:error, term()}
  defp refresh_tool_registry_contributions(%{custom_tools?: true} = state), do: {:ok, state}

  defp refresh_tool_registry_contributions(state) do
    table = state.tool_metadata.tool_registry

    case ToolRegistry.revision(table) do
      :unavailable ->
        {:error, :registry_unavailable}

      revision when revision == state.registry_revision ->
        {:ok, state}

      _changed ->
        with {:ok, revision, specs} <- ToolRegistry.snapshot(table) do
          base_tools =
            specs
            |> registry_tool_declarations(state.project_root, state.tool_metadata)
            |> filter_base_tools_for_read_only(state.read_only?)

          tools =
            (base_tools ++ state.mcp_tools)
            |> filter_tool_allowlist(state.tool_allowlist)

          {:ok, %{state | base_tools: base_tools, tools: tools, registry_revision: revision}}
        end
    end
  end

  @spec current_prefix_schemas(state()) :: {[map()], state()}
  defp current_prefix_schemas(%{tools: tools, schema_cache: {tools, schemas}} = state),
    do: {schemas, state}

  defp current_prefix_schemas(state) do
    schemas = ReqLLMAdapter.declarations(state.tools)
    {schemas, %{state | schema_cache: {state.tools, schemas}}}
  end

  # Apple's named-argument schemas share its small context window with conversation history.
  # Restrict the authoritative prefix, not just the transported declarations.
  @spec model_schemas([map()], ModelSelection.t()) :: [map()]
  defp model_schemas(schemas, %ModelSelection{route: %{request_provider: :apple}}) do
    Enum.filter(schemas, fn schema ->
      schema.name in ~w(read_file find grep edit_file write_file)
    end)
  end

  defp model_schemas(schemas, %ModelSelection{}), do: schemas

  @spec question_schemas([map()], boolean()) :: [map()]
  defp question_schemas(schemas, true), do: schemas
  defp question_schemas(schemas, false), do: Enum.reject(schemas, &(&1.name == "ask_user"))

  @spec refresh_base_tools(state()) :: [Tool.t()]
  defp refresh_base_tools(%{custom_tools?: true, custom_tool_declarations: declarations}) do
    Enum.map(declarations, &ReqLLMAdapter.tool(&1, :local))
  end

  defp refresh_base_tools(state), do: registry_tools(state.project_root, state.tool_metadata)

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

  @spec preview_skills(
          state(),
          :current
          | {:activate, String.t()}
          | {:deactivate, String.t()}
          | {:model, ModelSelection.t(), :exact | {:handoff, :retain | :reject}}
          | {:selected, term(), [String.t()]}
        ) ::
          {:ok, [Skills.skill()], term()} | {:error, term()}
  defp preview_skills(state, {:selected, operation, names}) do
    active = load_active_skills(state.project_root, names)

    case operation do
      :current -> {:ok, active, :ok}
      {:model, %ModelSelection{}, _changed?} -> {:ok, active, :ok}
      update -> preview_skills(%{state | active_skills: active}, update)
    end
  end

  defp preview_skills(state, :current),
    do:
      {:ok, load_active_skills(state.project_root, Enum.map(state.active_skills, & &1.name)), :ok}

  defp preview_skills(state, {:model, %ModelSelection{}, _changed?}),
    do: preview_skills(state, :current)

  defp preview_skills(state, {:activate, name}) do
    if Enum.any?(state.active_skills, &(&1.name == name)) do
      {:error, "Skill '#{name}' is already active"}
    else
      case Skills.find(name, state.project_root) do
        {:ok, skill} -> {:ok, state.active_skills ++ [skill], {:ok, skill}}
        :not_found -> {:error, "Skill '#{name}' not found"}
      end
    end
  end

  defp preview_skills(state, {:deactivate, name}) do
    if Enum.any?(state.active_skills, &(&1.name == name)),
      do: {:ok, Enum.reject(state.active_skills, &(&1.name == name)), :ok},
      else: {:error, "Skill '#{name}' is not active"}
  end

  @spec prefix_selection(ModelSelection.t(), term()) :: ModelSelection.t()
  defp prefix_selection(current, {:selected, operation, _names}),
    do: prefix_selection(current, operation)

  defp prefix_selection(_current, {:model, %ModelSelection{} = selection, _changed?}),
    do: selection

  defp prefix_selection(current, _operation), do: current

  @spec commit_prefix_preview(state(), reference(), pid()) :: {:reply, term(), state()}
  defp commit_prefix_preview(
         %{prefix_preview: %{token: token, owner: owner} = preview} = state,
         token,
         owner
       ) do
    {:reply, :ok,
     %{
       state
       | selection: preview.selection,
         active_skills: preview.active_skills,
         authentication: preview.authentication,
         prefix_candidate: preview.prefix,
         prefix_preview: nil
     }}
  end

  defp commit_prefix_preview(state, _token, _owner),
    do: {:reply, {:error, :stale_prefix_preview}, state}

  @spec local_spec(Tool.t()) :: ToolSpec.t()
  defp local_spec(%Tool{provider_options: %{minga_tool_spec: %ToolSpec{} = spec}}), do: spec
  defp local_spec(%Tool{} = tool), do: ToolRegistry.from_req_tool(tool)

  @spec system_prompt_parts(String.t(), [Skills.skill()], ModelSelection.t()) ::
          SystemPrompt.t()
  defp system_prompt_parts(project_root, active_skills, selection) do
    SystemPrompt.new(
      [resolve_base_prompt(project_root), provider_tool_guidance(selection)],
      instructions: Instructions.assemble(project_root),
      skills: Skills.format_for_prompt(active_skills),
      append_prompt: read_config_string(:agent_append_system_prompt)
    )
  end

  # Apple's 4,096-token context cannot hold large project instructions. Its prefix sends the
  # optional parts only when the Apple tokenizer says they leave room for the conversation,
  # and records every omission on the Prefix. Other routes send every part.
  @apple_history_floor 1_536

  @spec fit_system_prompt(state(), [Skills.skill()], ModelSelection.t(), [map()]) ::
          {:ok, SystemPrompt.fit(), state()} | {:error, String.t()}
  defp fit_system_prompt(
         state,
         active_skills,
         %ModelSelection{route: %{request_provider: :apple}} = selection,
         schemas
       ) do
    parts = system_prompt_parts(state.project_root, active_skills, selection)
    reserve = selection.policy.limits.request_output
    key = :crypto.hash(:sha256, :erlang.term_to_binary({parts, schemas, selection.policy.limits}))

    case state.prefix_fit do
      {^key, fit} ->
        {:ok, fit, state}

      _stale ->
        budget = %{reserve: reserve, history_floor: @apple_history_floor}
        measure = apple_prefix_measure(state.apple_counter, schemas, selection)

        case SystemPrompt.fit(parts, budget, measure) do
          {:ok, fit} -> {:ok, fit, %{state | prefix_fit: {key, fit}}}
          {:error, reason} -> {:error, prefix_refusal_message(reason, selection)}
        end
    end
  end

  defp fit_system_prompt(state, active_skills, selection, _schemas) do
    fit =
      state.project_root
      |> system_prompt_parts(active_skills, selection)
      |> SystemPrompt.unbounded()

    {:ok, fit, state}
  end

  # Preview runs inside Session's 5 s GenServer.call, which the Editor's synchronous prompt
  # send also waits on for 5 s. One bounded count leaves 2 s for credential binding, schema
  # projection, and Session's own transition, so a slow helper is refused, never a timeout.
  @apple_count_deadline 3_000

  # Counts every candidate instructions entry with the same tool projection a dispatch sends.
  @spec apple_prefix_measure(apple_counter(), [map()], ModelSelection.t()) ::
          SystemPrompt.measure()
  defp apple_prefix_measure(counter, schemas, selection) do
    tools = ReqLLMAdapter.advertised_tools(schemas)
    reserve = selection.policy.limits.request_output
    configured = selection.policy.limits.context

    fn texts, candidates ->
      case within_count_deadline(fn -> counter.(texts, candidates, tools, reserve) end) do
        {:ok, %{counts: counts, context: context}} ->
          {:ok, %{counts: counts, context: min(context, configured || context)}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # Runs the count in a process that owns the helper Port, so killing it at the deadline
  # also closes the Port and retires the helper.
  @spec within_count_deadline((-> result)) :: result | {:error, term()} when result: term()
  defp within_count_deadline(count) do
    parent = self()
    receipt = make_ref()
    {pid, monitor} = spawn_monitor(fn -> send(parent, {receipt, count.()}) end)

    receive do
      {^receipt, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:apple_count_failed, reason}}
    after
      @apple_count_deadline ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^receipt, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :apple_count_timeout}
    end
  end

  @spec prefix_refusal_message(term(), ModelSelection.t()) :: String.t()
  defp prefix_refusal_message(
         {:fixed_prefix_exceeded, %{prefix: prefix, reserve: reserve, context: context}},
         selection
       ) do
    "#{selection.route.display_name} cannot hold its fixed instructions and tools: Apple counts #{format_tokens(prefix)} tokens, plus #{format_tokens(reserve)} reserved for the response, over its #{format_tokens(context)}-token context. A new conversation will not help; choose a model with a larger context"
  end

  defp prefix_refusal_message(:apple_count_timeout, selection) do
    "#{selection.route.display_name} could not count its fixed instructions and tools within #{div(@apple_count_deadline, 1000)} seconds. Try again, or reopen /model to check availability"
  end

  defp prefix_refusal_message(reason, selection) do
    "#{selection.route.display_name} could not count its fixed instructions and tools (#{Redaction.format_error(reason)}). Reopen /model to check availability"
  end

  @spec format_tokens(non_neg_integer()) :: String.t()
  defp format_tokens(count) when is_integer(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  @spec provider_tool_guidance(ModelSelection.t()) :: String.t() | nil
  defp provider_tool_guidance(%ModelSelection{route: %{request_provider: :apple}}) do
    "Answer directly when the request does not require project files. Use a tool only when needed to fulfill the request. If a tool result already answers the request, use it in your answer instead of calling another tool."
  end

  defp provider_tool_guidance(%ModelSelection{}), do: nil

  @default_system_prompt_template """
  You are an AI coding assistant inside Minga, a modal text editor.

  <rules>
  - Read files before editing them and verify changes with appropriate tests.
  - Use edit_file for one ordered batch per file. Copy expected_revision from a complete read_file result. An edit with an empty old_text appends new_text at the end of the file. A rejected batch commits nothing; read again after a stale revision.
  - Use write_file with mode=create and expected_revision=absent for new files, or mode=replace and a full read revision for replacements. delete_file also requires a full read revision.
  - Atomicity is one file only. Report each file's outcome separately. Never claim cross-file transactions or bypass revision checks with shell writes.
  - Use the advertised tools for discovery, inspection and changes.
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

    base <>
      "\n## Environment\n\n" <>
      "- Project root: #{project_root}"
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

  defdelegate detect_project_root, to: Minga.Project, as: :resolve_root

  # Context admission uses only the exact resolved model limit. Unknown remains
  # nil so the UI does not display an invented capacity.
  @spec emit_context_usage(loop_ctx(), Context.t()) :: :ok
  defp emit_context_usage(lctx, context) do
    estimated = TokenEstimator.estimate(context.messages)

    emit(lctx, %Event.ContextUsage{
      estimated_tokens: estimated,
      context_limit: lctx.selection.policy.limits.context
    })
  end

  @spec emit_error_and_end(loop_ctx(), Event.Error.t()) :: :ok
  defp emit_error_and_end(lctx, %Event.Error{} = event) do
    emit(lctx, event)
    emit(lctx, %Event.AgentEnd{usage: nil})
  end

  # Reports an error that occurred inside the agent loop: logs a redacted
  # diagnostic detail for Messages/logs, emits a friendly Error + AgentEnd to
  # the UI, and returns a `{:reported, reason}` sentinel. The Task-completion
  # handler matches that sentinel and skips re-emitting, so a single failure
  # surfaces exactly once in the transcript instead of twice.
  @spec reported_error(loop_ctx(), String.t(), term()) :: {:error, {:reported, term()}}
  defp reported_error(lctx, message, reason) do
    event = loop_error_event(lctx, message, reason)
    detail = Redaction.format_error(reason)

    Log.error(:agent, "[Agent.Native] agent loop detail: #{detail}")
    Log.error(:agent, "[Agent.Native] agent loop error: #{event.message}")
    emit_error_and_end(lctx, event)
    {:error, {:reported, reason}}
  end

  @spec error_event(String.t(), term(), ModelSelection.t()) :: Event.Error.t()
  defp error_event(_message, {kind, _reason}, _selection)
       when kind in [
              :tool_outcome_persistence_failed,
              :tool_checkpoint_failed,
              :effect_admission_failed,
              :tool_storage_failed
            ] do
    %Event.Error{
      kind: :tool_error,
      provider: nil,
      message:
        "Tool state could not be saved. Model execution stopped. Reload this saved conversation to recover safely."
    }
  end

  defp error_event(message, {kind, _reason}, _selection)
       when kind in [:request_admission_refused, :request_admission_failed] do
    %Event.Error{kind: :request_admission_refused, message: message}
  end

  defp error_event(_message, {:apple_unavailable, reason}, %ModelSelection{
         route: %{request_provider: :apple}
       }) do
    %Event.Error{
      message: ModelResolver.apple_unavailable_message(reason),
      kind: :provider_error,
      provider: "apple"
    }
  end

  defp error_event(
         message,
         %ReqLLM.Error.API.Stream{cause: {:apple_inference, _reason} = cause},
         %ModelSelection{route: %{request_provider: :apple}} = selection
       ),
       do: error_event(message, cause, selection)

  defp error_event(
         message,
         {:apple_inference, "Apple inference failed: " <> _details},
         %ModelSelection{
           route: %{request_provider: :apple}
         } = selection
       ),
       do: error_event(message, :unexpected_apple_inference_failure, selection)

  defp error_event(_message, {:apple_inference, reason}, %ModelSelection{
         route: %{request_provider: :apple}
       })
       when is_binary(reason) do
    %Event.Error{message: reason, kind: :provider_error, provider: "apple"}
  end

  defp error_event(_message, _reason, %ModelSelection{route: %{request_provider: :apple}}) do
    %Event.Error{
      message:
        "Apple Intelligence could not complete this request. Reopen /model to check availability or open Messages for details.",
      kind: :provider_error,
      provider: "apple"
    }
  end

  defp error_event(message, reason, %ModelSelection{} = selection) do
    provider = Atom.to_string(selection.route.request_provider)
    now = DateTime.utc_now()

    case UsageLimitSignal.detect(reason, usage_limit_service(provider), now) do
      {:ok, limit} -> usage_limit_event(limit, provider, now)
      :none -> classified_error_event(message, reason, selection, provider)
    end
  end

  @spec classified_error_event(String.t(), term(), ModelSelection.t(), String.t()) ::
          Event.Error.t()
  defp classified_error_event(message, reason, selection, provider) do
    kind = classify_error_reason(reason)

    %Event.Error{
      message:
        error_event_message(
          kind,
          message,
          provider,
          reason,
          selection.route.execution.provider_model_id
        ),
      kind: kind,
      provider: provider
    }
  end

  # A contributed route classifies its own failures; admission and tool-state failures keep core wording.
  @spec loop_error_event(loop_ctx(), String.t(), term()) :: Event.Error.t()
  defp loop_error_event(
         %{selection: %{route: %{request_provider: :contributed}}} = lctx,
         message,
         reason
       ) do
    case error_event(message, reason, lctx.selection) do
      %Event.Error{kind: kind} = event when kind in [:tool_error, :request_admission_refused] ->
        event

      _route_failure ->
        contributed_error_event(lctx, reason)
    end
  end

  defp loop_error_event(lctx, message, reason), do: error_event(message, reason, lctx.selection)

  @spec contributed_error_event(loop_ctx(), term()) :: Event.Error.t()
  defp contributed_error_event(lctx, reason) do
    {:contributed, route_id, _model_id} = lctx.selection.route.origin
    {kind, message} = contributed_error(lctx.inference_routes, route_id, route_failure(reason))
    now = DateTime.utc_now()

    case contributed_usage_limit(kind, lctx.inference_routes, route_id) do
      {:window, limit} -> usage_limit_event(limit, route_id, now)
      {:unreported, limit} -> Event.Error.usage_limit(limit, message, route_id)
      :none -> %Event.Error{kind: kind, message: message, provider: route_id}
    end
  end

  # A route refusing requests through a `:rejected` plan window is at its usage limit. Without
  # such a window, only a route that classifies the failure as a usage limit itself is one, and
  # its own sentence stays.
  @spec contributed_usage_limit(Event.Error.kind(), GenServer.server(), String.t()) ::
          {:window | :unreported, UsageLimit.t()} | :none
  defp contributed_usage_limit(kind, registry, route_id)
       when kind in [:rate_limited, :usage_limit_reached] do
    case InferenceRouteRegistry.lookup(registry, route_id) do
      {:ok, entry} ->
        service = InferenceRouteSpec.short_name(entry.spec)

        entry.status
        |> InferenceRouteStatus.plan_windows()
        |> PlanWindow.rejected()
        |> route_usage_limit(kind, service)

      {:error, :not_found} ->
        :none
    end
  catch
    :exit, _reason -> :none
  end

  defp contributed_usage_limit(_kind, _registry, _route_id), do: :none

  @spec route_usage_limit(PlanWindow.t() | nil, Event.Error.kind(), String.t()) ::
          {:window | :unreported, UsageLimit.t()} | :none
  defp route_usage_limit(%PlanWindow{} = window, _kind, service),
    do: {:window, UsageLimit.from_plan_window(service, window)}

  defp route_usage_limit(nil, :usage_limit_reached, service),
    do: {:unreported, UsageLimit.unknown(service)}

  defp route_usage_limit(nil, _kind, _service), do: :none

  @spec usage_limit_event(UsageLimit.t(), String.t(), DateTime.t()) :: Event.Error.t()
  defp usage_limit_event(limit, provider, now) do
    message = UsageLimit.message(limit, now, &InferenceRouteRegistry.local_time/1)
    Event.Error.usage_limit(limit, message, provider)
  end

  # The subscription name the user recognizes in "Your ChatGPT Pro usage limit is reached."
  @spec usage_limit_service(String.t()) :: String.t()
  defp usage_limit_service("openai_codex"), do: "ChatGPT"

  defp usage_limit_service(provider) when provider in ["anthropic", "openai", "google"],
    do: provider_label(provider)

  defp usage_limit_service(_provider), do: "model provider"

  @spec route_failure(term()) :: term()
  defp route_failure(%ReqLLM.Error.API.Stream{cause: nil} = reason), do: reason
  defp route_failure(%ReqLLM.Error.API.Stream{cause: cause}), do: cause
  defp route_failure(reason), do: reason

  @spec contributed_error(GenServer.server(), String.t(), term()) ::
          {Event.Error.kind(), String.t()}
  defp contributed_error(_registry, route_id, {:inference_route_unavailable, route_id}),
    do: {:unreachable, InferenceRouteRegistry.unregistered_message(route_id)}

  defp contributed_error(_registry, route_id, {kind, _detail})
       when kind in [:inference_route_invalid_event, :inference_route_invalid_response],
       do:
         {:provider_error,
          "The #{route_id} model route sent an invalid response. Open *Messages* for details."}

  defp contributed_error(_registry, route_id, {:inference_route_unsupported_content, type}),
    do:
      {:invalid_model,
       "This conversation contains #{type} content that the #{route_id} model route cannot receive. Start a new conversation or choose another model."}

  defp contributed_error(registry, route_id, reason),
    do: InferenceRouteRegistry.classify_error(registry, route_id, reason)

  @spec error_event_message(Event.Error.kind(), String.t(), String.t() | nil, term(), String.t()) ::
          String.t()
  defp error_event_message(:auth_failed, _message, provider, _reason, _model) do
    "Couldn't authenticate with #{provider_label(provider)}. #{auth_hint_for_provider(provider)}"
  end

  defp error_event_message(:rate_limited, _message, _provider, _reason, _model) do
    "The model provider is rate limiting requests. Wait a moment, then try again."
  end

  defp error_event_message(:unreachable, _message, _provider, _reason, _model) do
    "Couldn't reach the model provider. Check your network connection, then try again."
  end

  defp error_event_message(:context_transition_required, _message, _provider, _reason, _model),
    do: Event.Error.context_transition_message()

  defp error_event_message(:provider_error, _message, _provider, _reason, _model) do
    "The model provider returned an unexpected error. Open Messages for details, or pick another configured model with /model."
  end

  defp error_event_message(:invalid_model, message, "openai_codex", reason, _model) do
    if codex_chatgpt_model_incompatible?(reason) do
      "This model isn't available for your ChatGPT account. Open /model and choose an available route, then retry."
    else
      message
    end
  end

  defp error_event_message(:invalid_model, message, _provider, _reason, _model), do: message

  @spec classify_error_reason(term()) :: Event.Error.kind()
  defp classify_error_reason(:invalid_format), do: :invalid_model

  defp classify_error_reason({:portable_context_transition_required, _reason}),
    do: :context_transition_required

  defp classify_error_reason({:http_streaming_failed, reason}), do: classify_error_reason(reason)
  defp classify_error_reason({:provider_build_failed, _reason}), do: :auth_failed
  defp classify_error_reason({:credential_unavailable, _identity}), do: :auth_failed
  defp classify_error_reason({:exit, reason}), do: classify_error_reason(reason)
  defp classify_error_reason({:throw, reason}), do: classify_error_reason(reason)

  defp classify_error_reason(reason) when is_map(reason), do: classify_map_error_reason(reason)

  defp classify_error_reason(reason) when reason in [:timeout, :nxdomain, :econnrefused],
    do: :unreachable

  defp classify_error_reason(reason) when is_binary(reason),
    do: classify_legacy_error_message(reason)

  defp classify_error_reason(_reason), do: :provider_error

  @spec classify_map_error_reason(map()) :: Event.Error.kind()
  defp classify_map_error_reason(reason) do
    classify_map_error_reason(reason, codex_chatgpt_model_incompatible?(reason))
  end

  @spec classify_map_error_reason(map(), boolean()) :: Event.Error.kind()
  defp classify_map_error_reason(_reason, true), do: :invalid_model

  defp classify_map_error_reason(%{status: status}, false) when status in [401, 403],
    do: :auth_failed

  defp classify_map_error_reason(%{status: 429}, false), do: :rate_limited

  defp classify_map_error_reason(%{"status" => status}, false) when status in [401, 403],
    do: :auth_failed

  defp classify_map_error_reason(%{"status" => 429}, false), do: :rate_limited
  defp classify_map_error_reason(%{reason: reason}, false), do: classify_error_reason(reason)
  defp classify_map_error_reason(%{"reason" => reason}, false), do: classify_error_reason(reason)
  defp classify_map_error_reason(_reason, false), do: :provider_error

  @spec codex_chatgpt_model_incompatible?(term()) :: boolean()
  defp codex_chatgpt_model_incompatible?(%{response_body: response_body}) do
    codex_chatgpt_model_incompatible?(response_body)
  end

  defp codex_chatgpt_model_incompatible?(%{"response_body" => response_body}) do
    codex_chatgpt_model_incompatible?(response_body)
  end

  defp codex_chatgpt_model_incompatible?(%{detail: detail}) when is_binary(detail) do
    codex_chatgpt_model_incompatible?(detail)
  end

  defp codex_chatgpt_model_incompatible?(%{"detail" => detail}) when is_binary(detail) do
    codex_chatgpt_model_incompatible?(detail)
  end

  defp codex_chatgpt_model_incompatible?(message) when is_binary(message) do
    normalized = String.downcase(message)

    String.contains?(normalized, "model is not supported") and
      String.contains?(normalized, "chatgpt account")
  end

  defp codex_chatgpt_model_incompatible?(_reason), do: false

  # Last-resort compatibility for third-party clients that only return a string.
  # Internal provider/session contracts use `Event.Error.kind` instead.
  @spec classify_legacy_error_message(String.t()) :: Event.Error.kind()
  defp classify_legacy_error_message(message) do
    normalized = String.downcase(message)

    classify_legacy_error_checks([
      {:auth_failed,
       String.match?(normalized, ~r/\b(401|403)\b/) or
         String.contains?(normalized, [
           "unauthorized",
           "invalid_api_key",
           "api key",
           "api_key",
           "provider_build_failed",
           "failed to build",
           "couldn't authenticate"
         ])},
      {:rate_limited,
       String.match?(normalized, ~r/\b429\b/) or
         String.contains?(normalized, ["api rate limited", "rate limited", "rate limit"])},
      {:unreachable,
       String.contains?(normalized, ["timeout", "timed out", "nxdomain", "econnrefused"])}
    ])
  end

  @spec classify_legacy_error_checks([{Event.Error.kind(), boolean()}]) :: Event.Error.kind()
  defp classify_legacy_error_checks([{kind, true} | _rest]), do: kind

  defp classify_legacy_error_checks([{_kind, false} | rest]),
    do: classify_legacy_error_checks(rest)

  defp classify_legacy_error_checks([]), do: :provider_error

  @spec normalize_usage(map() | nil, ModelSelection.t()) :: Event.token_usage() | nil
  defp normalize_usage(_usage, %ModelSelection{policy: %{usage: :none}}), do: nil

  defp normalize_usage(nil, _selection), do: nil

  defp normalize_usage(usage, %ModelSelection{} = selection) when is_map(usage) do
    normalized = %MingaAgent.TurnUsage{
      input: usage_value(usage, [:input_tokens, :input], 0),
      output: usage_value(usage, [:output_tokens, :output], 0),
      cache_read:
        usage_value(
          usage,
          [:cache_read_input_tokens, :cached_input, :cached_tokens, :cache_read],
          0
        ),
      cache_write:
        usage_value(
          usage,
          [:cache_creation_input_tokens, :cache_creation, :cache_creation_tokens, :cache_write],
          0
        ),
      cost: usage_value(usage, [:total_cost, :cost], 0.0)
    }

    priced_usage(normalized, selection)
  end

  # Subscription routes report tokens but no per-request dollar cost.
  @spec priced_usage(MingaAgent.TurnUsage.t(), ModelSelection.t()) :: MingaAgent.TurnUsage.t()
  defp priced_usage(usage, %ModelSelection{policy: %{cost_mode: :subscription}}),
    do: %{usage | cost: 0.0}

  defp priced_usage(usage, %ModelSelection{} = selection) do
    CostCalculator.ensure_cost(usage, selection.route.model_id, selection.route.model_provider)
  end

  @spec usage_value(map(), [atom()], term()) :: term()
  defp usage_value(_usage, [], default), do: default

  defp usage_value(usage, [key | rest], default) do
    case Map.fetch(usage, key) do
      {:ok, nil} -> usage_value(usage, rest, default)
      {:ok, value} -> value
      :error -> usage_value(usage, rest, default)
    end
  end

  @spec format_tool_result(term()) :: String.t()
  defp format_tool_result(result) when is_binary(result), do: result

  defp format_tool_result(result) when is_map(result) or is_list(result),
    do: JSON.encode!(result)

  defp format_tool_result(result), do: inspect(result)

  @spec format_error(term()) :: String.t()
  defp format_error(
         {:request_admission_refused,
          {:fixed_prefix_exceeded, %{prefix: prefix, reserve: reserve, context: context}}}
       ),
       do:
         "The fixed instructions and tools use #{format_tokens(prefix)} provider-counted tokens, plus #{format_tokens(reserve)} reserved for the response, over this model's #{format_tokens(context)}-token context. A new conversation will not help; choose a model with a larger context. The saved history was retained."

  defp format_error(
         {:request_admission_refused,
          {:history_exceeded,
           %{prefix: prefix, history: history, reserve: reserve, context: context}}}
       ),
       do:
         "Retained history and input use #{format_tokens(history)} provider-counted tokens on top of #{format_tokens(prefix)} for the fixed instructions and tools. With #{format_tokens(reserve)} reserved for the response, that exceeds this model's #{format_tokens(context)}-token context. Shorten the input or start a new conversation. The saved history was retained."

  defp format_error({:request_admission_refused, reason})
       when reason in [:input_limit_exceeded, :context_reservation_exceeded],
       do:
         "The request does not fit this model. Shorten the input or start a new conversation. The saved history was retained."

  defp format_error({:request_admission_refused, reason})
       when reason in [:missing_capacity, :missing_output_cap, :output_limit_exceeded],
       do:
         "This model route cannot reserve enough response capacity. Choose a model with a supported response limit."

  defp format_error({:request_admission_refused, {:unknown_input_size, _reason}}),
    do:
      "This model route cannot verify the prepared input size. Use a route with supported token counting."

  defp format_error({:request_admission_refused, {:count_acquisition_failed, _reason}}),
    do: "The provider did not return a usable input token count. No generation request was sent."

  defp format_error({:request_admission_refused, _reason}),
    do: "The prepared request could not be authorized. No generation request was sent."

  defp format_error({:request_admission_failed, _reason}),
    do:
      "Request preparation stopped before generation. Reload the saved conversation before retrying."

  defp format_error({:http_streaming_failed, reason}), do: format_error(reason)
  defp format_error({:provider_build_failed, reason}), do: format_error(reason)
  defp format_error({:exit, reason}), do: format_error(reason)
  defp format_error({:throw, reason}), do: format_error(reason)
  defp format_error(reason) when is_binary(reason), do: humanize_provider_error(reason)
  defp format_error(%{reason: reason}) when is_binary(reason), do: humanize_provider_error(reason)

  defp format_error(%{"reason" => reason}) when is_binary(reason),
    do: humanize_provider_error(reason)

  defp format_error(%{message: msg}) when is_binary(msg), do: humanize_provider_error(msg)
  defp format_error(%{"message" => msg}) when is_binary(msg), do: humanize_provider_error(msg)

  defp format_error(:invalid_format) do
    ~s|Invalid model format. Expected "provider:model" (e.g., "anthropic:claude-sonnet-4"), | <>
      "got a bare model name without a provider prefix."
  end

  defp format_error(reason), do: reason |> Redaction.format_error() |> humanize_provider_error()

  @spec humanize_provider_error(String.t()) :: String.t()
  defp humanize_provider_error(message) when is_binary(message) do
    message
    |> Redaction.format_error()
    |> humanize_redacted_provider_error()
  end

  @spec humanize_redacted_provider_error(String.t()) :: String.t()
  defp humanize_redacted_provider_error(message) do
    humanize_redacted_provider_error(
      message,
      missing_api_key?(message),
      raw_provider_dump?(message)
    )
  end

  @spec humanize_redacted_provider_error(String.t(), boolean(), boolean()) :: String.t()
  defp humanize_redacted_provider_error(message, true, _raw_dump?) do
    provider = provider_name_from_error(message)
    provider_label = provider_label(provider)
    auth_hint = auth_hint_for_provider(provider)
    "Couldn't authenticate with #{provider_label}. #{auth_hint}"
  end

  defp humanize_redacted_provider_error(_message, false, true) do
    "Something went wrong talking to the model provider. Check the Messages panel for details."
  end

  defp humanize_redacted_provider_error(message, false, false), do: message

  @spec missing_api_key?(String.t()) :: boolean()
  defp missing_api_key?(message) do
    String.contains?(message, ["api_key", "API_KEY", "API key", "provider_build_failed"])
  end

  @spec raw_provider_dump?(String.t()) :: boolean()
  defp raw_provider_dump?(message) do
    String.contains?(message, ["%ReqLLM.", "Splode", "bread_crumbs", "stacktrace:"])
  end

  @spec provider_name_from_error(String.t()) :: String.t()
  defp provider_name_from_error(message) do
    provider_name_from_error(
      String.contains?(message, ["Anthropic", "ANTHROPIC", "anthropic"]),
      String.contains?(message, ["OpenAI", "OPENAI", "openai"]),
      String.contains?(message, ["Google", "GOOGLE", "google"])
    )
  end

  @spec provider_name_from_error(boolean(), boolean(), boolean()) :: String.t()
  defp provider_name_from_error(true, _openai?, _google?), do: "anthropic"
  defp provider_name_from_error(false, true, _google?), do: "openai"
  defp provider_name_from_error(false, false, true), do: "google"
  defp provider_name_from_error(false, false, false), do: "provider"

  @spec provider_label(String.t()) :: String.t()
  defp provider_label("anthropic"), do: "Anthropic"
  defp provider_label("openai"), do: "OpenAI"
  defp provider_label("openai_codex"), do: "OpenAI Codex"
  defp provider_label("google"), do: "Google"
  defp provider_label(_provider), do: "the model provider"

  @spec auth_hint_for_provider(String.t()) :: String.t()
  defp auth_hint_for_provider("openai_codex") do
    "Sign in with /login for Codex models, or pick another configured model with /model."
  end

  defp auth_hint_for_provider("openai") do
    "Run /auth openai to enter a key, sign in with /login for Codex models, or pick another configured model with /model."
  end

  defp auth_hint_for_provider("anthropic") do
    "Run /auth anthropic to enter a key, or pick another configured model with /model."
  end

  defp auth_hint_for_provider("google") do
    "Run /auth google to enter a key, or pick another configured model with /model."
  end

  defp auth_hint_for_provider(_provider) do
    "Choose a provider with /model, check credential status with /auth, or sign in with /login."
  end

  @spec notify_lifecycle(pid(), Event.Error.t()) :: Event.Error.t()
  defp notify_lifecycle(subscriber, event) do
    send(subscriber, {:agent_provider_lifecycle_event, event})
    event
  end

  @spec notify(pid(), Event.t()) :: Event.t()
  defp notify(subscriber, event) do
    send(subscriber, {:agent_provider_event, event})
    event
  end

  @spec notify(pid(), String.t(), Event.t()) :: Event.t()
  defp notify(subscriber, request_id, event) do
    send(subscriber, {:agent_provider_event, request_id, event})
    event
  end

  @spec notify_active(state(), Event.t()) :: Event.t()
  defp notify_active(state, event) do
    case ExecutionState.request(state.execution) do
      %Request{request_id: request_id} -> notify(state.subscriber, request_id, event)
      nil -> notify(state.subscriber, event)
    end
  end

  @spec send_agent_event(pid(), Request.t(), Event.t()) :: :ok
  defp send_agent_event(provider_pid, request, event) do
    send(provider_pid, {:agent_event, request.request_id, event})
    :ok
  end

  @spec emit(loop_ctx(), Event.t()) :: :ok
  defp emit(lctx, event), do: send_agent_event(lctx.provider_pid, lctx.request, event)
end
