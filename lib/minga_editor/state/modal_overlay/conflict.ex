defmodule MingaEditor.State.ModalOverlay.Conflict do
  @moduledoc """
  Modal-overlay payload for the conflict prompt.

  The conflict prompt asks the user to resolve a buffer/disk conflict. It is
  bound to a specific buffer process; `owner` carries that buffer pid so the
  modal can be auto-dismissed when its buffer dies or the user switches
  away.

  Before #1425 the conflict prompt lived as `state.workspace.pending_conflict
  = {buffer_pid, prompt_text}`. This payload preserves that pair while
  making the metadata explicit.
  """

  @type owner :: pid()

  @type t :: %__MODULE__{
          buffer: pid(),
          message: String.t(),
          owner: owner(),
          opened_at: integer()
        }

  @enforce_keys [:buffer, :message, :owner]
  defstruct [:buffer, :message, :owner, opened_at: 0]

  @doc """
  Builds a conflict payload from the legacy `{buffer_pid, message}` tuple.

  The owner is set to the buffer pid; callers can override via opts.
  """
  @spec new(pid(), String.t(), keyword()) :: t()
  def new(buffer, message, opts \\ []) when is_pid(buffer) and is_binary(message) do
    %__MODULE__{
      buffer: buffer,
      message: message,
      owner: Keyword.get(opts, :owner, buffer),
      opened_at: Keyword.get(opts, :opened_at, System.monotonic_time(:millisecond))
    }
  end

  @doc "Returns the legacy `{buffer, message}` tuple shape."
  @spec to_legacy(t()) :: {pid(), String.t()}
  def to_legacy(%__MODULE__{buffer: buf, message: msg}), do: {buf, msg}
end
