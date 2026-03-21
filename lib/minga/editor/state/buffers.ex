defmodule Minga.Editor.State.Buffers do
  @moduledoc """
  Groups buffer-related fields from EditorState.

  Tracks the active buffer pid, the list of open buffers, the active index,
  and special (unlisted) buffers like *Messages*.
  """

  @type t :: %__MODULE__{
          active: pid() | nil,
          list: [pid()],
          active_index: non_neg_integer(),
          messages: pid() | nil,
          help: pid() | nil
        }

  defstruct active: nil,
            list: [],
            active_index: 0,
            messages: nil,
            help: nil

  @doc "Appends a buffer pid and makes it active."
  @spec add(t(), pid()) :: t()
  def add(%__MODULE__{} = bs, pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    buffers = bs.list ++ [pid]
    idx = length(buffers) - 1
    %{bs | list: buffers, active_index: idx, active: pid}
  end

  @doc "Appends a buffer pid without changing the active buffer."
  @spec add_background(t(), pid()) :: t()
  def add_background(%__MODULE__{} = bs, pid) do
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    %{bs | list: bs.list ++ [pid]}
  end

  @doc "Switches to the buffer at `idx`, wrapping around."
  @spec switch_to(t(), non_neg_integer()) :: t()
  def switch_to(%__MODULE__{list: [_ | _] = buffers} = bs, idx) do
    len = length(buffers)
    idx = rem(idx, len)
    idx = if idx < 0, do: idx + len, else: idx
    pid = Enum.at(buffers, idx)
    %{bs | active_index: idx, active: pid}
  end

  def switch_to(%__MODULE__{} = bs, _idx), do: bs

  @doc "Switches to the buffer with the given pid, if it exists in the list."
  @spec switch_to_pid(t(), pid()) :: t()
  def switch_to_pid(%__MODULE__{list: buffers} = bs, pid) do
    case Enum.find_index(buffers, &(&1 == pid)) do
      nil -> bs
      idx -> %{bs | active_index: idx, active: pid}
    end
  end
end
