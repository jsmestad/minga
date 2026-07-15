Code.require_file("editor_state_ownership/config.exs", __DIR__)
Code.require_file("editor_state_ownership/ownership.exs", __DIR__)
Code.require_file("editor_state_ownership/policy.exs", __DIR__)
Code.require_file("editor_state_ownership/source_environment.exs", __DIR__)
Code.require_file("editor_state_ownership/type_flow.exs", __DIR__)
Code.require_file("editor_state_ownership/direct_write_rule.exs", __DIR__)
Code.require_file("editor_state_ownership/generic_api_rule.exs", __DIR__)
Code.require_file("editor_state_ownership/purity_rule.exs", __DIR__)
Code.require_file("editor_state_ownership/validator.exs", __DIR__)
Code.require_file("editor_state_ownership/analysis.exs", __DIR__)
Code.require_file("editor_state_ownership/reporter.exs", __DIR__)

defmodule Minga.Credo.EditorStateOwnershipCheck do
  @moduledoc """
  Enforces explicit ownership and purity boundaries for Editor state values.

  EX9012 is an orchestration entry point. Validated policy, lexical source
  environments, type flow, and each rule category live in focused modules under
  `Minga.Credo.EditorStateOwnership`.
  """

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias Minga.Credo.EditorStateOwnership.Analysis
  alias Minga.Credo.EditorStateOwnership.Config
  alias Minga.Credo.EditorStateOwnership.Reporter
  alias Minga.Credo.EditorStateOwnership.Validator

  use Credo.Check,
    id: "EX9012",
    base_priority: :high,
    category: :design,
    param_defaults: [
      ownerships: Config.ownerships(),
      pure_modules: Config.pure_modules(),
      allowlist: Config.allowlist()
    ],
    explanations: [
      check: """
      Editor state values have one writer. Call the named owner transition API instead of updating a foreign struct. Value and aggregate owners stay pure; process, timer, task, logging, rendering, persistence, filesystem, registry, replay, workflow, and service work belongs in the named workflow boundary. Generic mutation APIs such as `update(value, fun)` are not valid owner transitions because they document no invariant.
      """,
      params: [
        ownerships:
          "Concrete Editor-owned struct, owner, receiver path, transition boundary, and workflow metadata.",
        pure_modules: "`:owners` or an explicit list of designated pure owner module names.",
        allowlist: "Must remain empty; EX9012 ownership exceptions are not accepted."
      ]
    ]

  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    if production_elixir?(source_file), do: analyze(source_file, params), else: []
  end

  @spec analyze(Credo.SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  defp analyze(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    ownerships = Params.get(params, :ownerships, __MODULE__)
    pure_modules = Params.get(params, :pure_modules, __MODULE__)
    allowlist = Params.get(params, :allowlist, __MODULE__)
    ast = SourceFile.ast(source_file)

    case Validator.validate(ownerships, pure_modules, allowlist) do
      {:ok, policy} ->
        ast
        |> Analysis.analyze(policy)
        |> Reporter.issues(issue_meta, &format_issue/2)

      {:error, errors} ->
        Reporter.config_issues(
          errors,
          issue_meta,
          Analysis.source_module(ast),
          &format_issue/2
        )
    end
  end

  @spec production_elixir?(Credo.SourceFile.t()) :: boolean()
  defp production_elixir?(%SourceFile{} = source_file) do
    filename = source_file.filename |> Path.expand() |> Path.relative_to_cwd()
    String.ends_with?(filename, [".ex", ".exs"]) and not String.starts_with?(filename, "test/")
  end
end
