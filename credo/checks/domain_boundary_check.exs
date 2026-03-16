defmodule Minga.Credo.DomainBoundaryCheck do
  @moduledoc """
  Enforces domain boundaries between Minga.Agent and Minga.Buffer.

  These are separate bounded contexts that share infrastructure through
  Minga.Editor, Minga.EditingModel, and Minga.NavigableContent, but must
  never import from each other directly.

  ## Why this exists

  The original Minga architecture had agent code scattered inside the
  editor namespace (editor/commands/agent.ex, input/scoped.ex with agent
  branches). Every feature required changes in multiple domains. This
  check prevents that coupling from creeping back in after the domain
  reorganization.

  See docs/REFACTOR.md § "Why Not Surfaces?" for the full history.

  ## Rules

  - `Minga.Agent.*` modules must not alias, import, require, or use
    any `Minga.Buffer.*` module.
  - `Minga.Buffer.*` modules must not alias, import, require, or use
    any `Minga.Agent.*` module.
  - Both may freely reference `Minga.Editor.*`, `Minga.EditingModel.*`,
    `Minga.NavigableContent`, `Minga.Input.*`, and other shared
    infrastructure.
  """

  use Credo.Check,
    id: "EX9001",
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Minga.Agent and Minga.Buffer are separate domains that must not
      import from each other. Both may use shared infrastructure
      (Minga.Editor, Minga.EditingModel, Minga.NavigableContent) but
      never cross-reference each other's modules.

      If you need shared functionality, move it to shared infrastructure
      or use the NavigableContent protocol.
      """
    ]

  @reference_forms [:alias, :import, :require, :use]

  # Agent modules that are allowed to reference Buffer.Server.
  # The agent's prompt buffer is a Buffer.Server instance, so these
  # cross-domain references are deliberate and unavoidable.
  @allowed_agent_buffer_modules [
    "Minga.Agent.View.Renderer",
    "Minga.Agent.UiState",
    "Minga.Agent.BufferSync",
    "Minga.Agent.ChatDecorations"
  ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    # Determine what domain this file's module is in from the filename.
    # This avoids tracking module names through AST traversal state.
    filename = source_file.filename

    source_domain = domain_for_file(filename)
    source_module = module_for_file(filename)

    # Skip files outside agent/buffer domains, and skip test files
    # (tests naturally need to reference the modules they test).
    if source_domain && source_module do
      source_file
      |> Credo.Code.prewalk(&find_violations(&1, &2, source_domain, source_module, issue_meta))
      |> Enum.filter(&is_map/1)
    else
      []
    end
  end

  defp find_violations(
         {form, meta, [{:__aliases__, _, ref_parts} | _]} = ast,
         issues,
         source_domain,
         source_module,
         issue_meta
       )
       when form in @reference_forms do
    ref_name = Enum.join(ref_parts, ".")
    target_domain = domain_for_module(ref_name)

    if target_domain && violates_boundary?(source_domain, target_domain) &&
         not allowed?(source_module, source_domain, target_domain) do
      issue =
        format_issue(issue_meta,
          message:
            "#{source_domain} must not reference #{target_domain} (domain boundary violation: #{form} #{ref_name})",
          trigger: ref_name,
          line_no: meta[:line]
        )

      {ast, [issue | issues]}
    else
      {ast, issues}
    end
  end

  defp find_violations(ast, issues, _source_domain, _source_module, _issue_meta),
    do: {ast, issues}

  # Check if this specific module is allowed to cross the boundary.
  defp allowed?(nil, _source_domain, _target_domain), do: false

  defp allowed?(source_module, :agent, :buffer) do
    source_module in @allowed_agent_buffer_modules
  end

  defp allowed?(_source_module, _source_domain, _target_domain), do: false

  # Extract a likely module name from the file path.
  # Returns nil for test files (tests are always allowed to cross boundaries).
  defp module_for_file(filename) do
    expanded = Path.expand(filename)

    if String.contains?(expanded, "/test/") do
      nil
    else
      expanded
      |> String.split("/lib/")
      |> List.last()
      |> String.trim_trailing(".ex")
      |> String.split("/")
      |> Enum.map_join(".", &Macro.camelize/1)
    end
  end

  defp domain_for_file(filename) do
    expanded = Path.expand(filename)

    cond do
      String.contains?(expanded, "/minga/agent/") -> :agent
      String.contains?(expanded, "/minga/buffer/") -> :buffer
      true -> nil
    end
  end

  defp domain_for_module("Minga.Agent." <> _), do: :agent
  defp domain_for_module("Minga.Buffer." <> _), do: :buffer
  defp domain_for_module(_), do: nil

  defp violates_boundary?(:agent, :buffer), do: true
  defp violates_boundary?(:buffer, :agent), do: true
  defp violates_boundary?(_, _), do: false
end
