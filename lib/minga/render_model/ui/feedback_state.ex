defmodule Minga.RenderModel.UI.FeedbackState do
  @moduledoc """
  Semantic feedback state for a single action lane.

  The BEAM owns the status vocabulary and transition logic; frontends render
  it according to the threshold contract below. The two-clock model separates
  *acknowledgment* (one-frame optimistic echo, handled by the input path) from
  *duration status* (this struct), so a snappy echo never waits for the spinner
  delay.

  ## Threshold contract (frontends implement, BEAM documents)

  - Acknowledgment: within one frame, unconditional (input path, not this struct).
  - Spinner: show only if still `pending`/`loading` at `@spinner_delay_ms` (100ms).
  - Spinner hold: once shown, spinner stays for at least `@spinner_hold_ms` (500ms).
  - Success dwell: `success` auto-clears to `idle` after `@success_dwell_ms` (1500ms).
  - `error`/`timeout`: sticky until explicitly cleared or a new action starts.
  - Queue suppression: while `queued` is true, terminal status is suppressed until
    the lane drains (one final status when the last op completes).
  """

  @type status :: :idle | :pending | :loading | :success | :error | :timeout | :canceled

  @type t :: %__MODULE__{
          status: status(),
          message: String.t() | nil,
          queued: boolean(),
          count: {non_neg_integer(), non_neg_integer()} | nil
        }

  defstruct status: :idle,
            message: nil,
            queued: false,
            count: nil

  @spinner_delay_ms 100
  @spinner_hold_ms 500
  @success_dwell_ms 1_500

  @doc "Returns the spinner delay threshold in milliseconds."
  @spec spinner_delay_ms() :: pos_integer()
  def spinner_delay_ms, do: @spinner_delay_ms

  @doc "Returns the minimum spinner hold time in milliseconds."
  @spec spinner_hold_ms() :: pos_integer()
  def spinner_hold_ms, do: @spinner_hold_ms

  @doc "Returns the success dwell time before auto-clear in milliseconds."
  @spec success_dwell_ms() :: pos_integer()
  def success_dwell_ms, do: @success_dwell_ms

  @doc "Creates an idle feedback state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Transitions to pending with an optional message. Clears any prior count."
  @spec start(t(), String.t() | nil) :: t()
  def start(%__MODULE__{} = _fs, message \\ nil) do
    %__MODULE__{status: :pending, message: message, queued: false, count: nil}
  end

  @doc "Transitions to loading (spinner threshold crossed)."
  @spec mark_loading(t()) :: t()
  def mark_loading(%__MODULE__{status: :pending} = fs) do
    %{fs | status: :loading}
  end

  def mark_loading(%__MODULE__{} = fs), do: fs

  @doc "Transitions to success with an optional message."
  @spec succeed(t(), String.t() | nil) :: t()
  def succeed(%__MODULE__{} = fs, message \\ nil) do
    %{fs | status: :success, message: message}
  end

  @doc "Transitions to error with a message."
  @spec fail(t(), String.t() | nil) :: t()
  def fail(%__MODULE__{} = fs, message \\ nil) do
    %{fs | status: :error, message: message}
  end

  @doc "Transitions to timeout with an optional message."
  @spec mark_timeout(t(), String.t() | nil) :: t()
  def mark_timeout(%__MODULE__{} = fs, message \\ nil) do
    %{fs | status: :timeout, message: message}
  end

  @doc "Transitions to canceled."
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = fs) do
    %{fs | status: :canceled, message: nil}
  end

  @doc "Clears to idle (e.g. after success dwell timer fires)."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = _fs) do
    %__MODULE__{}
  end

  @doc "Sets the queued flag (second op on a busy lane)."
  @spec set_queued(t(), boolean()) :: t()
  def set_queued(%__MODULE__{} = fs, queued) when is_boolean(queued) do
    %{fs | queued: queued}
  end

  @doc "Updates the progress count for partial results."
  @spec update_count(t(), non_neg_integer(), non_neg_integer()) :: t()
  def update_count(%__MODULE__{} = fs, completed, total)
      when is_integer(completed) and completed >= 0 and is_integer(total) and total >= 0 do
    %{fs | count: {completed, total}}
  end

  @doc "Returns true when the state represents an active (non-terminal) operation."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: status}) when status in [:pending, :loading], do: true
  def active?(%__MODULE__{}), do: false

  @doc "Returns true when the state is a terminal status (success, error, timeout, canceled)."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status})
      when status in [:success, :error, :timeout, :canceled],
      do: true

  def terminal?(%__MODULE__{}), do: false
end
