defmodule Minga.Credo.EditorStateOwnershipCheck do
  @moduledoc """
  Enforces explicit ownership and purity boundaries for Editor state values.

  The check uses concrete ownership metadata rather than guessed types. It flags explicit struct updates and map mutation calls only when the struct module or receiver path identifies a configured Editor-owned value. It also keeps configured value owners pure and rejects generic public mutation APIs that do not name an invariant.

  Temporary exceptions are exact module, function, violation, and target tuples. Every exception must include a migration ticket, reason, and preserved invariant. Wildcards and path-based exceptions are rejected.
  """

  use Credo.Check,
    id: "EX9012",
    base_priority: :high,
    category: :design,
    param_defaults: [
      ownerships: [
        [
          struct: "MingaEditor.State.FileTree.Refresh",
          owners: ["MingaEditor.State.FileTree.Refresh"],
          paths: [[:file_tree, :refresh]],
          boundary: "MingaEditor.State.FileTree.Refresh transition API",
          workflow: "MingaEditor.FileTree.Freshness"
        ],
        [
          struct: "MingaEditor.State.FileTree",
          owners: ["MingaEditor.State.FileTree"],
          paths: [[:file_tree]],
          boundary: "MingaEditor.State.FileTree transition API",
          workflow: "MingaEditor.FileTree.Freshness or a focused file-tree workflow"
        ],
        [
          struct: "MingaEditor.State.RenderCorrelation",
          owners: ["MingaEditor.State.RenderCorrelation"],
          paths: [[:render_correlation]],
          boundary: "MingaEditor.State.RenderCorrelation transition API",
          workflow: "MingaEditor.RenderPipeline or MingaEditor.Handlers.RenderHandler"
        ],
        [
          struct: "MingaEditor.State.Frontend",
          owners: ["MingaEditor.State.Frontend"],
          paths: [[:frontend]],
          boundary:
            "MingaEditor.State.Frontend transition API for frontend capability, viewport, and input correlation",
          workflow: "the focused frontend connection or render workflow"
        ],
        [
          struct: "MingaEditor.State.Render",
          owners: ["MingaEditor.State.Render"],
          paths: [[:render]],
          boundary:
            "MingaEditor.State.Render transition API for renderer connection, layout observations, and message storage",
          workflow: "MingaEditor.RenderPipeline or a focused render workflow"
        ],
        [
          struct: "MingaEditor.State.Parser",
          owners: ["MingaEditor.State.Parser"],
          paths: [[:parser]],
          boundary:
            "MingaEditor.State.Parser transition API for parser availability and derived highlight caches",
          workflow: "the focused parser or highlighting workflow"
        ],
        [
          struct: "MingaEditor.State.AgentConnection",
          owners: ["MingaEditor.State.AgentConnection"],
          paths: [[:agent_connection]],
          boundary:
            "MingaEditor.State.AgentConnection transition API for agent transport and session connection state",
          workflow: "the focused agent connection workflow"
        ],
        [
          struct: "MingaEditor.State.Interaction",
          owners: ["MingaEditor.State.Interaction"],
          paths: [[:interaction]],
          boundary:
            "MingaEditor.State.Interaction transition API for input model, focus routing, and keystroke history",
          workflow: "the focused input workflow"
        ],
        [
          struct: "MingaEditor.State.ExtensionSurfaces",
          owners: ["MingaEditor.State.ExtensionSurfaces"],
          paths: [[:extension_surfaces]],
          boundary:
            "MingaEditor.State.ExtensionSurfaces transition API for per-editor extension registry identities",
          workflow: "the focused extension lifecycle workflow"
        ],
        [
          struct: "MingaEditor.State.BufferLifecycle",
          owners: ["MingaEditor.State.BufferLifecycle"],
          paths: [[:buffer_lifecycle]],
          boundary:
            "MingaEditor.State.BufferLifecycle transition API for buffer registration and retirement metadata",
          workflow: "the focused buffer lifecycle workflow"
        ],
        [
          struct: "MingaEditor.State.Git",
          owners: ["MingaEditor.State.Git"],
          paths: [[:git]],
          boundary:
            "MingaEditor.State.Git transition API for Git status and diff presentation state",
          workflow: "the focused Git workflow"
        ],
        [
          struct: "MingaEditor.State.Session",
          owners: ["MingaEditor.State.Session"],
          paths: [[:session]],
          boundary:
            "MingaEditor.State.Session transition API for session persistence configuration and timer intent",
          workflow: "MingaEditor.Handlers.SessionHandler or MingaEditor.Startup"
        ],
        [
          struct: "MingaEditor.State.Feedback",
          owners: ["MingaEditor.State.Feedback"],
          paths: [[:feedback]],
          boundary:
            "MingaEditor.State.Feedback transition API for operation progress and user-facing feedback values",
          workflow: "the focused operation feedback workflow"
        ],
        [
          struct: "MingaEditor.State.LSP",
          owners: ["MingaEditor.State.LSP"],
          paths: [[:lsp]],
          boundary:
            "MingaEditor.State.LSP transition API for server status, responses, requests, and timer intent",
          workflow: "MingaEditor.LSPActions or the focused LSP event workflow"
        ],
        [
          struct: "MingaEditor.State.Remote",
          owners: ["MingaEditor.State.Remote"],
          paths: [[:remote]],
          boundary: "MingaEditor.State.Remote transition API for remote session and file state",
          workflow: "the focused remote session workflow"
        ],
        [
          struct: "MingaEditor.State.Appearance",
          owners: ["MingaEditor.State.Appearance"],
          paths: [[:appearance]],
          boundary:
            "MingaEditor.State.Appearance transition API for theme and display preference state",
          workflow: "the focused appearance workflow"
        ],
        [
          struct: "MingaEditor.State",
          owners: ["MingaEditor.State"],
          paths: [],
          boundary: "MingaEditor.State root transition API for a documented root-wide invariant",
          workflow: "the focused Editor workflow that owns the external action"
        ],
        [
          struct: "MingaEditor.State.Mouse",
          owners: ["MingaEditor.State.Mouse"],
          paths: [[:workspace, :mouse]],
          boundary:
            "MingaEditor.State.Mouse transition API for drag, click, and hover presentation values",
          workflow: "MingaEditor.Mouse"
        ],
        [
          struct: "MingaEditor.Session.State",
          owners: ["MingaEditor.Session.State"],
          paths: [[:workspace]],
          boundary: "MingaEditor.Session.State aggregate transition API",
          workflow:
            "a focused Editor workflow or MingaEditor.State for a documented root-wide invariant"
        ],
        [
          struct: "MingaEditor.Session.HoverObservation",
          owners: ["MingaEditor.Session.HoverObservation"],
          paths: [[:workspace, :hover_observation]],
          boundary: "MingaEditor.Session.HoverObservation transition API",
          workflow: "a focused Editor hover workflow"
        ],
        [
          struct: "MingaEditor.Shell.Runtime",
          owners: ["MingaEditor.Shell.Runtime"],
          paths: [[:shell_runtime]],
          boundary: "MingaEditor.Shell.Runtime transition API",
          workflow: "MingaEditor.Shell.Workflow"
        ],
        [
          struct: "MingaEditor.Shell.StateStash",
          owners: ["MingaEditor.Shell.StateStash"],
          paths: [],
          boundary: "MingaEditor.Shell.StateStash transition API",
          workflow: "MingaEditor.Shell.Workflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.State",
          owners: ["MingaEditor.Shell.Traditional.State"],
          paths: [[:shell_state]],
          boundary: "MingaEditor.Shell.Traditional.State aggregate transition API",
          workflow: "a focused MingaEditor.Shell.Traditional workflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.Flashes",
          owners: ["MingaEditor.Shell.Traditional.Flashes"],
          paths: [[:flashes]],
          boundary: "MingaEditor.Shell.Traditional.Flashes transition API",
          workflow: "MingaEditor.Shell.Traditional.FlashesWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.NavFlash",
          owners: ["MingaEditor.Shell.Traditional.NavFlash"],
          paths: [[:flashes, :nav]],
          boundary: "MingaEditor.Shell.Traditional.NavFlash transition API",
          workflow: "MingaEditor.Shell.Traditional.FlashesWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.YankFlash",
          owners: ["MingaEditor.Shell.Traditional.YankFlash"],
          paths: [[:flashes, :yank]],
          boundary: "MingaEditor.Shell.Traditional.YankFlash transition API",
          workflow: "MingaEditor.Shell.Traditional.FlashesWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.Notice",
          owners: ["MingaEditor.Shell.Traditional.Notice"],
          paths: [[:notice]],
          boundary: "MingaEditor.Shell.Traditional.Notice transition API",
          workflow: "MingaEditor.Shell.Traditional.NoticeWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.GitToast",
          owners: ["MingaEditor.Shell.Traditional.GitToast"],
          paths: [[:git_toast]],
          boundary: "MingaEditor.Shell.Traditional.GitToast transition API",
          workflow: "MingaEditor.Shell.Traditional.GitToastWorkflow"
        ],
        [
          struct: "MingaEditor.State.WhichKey",
          owners: ["MingaEditor.State.WhichKey"],
          paths: [[:whichkey]],
          boundary: "MingaEditor.State.WhichKey transition API",
          workflow: "MingaEditor.Shell.Traditional.WhichKeyWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.Sidebars",
          owners: ["MingaEditor.Shell.Traditional.Sidebars"],
          paths: [[:sidebars]],
          boundary: "MingaEditor.Shell.Traditional.Sidebars transition API",
          workflow: "MingaEditor.Shell.Traditional.SidebarWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.Observatory",
          owners: ["MingaEditor.Shell.Traditional.Observatory"],
          paths: [[:sidebars, :observatory]],
          boundary: "MingaEditor.Shell.Traditional.Observatory transition API",
          workflow: "MingaEditor.Shell.Traditional.SidebarWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.AgentSurfaces",
          owners: ["MingaEditor.Shell.Traditional.AgentSurfaces"],
          paths: [[:agent_surfaces]],
          boundary: "MingaEditor.Shell.Traditional.AgentSurfaces transition API",
          workflow: "a focused Traditional agent workflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.ToolPrompts",
          owners: ["MingaEditor.Shell.Traditional.ToolPrompts"],
          paths: [[:tool_prompts]],
          boundary: "MingaEditor.Shell.Traditional.ToolPrompts transition API",
          workflow: "MingaEditor.Shell.Traditional.ToolPromptWorkflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.InputState",
          owners: ["MingaEditor.Shell.Traditional.InputState"],
          paths: [[:input]],
          boundary: "MingaEditor.Shell.Traditional.InputState transition API",
          workflow: "a focused Traditional input workflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.SpaceLeader",
          owners: ["MingaEditor.Shell.Traditional.SpaceLeader"],
          paths: [[:input, :space_leader]],
          boundary: "MingaEditor.Shell.Traditional.SpaceLeader transition API",
          workflow: "a focused Traditional input workflow"
        ],
        [
          struct: "MingaEditor.Shell.Traditional.ClickRegions",
          owners: ["MingaEditor.Shell.Traditional.ClickRegions"],
          paths: [[:input, :click_regions]],
          boundary: "MingaEditor.Shell.Traditional.ClickRegions transition API",
          workflow: "the Traditional render/input workflow"
        ],
        [
          struct: "MingaEditor.Agent.UIState",
          owners: ["MingaEditor.Agent.UIState", "MingaEditor.Agent.UIState.Presentation"],
          paths: [[:agent_ui]],
          boundary:
            "MingaEditor.Agent.UIState or MingaEditor.Agent.UIState.Presentation transition API",
          workflow: "a focused Editor agent workflow"
        ]
      ],
      pure_modules: :owners,
      allowlist: []
    ],
    explanations: [
      check: """
      Editor state values have one writer. Call the named owner transition API instead of updating a foreign struct. Value and aggregate owners stay pure; process, timer, task, logging, rendering, persistence, filesystem, and service work belongs in the named workflow boundary. Generic mutation APIs such as `update(value, fun)` are not valid owner transitions because they document no invariant.
      """,
      params: [
        ownerships:
          "Concrete Editor-owned struct, owner, receiver path, transition boundary, and workflow metadata.",
        pure_modules: "`:owners` or an explicit list of designated pure owner module names.",
        allowlist:
          "Exact legacy exceptions with module, function/MFA, violation, target, ticket, reason, and invariant."
      ]
    ]

  @dynamic_key_functions ~w(
    fetch fetch! get get_lazy get_and_update get_and_update! has_key? pop put put_new put_new_lazy
    replace replace! update update!
  )a
  @local_effect_calls ~w(send spawn spawn_link spawn_monitor)a
  @erlang_effect_calls ~w(send send_after start_timer cancel_timer monitor demonitor spawn spawn_link spawn_monitor)a
  @process_modules ~w(Process GenServer Task Agent Registry)
  @unrestricted_import_functions %{"Registry" => Registry.__info__(:functions)}
  @external_module_prefixes [
    "File",
    "System",
    ":timer",
    ":file",
    ":gen_server",
    "Minga.Log",
    "Minga.Events",
    "Minga.Buffer",
    "Minga.Session",
    "Minga.LSP",
    "Minga.Git",
    "Minga.Keymap",
    "Minga.Config.Options",
    "MingaAgent",
    "MingaEditor.Extension.Sidebar",
    "MingaEditor.Agent.SemanticUI.Registry",
    "MingaEditor.Renderer",
    "MingaEditor.RenderPipeline",
    "MingaEditor.Session",
    "MingaEditor.Frontend",
    "MingaEditor.EffectScheduler"
  ]
  @pure_value_modules ["MingaEditor.Renderer.RenderReceipt"]
  @valid_violations ~w(direct_write pure_call generic_api)

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    if production_elixir?(source_file) do
      issue_meta = IssueMeta.for(source_file, params)
      ownerships = Params.get(params, :ownerships, __MODULE__)
      pure_modules = configured_pure_modules(params, ownerships)
      allowlist = Params.get(params, :allowlist, __MODULE__)
      ast = SourceFile.ast(source_file)
      aliases = collect_aliases(ast)
      imports = collect_imports(ast, aliases)
      module = find_module(ast)

      config_issues = validate_config(ownerships, pure_modules, allowlist, issue_meta, module)

      scan(ast, %{module: nil, function: nil, bindings: %{}}, %{
        aliases: aliases,
        imports: imports,
        ownerships: ownerships,
        pure_modules: pure_modules,
        impure_owner_targets: impure_owner_targets(allowlist),
        allowlist: allowlist,
        issue_meta: issue_meta
      }) ++ config_issues
    else
      []
    end
  end

  defp scan({:defmodule, _meta, [module_ast, [do: body]]}, context, config) do
    module = module_name(module_ast, context, config.aliases)
    scan(body, %{context | module: module, function: nil, bindings: %{}}, config)
  end

  defp scan({:@, _meta, _args}, _context, _config), do: []

  defp scan({:->, _meta, [patterns, body]}, context, config) do
    branch_context = lexical_pattern_context(context, patterns, config.aliases)
    scan(patterns, context, config) ++ scan(body, branch_context, config)
  end

  defp scan({kind, meta, [head, blocks]} = ast, context, config)
       when kind in [:def, :defmacro, :defp, :defmacrop] and is_list(blocks) do
    case function_identity(head) do
      nil ->
        scan_children(ast, context, config)

      {name, arity, args} ->
        function = "#{name}/#{arity}"
        bindings = explicit_struct_bindings(head, context, config.aliases)
        function_context = %{context | function: function, bindings: bindings}
        body = Keyword.values(blocks)

        generic_issues =
          public_generic_api_issues(kind, name, args, head, body, meta, function_context, config)

        generic_issues ++ scan(body, function_context, config)
    end
  end

  defp scan(
         {:%, meta, [module_ast, {:%{}, _, [{:|, _, [receiver, updates]}]}]},
         context,
         config
       ) do
    struct = module_name(module_ast, context, config.aliases)
    issues = direct_update_issues(struct, updates, meta, context, config)
    issues ++ scan(receiver, context, config) ++ scan(updates, context, config)
  end

  defp scan({:%{}, meta, [{:|, _, [receiver, updates]}]}, context, config) do
    ownership = receiver_ownership(receiver, context, config.ownerships)
    issues = direct_update_issues(ownership, updates, meta, context, config)

    issues ++ scan(receiver, context, config) ++ scan(updates, context, config)
  end

  defp scan({:put_in, meta, args} = ast, context, config) when is_list(args) do
    issues =
      args
      |> List.first()
      |> field_path()
      |> drop_updated_field()
      |> ownership_for_path(config.ownerships)
      |> direct_write_issues(meta, context, config)

    issues ++ scan_children(ast, context, config)
  end

  defp scan({:update_in, meta, args} = ast, context, config) when is_list(args) do
    issues =
      args
      |> List.first()
      |> field_path()
      |> ownership_for_nested_path(config.ownerships)
      |> direct_write_issues(meta, context, config)

    issues ++ scan_children(ast, context, config)
  end

  defp scan(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, meta, [receiver | _]} = ast,
         context,
         config
       ) do
    issues =
      receiver
      |> field_path()
      |> ownership_for_path(config.ownerships)
      |> direct_write_issues(meta, context, config)

    issues ++ scan_children(ast, context, config)
  end

  defp scan({{:., _, [module_ast, function]}, meta, args} = ast, context, config)
       when is_atom(function) and is_list(args) do
    module = module_name(module_ast, context, config.aliases)
    issues = pure_call_issues(module, function, length(args), meta, context, config)
    issues ++ scan_children(ast, context, config)
  end

  defp scan({name, meta, args} = ast, context, config)
       when name in @local_effect_calls and is_list(args) do
    issues = pure_call_issues("Kernel", name, length(args), meta, context, config)
    issues ++ scan_children(ast, context, config)
  end

  defp scan({name, meta, args} = ast, context, config)
       when is_atom(name) and is_list(args) do
    module = imported_module(config.imports, name, length(args))
    issues = pure_call_issues(module, name, length(args), meta, context, config)
    issues ++ scan_children(ast, context, config)
  end

  defp scan(ast, context, config), do: scan_children(ast, context, config)

  defp scan_children(tuple, context, config) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.flat_map(&scan(&1, context, config))
  end

  defp scan_children(list, context, config) when is_list(list) do
    scan_sequence(list, context, config)
  end

  defp scan_children(_ast, _context, _config), do: []

  defp scan_sequence([], _context, _config), do: []

  defp scan_sequence([ast | rest], context, config) do
    scan(ast, context, config) ++
      scan_sequence(rest, context_after(ast, context, config.aliases), config)
  end

  defp context_after({:=, _, [left, right]}, context, aliases) do
    rebound_variables = pattern_variables(left)
    bindings = Map.drop(context.bindings, rebound_variables)

    match_bindings =
      %{}
      |> bind_pattern_variables(right, struct_pattern_name(left, context, aliases))
      |> bind_pattern_variables(left, struct_pattern_name(right, context, aliases))

    %{context | bindings: Map.merge(bindings, match_bindings)}
  end

  defp context_after(_ast, context, _aliases), do: context

  defp lexical_pattern_context(context, patterns, aliases) do
    bindings = Map.drop(context.bindings, pattern_variables(patterns))
    match_bindings = explicit_struct_bindings(patterns, context, aliases)
    %{context | bindings: Map.merge(bindings, match_bindings)}
  end

  defp direct_update_issues(ownership, updates, meta, context, config) do
    if owner_produced_root_installation?(ownership, updates, context, config) do
      []
    else
      direct_write_issues(ownership, meta, context, config)
    end
  end

  defp owner_produced_root_installation?(ownership, updates, context, config)
       when is_binary(ownership) do
    config.ownerships
    |> ownership_by_struct(ownership)
    |> owner_produced_root_installation?(updates, context, config)
  end

  defp owner_produced_root_installation?(ownership, updates, context, config)
       when is_list(ownership) and is_list(updates) do
    Keyword.fetch!(ownership, :struct) == "MingaEditor.State" and updates != [] and
      Enum.all?(updates, &owner_produced_root_field?(&1, context, config))
  end

  defp owner_produced_root_installation?(_ownership, _updates, _context, _config), do: false

  defp owner_produced_root_field?({field, value}, context, config) when is_atom(field) do
    case ownership_for_path([field], config.ownerships) do
      nil -> false
      ownership -> owner_call?(value, Keyword.fetch!(ownership, :owners), context, config.aliases)
    end
  end

  defp owner_produced_root_field?(_update, _context, _config), do: false

  defp owner_call?(
         {{:., _, [module_ast, function]}, _, args},
         owners,
         context,
         aliases
       )
       when is_atom(function) and is_list(args) do
    module_name(module_ast, context, aliases) in owners
  end

  defp owner_call?(_value, _owners, _context, _aliases), do: false

  defp direct_write_issues(nil, _meta, _context, _config), do: []

  defp direct_write_issues(struct, meta, context, config) when is_binary(struct) do
    case ownership_by_struct(config.ownerships, struct) do
      nil -> []
      ownership -> direct_write_issues(ownership, meta, context, config)
    end
  end

  defp direct_write_issues(ownership, meta, context, config) when is_list(ownership) do
    owner_modules = Keyword.fetch!(ownership, :owners)

    if context.module in owner_modules do
      []
    else
      target = Keyword.fetch!(ownership, :struct)
      owner = Enum.join(owner_modules, " or ")
      boundary = Keyword.fetch!(ownership, :boundary)

      issue_unless_allowed(
        "direct_write",
        target,
        meta,
        context,
        config,
        "Direct update to #{target} is outside its owner #{owner}. Use #{boundary}."
      )
    end
  end

  defp public_generic_api_issues(
         kind,
         _name,
         _args,
         _head,
         _body,
         _meta,
         _context,
         _config
       )
       when kind in [:defp, :defmacrop],
       do: []

  defp public_generic_api_issues(_kind, name, args, head, body, meta, context, config) do
    ownership = owner_ownership(config.ownerships, context.module)

    if ownership && generic_api?(name, args, head, body, context, config.aliases) do
      struct = Keyword.fetch!(ownership, :struct)
      boundary = Keyword.fetch!(ownership, :boundary)
      target = "#{context.module}.#{name}/#{length(args)}"

      issue_unless_allowed(
        "generic_api",
        target,
        meta,
        context,
        config,
        "Generic mutation API #{target} exposes arbitrary state changes for owner #{context.module} of #{struct}. Add a domain transition that encodes its invariant at #{boundary}."
      )
    else
      []
    end
  end

  defp generic_api?(_name, args, _head, body, context, aliases) do
    argument_names = args |> Enum.map(&argument_name/1) |> Enum.reject(&is_nil/1)

    (length(args) >= 2 and invokes_argument?(body, argument_names)) or
      (length(argument_names) >= 2 and
         uses_argument_as_dynamic_key?(body, argument_names, context, aliases))
  end

  defp argument_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp argument_name({:\\, _, [arg, _default]}), do: argument_name(arg)
  defp argument_name(_arg), do: nil

  defp invokes_argument?(ast, argument_names) do
    ast_contains?(ast, fn
      {{:., _, [{name, _, variable_context}]}, _, args}
      when is_atom(name) and is_atom(variable_context) and is_list(args) ->
        name in argument_names

      _ast ->
        false
    end)
  end

  defp uses_argument_as_dynamic_key?(ast, argument_names, context, aliases) do
    ast_contains?(ast, fn
      {{:., _, [module_ast, function]}, _, args}
      when function in @dynamic_key_functions and is_list(args) ->
        module_name(module_ast, context, aliases) in ["Map", "Access"] and
          argument_name(Enum.at(args, 0)) in argument_names and
          argument_name(Enum.at(args, 1)) in argument_names

      _ast ->
        false
    end)
  end

  defp ast_contains?(ast, predicate) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn node, found? ->
        {node, found? or predicate.(node)}
      end)

    found?
  end

  defp pure_call_issues(nil, _function, _arity, _meta, _context, _config), do: []

  defp pure_call_issues(module, function, arity, meta, context, config) do
    impure_owner_target? =
      MapSet.member?(config.impure_owner_targets, {module, Atom.to_string(function), arity})

    prohibited_boundary? = prohibited_call?(module, function) or impure_owner_target?

    value_only_target? =
      value_call?(config.ownerships, module, impure_owner_target?)

    if context.module in config.pure_modules and prohibited_boundary? and
         not value_only_target? do
      ownership = owner_ownership(config.ownerships, context.module)

      workflow =
        if ownership, do: Keyword.fetch!(ownership, :workflow), else: "a focused Editor workflow"

      target = "#{module}.#{function}"

      issue_unless_allowed(
        "pure_call",
        target,
        meta,
        context,
        config,
        "Pure owner #{context.module} calls prohibited external boundary #{target}. Keep the owner value-only and move this work to #{workflow}."
      )
    else
      []
    end
  end

  defp prohibited_call?(":file", :format_error), do: false

  defp prohibited_call?("Kernel", function) when function in @local_effect_calls, do: true
  defp prohibited_call?(":erlang", function) when function in @erlang_effect_calls, do: true

  defp prohibited_call?(module, _function) do
    Enum.any?(@process_modules ++ @external_module_prefixes, fn prefix ->
      module == prefix or String.starts_with?(module, prefix <> ".")
    end) or minga_storage_boundary?(module)
  end

  defp minga_storage_boundary?(module) do
    minga_namespace? =
      Enum.any?(["Minga.", "MingaAgent.", "MingaEditor."], &String.starts_with?(module, &1))

    minga_namespace? and
      Enum.any?(String.split(module, "."), &(&1 in ["Persistence", "Storage"]))
  end

  defp issue_unless_allowed(violation, target, meta, context, config, message) do
    if allowed?(config.allowlist, context, violation, target) do
      []
    else
      [
        format_issue(config.issue_meta,
          message: message,
          trigger: target,
          line_no: meta[:line] || 1
        )
      ]
    end
  end

  defp allowed?(allowlist, context, violation, target) do
    Enum.any?(allowlist, fn entry ->
      is_list(entry) and
        Keyword.get(entry, :module) == context.module and
        Keyword.get(entry, :function) == context.function and
        Keyword.get(entry, :violation) == violation and
        Keyword.get(entry, :target) == target
    end)
  end

  defp configured_pure_modules(params, ownerships) do
    case Params.get(params, :pure_modules, __MODULE__) do
      :owners -> ownerships |> Enum.flat_map(&Keyword.get(&1, :owners, [])) |> Enum.uniq()
      modules when is_list(modules) -> modules
      invalid -> invalid
    end
  end

  defp validate_config(ownerships, pure_modules, allowlist, issue_meta, module) do
    errors =
      validate_ownerships(ownerships) ++
        validate_pure_modules(pure_modules) ++
        validate_allowlist(allowlist)

    Enum.map(errors, fn error ->
      format_issue(issue_meta,
        message:
          "Editor ownership configuration is invalid for #{module || "this file"}: #{error}",
        trigger: "ownership configuration",
        line_no: 1
      )
    end)
  end

  defp validate_ownerships(ownerships) when is_list(ownerships) do
    Enum.flat_map(ownerships, fn ownership ->
      required = [:struct, :owners, :paths, :boundary, :workflow]

      if is_list(ownership) and Enum.all?(required, &Keyword.has_key?(ownership, &1)) and
           exact_module?(Keyword.get(ownership, :struct)) and
           valid_owner_list?(Keyword.get(ownership, :owners)) and
           valid_paths?(Keyword.get(ownership, :paths)) and
           documented?(Keyword.get(ownership, :boundary)) and
           documented?(Keyword.get(ownership, :workflow)) do
        []
      else
        [
          "ownership entries require an exact struct, non-empty owners, bounded atom paths, boundary, and workflow"
        ]
      end
    end)
  end

  defp validate_ownerships(_ownerships), do: ["ownerships must be a list"]

  defp validate_pure_modules(modules) when is_list(modules) do
    if Enum.all?(modules, &exact_module?/1),
      do: [],
      else: ["pure_modules must contain exact module names"]
  end

  defp validate_pure_modules(_modules),
    do: ["pure_modules must be :owners or a list of exact module names"]

  defp validate_allowlist(allowlist) when is_list(allowlist) do
    Enum.flat_map(allowlist, fn entry ->
      if valid_allowlist_entry?(entry) do
        []
      else
        [
          "allowlist entries require exact module, function/MFA, violation, target, migration ticket, reason, and invariant; wildcards and paths are forbidden"
        ]
      end
    end)
  end

  defp validate_allowlist(_allowlist), do: ["allowlist must be a list"]

  defp valid_allowlist_entry?(entry) when is_list(entry) do
    required = [:module, :function, :violation, :target, :ticket, :reason, :invariant]

    Enum.all?(required, &Keyword.has_key?(entry, &1)) and
      exact_module?(Keyword.get(entry, :module)) and
      exact_function?(Keyword.get(entry, :function)) and
      Keyword.get(entry, :violation) in @valid_violations and
      exact_target?(Keyword.get(entry, :target)) and
      migration_ticket?(Keyword.get(entry, :ticket)) and
      documented?(Keyword.get(entry, :reason)) and
      documented?(Keyword.get(entry, :invariant)) and
      not Keyword.has_key?(entry, :path)
  end

  defp valid_allowlist_entry?(_entry), do: false

  defp valid_owner_list?(owners) when is_list(owners) and owners != [],
    do: Enum.all?(owners, &exact_module?/1)

  defp valid_owner_list?(_owners), do: false

  defp valid_paths?(paths) when is_list(paths) do
    Enum.all?(paths, fn path -> is_list(path) and path != [] and Enum.all?(path, &is_atom/1) end)
  end

  defp valid_paths?(_paths), do: false

  defp exact_module?(value) when is_binary(value) do
    value =~ ~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/ and not wildcard?(value)
  end

  defp exact_module?(_value), do: false

  defp exact_function?(value) when is_binary(value) do
    value =~ ~r/^[a-z_][a-zA-Z0-9_?!]*\/\d+$/ and not wildcard?(value)
  end

  defp exact_function?(_value), do: false

  defp exact_target?(value) when is_binary(value) do
    value =~
      ~r/^(?:[A-Z][A-Za-z0-9_]*|:[a-z_][a-z0-9_]*)(?:\.[A-Za-z_][A-Za-z0-9_?!]*)*(?:\/\d+)?$/ and
      not wildcard?(value)
  end

  defp exact_target?(_value), do: false

  defp migration_ticket?(value) when is_binary(value), do: value =~ ~r/^#\d+$/
  defp migration_ticket?(_value), do: false

  defp documented?(value) when is_binary(value), do: String.length(String.trim(value)) >= 12
  defp documented?(_value), do: false

  defp wildcard?(value), do: String.contains?(value, ["*", "["])

  defp ownership_by_struct(ownerships, struct) do
    Enum.find(ownerships, &(Keyword.get(&1, :struct) == struct))
  end

  defp owner_ownership(ownerships, module) do
    Enum.find(ownerships, &(module in Keyword.get(&1, :owners, [])))
  end

  defp value_call?(_ownerships, module, false) when module in @pure_value_modules, do: true

  defp value_call?(ownerships, module, false) do
    Enum.any?(ownerships, &(module in Keyword.get(&1, :owners, [])))
  end

  defp value_call?(_ownerships, _module, true), do: false

  defp receiver_ownership({name, _, variable_context}, context, ownerships)
       when is_atom(name) and is_atom(variable_context) do
    context.bindings
    |> Map.get(name)
    |> binding_ownership(ownerships)
  end

  defp receiver_ownership(receiver, _context, ownerships) do
    receiver
    |> field_path()
    |> ownership_for_path(ownerships)
  end

  defp binding_ownership(nil, _ownerships), do: nil

  defp binding_ownership(struct, ownerships) do
    ownership_by_struct(ownerships, struct)
  end

  defp ownership_for_path(nil, _ownerships), do: nil

  defp ownership_for_path(path, ownerships) do
    ownerships
    |> Enum.flat_map(fn ownership ->
      ownership
      |> Keyword.get(:paths, [])
      |> Enum.map(fn owned_path -> {ownership, path_rank(path, owned_path)} end)
    end)
    |> Enum.reject(fn {_ownership, rank} -> is_nil(rank) end)
    |> Enum.max_by(fn {_ownership, rank} -> rank end, fn -> {nil, nil} end)
    |> elem(0)
  end

  defp path_rank(path, owned_path) do
    if List.ends_with?(path, owned_path), do: {length(path), length(owned_path)}
  end

  defp ownership_for_nested_path(nil, _ownerships), do: nil

  defp ownership_for_nested_path(path, ownerships) do
    ownerships
    |> Enum.flat_map(fn ownership ->
      ownership
      |> Keyword.get(:paths, [])
      |> Enum.map(fn owned_path -> {ownership, nested_path_rank(path, owned_path)} end)
    end)
    |> Enum.reject(fn {_ownership, rank} -> is_nil(rank) end)
    |> Enum.max_by(fn {_ownership, rank} -> rank end, fn -> {nil, nil} end)
    |> elem(0)
  end

  defp nested_path_rank(path, owned_path) do
    owned_length = length(owned_path)

    path
    |> Enum.chunk_every(owned_length, 1, :discard)
    |> Enum.with_index(owned_length)
    |> Enum.filter(fn {candidate, _end_index} -> candidate == owned_path end)
    |> Enum.map(fn {_candidate, end_index} -> {owned_length, end_index} end)
    |> Enum.max(fn -> nil end)
  end

  defp drop_updated_field(nil), do: nil
  defp drop_updated_field([]), do: []
  defp drop_updated_field(path), do: Enum.drop(path, -1)

  defp field_path({{:., _, [base, field]}, _, []}) when is_atom(field) do
    case field_path(base) do
      nil -> [field]
      path -> path ++ [field]
    end
  end

  defp field_path({_name, _, context}) when is_atom(context), do: nil
  defp field_path(_ast), do: nil

  defp function_identity({:when, _, [head | _guards]}), do: function_identity(head)
  defp function_identity({name, _, nil}) when is_atom(name), do: {name, 0, []}

  defp function_identity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args), args}

  defp function_identity(_head), do: nil

  defp explicit_struct_bindings(ast, context, aliases) do
    {_ast, bindings} =
      Macro.prewalk(ast, %{}, fn
        {:=, _, [left, right]} = node, acc ->
          acc = bind_pattern_variables(acc, right, struct_pattern_name(left, context, aliases))
          {node, bind_pattern_variables(acc, left, struct_pattern_name(right, context, aliases))}

        node, acc ->
          {node, acc}
      end)

    bindings
  end

  defp struct_pattern_name({:%, _, [module_ast, {:%{}, _, _fields}]}, context, aliases) do
    module_name(module_ast, context, aliases)
  end

  defp struct_pattern_name(_ast, _context, _aliases), do: nil

  defp bind_pattern_variables(bindings, _pattern, nil), do: bindings

  defp bind_pattern_variables(bindings, pattern, struct) do
    {_pattern, bindings} =
      Macro.prewalk(pattern, bindings, fn
        {name, _, variable_context} = node, acc
        when is_atom(name) and is_atom(variable_context) and name != :_ ->
          {node, Map.put(acc, name, struct)}

        node, acc ->
          {node, acc}
      end)

    bindings
  end

  defp pattern_variables(pattern) do
    {_pattern, variables} =
      Macro.prewalk(pattern, MapSet.new(), fn
        {name, _, variable_context} = node, acc
        when is_atom(name) and is_atom(variable_context) and name != :_ ->
          {node, MapSet.put(acc, name)}

        node, acc ->
          {node, acc}
      end)

    MapSet.to_list(variables)
  end

  defp collect_imports(ast, aliases) do
    context = %{module: find_module(ast)}

    {_ast, imports} =
      Macro.prewalk(ast, [], fn
        {:import, _, [module_ast]} = node, acc ->
          {node, [import_entry(module_ast, [], context, aliases) | acc]}

        {:import, _, [module_ast, opts]} = node, acc when is_list(opts) ->
          {node, [import_entry(module_ast, opts, context, aliases) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reject(imports, &is_nil(&1.module))
  end

  defp import_entry(module_ast, opts, context, aliases) do
    module = module_name(module_ast, context, aliases)
    only = import_selection(Keyword.get(opts, :only), :only)

    %{
      module: module,
      only: only || Map.get(@unrestricted_import_functions, module, []),
      except: import_selection(Keyword.get(opts, :except), :except)
    }
  end

  defp import_selection(nil, :only), do: nil
  defp import_selection(nil, :except), do: []
  defp import_selection(:functions, _kind), do: nil
  defp import_selection(:macros, _kind), do: []

  defp import_selection(selection, _kind) when is_list(selection) do
    Enum.filter(selection, fn
      {name, arity} when is_atom(name) and is_integer(arity) -> true
      _entry -> false
    end)
  end

  defp import_selection(_selection, :only), do: []
  defp import_selection(_selection, :except), do: []

  defp imported_module(imports, function, arity) do
    Enum.find_value(imports, fn import ->
      imported? =
        (is_nil(import.only) or {function, arity} in import.only) and
          {function, arity} not in import.except

      if imported?, do: import.module
    end)
  end

  defp impure_owner_targets(allowlist) do
    allowlist
    |> Enum.flat_map(fn
      entry when is_list(entry) ->
        with "pure_call" <- Keyword.get(entry, :violation),
             module when is_binary(module) <- Keyword.get(entry, :module),
             function when is_binary(function) <- Keyword.get(entry, :function),
             [name, arity_string] <- String.split(function, "/", parts: 2),
             {arity, ""} <- Integer.parse(arity_string) do
          [{module, name, arity}]
        else
          _invalid -> []
        end

      _invalid ->
        []
    end)
    |> MapSet.new()
  end

  defp collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, [module_ast]} = node, acc ->
          {node, put_alias(acc, module_ast, nil)}

        {:alias, _, [module_ast, opts]} = node, acc ->
          {node, put_alias(acc, module_ast, Keyword.get(opts, :as))}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp put_alias(aliases, {:__aliases__, _, parts}, nil) do
    if Enum.all?(parts, &is_atom/1) do
      Map.put(aliases, List.last(parts), Enum.map_join(parts, ".", &Atom.to_string/1))
    else
      aliases
    end
  end

  defp put_alias(aliases, {:__aliases__, _, parts}, {:__aliases__, _, as_parts}) do
    if Enum.all?(parts, &is_atom/1) and Enum.all?(as_parts, &is_atom/1) do
      Map.put(aliases, List.last(as_parts), Enum.map_join(parts, ".", &Atom.to_string/1))
    else
      aliases
    end
  end

  defp put_alias(aliases, _module_ast, _as), do: aliases

  defp find_module(ast) do
    {_ast, module} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, nil ->
          {node, Enum.map_join(parts, ".", &Atom.to_string/1)}

        node, acc ->
          {node, acc}
      end)

    module
  end

  defp module_name({:__MODULE__, _, _}, context, _aliases), do: context.module

  defp module_name({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, context, _aliases) do
    if context.module && Enum.all?(parts, &is_atom/1) do
      Enum.join([context.module | Enum.map(parts, &Atom.to_string/1)], ".")
    end
  end

  defp module_name({:__aliases__, _, [short]}, _context, aliases) when is_atom(short) do
    Map.get(aliases, short, Atom.to_string(short))
  end

  defp module_name({:__aliases__, _, parts}, _context, _aliases) do
    if Enum.all?(parts, &is_atom/1), do: Enum.map_join(parts, ".", &Atom.to_string/1)
  end

  defp module_name(atom, _context, _aliases) when is_atom(atom), do: inspect(atom)
  defp module_name(_ast, _context, _aliases), do: nil

  defp production_elixir?(%SourceFile{} = source_file) do
    filename = source_file.filename |> Path.expand() |> Path.relative_to_cwd()
    String.ends_with?(filename, [".ex", ".exs"]) and not String.starts_with?(filename, "test/")
  end
end
