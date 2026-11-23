defmodule MingaAgent.Providers.Native.SystemPrompt do
  @moduledoc """
  Composes the native system prompt and fits it to a measured prefix budget.

  Required parts (the base prompt and route guidance) are always sent. Optional parts (project instructions, active skills, and the append prompt) are sent in that order only while the measured prefix stays within the budget. Every part left out is reported so the caller can record and disclose it; nothing is dropped silently.

  The budget keeps room for conversation history: a prefix fits when it leaves at least `history_floor` tokens of the context after the output reserve. A prefix that does not fit even with every optional part omitted is refused when it leaves no room for the reserve at all.
  """

  alias MingaAgent.Session.Prefix

  @enforce_keys [:required, :optional]
  defstruct @enforce_keys

  @typedoc "The prompt parts in send order. Optional parts are paired with the name an omission reports."
  @type t :: %__MODULE__{
          required: [String.t()],
          optional: [{Prefix.omittable(), String.t()}]
        }

  @typedoc "Provider counts of candidate prefixes, in candidate order, and the context they were counted against."
  @type counts :: %{counts: [non_neg_integer()], context: pos_integer()}

  @typedoc """
  Counts every candidate prefix in one measurement. `texts` are the parts, each once; a candidate lists the indices of the parts it joins, in order. One call means one helper start and one deadline.
  """
  @type measure :: ([String.t()], [[non_neg_integer()]] -> {:ok, counts()} | {:error, term()})

  @typedoc "Output reserve and the minimum history room the prefix must leave."
  @type budget :: %{reserve: pos_integer(), history_floor: non_neg_integer()}

  @typedoc "The prompt to send, the parts it omits, and its provider-counted prefix size when measured."
  @type fit :: %{
          text: String.t(),
          omitted: [Prefix.omittable()],
          prefix: non_neg_integer() | nil,
          context: pos_integer() | nil
        }

  @typedoc "Provider counts behind a refused prefix; `history` is zero because no history fits."
  @type overflow :: %{
          prefix: non_neg_integer(),
          history: 0,
          reserve: pos_integer(),
          context: pos_integer()
        }

  @doc "Builds prompt parts, dropping empty values."
  @spec new([String.t() | nil], [{Prefix.omittable(), String.t() | nil}]) :: t()
  def new(required, optional) do
    %__MODULE__{
      required: Enum.reject(required, &blank?/1),
      optional: Enum.reject(optional, fn {_part, text} -> blank?(text) end)
    }
  end

  @doc "Joins every part."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{required: required, optional: optional}),
    do: join(required ++ Enum.map(optional, &elem(&1, 1)))

  @doc "Sends every part unmeasured, for a route without a prefix budget."
  @spec unbounded(t()) :: fit()
  def unbounded(%__MODULE__{} = parts),
    do: %{text: text(parts), omitted: [], prefix: nil, context: nil}

  @doc """
  Chooses the largest in-order set of optional parts whose measured prefix leaves `history_floor` tokens free.

  Every in-order combination of optional parts is counted in one `measure` call, so the decision never waits on more than one measurement. Returns `{:error, {:fixed_prefix_exceeded, overflow}}` when the required parts alone leave no room for the output reserve. When the measurement request is too large to encode, the largest optional part is omitted and the rest are measured again; any other measurement error is returned.
  """
  @spec fit(t(), budget(), measure()) ::
          {:ok, fit()} | {:error, {:fixed_prefix_exceeded, overflow()} | term()}
  def fit(%__MODULE__{} = parts, %{reserve: reserve, history_floor: floor} = budget, measure)
      when is_integer(reserve) and reserve > 0 and is_integer(floor) and floor >= 0 and
             is_function(measure, 2),
      do: fit(parts, budget, measure, [])

  @spec fit(t(), budget(), measure(), [Prefix.omittable()]) ::
          {:ok, fit()} | {:error, term()}
  defp fit(parts, budget, measure, too_large) do
    required = Enum.to_list(0..(length(parts.required) - 1)//1)
    optional = Enum.with_index(parts.optional, length(parts.required))
    combinations = in_order_subsets(optional)

    candidates =
      Enum.map(combinations, fn subset -> required ++ Enum.map(subset, &elem(&1, 1)) end)

    texts = parts.required ++ Enum.map(parts.optional, &elem(&1, 1))

    case measure.(texts, candidates) do
      {:ok, %{counts: counts, context: context}} ->
        with {:ok, table} <- count_table(combinations, counts),
             do: decide(parts, budget, table, context, too_large)

      {:error, :oversized_apple_request} when parts.optional != [] ->
        {name, _text} = largest = Enum.max_by(parts.optional, &byte_size(elem(&1, 1)))

        fit(%{parts | optional: List.delete(parts.optional, largest)}, budget, measure, [
          name | too_large
        ])

      {:error, _reason} = error ->
        error
    end
  end

  @spec decide(t(), budget(), %{[Prefix.omittable()] => non_neg_integer()}, pos_integer(), [
          Prefix.omittable()
        ]) :: {:ok, fit()} | {:error, {:fixed_prefix_exceeded, overflow()}}
  defp decide(parts, budget, table, context, too_large) do
    required = Map.fetch!(table, [])

    if required + budget.reserve > context do
      {:error,
       {:fixed_prefix_exceeded,
        %{prefix: required, history: 0, reserve: budget.reserve, context: context}}}
    else
      {sent, omitted} = choose_optional(parts.optional, table, context, budget, too_large)
      sent = Enum.reverse(sent)
      texts = for {name, text} <- parts.optional, name in sent, do: text

      {:ok,
       %{
         text: join(parts.required ++ texts),
         omitted: Enum.filter(Prefix.omittable(), &(&1 in omitted)),
         prefix: Map.fetch!(table, sent),
         context: context
       }}
    end
  end

  @spec count_table([list()], [non_neg_integer()]) ::
          {:ok, %{[Prefix.omittable()] => non_neg_integer()}} | {:error, :invalid_count_response}
  defp count_table(combinations, counts) do
    if length(counts) == length(combinations),
      do: {:ok, combinations |> Enum.map(&names/1) |> Enum.zip(counts) |> Map.new()},
      else: {:error, :invalid_count_response}
  end

  # Greedy in send order: a part is sent when it fits together with the parts already sent.
  @spec choose_optional(
          [{Prefix.omittable(), String.t()}],
          %{[Prefix.omittable()] => non_neg_integer()},
          pos_integer(),
          budget(),
          [Prefix.omittable()]
        ) :: {[Prefix.omittable()], [Prefix.omittable()]}
  defp choose_optional(optional, table, context, budget, too_large) do
    Enum.reduce(optional, {[], too_large}, fn {name, _text}, {sent, omitted} ->
      tokens = Map.fetch!(table, Enum.reverse([name | sent]))

      if within_floor?(tokens, context, budget),
        do: {[name | sent], omitted},
        else: {sent, [name | omitted]}
    end)
  end

  # Every combination keeps the parts' order, from none to all of them.
  @spec in_order_subsets([elem]) :: [[elem]] when elem: term()
  defp in_order_subsets([]), do: [[]]

  defp in_order_subsets([first | rest]) do
    subsets = in_order_subsets(rest)
    subsets ++ Enum.map(subsets, &[first | &1])
  end

  @spec names([{{Prefix.omittable(), String.t()}, non_neg_integer()}]) :: [Prefix.omittable()]
  defp names(subset), do: Enum.map(subset, fn {{name, _text}, _index} -> name end)

  @spec within_floor?(non_neg_integer(), pos_integer(), budget()) :: boolean()
  defp within_floor?(prefix, context, %{reserve: reserve, history_floor: floor}),
    do: prefix + reserve + floor <= context

  @spec join([String.t()]) :: String.t()
  defp join(parts), do: Enum.join(parts, "\n\n")

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(text), do: text in [nil, ""]
end
