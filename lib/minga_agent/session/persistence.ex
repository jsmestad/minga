defmodule MingaAgent.Session.Persistence do
  @moduledoc """
  Owns transcript save intent, timer correlation, and retry state.

  Session performs each write synchronously, so a dirty flag is sufficient:
  no transcript change can overtake an in-flight write. Session owns timer and
  storage effects; this value only calculates bookkeeping transitions.
  """

  @retry_delays {5_000, 10_000, 20_000, 40_000, 60_000}

  @typedoc "A semantic timer token paired with the runtime timer reference."
  @type timer :: {token :: reference(), timer_ref :: reference()}

  @typedoc "Focused transcript persistence bookkeeping."
  @type t :: %__MODULE__{
          enabled?: boolean(),
          timer: timer() | nil,
          dirty?: boolean(),
          retry_count: non_neg_integer()
        }

  @enforce_keys [:enabled?]
  defstruct enabled?: true, timer: nil, dirty?: false, retry_count: 0

  @doc "Creates persistence bookkeeping for one Session."
  @spec new(boolean()) :: t()
  def new(enabled?) when is_boolean(enabled?), do: %__MODULE__{enabled?: enabled?}

  @doc "Returns whether transcript persistence is enabled."
  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{} = persistence), do: persistence.enabled?

  @doc "Returns whether the transcript has unsaved changes."
  @spec dirty?(t()) :: boolean()
  def dirty?(%__MODULE__{} = persistence), do: persistence.dirty?

  @doc "Marks the transcript dirty and returns the timer Session must cancel."
  @spec changed(t()) :: {t(), timer() | nil}
  def changed(%__MODULE__{enabled?: false} = persistence), do: {persistence, nil}

  def changed(%__MODULE__{} = persistence) do
    next = %__MODULE__{persistence | timer: nil, dirty?: true, retry_count: 0}
    {next, persistence.timer}
  end

  @doc "Installs a runtime timer under its semantic delivery token."
  @spec scheduled(t(), reference(), reference()) :: t()
  def scheduled(%__MODULE__{} = persistence, token, timer_ref)
      when is_reference(token) and is_reference(timer_ref) do
    %__MODULE__{persistence | timer: {token, timer_ref}}
  end

  @doc "Consumes a due save token or rejects stale timer delivery."
  @spec save_due(t(), reference()) :: {:save, t()} | :stale
  def save_due(%__MODULE__{timer: {token, _timer_ref}} = persistence, token) do
    {:save, %__MODULE__{persistence | timer: nil}}
  end

  def save_due(%__MODULE__{}, _token), do: :stale

  @doc "Records a successful synchronous write."
  @spec saved(t()) :: t()
  def saved(%__MODULE__{} = persistence) do
    %__MODULE__{persistence | dirty?: false, retry_count: 0}
  end

  @doc "Records a failed write and returns the next retry delay."
  @spec failed(t()) :: {t(), pos_integer()}
  def failed(%__MODULE__{} = persistence) do
    retry_count = persistence.retry_count + 1
    {%__MODULE__{persistence | retry_count: retry_count}, retry_delay_ms(retry_count)}
  end

  @doc "Cancels bookkeeping for the current timer and returns its runtime effect handle."
  @spec cancel(t()) :: {t(), timer() | nil}
  def cancel(%__MODULE__{} = persistence) do
    {%__MODULE__{persistence | timer: nil}, persistence.timer}
  end

  @doc "Marks a restored transcript as already persisted."
  @spec restored(t()) :: {t(), timer() | nil}
  def restored(%__MODULE__{} = persistence) do
    next = %__MODULE__{persistence | timer: nil, dirty?: false, retry_count: 0}
    {next, persistence.timer}
  end

  @spec retry_delay_ms(pos_integer()) :: pos_integer()
  defp retry_delay_ms(retry_count) do
    index = min(retry_count, tuple_size(@retry_delays)) - 1
    elem(@retry_delays, index)
  end
end
