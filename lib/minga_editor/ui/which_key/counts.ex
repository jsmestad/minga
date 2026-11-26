defmodule MingaEditor.UI.WhichKey.Counts do
  @moduledoc """
  Live counts for which-key entries ("Tasks · 1 needs you", "Review · 3", "Code › · 1 error").

  Counts come from the same facts the modeline shows, so the two never disagree, and the builder recomputes them on every frame, so a count changes while the panel is open. A count is keyed by what the entry does, never by its key or label: `{:command, command}` for a command row and `{:group, prefix}` for a group, where `prefix` is the formatted sequence after the leader (`"a"` for `SPC a`).

  The text is drawn verbatim after the label: `"· 1 needs you"` after a command or a group, `"· 3"` for a bare number. Its tone names the colour role: `:needs_you` and `:error` draw in those state roles, as the modeline does, and `:muted` in the secondary colour.
  """

  @typedoc "What a count belongs to."
  @type target :: {:command, atom() | tuple()} | {:group, String.t()}

  alias Minga.RenderModel.UI.WhichKey

  @typedoc "One count: its text and the colour role it draws in."
  @type count :: WhichKey.count()

  @typedoc "Counts by target; a target with nothing to count is absent."
  @type t :: %{target() => count()}

  @typedoc "The facts counts are made from."
  @type facts :: %{
          optional(:needs_you_count) => non_neg_integer(),
          optional(:diagnostic_counts) =>
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          optional(:git_diff_summary) =>
            {non_neg_integer(), non_neg_integer(), non_neg_integer()} | nil,
          optional(:pending_review_count) => non_neg_integer()
        }

  @doc """
  Builds the counts from modeline facts.

  ## Examples

      iex> MingaEditor.UI.WhichKey.Counts.from_facts(%{needs_you_count: 1, diagnostic_counts: {2, 0, 0, 0}})
      %{
        {:command, :agent_attach_diagnostics} => %{text: "· 2 errors", tone: :error},
        {:command, :agent_tasks} => %{text: "· 1 needs you", tone: :needs_you},
        {:command, :diagnostics_list} => %{text: "· 2 errors", tone: :error},
        {:group, "a"} => %{text: "· 1 needs you", tone: :needs_you},
        {:group, "c"} => %{text: "· 2 errors", tone: :error}
      }
  """
  @spec from_facts(facts()) :: t()
  def from_facts(facts) when is_map(facts) do
    [
      needs_you(Map.get(facts, :needs_you_count, 0)),
      errors(Map.get(facts, :diagnostic_counts)),
      changed(Map.get(facts, :git_diff_summary)),
      reviews(Map.get(facts, :pending_review_count, 0))
    ]
    |> List.flatten()
    |> Map.new()
  end

  @doc "Returns the count for `target`, or an empty muted count."
  @spec get(t(), target()) :: count()
  def get(counts, target) when is_map(counts),
    do: Map.get(counts, target, %{text: "", tone: :muted})

  @spec needs_you(non_neg_integer()) :: [{target(), count()}]
  defp needs_you(count) when is_integer(count) and count > 0 do
    count = %{text: "· #{count} needs you", tone: :needs_you}
    [{{:group, "a"}, count}, {{:command, :agent_tasks}, count}]
  end

  defp needs_you(_count), do: []

  @spec errors(tuple() | nil) :: [{target(), count()}]
  defp errors({errors, _warnings, _info, _hints}) when is_integer(errors) and errors > 0 do
    count = %{text: "· #{errors} #{plural(errors, "error", "errors")}", tone: :error}

    [
      {{:group, "c"}, count},
      {{:command, :diagnostics_list}, count},
      {{:command, :agent_attach_diagnostics}, count}
    ]
  end

  defp errors(_counts), do: []

  @spec changed(tuple() | nil) :: [{target(), count()}]
  defp changed({added, modified, deleted}) when added + modified + deleted > 0,
    do: [{{:group, "g"}, %{text: "· #{added + modified + deleted} changed", tone: :muted}}]

  defp changed(_summary), do: []

  @spec reviews(non_neg_integer()) :: [{target(), count()}]
  defp reviews(count) when is_integer(count) and count > 0,
    do: [{{:command, :workspace_pending_reviews}, %{text: "· #{count}", tone: :muted}}]

  defp reviews(_count), do: []

  @spec plural(non_neg_integer(), String.t(), String.t()) :: String.t()
  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many
end
