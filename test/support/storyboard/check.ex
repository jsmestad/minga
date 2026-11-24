defmodule Minga.Test.Storyboard.Check do
  @moduledoc """
  One design assertion for a scenario, run against its semantic model.

  `run` raises `ExUnit.AssertionError` when the frame disagrees with the design; use the functions in `Minga.Test.Storyboard.Assertions`. A check with `pending: issue` names the surface ticket that makes it true. The suite still runs pending checks and fails when one starts passing, so the ticket that lands the surface must promote it (shrink-only, like `test/fixtures/keymap/grammar_baseline.tsv`).
  """

  alias Minga.Test.Storyboard.Model

  @type t :: %__MODULE__{
          name: String.t(),
          run: (Model.t() -> term()),
          pending: pos_integer() | nil
        }

  @enforce_keys [:name, :run]
  defstruct [:name, :run, pending: nil]

  @doc "An active check: it must pass today."
  @spec new(String.t(), (Model.t() -> term())) :: t()
  def new(name, run) when is_function(run, 1), do: %__MODULE__{name: name, run: run}

  @doc "A check the design asks for that waits on the named surface ticket."
  @spec pending(String.t(), pos_integer(), (Model.t() -> term())) :: t()
  def pending(name, issue, run) when is_integer(issue) and is_function(run, 1),
    do: %__MODULE__{name: name, run: run, pending: issue}

  @doc """
  Runs the check. Returns `:ok` or `{:error, message}`; never raises.

  Any exception counts as a failed check, so a pending check over a surface that is not built yet (a missing field, an unmatched clause) reports as not passing instead of crashing the suite.
  """
  @spec run(t(), Model.t()) :: :ok | {:error, String.t()}
  def run(%__MODULE__{run: run}, %Model{} = model) do
    _ = run.(model)
    :ok
  rescue
    error in [ExUnit.AssertionError] -> {:error, error.message}
    error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
  end
end
