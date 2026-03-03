defmodule Minga.Editor.State.Buffers do
  @moduledoc """
  Groups buffer-related fields from EditorState.

  Tracks the active buffer pid, the list of open buffers, the active index,
  and special (unlisted) buffers like *Messages* and *scratch*.
  """

  @type t :: %__MODULE__{
          buffer: pid() | nil,
          buffers: [pid()],
          active_buffer: non_neg_integer(),
          messages_buffer: pid() | nil,
          scratch_buffer: pid() | nil,
          help_buffer: pid() | nil
        }

  defstruct buffer: nil,
            buffers: [],
            active_buffer: 0,
            messages_buffer: nil,
            scratch_buffer: nil,
            help_buffer: nil

  @doc "Appends a buffer pid and makes it active."
  @spec add(t(), pid()) :: t()
  def add(%__MODULE__{} = bs, pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    buffers = bs.buffers ++ [pid]
    idx = length(buffers) - 1
    %{bs | buffers: buffers, active_buffer: idx, buffer: pid}
  end

  @doc "Switches to the buffer at `idx`, wrapping around."
  @spec switch_to(t(), non_neg_integer()) :: t()
  def switch_to(%__MODULE__{buffers: [_ | _] = buffers} = bs, idx) do
    len = length(buffers)
    idx = rem(idx, len)
    idx = if idx < 0, do: idx + len, else: idx
    pid = Enum.at(buffers, idx)
    %{bs | active_buffer: idx, buffer: pid}
  end

  def switch_to(%__MODULE__{} = bs, _idx), do: bs
end
