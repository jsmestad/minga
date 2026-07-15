defmodule Minga.Credo.EditorStateOwnership.Reporter do
  @moduledoc """
  Converts EX9012 analysis findings and configuration errors into Credo issues.

  Messages consistently identify the concrete receiver, expected owner, and
  transition or workflow boundary required to perform the operation.
  """

  alias Minga.Credo.EditorStateOwnership.Ownership

  @typedoc "An AST analysis finding emitted by the ownership scanner."
  @type finding :: %{
          required(:violation) => String.t(),
          required(:target) => String.t(),
          required(:receiver) => String.t(),
          required(:module) => String.t() | nil,
          required(:function) => String.t() | nil,
          required(:line) => pos_integer(),
          optional(:ownership) => Ownership.t()
        }

  @type formatter :: (Credo.IssueMeta.t(), keyword() -> Credo.Issue.t())

  @doc "Formats all analysis findings as Credo issues."
  @spec issues([finding()], Credo.IssueMeta.t(), formatter()) :: [Credo.Issue.t()]
  def issues(findings, issue_meta, formatter) do
    Enum.map(findings, &issue(&1, issue_meta, formatter))
  end

  @doc "Formats invalid configuration as Credo issues on the first source line."
  @spec config_issues([String.t()], Credo.IssueMeta.t(), String.t() | nil, formatter()) ::
          [Credo.Issue.t()]
  def config_issues(errors, issue_meta, module, formatter) do
    Enum.map(errors, fn error ->
      formatter.(issue_meta,
        message:
          "Editor ownership configuration is invalid for #{module || "this file"}: #{error}",
        trigger: "ownership configuration",
        line_no: 1
      )
    end)
  end

  @spec issue(finding(), Credo.IssueMeta.t(), formatter()) :: Credo.Issue.t()
  defp issue(
         %{violation: "direct_write", ownership: %Ownership{} = ownership} = finding,
         issue_meta,
         formatter
       ) do
    owners = Enum.join(ownership.owners, " or ")

    formatter.(issue_meta,
      message:
        "Direct update: receiver #{finding.receiver} resolves to #{ownership.struct} and is outside its owner #{owners}; " <>
          "expected owner #{owners}. Use #{ownership.boundary}; cross-owner coordination belongs in #{ownership.workflow}.",
      trigger: finding.target,
      line_no: finding.line
    )
  end

  defp issue(
         %{violation: "pure_call", ownership: %Ownership{} = ownership} = finding,
         issue_meta,
         formatter
       ) do
    owners = Enum.join(ownership.owners, " or ")

    formatter.(issue_meta,
      message:
        "Pure owner #{finding.module}: receiver #{finding.receiver} has expected owner #{owners} but calls " <>
          "prohibited external boundary #{finding.target}. Keep the owner value-only and move this work to #{ownership.workflow}.",
      trigger: finding.target,
      line_no: finding.line
    )
  end

  defp issue(
         %{violation: "generic_api", ownership: %Ownership{} = ownership} = finding,
         issue_meta,
         formatter
       ) do
    owners = Enum.join(ownership.owners, " or ")

    formatter.(issue_meta,
      message:
        "Generic mutation API receiver #{finding.receiver} exposes arbitrary changes to #{ownership.struct}; expected " <>
          "owner #{owners}. Add a domain transition that encodes its invariant at #{ownership.boundary}.",
      trigger: finding.target,
      line_no: finding.line
    )
  end
end
