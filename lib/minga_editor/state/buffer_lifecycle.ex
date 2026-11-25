defmodule MingaEditor.State.BufferLifecycle do
  @moduledoc """
  Editor-mailbox correlation for buffer process lifecycle events.

  The Editor process creates monitors; this value only records their identity
  and the shell context associated with the next buffer registration.

  It also holds the crash a monitored buffer announced before it exited. The buffer sends `:buffer_crashed` from `terminate/2`, so the announcement always arrives before the buffer's `:DOWN`; the Editor takes it when it retires the dead buffer.
  """

  alias Minga.Events.BufferCrashedEvent

  @type t :: %__MODULE__{
          buffer_monitors: %{pid() => reference()},
          buffer_crashes: %{pid() => BufferCrashedEvent.t()},
          buffer_add_context: MingaEditor.Shell.buffer_add_context()
        }

  defstruct buffer_monitors: %{},
            buffer_crashes: %{},
            buffer_add_context: :open

  @doc "Returns whether a monitor is already recorded for a buffer."
  @spec monitored?(t(), pid()) :: boolean()
  def monitored?(%__MODULE__{buffer_monitors: monitors}, pid) when is_pid(pid),
    do: Map.has_key?(monitors, pid)

  @doc "Records the first monitor reference created for a buffer."
  @spec record_monitor(t(), pid(), reference()) :: t()
  def record_monitor(%__MODULE__{} = lifecycle, pid, ref)
      when is_pid(pid) and is_reference(ref) do
    %{lifecycle | buffer_monitors: Map.put_new(lifecycle.buffer_monitors, pid, ref)}
  end

  @doc "Forgets the monitor correlated with a terminal buffer exit, and any crash it announced."
  @spec retire_monitor(t(), pid()) :: t()
  def retire_monitor(%__MODULE__{} = lifecycle, pid) when is_pid(pid) do
    %{
      lifecycle
      | buffer_monitors: Map.delete(lifecycle.buffer_monitors, pid),
        buffer_crashes: Map.delete(lifecycle.buffer_crashes, pid)
    }
  end

  @doc """
  Records the crash a monitored buffer announced.

  A crash from a buffer this Editor does not monitor is ignored: another owner retires that buffer.
  """
  @spec record_crash(t(), BufferCrashedEvent.t()) :: t()
  def record_crash(%__MODULE__{} = lifecycle, %BufferCrashedEvent{buffer: pid} = crash) do
    if monitored?(lifecycle, pid) do
      %{lifecycle | buffer_crashes: Map.put(lifecycle.buffer_crashes, pid, crash)}
    else
      lifecycle
    end
  end

  @doc "Takes the crash a buffer announced, or `nil` when it stopped without one."
  @spec take_crash(t(), pid()) :: {BufferCrashedEvent.t() | nil, t()}
  def take_crash(%__MODULE__{} = lifecycle, pid) when is_pid(pid) do
    {crash, crashes} = Map.pop(lifecycle.buffer_crashes, pid)
    {crash, %{lifecycle | buffer_crashes: crashes}}
  end

  @doc "Records how the shell should integrate the next added buffer."
  @spec expect_buffer(t(), MingaEditor.Shell.buffer_add_context()) :: t()
  def expect_buffer(%__MODULE__{} = lifecycle, context),
    do: %{lifecycle | buffer_add_context: context}

  @doc "Consumes the pending add context and restores the default open behavior."
  @spec consume_buffer_context(t()) :: {MingaEditor.Shell.buffer_add_context(), t()}
  def consume_buffer_context(%__MODULE__{} = lifecycle),
    do: {lifecycle.buffer_add_context, %{lifecycle | buffer_add_context: :open}}
end
