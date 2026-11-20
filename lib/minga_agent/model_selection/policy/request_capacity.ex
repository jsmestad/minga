defmodule MingaAgent.ModelSelection.Policy.RequestCapacity do
  @moduledoc "Checks the capacity of a prepared request using its measured input and encoded output cap."

  alias MingaAgent.ModelSelection.Policy.Limits

  @type acquisition_error ::
          :invalid_request_body
          | :invalid_count_response
          | :count_transport
          | {:count_http, pos_integer()}

  @type input_measurement ::
          {:provider_count, non_neg_integer()}
          | {:upper_bound, non_neg_integer()}
          | {:estimate, non_neg_integer()}
          | {:unavailable, atom()}
          | {:failed, acquisition_error()}
  @type output_cap :: {:encoded, pos_integer()} | :omitted

  @typedoc "Secret-free evidence and disposition for a single prepared request."
  @type t :: %__MODULE__{
          limits: Limits.t(),
          observed_context: pos_integer() | nil,
          input: input_measurement(),
          output_cap: output_cap(),
          decision: :ok | {:error, refusal()}
        }

  @enforce_keys [:limits, :input, :output_cap, :decision]
  defstruct @enforce_keys ++ [observed_context: nil]

  @type refusal ::
          {:unknown_input_size, atom()}
          | :estimate_not_a_bound
          | {:count_acquisition_failed, acquisition_error()}
          | :missing_capacity
          | :missing_output_cap
          | :input_limit_exceeded
          | :output_limit_exceeded
          | :context_reservation_exceeded

  @doc "Reports exact count provenance, reserve, encoded cap, and any uncertainty or refusal."
  @spec assess(Limits.t(), input_measurement(), output_cap(), pos_integer() | nil) :: t()
  def assess(%Limits{} = limits, measurement, cap, observed_context \\ nil) do
    effective_context = context_ceiling(limits.context, observed_context)

    %__MODULE__{
      limits: limits,
      observed_context: observed_context,
      input: measurement,
      output_cap: cap,
      decision: check(limits, measurement, cap, effective_context)
    }
  end

  @spec context_ceiling(pos_integer() | nil, pos_integer() | nil) :: pos_integer() | nil
  defp context_ceiling(nil, observed), do: observed
  defp context_ceiling(configured, nil), do: configured
  defp context_ceiling(configured, observed), do: min(configured, observed)

  @doc "Checks each applicable limit, using the greater of the policy reserve and the encoded cap for shared context."
  @spec check(Limits.t(), input_measurement(), output_cap()) :: :ok | {:error, refusal()}
  def check(%Limits{context: context} = limits, measurement, cap),
    do: check(limits, measurement, cap, context)

  @spec check(Limits.t(), input_measurement(), output_cap(), pos_integer() | nil) ::
          :ok | {:error, refusal()}
  defp check(%Limits{}, {:failed, reason}, _cap, _context),
    do: {:error, {:count_acquisition_failed, reason}}

  defp check(%Limits{}, {:unavailable, reason}, _cap, _context),
    do: {:error, {:unknown_input_size, reason}}

  defp check(%Limits{}, {:estimate, _tokens}, _cap, _context),
    do: {:error, :estimate_not_a_bound}

  defp check(%Limits{} = limits, {method, tokens}, cap, context)
       when method in [:provider_count, :upper_bound] and is_integer(tokens) and tokens >= 0 do
    with :ok <- check_input(limits.input, context, tokens),
         :ok <- check_output(limits, cap) do
      check_context(context, limits.request_output, tokens, cap)
    end
  end

  @spec check_input(pos_integer() | nil, pos_integer() | nil, non_neg_integer()) ::
          :ok | {:error, :missing_capacity | :input_limit_exceeded}
  defp check_input(nil, nil, _tokens), do: {:error, :missing_capacity}

  defp check_input(limit, _context, tokens) when is_integer(limit) and tokens > limit,
    do: {:error, :input_limit_exceeded}

  defp check_input(_limit, _context, _tokens), do: :ok

  @spec check_output(Limits.t(), output_cap()) ::
          :ok | {:error, :missing_output_cap | :output_limit_exceeded}
  defp check_output(%Limits{output: limit}, :omitted) when is_integer(limit),
    do: {:error, :missing_output_cap}

  defp check_output(%Limits{output: limit}, {:encoded, cap})
       when is_integer(limit) and cap > limit,
       do: {:error, :output_limit_exceeded}

  defp check_output(%Limits{}, _cap), do: :ok

  @spec check_context(pos_integer() | nil, non_neg_integer(), non_neg_integer(), output_cap()) ::
          :ok | {:error, :missing_output_cap | :context_reservation_exceeded}
  defp check_context(nil, _reserve, _tokens, _cap), do: :ok
  defp check_context(_context, _reserve, _tokens, :omitted), do: {:error, :missing_output_cap}

  defp check_context(context, reserve, tokens, {:encoded, cap}) do
    if tokens + max(reserve, cap) <= context,
      do: :ok,
      else: {:error, :context_reservation_exceeded}
  end
end
