defmodule MingaEditor.Agent.UIState.Compaction do
  @moduledoc "Pure owner for agent context-compaction threshold and execution state."

  @type threshold :: :fresh | :warned | :triggered
  @type execution :: :idle | {:deferred, pct()} | :requested
  @type action :: :none | {:warn, pct()} | :schedule
  @type pct :: non_neg_integer()
  @type t :: %__MODULE__{threshold: threshold(), execution: execution()}

  defstruct threshold: :fresh,
            execution: :idle

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec record_context_usage(t(), pct(), atom(), pct(), pct(), boolean()) :: {t(), action()}
  def record_context_usage(%__MODULE__{execution: :requested} = compaction, _, _, _, _, _),
    do: {compaction, :none}

  def record_context_usage(%__MODULE__{} = compaction, fill_pct, status, _, _, _)
      when status in [:thinking, :tool_executing] do
    {%{compaction | execution: {:deferred, fill_pct}}, :none}
  end

  def record_context_usage(%__MODULE__{} = state, fill, _status, warn, auto, schedulable?) do
    apply_thresholds(state, fill, warn, auto, schedulable?)
  end

  @spec status_changed(t(), atom(), pct(), pct(), boolean()) :: {t(), action()}
  def status_changed(
        %__MODULE__{execution: {:deferred, fill}} = state,
        :idle,
        warn,
        auto,
        schedulable?
      ) do
    state
    |> reset_threshold()
    |> finish()
    |> apply_thresholds(fill, warn, auto, schedulable?)
  end

  def status_changed(%__MODULE__{} = compaction, :idle, _, _, _),
    do: {reset_threshold(compaction), :none}

  def status_changed(%__MODULE__{} = compaction, _status, _, _, _), do: {compaction, :none}

  @spec finish(t()) :: t()
  def finish(%__MODULE__{} = compaction), do: %{compaction | execution: :idle}

  @spec requested?(t()) :: boolean()
  def requested?(%__MODULE__{execution: :requested}), do: true
  def requested?(%__MODULE__{}), do: false

  defp apply_thresholds(
         %__MODULE__{threshold: threshold} = state,
         fill,
         _warn,
         auto,
         schedulable?
       )
       when auto > 0 and fill >= auto and threshold != :triggered do
    auto_threshold_result(state, schedulable?)
  end

  defp apply_thresholds(%__MODULE__{threshold: :fresh} = state, fill, warn, _auto, _schedulable?)
       when warn > 0 and fill >= warn do
    {%{state | threshold: :warned}, {:warn, fill}}
  end

  defp apply_thresholds(%__MODULE__{} = state, _, _, _, _), do: {state, :none}

  defp auto_threshold_result(%__MODULE__{} = compaction, true),
    do: {%{compaction | threshold: :triggered, execution: :requested}, :schedule}

  defp auto_threshold_result(%__MODULE__{} = compaction, false), do: {compaction, :none}

  defp reset_threshold(%__MODULE__{} = compaction), do: %{compaction | threshold: :fresh}
end
