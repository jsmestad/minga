defmodule Minga.Parser.ParseScheduler do
  @moduledoc """
  Pure global admission state for editor-buffer parser synchronization.

  The parser Port is single-threaded, so the manager admits one buffer snapshot or parse at a time. Repeated readiness signals coalesce by buffer PID.
  """

  @type t :: %__MODULE__{
          active: pid() | nil,
          queue: term(),
          queued: term(),
          timeout_token: term() | nil,
          timeout_ref: reference() | nil
        }

  defstruct active: nil,
            queue: :queue.new(),
            queued: MapSet.new(),
            timeout_token: nil,
            timeout_ref: nil

  @doc "Creates an empty scheduler."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Queues a buffer once unless it is already active or queued."
  @spec enqueue(t(), pid()) :: t()
  def enqueue(%__MODULE__{active: buffer_pid} = scheduler, buffer_pid), do: scheduler

  def enqueue(%__MODULE__{} = scheduler, buffer_pid) when is_pid(buffer_pid) do
    if MapSet.member?(scheduler.queued, buffer_pid) do
      scheduler
    else
      %{
        scheduler
        | queue: :queue.in(buffer_pid, scheduler.queue),
          queued: MapSet.put(scheduler.queued, buffer_pid)
      }
    end
  end

  @doc "Activates the next queued buffer when no work is active."
  @spec activate_next(t()) :: {:ok, pid(), t()} | :busy | :empty
  def activate_next(%__MODULE__{active: active}) when is_pid(active), do: :busy

  def activate_next(%__MODULE__{} = scheduler) do
    case :queue.out(scheduler.queue) do
      {{:value, buffer_pid}, queue} ->
        updated = %{
          scheduler
          | active: buffer_pid,
            queue: queue,
            queued: MapSet.delete(scheduler.queued, buffer_pid)
        }

        {:ok, buffer_pid, updated}

      {:empty, _queue} ->
        :empty
    end
  end

  @doc "Returns whether the supplied buffer owns the active admission."
  @spec active?(t(), pid()) :: boolean()
  def active?(%__MODULE__{active: buffer_pid}, buffer_pid), do: true
  def active?(%__MODULE__{}, _buffer_pid), do: false

  @doc "Associates a timeout token and timer with the active admission."
  @spec arm_timeout(t(), term(), reference()) :: t()
  def arm_timeout(%__MODULE__{active: active} = scheduler, token, timer_ref)
      when is_pid(active) and is_reference(timer_ref) do
    %{scheduler | timeout_token: token, timeout_ref: timer_ref}
  end

  @doc "Returns whether a timeout belongs to the current active admission."
  @spec timeout?(t(), pid(), term()) :: boolean()
  def timeout?(%__MODULE__{active: buffer_pid, timeout_token: token}, buffer_pid, token), do: true
  def timeout?(%__MODULE__{}, _buffer_pid, _token), do: false

  @doc "Returns the current admission timer reference."
  @spec timeout_ref(t()) :: reference() | nil
  def timeout_ref(%__MODULE__{timeout_ref: timeout_ref}), do: timeout_ref

  @doc "Releases the matching active buffer."
  @spec release(t(), pid()) :: t()
  def release(%__MODULE__{active: buffer_pid} = scheduler, buffer_pid),
    do: %{scheduler | active: nil, timeout_token: nil, timeout_ref: nil}

  def release(%__MODULE__{} = scheduler, _buffer_pid), do: scheduler

  @doc "Drops all active and queued admission state."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{}), do: new()
end
