defmodule Minga.Picker.BufferSource do
  @moduledoc """
  Picker source for switching between open buffers.

  Provides the list of open buffers as picker candidates with file name,
  path, and dirty status. Supports live preview — navigating the picker
  temporarily switches to the highlighted buffer.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch buffer"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Minga.Picker.item()]
  def candidates(%{buffers: buffers}) do
    buffers
    |> Enum.with_index()
    |> Enum.reject(fn {buf, _idx} ->
      Process.alive?(buf) and BufferServer.unlisted?(buf)
    end)
    |> Enum.map(fn {buf, idx} ->
      name = display_name(buf)
      desc = BufferServer.file_path(buf) || ""
      dirty = if BufferServer.dirty?(buf), do: " [+]", else: ""
      ro = if BufferServer.read_only?(buf), do: " [RO]", else: ""

      {idx, name <> dirty <> ro, desc}
    end)
  end

  @impl true
  @spec on_select(Minga.Picker.item(), term()) :: term()
  def on_select({idx, _label, _desc}, state) do
    switch_to_buffer(state, idx)
  end

  @impl true
  @spec on_cancel(term()) :: term()
  def on_cancel(%{picker_restore: restore_idx} = state) when is_integer(restore_idx) do
    switch_to_buffer(state, restore_idx)
  end

  def on_cancel(state), do: state

  @impl true
  @spec actions(Minga.Picker.item()) :: [Minga.Picker.Source.action_entry()]
  def actions(_item) do
    [{"Switch", :switch}, {"Kill", :kill}]
  end

  @impl true
  @spec on_action(atom(), Minga.Picker.item(), term()) :: term()
  def on_action(:switch, item, state), do: on_select(item, state)

  def on_action(:kill, {idx, _label, _desc}, %{buffers: buffers} = state)
      when is_integer(idx) and idx < length(buffers) do
    pid = Enum.at(buffers, idx)

    if Process.alive?(pid) do
      DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, pid)
    end

    new_buffers = List.delete_at(buffers, idx)

    case new_buffers do
      [] ->
        state

      _ ->
        new_active = min(state.active_buffer, length(new_buffers) - 1)
        new_pid = Enum.at(new_buffers, new_active)
        %{state | buffers: new_buffers, active_buffer: new_active, buffer: new_pid}
    end
  end

  def on_action(_action, _item, state), do: state

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec switch_to_buffer(map(), non_neg_integer()) :: map()
  defp switch_to_buffer(%{buffers: [_ | _] = buffers} = state, idx) do
    len = Enum.count(buffers)
    idx = rem(idx, len)
    idx = if idx < 0, do: idx + len, else: idx
    pid = Enum.at(buffers, idx)
    %{state | active_buffer: idx, buffer: pid}
  end

  defp switch_to_buffer(state, _idx), do: state

  @spec display_name(pid()) :: String.t()
  defp display_name(buf) do
    case BufferServer.buffer_name(buf) do
      nil -> Path.basename(BufferServer.file_path(buf) || "[scratch]")
      name -> name
    end
  end
end
