defmodule MingaAgent.ToolCall do
  @moduledoc """
  A single tool call in the agent conversation.

  Tracks the tool's identity (id, name, args), its execution lifecycle
  (status, result, error state, timing), and display state (collapsed).

  Mutation methods live here so consumers don't scatter `%{tc | ...}`
  updates across 11 files. Each method encodes a domain transition:
  `complete/2` records success, while failure, denial, cancellation and approval
  expiry retain distinct terminal facts. Ordinary late events never reopen a call.
  """

  alias MingaAgent.ToolApproval.Preview
  alias MingaAgent.Tool.Output

  @typedoc "Tool call execution status."
  @type status :: :running | :complete | :denied | :cancelled | :error
  @type outcome :: :complete | :denied | :cancelled | :error
  @type terminal_reason :: :approval_timeout | nil

  @typedoc "Scope that auto-approved this tool call."
  @type auto_approved_scope :: :session | :turn

  @typedoc "A tool call."
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          args: map(),
          status: status(),
          terminal_reason: terminal_reason(),
          result: String.t(),
          output: Output.t() | nil,
          is_error: boolean(),
          collapsed: boolean(),
          auto_approved_scope: auto_approved_scope() | nil,
          preview: Preview.t() | nil,
          started_at: integer() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @enforce_keys [:id, :name]
  defstruct id: nil,
            name: nil,
            args: %{},
            status: :running,
            terminal_reason: nil,
            result: "",
            output: nil,
            is_error: false,
            collapsed: true,
            auto_approved_scope: nil,
            preview: nil,
            started_at: nil,
            duration_ms: nil

  @doc "Creates a new running tool call with a monotonic start timestamp."
  @spec new(String.t(), String.t(), map()) :: t()
  def new(id, name, args \\ %{}) when is_binary(id) and is_binary(name) do
    %__MODULE__{
      id: id,
      name: name,
      args: args,
      started_at: System.monotonic_time(:millisecond)
    }
  end

  @doc false
  @spec restore(keyword()) :: t()
  def restore(attrs) when is_list(attrs), do: struct!(__MODULE__, attrs)

  @doc "Starts elapsed timing at the exact authorized approval decision, before work resumes."
  @spec approve_execution(t()) :: t()
  def approve_execution(%__MODULE__{status: :running} = tc),
    do: %{tc | started_at: System.monotonic_time(:millisecond)}

  def approve_execution(%__MODULE__{status: status} = tc)
      when status in [:complete, :denied, :cancelled, :error], do: tc

  @doc "Records successful completion without reopening a terminal call."
  @spec complete(t(), String.t(), Output.t() | nil) :: t()
  def complete(tc, result, output \\ nil), do: finish(tc, :complete, nil, result, output)

  @doc "Records an execution failure without inventing its cause."
  @spec error(t(), String.t(), Output.t() | nil) :: t()
  def error(tc, result, output \\ nil), do: finish(tc, :error, nil, result, output)

  @doc "Records a known pre-execution refusal."
  @spec deny(t(), String.t(), Output.t() | nil) :: t()
  def deny(tc, result, output \\ nil), do: finish(tc, :denied, nil, result, output)

  @doc "Records known cancellation, not an indeterminate admitted effect."
  @spec cancel(t(), String.t(), Output.t() | nil) :: t()
  def cancel(tc, result, output \\ nil), do: finish(tc, :cancelled, nil, result, output)

  @doc "Records approval expiry as an error without an execution duration."
  @spec expire_approval(t(), String.t(), Output.t() | nil) :: t()
  def expire_approval(tc, result, output \\ nil),
    do: finish(tc, :error, :approval_timeout, result, output)

  @doc "Records uncertain result persistence, not an invented execution outcome or duration."
  @spec result_persistence_failed(t(), String.t(), Output.t() | nil) :: t()
  def result_persistence_failed(%__MODULE__{status: :running} = tc, explanation, output)
      when is_binary(explanation) and (is_struct(output, Output) or is_nil(output)) do
    %{
      tc
      | status: :error,
        terminal_reason: nil,
        result: explanation,
        output: output,
        is_error: true,
        collapsed: true,
        duration_ms: nil
    }
  end

  def result_persistence_failed(%__MODULE__{status: status} = tc, _explanation, _output)
      when status in [:complete, :denied, :cancelled, :error], do: tc

  @doc "Marks interrupted execution as uncertain, preserving captured output and expansion."
  @spec abort(t()) :: t()
  def abort(%__MODULE__{status: :running} = tc) do
    %{
      tc
      | status: :error,
        terminal_reason: nil,
        result: aborted_text(tc.result),
        is_error: true,
        duration_ms: terminal_duration(tc, :error, nil)
    }
  end

  def abort(%__MODULE__{status: status} = tc)
      when status in [:complete, :denied, :cancelled, :error],
      do: tc

  defp aborted_text(""), do: "aborted"
  defp aborted_text(partial), do: "aborted\n\n" <> partial

  @doc "Installs explicitly reconciled durable truth, preserving display state."
  @spec reconcile(t(), outcome(), terminal_reason(), String.t(), Output.t() | nil) :: t()
  def reconcile(%__MODULE__{} = tc, outcome, reason, result, output)
      when outcome in [:complete, :denied, :cancelled, :error] and
             (is_nil(reason) or (outcome == :error and reason == :approval_timeout)) and
             is_binary(result) and (is_struct(output, Output) or is_nil(output)) do
    %{
      tc
      | status: outcome,
        terminal_reason: reason,
        result: result,
        output: output,
        collapsed: terminal_collapsed(tc),
        is_error: outcome != :complete,
        duration_ms: terminal_duration(tc, outcome, reason)
    }
  end

  @doc "Reconciles proven non-execution without counting pre-execution waiting as execution."
  @spec reconcile_not_executed(t(), String.t(), Output.t() | nil) :: t()
  def reconcile_not_executed(%__MODULE__{} = tc, result, output)
      when is_binary(result) and (is_struct(output, Output) or is_nil(output)) do
    %{
      tc
      | status: :error,
        terminal_reason: nil,
        result: result,
        output: output,
        is_error: true,
        duration_ms: nil
    }
  end

  @doc "Reads canonical saved outcomes; legacy defaults belong only to the versioned reader."
  @spec saved_outcome(map()) ::
          {:ok, outcome(), terminal_reason()} | {:error, :invalid_tool_outcome}
  def saved_outcome(%{
        tool_outcome: :error,
        tool_outcome_reason: :approval_timeout,
        is_error: true
      }),
      do: {:ok, :error, :approval_timeout}

  def saved_outcome(%{tool_outcome: outcome, is_error: is_error} = metadata)
      when outcome in [:complete, :denied, :cancelled, :error] and
             is_error == (outcome != :complete) do
    case Map.get(metadata, :tool_outcome_reason) do
      nil -> {:ok, outcome, nil}
      _invalid -> {:error, :invalid_tool_outcome}
    end
  end

  def saved_outcome(%{}), do: {:error, :invalid_tool_outcome}

  defp finish(%__MODULE__{status: :running} = tc, outcome, reason, result, output)
       when is_binary(result) and (is_struct(output, Output) or is_nil(output)) do
    reconcile(tc, outcome, reason, result, output)
  end

  # An immediate Deny can acquire its matching durable output exactly once.
  defp finish(
         %__MODULE__{status: :denied, result: result, output: nil} = tc,
         :denied,
         nil,
         result,
         %Output{} = output
       ),
       do: %{tc | output: output}

  defp finish(%__MODULE__{status: status} = tc, _outcome, _reason, _result, _output)
       when status in [:complete, :denied, :cancelled, :error],
       do: tc

  defp terminal_collapsed(%__MODULE__{status: :running}), do: true

  defp terminal_collapsed(%__MODULE__{status: status, collapsed: collapsed})
       when status in [:complete, :denied, :cancelled, :error], do: collapsed

  defp terminal_duration(_tc, :denied, nil), do: nil
  defp terminal_duration(_tc, :error, :approval_timeout), do: nil
  defp terminal_duration(%__MODULE__{status: :running}, :cancelled, nil), do: nil
  defp terminal_duration(%__MODULE__{status: :running} = tc, _outcome, _reason), do: elapsed(tc)

  defp terminal_duration(%__MODULE__{status: status, duration_ms: duration}, _outcome, _reason)
       when status in [:complete, :denied, :cancelled, :error], do: duration

  @doc "Updates only running output; late partials cannot erase terminal facts."
  @spec update_partial(t(), String.t()) :: t()
  def update_partial(%__MODULE__{status: :running} = tc, partial_result)
      when is_binary(partial_result) do
    %{tc | result: partial_result, output: nil, collapsed: false}
  end

  def update_partial(%__MODULE__{status: status} = tc, partial_result)
      when status in [:complete, :denied, :cancelled, :error] and is_binary(partial_result),
      do: tc

  @doc "Toggles the collapsed display state."
  @spec toggle_collapsed(t()) :: t()
  def toggle_collapsed(%__MODULE__{} = tc) do
    %{tc | collapsed: !tc.collapsed}
  end

  @doc "Sets the collapsed state to a specific value."
  @spec set_collapsed(t(), boolean()) :: t()
  def set_collapsed(%__MODULE__{} = tc, collapsed) when is_boolean(collapsed) do
    %{tc | collapsed: collapsed}
  end

  @doc "Records the trust scope that auto-approved this tool call."
  @spec set_auto_approved_scope(t(), auto_approved_scope() | nil) :: t()
  def set_auto_approved_scope(%__MODULE__{} = tc, scope) when scope in [:session, :turn, nil] do
    %{tc | auto_approved_scope: scope}
  end

  @doc "Records the transcript preview captured while the tool executed."
  @spec set_preview(t(), Preview.t()) :: t()
  def set_preview(%__MODULE__{} = tc, %Preview{} = preview) do
    %{tc | preview: preview}
  end

  @doc "Returns true when the tool call has a terminal outcome."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: :running}), do: false

  def finished?(%__MODULE__{status: status})
      when status in [:complete, :denied, :cancelled, :error],
      do: true

  # Computes elapsed milliseconds from started_at, or nil if no start time.
  @spec elapsed(t()) :: non_neg_integer() | nil
  defp elapsed(%__MODULE__{started_at: nil}), do: nil

  defp elapsed(%__MODULE__{started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at
  end
end
