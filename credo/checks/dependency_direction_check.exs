defmodule Minga.Credo.DependencyDirectionCheck do
  @moduledoc """
  Enforces dependency direction rules for Minga's layered architecture.

  Code is organized in three layers with dependencies flowing downward only:

  - **Layer 0** (pure foundations): Buffer.Document, Editing.Motion, Core.*,
    Mode.* FSM modules. No dependencies on other Minga modules.
  - **Layer 1** (stateful services): Buffer.Process, Config.*, Language.*,
    LSP.*, Git.*, Project.*, Keymap.*, Parser.*, Frontend.Manager/Protocol.
    May depend on Layer 0 only.
  - **Layer 2** (orchestration/presentation): Editor.*, Shell.*, Input.*,
    Session.*, plus presentation sub-namespaces from Frontend (Emit,
    Protocol.GUI), UI (Picker, Popup.Lifecycle, Prompt), and Agent (View,
    UIState, Events, SlashCommand). May depend on Layers 0 and 1.

  An upward dependency (Layer 0 importing from Layer 1 or 2, or Layer 1
  importing from Layer 2) is flagged as a violation.

  See AGENTS.md § "Code Organization" for the full rationale.
  """

  use Credo.Check,
    id: "EX9001",
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Minga uses layered dependency direction: Layer 0 (pure) → Layer 1
      (services) → Layer 2 (orchestration). Dependencies flow downward
      only. If a Layer 0 module imports from Layer 1 or 2, or a Layer 1
      module imports from Layer 2, that's a violation.

      Fix by moving logic to the correct layer, or by passing the needed
      data as a function argument instead of importing the module.
      """
    ]

  @reference_forms [:alias, :import, :require, :use]

  # Layer 0: Pure foundations. No dependencies on other Minga modules.
  # Entire directories (Minga.Core, Minga.Mode) are Layer 0.
  # Individual modules from mixed directories (buffer/, editing/) are listed explicitly.
  @layer_0_prefixes [
    "Minga.Buffer.ChangeLog",
    "Minga.Buffer.Cursor",
    "Minga.Buffer.Document",
    "Minga.Buffer.EditDelta",
    "Minga.Buffer.EditSource",
    "Minga.Buffer.Lines",
    "Minga.Buffer.Position",
    "Minga.Buffer.RenderSnapshot",
    "Minga.Buffer.SaveState",
    "Minga.Buffer.Selection",
    "Minga.Buffer.Span",
    "Minga.Buffer.State",
    "Minga.Buffer.UndoHistory",
    "Minga.Buffer.UndoPatch",
    "Minga.Editing.Motion",
    "Minga.Editing.Operator",
    "Minga.Editing.TextObject",
    "Minga.Editing.Search",
    "Minga.Editing.AutoPair",
    "Minga.Editing.Comment",
    "Minga.Editing.Text.Readable",
    "Minga.Editing.NavigableContent",
    "Minga.Editing.Scroll",
    "Minga.Editing.Fold.Range",
    "Minga.Editing.Model",
    "Minga.Core",
    "Minga.Mode",
    "Minga.RenderModel",
    "Minga.Command.Parser",
    "Minga.Keymap.Bindings",
    "Minga.Keymap.KeyParser",
    "Minga.Keymap.NormalPrefixes",
    "Minga.Keymap.Sigil",
    # Pure data struct under the UI.Picker blanket; must be accessible from Layer 1.
    "MingaEditor.UI.Picker.Item"
  ]

  # Layer 2: Orchestration and presentation.
  #
  # Some namespaces (Frontend, UI, Agent) are split across layers. The
  # sub-namespaces listed here are presentation modules that legitimately
  # depend on Editor/Shell state. The rest of those namespaces stays Layer 1.
  @layer_2_prefixes [
    "MingaEditor",
    "MingaEditor.Shell",
    "MingaEditor.Input",
    "MingaEditor.Session",
    # Render pipeline tail (emit + GUI protocol encoding)
    "MingaEditor.Frontend.Emit",
    "MingaEditor.Frontend.Protocol.GUI",
    "MingaEditor.Frontend.Protocol.GUIWindowContent",
    # UI presentation (picker, popup lifecycle, prompts).
    # Blanket prefix: Picker and Picker.Item are technically pure data, but
    # nothing in Layer 1 references them today. Picker.Item is carved out in
    # @layer_0_prefixes above so Layer 1 can use it if needed.
    "MingaEditor.UI.Picker",
    "MingaEditor.UI.Popup.Lifecycle",
    "MingaEditor.UI.Popup.Active",
    "MingaEditor.UI.Prompt",
    # Agent presentation
    "MingaEditor.Agent.View",
    "MingaEditor.Agent.UIState",
    "MingaEditor.Agent.ViewContext",
    "MingaEditor.Agent.Events",
    "MingaEditor.Agent.SlashCommand",
    "MingaEditor.Agent.DiffReview",
    "MingaEditor.Agent.DiffRenderer"
  ]

  # Allowed cross-layer references for structural dispatch.
  #
  # This map should stay small. Each entry must explain why the cross-layer
  # reference is wire-format dispatch rather than an architectural violation.
  # Do not add entries to silence violations that should be fixed with code changes.
  @allowed_references %{
    # Protocol.decode_event/1 dispatches GUI action decoding to Protocol.GUI.
    # This is wire-format dispatch, not a dependency on presentation state.
    "MingaEditor.Frontend.Protocol" => ["MingaEditor.Frontend.Protocol.GUI"],
    # Frontend facade calls Protocol.GUI for GUI-specific config encoding
    # (line spacing, etc.). Same structural dispatch pattern.
    "MingaEditor.Frontend" => ["MingaEditor.Frontend.Protocol.GUI"]
    # All pre-existing cross-layer violations from #1368 have been resolved
    # in Wave 6 Track B. Modules were moved to their correct layers:
    # - Devicon → Minga.Language.Devicon
    # - Grammar → Minga.Language.Grammar
    # - Popup.Rule/Registry → Minga.Popup.Rule/Registry
    # - Parser protocol → Minga.Parser.Protocol
    # - Theme loading → Events broadcast
  }

  # MingaAgent internal levels. These are intentionally separate from the
  # top-level Minga/MingaAgent/MingaEditor layers above. The broad Level 1
  # fallback reflects the current codebase; later extraction tickets can move
  # specific bundled integrations to Level 2 as registry boundaries land.
  @agent_level_0_prefixes [
    "Minga.Extension.Agent",
    "MingaAgent.Branch",
    "MingaAgent.Changeset.BudgetExhaustedEvent",
    "MingaAgent.Changeset.MergedEvent",
    "MingaAgent.CostCalculator",
    "MingaAgent.EditBoundary",
    "MingaAgent.Event",
    "MingaAgent.EventLog.EventRecord",
    "MingaAgent.EventLog.Taxonomy",
    "MingaAgent.Hooks.Hook",
    "MingaAgent.Hooks.NotificationPayload",
    "MingaAgent.Hooks.PostToolUsePayload",
    "MingaAgent.Hooks.PreCompactPayload",
    "MingaAgent.Hooks.PreToolUsePayload",
    "MingaAgent.Hooks.Result",
    "MingaAgent.Hooks.SessionEndPayload",
    "MingaAgent.Hooks.SessionStartPayload",
    "MingaAgent.Hooks.StopPayload",
    "MingaAgent.Hooks.UserPromptSubmitPayload",
    "MingaAgent.Instruction",
    "MingaAgent.InternalState",
    "MingaAgent.MCP.ServerConfig",
    "MingaAgent.MCP.Tool",
    "MingaAgent.MCP.Transport",
    "MingaAgent.Message",
    "MingaAgent.ModelLimits",
    "MingaAgent.OAuth.PendingFlow.Entry",
    "MingaAgent.Provider",
    "MingaAgent.RuntimeState",
    "MingaAgent.Subagent.Handle",
    "MingaAgent.TodoItem",
    "MingaAgent.TokenEstimator",
    "MingaAgent.Tool.Spec",
    "MingaAgent.ToolApproval.Preview",
    "MingaAgent.ToolCall",
    "MingaAgent.TurnUsage",
    "MingaEditor.Agent.SlashCommand.Command"
  ]

  @agent_level_1_prefixes [
    "Minga.Extension.AgentAPI",
    "Minga.Extension.CodeLease",
    "MingaAgent"
  ]

  @agent_level_2_prefixes [
    "MingaAgent.ToolPacks",
    "MingaEditor"
  ]

  # Cross-cutting modules allowed everywhere.
  @cross_cutting [
    "Minga.Events",
    "Minga.Log",
    "Minga.Telemetry",
    "Minga.Clipboard"
  ]

  @impl true
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    filename = source_file.filename

    if test_file?(filename) do
      []
    else
      source_layer = layer_for_file(filename)
      source_module = source_file_to_module_name(source_file)

      source_file
      |> Credo.Code.prewalk(&find_violations(&1, &2, source_layer, source_module, issue_meta))
      |> Enum.filter(&is_map/1)
    end
  end

  defp find_violations(
         {{:., meta, [{:__aliases__, _, ref_parts}, function]}, _, _args} = ast,
         issues,
         source_layer,
         source_module,
         issue_meta
       )
       when source_layer != nil and function != :{} do
    if Enum.all?(ref_parts, &is_atom/1) do
      ref_name = Enum.map_join(ref_parts, ".", &Atom.to_string/1)
      issues = check_agent_ref_violations(ast, issues, source_module, ref_name, meta, issue_meta)
      {ast, issues}
    else
      {ast, issues}
    end
  end

  defp find_violations(
         {form, meta, _args} = ast,
         issues,
         source_layer,
         source_module,
         issue_meta
       )
       when source_layer != nil and form in [:def, :defp, :defmacro, :defmacrop] do
    issues = check_direct_alias_refs(ast, issues, source_layer, source_module, meta, issue_meta)
    {ast, issues}
  end

  defp find_violations(
         {:%, meta, [{:__aliases__, _, ref_parts} | _]} = ast,
         issues,
         source_layer,
         source_module,
         issue_meta
       )
       when source_layer != nil do
    if Enum.all?(ref_parts, &is_atom/1) do
      ref_name = Enum.map_join(ref_parts, ".", &Atom.to_string/1)
      issues = check_agent_ref_violations(ast, issues, source_module, ref_name, meta, issue_meta)
      {ast, issues}
    else
      {ast, issues}
    end
  end

  defp find_violations(
         {form, meta, _args} = ast,
         issues,
         source_layer,
         source_module,
         issue_meta
       )
       when source_layer != nil and form in [:@, :defstruct] do
    issues = check_direct_alias_refs(ast, issues, source_layer, source_module, meta, issue_meta)
    {ast, issues}
  end

  defp find_violations(
         {form, meta,
          [
            {{:., _, [{:__aliases__, _, base_parts}, :{}]}, _, grouped_refs}
          ]} = ast,
         issues,
         source_layer,
         source_module,
         issue_meta
       )
       when form in @reference_forms and source_layer != nil do
    if Enum.all?(base_parts, &is_atom/1) do
      issues =
        Enum.reduce(grouped_refs, issues, fn
          {:__aliases__, _, ref_parts}, acc when is_list(ref_parts) ->
            ref_name = Enum.map_join(base_parts ++ ref_parts, ".", &Atom.to_string/1)

            check_ref_violations(
              ast,
              acc,
              source_layer,
              source_module,
              ref_name,
              meta,
              issue_meta
            )

          _grouped_ref, acc ->
            acc
        end)

      {ast, issues}
    else
      {ast, issues}
    end
  end

  defp find_violations(
         {form, meta, [{:__aliases__, _, ref_parts} | _]} = ast,
         issues,
         source_layer,
         source_module,
         issue_meta
       )
       when form in @reference_forms and source_layer != nil do
    if Enum.all?(ref_parts, &is_atom/1) do
      ref_name = Enum.map_join(ref_parts, ".", &Atom.to_string/1)

      issues =
        check_ref_violations(ast, issues, source_layer, source_module, ref_name, meta, issue_meta)

      {ast, issues}
    else
      {ast, issues}
    end
  end

  defp find_violations(ast, issues, _source_layer, _source_module, _issue_meta),
    do: {ast, issues}

  defp check_direct_alias_refs(ast, issues, _source_layer, source_module, meta, issue_meta) do
    ast
    |> direct_alias_refs()
    |> Enum.reduce(issues, fn {ref_parts, ref_meta}, acc ->
      ref_name = Enum.map_join(ref_parts, ".", &Atom.to_string/1)
      check_agent_ref_violations(ast, acc, source_module, ref_name, ref_meta || meta, issue_meta)
    end)
  end

  defp direct_alias_refs(
         {{:., _meta, [{:__aliases__, _alias_meta, _ref_parts}, _function]}, _call_meta, _args}
       ),
       do: []

  defp direct_alias_refs({:%, _meta, [{:__aliases__, _alias_meta, _ref_parts} | _args]}), do: []

  defp direct_alias_refs({:__aliases__, meta, ref_parts}) when length(ref_parts) >= 2 do
    if Enum.all?(ref_parts, &is_atom/1), do: [{ref_parts, meta}], else: []
  end

  defp direct_alias_refs(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> direct_alias_refs()

  defp direct_alias_refs(list) when is_list(list), do: Enum.flat_map(list, &direct_alias_refs/1)
  defp direct_alias_refs(_), do: []

  defp check_agent_ref_violations(_ast, issues, source_module, ref_name, meta, issue_meta) do
    if cross_cutting?(ref_name) || not minga_module?(ref_name) do
      issues
    else
      source_agent_level = agent_level_for_module(source_module)
      target_agent_level = agent_level_for_module(ref_name)

      case agent_level_violation(source_agent_level, target_agent_level, ref_name) do
        {:violation, message} ->
          issue =
            format_issue(issue_meta,
              message: message,
              trigger: ref_name,
              line_no: meta[:line]
            )

          [issue | issues]

        :ok ->
          issues
      end
    end
  end

  defp check_ref_violations(ast, issues, source_layer, source_module, ref_name, meta, issue_meta) do
    if cross_cutting?(ref_name) || not minga_module?(ref_name) do
      issues
    else
      target_layer = layer_for_module(ref_name)

      {_ast, issues} =
        check_violation(
          ast,
          issues,
          source_layer,
          source_module,
          target_layer,
          ref_name,
          meta,
          issue_meta
        )

      issues
    end
  end

  defp check_violation(
         ast,
         issues,
         source_layer,
         source_module,
         target_layer,
         ref_name,
         meta,
         issue_meta
       ) do
    source_agent_level = agent_level_for_module(source_module)
    target_agent_level = agent_level_for_module(ref_name)

    case agent_level_violation(source_agent_level, target_agent_level, ref_name) do
      {:violation, message} ->
        issue =
          format_issue(issue_meta,
            message: message,
            trigger: ref_name,
            line_no: meta[:line]
          )

        {ast, [issue | issues]}

      :ok ->
        check_top_level_violation(
          ast,
          issues,
          source_layer,
          source_module,
          target_layer,
          ref_name,
          meta,
          issue_meta
        )
    end
  end

  defp check_top_level_violation(
         ast,
         issues,
         _source_layer,
         _source_module,
         nil,
         _ref_name,
         _meta,
         _issue_meta
       ),
       do: {ast, issues}

  defp check_top_level_violation(
         ast,
         issues,
         source_layer,
         source_module,
         target_layer,
         ref_name,
         meta,
         issue_meta
       ) do
    if allowed_reference?(source_module, ref_name) do
      {ast, issues}
    else
      check_top_level_direction(
        ast,
        issues,
        source_layer,
        target_layer,
        ref_name,
        meta,
        issue_meta
      )
    end
  end

  defp check_top_level_direction(ast, issues, 0, target_layer, ref_name, meta, issue_meta)
       when target_layer > 0 do
    issue =
      format_issue(issue_meta,
        message:
          "Layer violation: Layer 0 module references Layer #{target_layer} module #{ref_name}. " <>
            "Layer 0 (pure) modules must not depend on stateful services or orchestration.",
        trigger: ref_name,
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp check_top_level_direction(ast, issues, 1, 2, ref_name, meta, issue_meta) do
    issue =
      format_issue(issue_meta,
        message:
          "Layer violation: Layer 1 module references Layer 2 module #{ref_name}. " <>
            "Services must not depend on orchestration/presentation. Pass data as arguments instead.",
        trigger: ref_name,
        line_no: meta[:line]
      )

    {ast, [issue | issues]}
  end

  defp check_top_level_direction(
         ast,
         issues,
         _source_layer,
         _target_layer,
         _ref_name,
         _meta,
         _issue_meta
       ),
       do: {ast, issues}

  defp agent_level_violation(0, target_level, ref_name) when target_level in [1, 2] do
    {:violation,
     "Agent level violation: Agent Level 0 module references Agent Level #{target_level} module #{ref_name}. " <>
       "Agent Level 0 modules are pure contracts, value types, and safety interfaces; pass data in instead of depending on runtime services or UI integrations."}
  end

  defp agent_level_violation(1, 2, ref_name) do
    {:violation,
     "Agent level violation: Agent Level 1 module references Agent Level 2 module #{ref_name}. " <>
       "Agent runtime services and registries must not depend on bundled integrations or presentation modules."}
  end

  defp agent_level_violation(_source_level, _target_level, _ref_name), do: :ok

  defp test_file?(filename) do
    String.contains?(Path.expand(filename), "/test/")
  end

  @spec layer_for_file(String.t()) :: 0 | 1 | 2 | nil
  defp layer_for_file(filename) do
    filename
    |> Path.expand()
    |> layer_for_expanded_file()
  end

  defp layer_for_expanded_file(path) do
    case layer_0_file?(path) do
      true -> 0
      false -> layer_for_non_layer_0_file(path)
    end
  end

  defp layer_for_non_layer_0_file(path) do
    case layer_2_file?(path) do
      true -> 2
      false -> layer_for_service_file(path)
    end
  end

  defp layer_for_service_file(path) do
    case String.contains?(path, "/minga_agent/") or String.contains?(path, "/minga/") do
      true -> 1
      false -> nil
    end
  end

  defp layer_0_file?(path) do
    Enum.any?(@layer_0_prefixes, fn prefix ->
      # Convert module prefix to path fragment: "Minga.Core.Face" -> "/minga/core/face"
      path_fragment = module_to_path_fragment(prefix)
      String.contains?(path, path_fragment)
    end)
  end

  defp layer_2_file?(path) do
    Enum.any?(@layer_2_prefixes, fn prefix ->
      path_fragment = module_to_path_fragment(prefix)
      String.contains?(path, path_fragment)
    end)
  end

  @spec layer_for_module(String.t()) :: 0 | 1 | 2 | nil
  defp layer_for_module(ref_name) do
    case layer_0_module?(ref_name) do
      true -> 0
      false -> layer_for_non_layer_0_module(ref_name)
    end
  end

  defp layer_for_non_layer_0_module(ref_name) do
    case layer_2_module?(ref_name) do
      true -> 2
      false -> layer_for_service_module(ref_name)
    end
  end

  defp layer_for_service_module(ref_name) do
    case String.starts_with?(ref_name, "MingaAgent.") or String.starts_with?(ref_name, "Minga.") do
      true -> 1
      false -> nil
    end
  end

  defp layer_0_module?(ref_name) do
    Enum.any?(@layer_0_prefixes, fn prefix ->
      ref_name == prefix || String.starts_with?(ref_name, prefix <> ".")
    end)
  end

  defp layer_2_module?(ref_name) do
    Enum.any?(@layer_2_prefixes, fn prefix ->
      ref_name == prefix || String.starts_with?(ref_name, prefix <> ".")
    end)
  end

  @spec agent_level_for_module(String.t() | nil) :: 0 | 1 | 2 | nil
  defp agent_level_for_module(nil), do: nil

  defp agent_level_for_module(ref_name) do
    case agent_level_prefix_match(ref_name, @agent_level_0_prefixes) do
      true -> 0
      false -> agent_level_1_or_2_for_module(ref_name)
    end
  end

  defp agent_level_1_or_2_for_module(ref_name) do
    case agent_level_prefix_match(ref_name, @agent_level_2_prefixes) do
      true -> 2
      false -> agent_level_1_for_module(ref_name)
    end
  end

  defp agent_level_1_for_module(ref_name) do
    case agent_level_prefix_match(ref_name, @agent_level_1_prefixes) do
      true -> 1
      false -> nil
    end
  end

  defp agent_level_prefix_match(ref_name, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      ref_name == prefix || String.starts_with?(ref_name, prefix <> ".")
    end)
  end

  defp cross_cutting?(ref_name) do
    Enum.any?(@cross_cutting, fn prefix ->
      ref_name == prefix || String.starts_with?(ref_name, prefix <> ".")
    end)
  end

  defp minga_module?(ref_name) do
    String.starts_with?(ref_name, "Minga.") ||
      String.starts_with?(ref_name, "MingaEditor.") ||
      String.starts_with?(ref_name, "MingaAgent.")
  end

  defp module_to_path_fragment(module_name) do
    "/" <> Enum.map_join(String.split(module_name, "."), "/", &Macro.underscore/1)
  end

  defp allowed_reference?(source_module, ref_name) do
    case Map.get(@allowed_references, source_module) do
      nil ->
        false

      allowed ->
        Enum.any?(allowed, fn prefix ->
          ref_name == prefix || String.starts_with?(ref_name, prefix <> ".")
        end)
    end
  end

  # Prefer the declared module over path reconstruction so acronym modules like
  # RemoteAPI, MCP, and OAuth keep their exact casing for classification.
  defp source_file_to_module_name(%SourceFile{} = source_file) do
    source_file
    |> SourceFile.ast()
    |> ast_to_module_name()
    |> case do
      nil -> file_to_module_name(source_file.filename)
      module_name -> module_name
    end
  end

  defp ast_to_module_name(ast) do
    {_ast, module_name} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _meta, [{:__aliases__, _, parts} | _]} = node, nil ->
          {node, Enum.map_join(parts, ".", &Atom.to_string/1)}

        node, module_name ->
          {node, module_name}
      end)

    module_name
  end

  # Convert a file path like "lib/minga/frontend/protocol.ex" to a module
  # name like "MingaEditor.Frontend.Protocol". Used only as a fallback.
  defp file_to_module_name(filename) do
    filename
    |> Path.expand()
    |> then(fn path ->
      case Regex.run(~r{lib/(.+)\.ex$}, path) do
        [_, rel] ->
          rel
          |> String.split("/")
          |> Enum.map_join(".", &Macro.camelize/1)

        _ ->
          nil
      end
    end)
  end
end
