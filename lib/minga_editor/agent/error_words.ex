defmodule MingaEditor.Agent.ErrorWords do
  @moduledoc """
  Turns the reason an agent session refused a request into plain words for a notice or a task row.

  Session calls such as `MingaAgent.Session.continue/1` return `{:error, term()}`, and a notice takes a string. Every place that reports such a reason goes through `describe/1`, so a new reason shape reads as words everywhere instead of crashing the one caller that forgot it.
  """

  @doc """
  Describes `reason` in plain words.

  A string is already words. An atom reads with spaces for underscores. A failed conversation save names what failed. Any other term is shown as Elixir would print it, so nothing is hidden.

      iex> MingaEditor.Agent.ErrorWords.describe("No active agent session")
      "No active agent session"

      iex> MingaEditor.Agent.ErrorWords.describe({:conversation_persistence_failed, :invalid_continuation_boundaries})
      "the conversation could not be saved (invalid continuation boundaries)"
  """
  @spec describe(term()) :: String.t()
  def describe(reason) when is_binary(reason), do: reason

  def describe({:conversation_persistence_failed, reason}),
    do: "the conversation could not be saved (#{describe(reason)})"

  def describe(reason) when is_atom(reason) and not is_boolean(reason) and not is_nil(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  def describe(reason), do: inspect(reason)
end
