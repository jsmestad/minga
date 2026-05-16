defmodule MingaEditor.State.Buffers do
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

  @doc """
  Removes dead pids from the buffer list and selects a live neighbor as active.

  If `active` is nil, not a pid, or still alive, returns unchanged.
  If `active` is dead, filters all dead pids from `list` and selects
  a neighbor using the same logic as `remove/2`.
  """
  @spec scrub_dead_active(t()) :: t()
  def scrub_dead_active(%__MODULE__{active: nil} = bs), do: bs
  def scrub_dead_active(%__MODULE__{active: active} = bs) when not is_pid(active), do: bs

  def scrub_dead_active(%__MODULE__{active: active} = bs) do
    if Process.alive?(active) do
      bs
    else
      live_list = Enum.filter(bs.list, &Process.alive?/1)

      {new_active, new_index} =
        case live_list do
          [] ->
            {nil, 0}

          _ ->
            idx = min(bs.active_index, length(live_list) - 1)
            {Enum.at(live_list, idx), idx}
        end

      %{bs | list: live_list, active: new_active, active_index: new_index}
    end
  end

  @doc "Removes a buffer pid, selecting a neighbor as the new active."
  @spec remove(t(), pid()) :: t()
  def remove(%__MODULE__{} = bs, pid) do
    new_list = Enum.reject(bs.list, &(&1 == pid))
    messages = if bs.messages == pid, do: nil, else: bs.messages
    help = if bs.help == pid, do: nil, else: bs.help

    {new_active, new_index} =
      case new_list do
        [] ->
          {nil, 0}

        _ ->
          idx = min(bs.active_index, length(new_list) - 1)
          {Enum.at(new_list, idx), idx}
      end

    %__MODULE__{
      bs
      | list: new_list,
        active: new_active,
        active_index: new_index,
        messages: messages,
        help: help
    }
  end

  @doc "Sets the help buffer pid."
  @spec set_help(t(), pid() | nil) :: t()
  def set_help(%__MODULE__{} = bs, pid), do: %{bs | help: pid}

  @doc "Sets the messages buffer pid."
  @spec set_messages(t(), pid() | nil) :: t()
  def set_messages(%__MODULE__{} = bs, pid), do: %{bs | messages: pid}

  @doc "Overrides the active buffer pid without updating the index. Use for temporary buffer swaps where the pid is not in the buffer list."
  @spec set_active_override(t(), pid() | nil) :: t()
  def set_active_override(%__MODULE__{} = bs, pid), do: %{bs | active: pid}

  @doc "Replaces the buffer list and selects the buffer at the given index."
  @spec replace_list(t(), [pid()], non_neg_integer()) :: t()
  def replace_list(%__MODULE__{} = bs, list, idx) when is_list(list) and is_integer(idx) do
    active = Enum.at(list, idx)
    %{bs | list: list, active_index: idx, active: active}
  end
end
