defmodule Minga.Test.Storyboard.KnownViolations do
  @moduledoc """
  Flow-graph violations the real editor has today, each tied to the issue that removes it.

  The list lives in `test/fixtures/storyboard/known_violations.tsv` and only shrinks: `test/storyboard/flow_explorer_test.exs` fails on a violation that is not listed, and on a listed row that no longer happens. Never add a row to make a new violation pass; fix it, or file a bug and fix it.

  Columns, tab-separated: invariant, scenario, keys, command, issue, reason.
  """

  @path Path.expand("../../fixtures/storyboard/known_violations.tsv", __DIR__)
  @external_resource @path

  @typedoc "One known violation."
  @type row :: %{
          invariant: String.t(),
          scenario: String.t(),
          keys: String.t(),
          command: String.t(),
          issue: pos_integer(),
          reason: String.t()
        }

  @typedoc "What identifies a violation: invariant, scenario and keys."
  @type identity :: {String.t(), String.t(), String.t()}

  @doc "Path of the list."
  @spec path() :: Path.t()
  def path, do: @path

  @doc "Every listed violation."
  @spec rows() :: [row()]
  def rows do
    @path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(&parse/1)
  end

  @doc "The identity of a row or of a violation found by the explorer."
  @spec identity(%{invariant: String.t(), scenario: String.t(), keys: String.t()}) :: identity()
  def identity(%{invariant: invariant, scenario: scenario, keys: keys}),
    do: {invariant, scenario, keys}

  @doc "Commands whose key paths are listed; the random walk leaves them out because the explorer already tracks them."
  @spec commands() :: [String.t()]
  def commands, do: rows() |> Enum.map(& &1.command) |> Enum.uniq()

  @spec parse(String.t()) :: row()
  defp parse(line) do
    [invariant, scenario, keys, command, issue, reason] = String.split(line, "\t")

    %{
      invariant: invariant,
      scenario: scenario,
      keys: keys,
      command: command,
      issue: String.to_integer(issue),
      reason: reason
    }
  end
end
