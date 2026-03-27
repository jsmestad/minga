defmodule Minga.Credo.DependencyDirectionCheck do
  @moduledoc """
  Enforces dependency direction rules for Minga's layered architecture.

  Code is organized in three layers with dependencies flowing downward only:

  - **Layer 0** (pure foundations): Buffer.Document, Editing.Motion, Core.*,
    Mode.* FSM modules. No dependencies on other Minga modules.
  - **Layer 1** (stateful services): Buffer.Server, Config.*, Language.*,
    LSP.*, Git.*, Project.*, Agent.*, Keymap.*, Parser.*, Frontend.*.
    May depend on Layer 0 only.
  - **Layer 2** (orchestration/presentation): Editor.*, Shell.*, Input.*,
    Workspace.*. May depend on Layers 0 and 1.

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
    "Minga.Editing.Model",
    "Minga.Core",
    "Minga.Mode",
    "Minga.Keymap.Bindings",
    "Minga.Keymap.NormalPrefixes"
  ]

  # Layer 2: Orchestration and presentation.
  @layer_2_prefixes [
    "Minga.Editor",
    "Minga.Shell",
    "Minga.Input",
    "Minga.Workspace"
  ]

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

      source_file
      |> Credo.Code.prewalk(&find_violations(&1, &2, source_layer, issue_meta))
      |> Enum.filter(&is_map/1)
    end
  end

  defp find_violations(
         {form, meta, [{:__aliases__, _, ref_parts} | _]} = ast,
         issues,
         source_layer,
         issue_meta
       )
       when form in @reference_forms and source_layer != nil do
    if Enum.all?(ref_parts, &is_atom/1) do
      ref_name = Enum.map_join(ref_parts, ".", &Atom.to_string/1)

      if cross_cutting?(ref_name) || not String.starts_with?(ref_name, "Minga.") do
        {ast, issues}
      else
        target_layer = layer_for_module(ref_name)
        check_violation(ast, issues, source_layer, target_layer, ref_name, meta, issue_meta)
      end
    else
      {ast, issues}
    end
  end

  defp find_violations(ast, issues, _source_layer, _issue_meta),
    do: {ast, issues}

  defp check_violation(ast, issues, source_layer, target_layer, ref_name, meta, issue_meta) do
    cond do
      target_layer == nil ->
        # Unknown module, skip
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

  defp module_to_path_fragment(module_name) do
    "/" <> Enum.map_join(String.split(module_name, "."), "/", &Macro.underscore/1)
  end
end
