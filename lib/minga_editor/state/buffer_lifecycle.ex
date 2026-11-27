defmodule MingaEditor.State.BufferLifecycle do
  @moduledoc """
  Editor-mailbox correlation for buffer process lifecycle events.

  The Editor process creates monitors; this value only records their identity
  and the shell context associated with the next buffer registration.

  It also holds the crash a monitored buffer announced before it exited. The buffer sends `:buffer_crashed` from `terminate/2`, so the announcement always arrives before the buffer's `:DOWN`; the Editor takes it when it retires the dead buffer.

  A buffer that crash recovery reopened is remembered. If that buffer crashes too, its crash is taken as `:repeated`, so the Editor does not reopen the same text in a loop.
  """

  alias Minga.Events.BufferCrashedEvent

  @type t :: %__MODULE__{
          buffer_monitors: %{pid() => reference()},
          buffer_crashes: %{pid() => BufferCrashedEvent.t()},
          crash_recovered: MapSet.t(pid()),
          review_sources: MapSet.t(pid()),
          buffer_add_context: MingaEditor.Shell.buffer_add_context()
        }

  @typedoc """
  The crash a retired buffer announced. `:first` is a buffer the user or an agent opened. `:repeated` is a buffer that crash recovery had reopened.
  """
  @type crash :: {:first, BufferCrashedEvent.t()} | {:repeated, BufferCrashedEvent.t()}

  defstruct buffer_monitors: %{},
            buffer_crashes: %{},
            crash_recovered: MapSet.new(),
            review_sources: MapSet.new(),
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
        buffer_crashes: Map.delete(lifecycle.buffer_crashes, pid),
        crash_recovered: MapSet.delete(lifecycle.crash_recovered, pid),
        review_sources: MapSet.delete(lifecycle.review_sources, pid)
    }
  end

  @doc "Keeps a review-loaded file in Save All and quit inventory independently of its tab."
  @spec retain_review_source(t(), pid()) :: t()
  def retain_review_source(%__MODULE__{} = lifecycle, buffer) when is_pid(buffer),
    do: %{lifecycle | review_sources: MapSet.put(lifecycle.review_sources, buffer)}

  @doc "Remembers that crash recovery reopened this buffer, so a crash of it is not recovered automatically again."
  @spec mark_crash_recovered(t(), pid()) :: t()
  def mark_crash_recovered(%__MODULE__{} = lifecycle, pid) when is_pid(pid),
    do: %{lifecycle | crash_recovered: MapSet.put(lifecycle.crash_recovered, pid)}

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
  @spec take_crash(t(), pid()) :: {crash() | nil, t()}
  def take_crash(%__MODULE__{} = lifecycle, pid) when is_pid(pid) do
    case Map.pop(lifecycle.buffer_crashes, pid) do
      {nil, _crashes} ->
        {nil, lifecycle}

      {%BufferCrashedEvent{} = event, crashes} ->
        kind = if MapSet.member?(lifecycle.crash_recovered, pid), do: :repeated, else: :first
        {{kind, event}, %{lifecycle | buffer_crashes: crashes}}
    end
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
