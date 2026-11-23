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

  @typedoc "Provider-counted size of a candidate prefix and the context it was counted against."
  @type measurement :: %{prefix: non_neg_integer(), context: pos_integer()}

  @typedoc "Counts the fixed prefix (instructions and tool declarations) for one candidate prompt."
  @type measure :: (String.t() -> {:ok, measurement()} | {:error, term()})

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

  Returns `{:error, {:fixed_prefix_exceeded, overflow}}` when the required parts alone leave no room for the output reserve. A measurement error for a candidate that includes optional parts counts as not fitting only when the request was too large to encode; any other measurement error is returned.
  """
  @spec fit(t(), budget(), measure()) ::
          {:ok, fit()} | {:error, {:fixed_prefix_exceeded, overflow()} | term()}
  def fit(%__MODULE__{} = parts, %{reserve: reserve, history_floor: floor} = budget, measure)
      when is_integer(reserve) and reserve > 0 and is_integer(floor) and floor >= 0 and
             is_function(measure, 1) do
    full = text(parts)
    measured = if parts.optional == [], do: measure.(full), else: fitting_measure(measure, full)

    case measured do
      {:ok, measurement} ->
        if within_floor?(measurement, budget),
          do: {:ok, fit_result(full, [], measurement)},
          else: fit_required(parts, budget, measure, %{full => measurement})

      :too_large ->
        fit_required(parts, budget, measure, %{})

      {:error, _reason} = error ->
        error
    end
  end

  @spec fit_required(t(), budget(), measure(), %{String.t() => measurement()}) ::
          {:ok, fit()} | {:error, term()}
  defp fit_required(parts, budget, measure, memo) do
    required = join(parts.required)

    with {:ok, %{prefix: prefix, context: context} = measured} <-
           memo_or(memo, required, fn -> measure.(required) end) do
      if prefix + budget.reserve > context do
        {:error,
         {:fixed_prefix_exceeded,
          %{prefix: prefix, history: 0, reserve: budget.reserve, context: context}}}
      else
        add_optional(parts, budget, measure, memo, measured)
      end
    end
  end

  @spec add_optional(t(), budget(), measure(), %{String.t() => measurement()}, measurement()) ::
          {:ok, fit()} | {:error, term()}
  defp add_optional(parts, budget, measure, memo, required) do
    context = %{budget: budget, measure: measure, memo: memo}
    consider(parts.optional, Enum.reverse(parts.required), [], required, context)
  end

  # Walks the optional parts in order with reversed accumulators of sent text and omitted names.
  @spec consider(
          [{Prefix.omittable(), String.t()}],
          [String.t()],
          [Prefix.omittable()],
          measurement(),
          map()
        ) :: {:ok, fit()} | {:error, term()}
  defp consider([], sent, omitted, measured, _context),
    do: {:ok, fit_result(join(Enum.reverse(sent)), Enum.reverse(omitted), measured)}

  defp consider([{name, text} | rest], sent, omitted, measured, context) do
    candidate = [text | sent]
    joined = join(Enum.reverse(candidate))

    case memo_or(context.memo, joined, fn -> fitting_measure(context.measure, joined) end) do
      {:ok, next} ->
        if within_floor?(next, context.budget),
          do: consider(rest, candidate, omitted, next, context),
          else: consider(rest, sent, [name | omitted], measured, context)

      :too_large ->
        consider(rest, sent, [name | omitted], measured, context)

      {:error, _reason} = error ->
        error
    end
  end

  @spec memo_or(%{String.t() => measurement()}, String.t(), (-> result)) ::
          {:ok, measurement()} | result
        when result: {:ok, measurement()} | :too_large | {:error, term()}
  defp memo_or(memo, text, measure) do
    case Map.fetch(memo, text) do
      {:ok, measured} -> {:ok, measured}
      :error -> measure.()
    end
  end

  # A candidate with optional parts that is too large to encode cannot be sent, so it does not fit.
  @spec fitting_measure(measure(), String.t()) ::
          {:ok, measurement()} | :too_large | {:error, term()}
  defp fitting_measure(measure, text) do
    case measure.(text) do
      {:error, :oversized_apple_request} -> :too_large
      result -> result
    end
  end

  @spec within_floor?(measurement(), budget()) :: boolean()
  defp within_floor?(%{prefix: prefix, context: context}, %{
         reserve: reserve,
         history_floor: floor
       }),
       do: prefix + reserve + floor <= context

  @spec fit_result(String.t(), [Prefix.omittable()], measurement()) :: fit()
  defp fit_result(text, omitted, %{prefix: prefix, context: context}),
    do: %{text: text, omitted: omitted, prefix: prefix, context: context}

  @spec join([String.t()]) :: String.t()
  defp join(parts), do: Enum.join(parts, "\n\n")

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(text), do: text in [nil, ""]
end
