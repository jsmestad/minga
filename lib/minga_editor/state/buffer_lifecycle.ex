defmodule MingaEditor.State.BufferLifecycle do
  @moduledoc """
  Editor-mailbox correlation for buffer process lifecycle events.

  The Editor process creates monitors; this value only records their identity
  and the shell context associated with the next buffer registration.
  """

  @type t :: %__MODULE__{
          buffer_monitors: %{pid() => reference()},
          buffer_add_context: MingaEditor.Shell.buffer_add_context()
        }

  defstruct buffer_monitors: %{},
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

  @doc "Forgets the monitor correlated with a terminal buffer exit."
  @spec retire_monitor(t(), pid()) :: t()
  def retire_monitor(%__MODULE__{} = lifecycle, pid) when is_pid(pid),
    do: %{lifecycle | buffer_monitors: Map.delete(lifecycle.buffer_monitors, pid)}

  @doc "Records how the shell should integrate the next added buffer."
  @spec expect_buffer(t(), MingaEditor.Shell.buffer_add_context()) :: t()
  def expect_buffer(%__MODULE__{} = lifecycle, context),
    do: %{lifecycle | buffer_add_context: context}

  @doc "Consumes the pending add context and restores the default open behavior."
  @spec consume_buffer_context(t()) :: {MingaEditor.Shell.buffer_add_context(), t()}
  def consume_buffer_context(%__MODULE__{} = lifecycle),
    do: {lifecycle.buffer_add_context, %{lifecycle | buffer_add_context: :open}}
end
