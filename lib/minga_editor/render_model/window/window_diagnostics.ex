defmodule MingaEditor.RenderModel.Window.WindowDiagnostics do
  @moduledoc """
  Renderer-retained view of one URI's committed diagnostics.

  The value keeps the publication revision, the raw merged list in published order, the gutter signs published with it, and a line interval index. It is rebuilt only when `Minga.Diagnostics` reports a different revision, so an unchanged frame reuses the same terms without copying a diagnostic list. Windows showing the same URI share one value per frame.

  `visible/3` returns the diagnostics whose line span can touch a source line range, in original published order with duplicates preserved. Callers apply their own exact predicate to that bounded candidate set, so per-window work follows the visible matches rather than the URI's total diagnostic count.
  """

  alias Minga.Core.IntervalTree
  alias Minga.Diagnostics
  alias Minga.Diagnostics.Diagnostic

  @enforce_keys [:revision, :diagnostics, :signs, :index]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          revision: Diagnostics.revision(),
          diagnostics: [Diagnostic.t()],
          signs: Diagnostics.gutter_signs(),
          index: IntervalTree.t()
        }

  @typedoc "The conditional lookup result returned by `Minga.Diagnostics.changed_since/3`."
  @type change ::
          :unchanged
          | {:changed, Diagnostics.revision(), [Diagnostic.t()], Diagnostics.gutter_signs()}

  @doc "Returns the value for a URI with no diagnostics (revision 0)."
  @spec empty() :: t()
  def empty, do: %__MODULE__{revision: 0, diagnostics: [], signs: %{}, index: nil}

  @doc "Applies a conditional lookup result. An unchanged revision returns the same value."
  @spec apply_change(t(), change()) :: t()
  def apply_change(%__MODULE__{} = current, :unchanged), do: current
  def apply_change(%__MODULE__{}, {:changed, 0, [], _signs}), do: empty()

  def apply_change(%__MODULE__{}, {:changed, revision, diagnostics, signs})
      when is_integer(revision) and revision > 0 and is_list(diagnostics) and is_map(signs) do
    %__MODULE__{
      revision: revision,
      diagnostics: diagnostics,
      signs: signs,
      index: build_index(diagnostics)
    }
  end

  @doc "Returns the `{revision, diagnostics}` pair consumed by resident semantic layers."
  @spec snapshot(t()) :: {Diagnostics.revision(), [Diagnostic.t()]}
  def snapshot(%__MODULE__{revision: revision, diagnostics: diagnostics}),
    do: {revision, diagnostics}

  @doc """
  Returns diagnostics whose line span intersects `first_line..last_line`, in published order.

  The span of a malformed range (end before start) is taken from its smaller to its larger line, so the result is a superset of every diagnostic an overlap predicate on either endpoint could accept.
  """
  @spec visible(t(), non_neg_integer(), non_neg_integer()) :: [Diagnostic.t()]
  def visible(%__MODULE__{index: nil}, _first_line, _last_line), do: []
  def visible(%__MODULE__{}, first_line, last_line) when last_line < first_line, do: []

  def visible(%__MODULE__{index: index}, first_line, last_line) do
    index
    |> IntervalTree.query_lines(first_line, last_line)
    |> Enum.map(& &1.value)
    |> Enum.sort()
    |> Enum.map(fn {_position, diagnostic} -> diagnostic end)
  end

  @spec build_index([Diagnostic.t()]) :: IntervalTree.t()
  defp build_index(diagnostics) do
    diagnostics
    |> Enum.with_index()
    |> Enum.map(fn {%Diagnostic{range: range} = diagnostic, position} ->
      low = min(range.start_line, range.end_line)
      high = max(range.start_line, range.end_line)
      # The published position is the id. With make_ref/0 ids, 10,000 retained
      # references multiplied renderer major GCs on publication frames (#3488).
      %{id: position, start: {low, 0}, end_: {high + 1, 0}, value: {position, diagnostic}}
    end)
    |> IntervalTree.from_list()
  end
end
