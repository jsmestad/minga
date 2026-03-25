defmodule Minga.Agent.ToolCall do
  @moduledoc """
  A single tool call in the agent conversation.

  Tracks the tool's identity (id, name, args), its execution lifecycle
  (status, result, error state, timing), and display state (collapsed).

  Mutation methods live here so consumers don't scatter `%{tc | ...}`
  updates across 11 files. Each method encodes a domain transition:
  `complete/2` records the result and collapses the output, `error/2`
  marks a failure, `abort/1` handles user cancellation mid-execution.
  """

  @typedoc "Tool call execution status."
  @type status :: :running | :complete | :error

  @typedoc "A tool call."
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          args: map(),
          status: status(),
          result: String.t(),
          is_error: boolean(),
          collapsed: boolean(),
          started_at: integer() | nil,
          duration_ms: non_neg_integer() | nil
        }

  @enforce_keys [:id, :name]
  defstruct id: nil,
            name: nil,
            args: %{},
            status: :running,
            result: "",
            is_error: false,
            collapsed: true,
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

  @doc "Marks the tool call as successfully completed, recording the result and duration."
  @spec complete(t(), String.t()) :: t()
  def complete(%__MODULE__{} = tc, result) when is_binary(result) do
    %{tc | status: :complete, result: result, collapsed: true, duration_ms: elapsed(tc)}
  end

  @doc "Marks the tool call as failed, recording the error result and duration."
  @spec error(t(), String.t()) :: t()
  def error(%__MODULE__{} = tc, result) when is_binary(result) do
    %{
      tc
      | status: :error,
        result: result,
        is_error: true,
        collapsed: true,
        duration_ms: elapsed(tc)
    }
  end

  @doc "Aborts a running tool call. Only transitions `:running` calls."
  @spec abort(t()) :: t()
  def abort(%__MODULE__{status: :running} = tc) do
    %{tc | status: :error, result: "aborted", is_error: true}
  end

  def abort(%__MODULE__{} = tc), do: tc

  @doc "Updates the partial result during streaming, auto-expanding the display."
  @spec update_partial(t(), String.t()) :: t()
  def update_partial(%__MODULE__{} = tc, partial_result) when is_binary(partial_result) do
    %{tc | result: partial_result, collapsed: false}
  end

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

  @doc "Returns true if the tool call has finished (complete or error)."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: :running}), do: false
  def finished?(%__MODULE__{}), do: true

  # Computes elapsed milliseconds from started_at, or nil if no start time.
  @spec elapsed(t()) :: non_neg_integer() | nil
  defp elapsed(%__MODULE__{started_at: nil}), do: nil

  defp elapsed(%__MODULE__{started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at
  end
end
