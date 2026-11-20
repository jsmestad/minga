defmodule Minga.Credo.NoTrueWithCheck do
  @moduledoc """
  Rejects new literal `true <-` generators in the `with` special form.

  The baseline gives each legacy RHS, in its original file, one allowance per
  row. Fingerprints retain the clause's AST but ignore source positions and
  formatting. Delete a row whenever its clause is removed; never add rows for
  new or rewritten clauses. This keeps deletions from freeing up allowances.
  """

  @baseline_path Path.join(__DIR__, "no_true_with_baseline.tsv")
  @external_resource @baseline_path
  @baseline @baseline_path
            |> File.stream!()
            |> Stream.reject(&String.starts_with?(&1, "#"))
            |> Enum.reduce(%{}, fn line, files ->
              [filename, key, rhs] =
                line |> String.trim_trailing() |> String.split("\t", parts: 3)

              Map.update(files, filename, %{key => {rhs, 1}}, fn clauses ->
                Map.update(clauses, key, {rhs, 1}, fn {rhs, count} -> {rhs, count + 1} end)
              end)
            end)

  use Credo.Check,
    id: "EX9016",
    base_priority: :high,
    category: :warning,
    param_defaults: [legacy: @baseline],
    explanations: [
      check: """
      Use `if` or `cond` for predicates. Use `with` for dependent success
      bindings with meaningful failure results rather than matching `true`.
      """
    ]

  @impl Credo.Check
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    legacy = Map.get(Params.get(params, :legacy, __MODULE__), source_file.filename, %{})

    {issues, unused} =
      source_file
      |> Credo.Code.prewalk(&collect_generators/2)
      |> Enum.sort_by(fn {line, column, _rhs} -> {line, column} end)
      |> Enum.reduce({[], legacy}, fn {line, column, rhs}, {issues, unused} ->
        key = fingerprint(rhs)

        case unused do
          %{^key => {_text, 1}} ->
            {issues, Map.delete(unused, key)}

          %{^key => {text, count}} ->
            {issues, %{unused | key => {text, count - 1}}}

          %{} ->
            issue =
              format_issue(issue_meta,
                message:
                  "Avoid `true <-` in `with`. Use `if`, `cond`, or a meaningful success result.",
                trigger: "<-",
                line_no: line,
                column: column
              )

            {[issue | issues], unused}
        end
      end)

    Enum.reduce(unused, issues, fn {key, {rhs, count}}, issues ->
      issue =
        format_issue(issue_meta,
          message:
            "Remove #{count} stale baseline row(s) for `true <-` with RHS #{rhs} (#{key}) " <>
              "from credo/checks/no_true_with_baseline.tsv.",
          trigger: Issue.no_trigger()
        )

      [issue | issues]
    end)
  end

  # The special form is a bare :with node, unlike calls to other modules'
  # macros named with. Only its direct arguments can be its generators.
  defp collect_generators({:with, _, args} = node, acc) when is_list(args) do
    acc =
      Enum.reduce(args, acc, fn
        {:<-, meta, [true, rhs]}, acc -> [{meta[:line], meta[:column], rhs} | acc]
        _, acc -> acc
      end)

    {node, acc}
  end

  defp collect_generators(node, acc), do: {node, acc}

  defp fingerprint(rhs) do
    ast =
      Macro.prewalk(rhs, fn
        # On a zero-arity dot expression this distinguishes field access
        # from an explicit call. Other parser metadata is positional or cosmetic.
        {name, meta, args} when is_list(meta) -> {name, Keyword.take(meta, [:no_parens]), args}
        node -> node
      end)

    digest = :crypto.hash(:sha256, :erlang.term_to_binary(ast, [:deterministic]))
    Base.encode16(digest, case: :lower)
  end
end
