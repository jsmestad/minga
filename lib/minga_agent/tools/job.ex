defmodule MingaAgent.Tools.Job do
  @moduledoc """
  Pure data structure representing a verification job's lifecycle.

  A job wraps one shell command execution with stable identity and tagged
  lifecycle states. The exit code is preserved separately from output text
  so a command that prints "PASS" and exits 42 reports failure with exit 42.

  Transitions are pure functions. The owning process (`JobOwner`) is
  responsible for port management, monitoring, and notifications.
  """

  @typedoc "Stable job identifier, unique within a session."
  @type id :: String.t()

  @typedoc "Monotonically increasing generation counter for deduplication."
  @type generation :: pos_integer()

  @typedoc "Terminal outcome of a finished job."
  @type outcome :: :completed | :failed | :timeout | :cancelled | :crashed

  @typedoc "Job lifecycle status."
  @type status ::
          :starting
          | :running
          | {:terminal, outcome()}
          | :interrupted

  @typedoc "Reference to retained output in the artifact store."
  @type output_ref :: MingaAgent.Tool.Output.Reference.t() | nil

  @type t :: %__MODULE__{
          id: id(),
          session_id: String.t(),
          command: String.t(),
          cwd: String.t(),
          background?: boolean(),
          timeout_secs: pos_integer(),
          status: status(),
          exit_code: non_neg_integer() | nil,
          output_ref: output_ref(),
          output_text: String.t() | nil,
          generation: generation(),
          started_at: integer(),
          finished_at: integer() | nil
        }

  @enforce_keys [:id, :session_id, :command, :cwd, :timeout_secs, :generation, :started_at]
  defstruct [
    :id,
    :session_id,
    :command,
    :cwd,
    :timeout_secs,
    :generation,
    :started_at,
    :exit_code,
    :output_ref,
    :output_text,
    :finished_at,
    background?: false,
    status: :starting
  ]

  @doc "Creates a new job in the `:starting` state."
  @spec new(keyword()) :: t()
  def new(attrs) when is_list(attrs) do
    %__MODULE__{
      id: Keyword.fetch!(attrs, :id),
      session_id: Keyword.fetch!(attrs, :session_id),
      command: Keyword.fetch!(attrs, :command),
      cwd: Keyword.fetch!(attrs, :cwd),
      timeout_secs: Keyword.fetch!(attrs, :timeout_secs),
      generation: Keyword.fetch!(attrs, :generation),
      started_at: Keyword.fetch!(attrs, :started_at),
      background?: Keyword.get(attrs, :background?, false),
      status: :starting
    }
  end

  @doc "Transitions a starting job to running."
  @spec mark_running(t()) :: t()
  def mark_running(%__MODULE__{status: :starting} = job) do
    %{job | status: :running}
  end

  @doc "Transitions to a terminal state with an outcome and optional exit code."
  @spec terminate(t(), outcome(), non_neg_integer() | nil) :: t()
  def terminate(%__MODULE__{status: status} = job, outcome, exit_code)
      when status in [:starting, :running] and
             outcome in [:completed, :failed, :timeout, :cancelled, :crashed] and
             (is_nil(exit_code) or (is_integer(exit_code) and exit_code >= 0)) do
    %{job | status: {:terminal, outcome}, exit_code: exit_code, finished_at: now()}
  end

  def terminate(%__MODULE__{status: {:terminal, _}} = job, _outcome, _exit_code), do: job
  def terminate(%__MODULE__{status: :interrupted} = job, _outcome, _exit_code), do: job

  @doc "Records the output reference after capture."
  @spec set_output(t(), output_ref(), String.t() | nil) :: t()
  def set_output(%__MODULE__{} = job, output_ref, output_text) do
    %{job | output_ref: output_ref, output_text: output_text}
  end

  @doc "Marks a formerly live job as interrupted (unknown outcome after restart)."
  @spec interrupt(t()) :: t()
  def interrupt(%__MODULE__{status: status} = job) when status in [:starting, :running] do
    %{job | status: :interrupted, finished_at: now()}
  end

  def interrupt(%__MODULE__{status: {:terminal, _}} = job), do: job
  def interrupt(%__MODULE__{status: :interrupted} = job), do: job

  @doc "Returns true when the job has reached a terminal or interrupted state."
  @spec finished?(t()) :: boolean()
  def finished?(%__MODULE__{status: {:terminal, _}}), do: true
  def finished?(%__MODULE__{status: :interrupted}), do: true
  def finished?(%__MODULE__{}), do: false

  @doc "Returns true when the job is still live (starting or running)."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{status: :starting}), do: true
  def live?(%__MODULE__{status: :running}), do: true
  def live?(%__MODULE__{}), do: false

  @doc "Returns the terminal outcome or nil if the job is still live."
  @spec outcome(t()) :: outcome() | nil
  def outcome(%__MODULE__{status: {:terminal, outcome}}), do: outcome
  def outcome(%__MODULE__{}), do: nil

  @doc "Derives a user-visible status summary."
  @spec summary_status(t()) ::
          :starting
          | :running
          | :completed
          | :failed
          | :timeout
          | :cancelled
          | :crashed
          | :interrupted
  def summary_status(%__MODULE__{status: :starting}), do: :starting
  def summary_status(%__MODULE__{status: :running}), do: :running
  def summary_status(%__MODULE__{status: {:terminal, outcome}}), do: outcome
  def summary_status(%__MODULE__{status: :interrupted}), do: :interrupted

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
