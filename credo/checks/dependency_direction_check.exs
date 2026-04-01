defmodule Minga.Credo.DependencyDirectionCheck do
  @moduledoc """
  Enforces dependency direction rules for Minga's layered architecture.

  Code is organized in three layers with dependencies flowing downward only:

  - **Layer 0** (pure foundations): Buffer.Document, Editing.Motion, Core.*,
    Mode.* FSM modules. No dependencies on other Minga modules.
  - **Layer 1** (stateful services): Buffer.Server, Config.*, Language.*,
    LSP.*, Git.*, Project.*, Keymap.*, Parser.*, Frontend.Manager/Protocol.
    May depend on Layer 0 only.
  - **Layer 2** (orchestration/presentation): Editor.*, Shell.*, Input.*,
    Workspace.*, plus presentation sub-namespaces from Frontend (Emit,
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
    "Minga.Buffer.Document",
    "Minga.Buffer.EditDelta",
    "Minga.Buffer.EditSource",
    "Minga.Buffer.RenderSnapshot",
    "Minga.Buffer.State",
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
    "Minga.Command.Parser",
    "Minga.Keymap.Bindings",
    "Minga.Keymap.NormalPrefixes",
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
    "MingaEditor.Workspace",
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
    "MingaEditor.Agent.DiffRenderer",
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
    "MingaEditor.Frontend" => ["MingaEditor.Frontend.Protocol.GUI"],
    # All pre-existing cross-layer violations from #1368 have been resolved
    # in Wave 6 Track B. Modules were moved to their correct layers:
    # - Devicon → Minga.Language.Devicon
    # - Grammar → Minga.Language.Grammar
    # - Popup.Rule/Registry → Minga.Popup.Rule/Registry
    # - Parser protocol → Minga.Parser.Protocol
    # - Theme loading → Events broadcast
  }

  # Cross-cutting modules allowed everywhere.
  @cross_cutting [
    "Minga.Events",
    "Minga.Log",
    "Minga.Telemetry",
    "Minga.Clipboard"
  ]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    filename = source_file.filename

    if test_file?(filename) do
      []
    else
      source_layer = layer_for_file(filename)
      source_module = file_to_module_name(filename)

      source_file
      |> Credo.Code.prewalk(&find_violations(&1, &2, source_layer, source_module, issue_meta))
      |> Enum.filter(&is_map/1)
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

      if cross_cutting?(ref_name) || not minga_module?(ref_name) do
        {ast, issues}
      else
        target_layer = layer_for_module(ref_name)

        check_violation(
          ast, issues, source_layer, source_module, target_layer, ref_name, meta, issue_meta
        )
      end
    else
      {ast, issues}
    end
  end

  defp find_violations(ast, issues, _source_layer, _source_module, _issue_meta),
    do: {ast, issues}

  defp check_violation(ast, issues, source_layer, source_module, target_layer, ref_name, meta, issue_meta) do
    cond do
      target_layer == nil ->
        # Unknown module, skip
        {ast, issues}

      allowed_reference?(source_module, ref_name) ->
        {ast, issues}

      source_layer == 0 and target_layer > 0 ->
        issue =
          format_issue(issue_meta,
            message:
              "Layer violation: Layer 0 module references Layer #{target_layer} module #{ref_name}. " <>
                "Layer 0 (pure) modules must not depend on stateful services or orchestration.",
            trigger: ref_name,
            line_no: meta[:line]
          )

        {ast, [issue | issues]}

      source_layer == 1 and target_layer == 2 ->
        issue =
          format_issue(issue_meta,
            message:
              "Layer violation: Layer 1 module references Layer 2 module #{ref_name}. " <>
                "Services must not depend on orchestration/presentation. Pass data as arguments instead.",
            trigger: ref_name,
            line_no: meta[:line]
          )

        {ast, [issue | issues]}

      true ->
        {ast, issues}
    end
  end

  defp test_file?(filename) do
    String.contains?(Path.expand(filename), "/test/")
  end

  @spec layer_for_file(String.t()) :: 0 | 1 | 2 | nil
  defp layer_for_file(filename) do
    expanded = Path.expand(filename)

    cond do
      layer_0_file?(expanded) -> 0
      layer_2_file?(expanded) -> 2
      String.contains?(expanded, "/minga_agent/") -> 1
      String.contains?(expanded, "/minga/") -> 1
      true -> nil
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
    cond do
      layer_0_module?(ref_name) -> 0
      layer_2_module?(ref_name) -> 2
      String.starts_with?(ref_name, "MingaAgent.") -> 1
      String.starts_with?(ref_name, "Minga.") -> 1
      true -> nil
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
      nil -> false
      allowed -> Enum.any?(allowed, fn prefix ->
        ref_name == prefix || String.starts_with?(ref_name, prefix <> ".")
      end)
    end
  end

  # Convert a file path like "lib/minga/frontend/protocol.ex" to a module
  # name like "MingaEditor.Frontend.Protocol". Used for @allowed_references lookup.
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
