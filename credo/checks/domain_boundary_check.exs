defmodule Minga.Credo.DomainBoundaryCheck do
  @moduledoc """
  Enforces domain boundaries for all facade'd domains in Minga.

  Each domain has a facade module (e.g., `Minga.Buffer`) that is the
  only valid entry point from outside the domain. Any reference to an
  internal module (alias, import, require, use) from outside the domain
  is a violation. No exceptions for struct types, protocols, or
  behaviours: if something is genuinely needed across multiple domains,
  it should be promoted to a core entity at the top level.

  See AGENTS.md § "Domain Architecture" and BIG_REFACTOR_PLAN.md
  § "Domain Architecture Integration" for the full rationale.
  """

  use Credo.Check,
    id: "EX9001",
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Minga uses bounded contexts (domains) with facade modules as the
      only valid entry point. Code outside a domain must go through the
      facade, not reference internal modules directly.

      Example: use `Minga.Buffer.content(buf)` instead of
      `Minga.Buffer.Server.content(buf)`.

      If a struct, protocol, or behaviour is needed across domains,
      promote it to a core entity rather than reaching past the facade.
      """
    ]

  @reference_forms [:alias, :import, :require, :use]

  # Domain facade modules. The facade is the only valid entry point.
  @domains %{
    agent: "Minga.Agent",
    buffer: "Minga.Buffer",
    editing: "Minga.Editing",
    frontend: "Minga.Frontend",
    ui: "Minga.UI",
    project: "Minga.Project",
    language: "Minga.Language",
    session: "Minga.Session",
    config: "Minga.Config",
    keymap: "Minga.Keymap",
    command: "Minga.Command",
    git: "Minga.Git",
    input: "Minga.Input",
    mode: "Minga.Mode"
  }

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    filename = source_file.filename
    source_domain = domain_for_file(filename)

    # Skip test files (tests naturally reference the modules they test)
    if test_file?(filename) do
      []
    else
      source_file
      |> Credo.Code.prewalk(&find_violations(&1, &2, source_domain, issue_meta))
      |> Enum.filter(&is_map/1)
    end
  end

  defp find_violations(
         {form, meta, [{:__aliases__, _, ref_parts} | _]} = ast,
         issues,
         source_domain,
         issue_meta
       )
       when form in @reference_forms do
    if Enum.all?(ref_parts, &is_atom/1) do
      ref_name = Enum.map_join(ref_parts, ".", &Atom.to_string/1)
      target_domain = domain_for_module(ref_name)

      if target_domain &&
           target_domain != source_domain &&
           ref_name != Map.fetch!(@domains, target_domain) do
        facade = Map.fetch!(@domains, target_domain)

        issue =
          format_issue(issue_meta,
            message:
              "Domain boundary violation: #{form} #{ref_name}. " <>
                "Use the `#{facade}` facade instead.",
            trigger: ref_name,
            line_no: meta[:line]
          )

        {ast, [issue | issues]}
      else
        {ast, issues}
      end
    else
      {ast, issues}
    end
  end

  defp find_violations(ast, issues, _source_domain, _issue_meta),
    do: {ast, issues}

  defp test_file?(filename) do
    String.contains?(Path.expand(filename), "/test/")
  end

  # Determine which domain a file belongs to from its path.
  @spec domain_for_file(String.t()) :: atom() | nil
  defp domain_for_file(filename) do
    expanded = Path.expand(filename)

    Enum.find_value(@domains, fn {domain, _facade} ->
      if String.contains?(expanded, "/minga/#{domain}/"), do: domain
    end)
  end

  # Determine which domain a module belongs to from its name.
  @spec domain_for_module(String.t()) :: atom() | nil
  defp domain_for_module(ref_name) do
    Enum.find_value(@domains, fn {domain, facade} ->
      if ref_name == facade || String.starts_with?(ref_name, facade <> ".") do
        domain
      end
    end)
  end
end
