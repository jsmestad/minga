defmodule Minga.Test.Storyboard.Entry do
  @moduledoc """
  The registry's record for one scenario id.

  A **built** entry can be driven to in the real editor: `reach` is its key path from the factory's cold start in inventory notation, `recognize` classifies a semantic model as this scenario, and `checks` hold the design assertions. A **pending** entry names the surface ticket that builds it; the suite lists it and never fails on it.

  Entries for scenarios that are not `designed` exist only so the flow explorer can name the screens it reaches (`checks` is then empty).

  `explore` says which keys the flow explorer presses from this scenario: `:normal` (the Vim normal keys and every leader binding), `:which_key` (every entry the open which-key panel shows), or `:none`.
  """

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Model

  @type status :: :built | {:pending, pos_integer(), String.t()}
  @type explore :: :normal | :which_key | :none

  @type t :: %__MODULE__{
          id: String.t(),
          status: status(),
          reach: String.t() | nil,
          click_reach: [Minga.Test.Storyboard.Session.click()] | {:pending, pos_integer()},
          recognize: (Model.t() -> boolean()) | nil,
          checks: [Check.t()],
          explore: explore(),
          start: keyword()
        }

  @enforce_keys [:id, :status]
  defstruct [
    :id,
    :status,
    :reach,
    :recognize,
    click_reach: {:pending, 4044},
    checks: [],
    explore: :none,
    start: []
  ]

  @doc "A scenario whose surface is not built yet, with the ticket that builds it."
  @spec pending(String.t(), pos_integer(), String.t()) :: t()
  def pending(id, issue, reason), do: %__MODULE__{id: id, status: {:pending, issue, reason}}

  @doc """
  A scenario the real editor can be driven to.

  Required options: `:reach` and `:recognize`. Optional: `:checks`, `:click_reach`, `:explore`, `:start`.
  """
  @spec built(String.t(), keyword()) :: t()
  def built(id, opts) do
    opts = Keyword.validate!(opts, fields())
    struct!(__MODULE__, [id: id, status: :built] ++ opts)
  end

  @doc "Applies the start options specific to a journey, leaving the scenario's other options in place."
  @spec with_start_options(t(), keyword()) :: t()
  def with_start_options(%__MODULE__{} = entry, []), do: entry

  def with_start_options(%__MODULE__{start: defaults} = entry, options) do
    %{entry | start: Keyword.merge(defaults, options)}
  end

  @doc "True when the entry can be driven to today."
  @spec built?(t()) :: boolean()
  def built?(%__MODULE__{status: :built}), do: true
  def built?(%__MODULE__{}), do: false

  @doc "True when the surface is built and no design check is pending."
  @spec implemented?(t()) :: boolean()
  def implemented?(%__MODULE__{status: :built, checks: checks}),
    do: Enum.all?(checks, &is_nil(&1.pending))

  def implemented?(%__MODULE__{}), do: false

  @doc "The issues this entry still waits on: its surface ticket, or the tickets of its pending checks."
  @spec waiting_on(t()) :: [pos_integer()]
  def waiting_on(%__MODULE__{status: {:pending, issue, _reason}}), do: [issue]

  def waiting_on(%__MODULE__{checks: checks}),
    do: checks |> Enum.map(& &1.pending) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  @spec fields() :: [atom()]
  defp fields, do: [:reach, :recognize, :checks, :click_reach, :explore, :start]
end
