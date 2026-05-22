defmodule MingaEditor.UI.Picker.BufferSource do
  @moduledoc """
  Picker source for switching between open buffers.

  Provides the list of open buffers as picker candidates with file name,
  path, and dirty status. Supports live preview — navigating the picker
  temporarily switches to the highlighted buffer.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias MingaEditor.UI.Devicon

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch buffer"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(ctx), do: build_candidates(ctx, include_special: false)

  @doc """
  Builds picker candidates from the buffer list.

  ## Options

  * `:include_special` — when `true`, includes special buffers (`*Messages*`,
    `*Warnings*`, etc.) in the results. Defaults to `false`.
  """
  @spec build_candidates(Context.t(), keyword()) :: [Item.t()]
  def build_candidates(%Context{buffers: buffers_state}, opts \\ []) do
    %{list: buffers} = buffers_state
    include_special = Keyword.get(opts, :include_special, false)

    listed =
      buffers
      |> Enum.with_index()
      |> Enum.reject(fn {buf, _idx} ->
        reject_buffer?(buf, include_special)
      end)
      |> Enum.map(fn {buf, idx} -> format_candidate(buf, idx) end)

    if include_special do
      extra = extra_special_buffers(buffers_state)
      listed ++ extra
    else
      listed
    end
  end

  @doc """
  Returns candidate entries for special buffers (messages) that are
  alive but not currently in the buffer list. Uses `{:pid, pid}` as the item
  key so `on_select` can distinguish them from list-indexed buffers.
  """
  @spec extra_special_buffers(Buffers.t()) :: [Item.t()]
  def extra_special_buffers(%Buffers{list: list} = bs) do
    special_fields = [bs.messages]

    special_fields
    |> Enum.reject(fn pid -> is_nil(pid) or Enum.member?(list, pid) end)
    |> Enum.flat_map(fn pid ->
      try do
        [format_candidate(pid, {:pid, pid})]
      catch
        :exit, _ -> []
      end
    end)
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:pid, pid}}, state) do
    # Special buffer not yet in the list: add it (which also switches to it)
    EditorState.add_buffer(state, pid)
  end

  def on_select(%Item{id: idx}, state) when is_integer(idx) do
    EditorState.switch_buffer(state, idx)
  end

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  @impl true
  @spec actions(Item.t()) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def actions(_item) do
    [{"Switch", :switch}, {"Kill", :kill}]
  end

  @impl true
  @spec on_action(term(), Item.t(), term()) :: term()
  def on_action(:switch, item, state), do: on_select(item, state)
  def on_action(:kill, item, state), do: kill_items([item], state)
  def on_action(_action, _item, state), do: state

  @impl true
  @spec on_bulk_select([Item.t()], term()) :: term()
  def on_bulk_select(items, state), do: kill_items(items, state)

  @impl true
  @spec bulk_actions([Item.t()]) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def bulk_actions(_items), do: [{"Kill all marked", :kill_marked}]

  @impl true
  @spec on_bulk_action(term(), [Item.t()], term()) :: term()
  def on_bulk_action(:kill_marked, items, state), do: kill_items(items, state)
  def on_bulk_action(_action, _items, state), do: state

  @doc """
  Returns `true` if the buffer is a special buffer (name matches `*...*` pattern).
  """
  @spec special?(pid()) :: boolean()
  def special?(buf) do
    case Buffer.buffer_name(buf) do
      nil -> false
      name -> String.match?(name, ~r/^\*.+\*$/)
    end
  end

  # Returns true if a buffer should be excluded from the picker.
  # Special buffers (like *Messages*) are unlisted by default but should
  # appear when include_special is true.
  @spec reject_buffer?(pid(), boolean()) :: boolean()
  defp reject_buffer?(buf, include_special) do
    do_reject?(buf, include_special)
  catch
    :exit, _ -> true
  end

  @spec do_reject?(pid(), boolean()) :: boolean()
  defp do_reject?(buf, true = _include_special) do
    # When showing all: only reject unlisted non-special buffers
    Buffer.unlisted?(buf) and not special?(buf)
  end

  defp do_reject?(buf, false = _include_special) do
    # Default: reject unlisted buffers and special buffers
    Buffer.unlisted?(buf) or special?(buf)
  end

  @spec kill_items([Item.t()], term()) :: term()
  defp kill_items(items, %{workspace: %{buffers: %Buffers{} = bs}} = state) do
    pids = items |> Enum.map(&item_pid(&1, bs.list)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case pids do
      [] ->
        state

      _ ->
        Enum.each(pids, &stop_buffer/1)
        new_bs = Enum.reduce(pids, bs, fn pid, acc -> Buffers.remove(acc, pid) end)

        state
        |> EditorState.set_buffers(new_bs)
        |> EditorState.sync_active_window_buffer()
    end
  end

  defp kill_items(_items, state), do: state

  @spec item_pid(Item.t(), [pid()]) :: pid() | nil
  defp item_pid(%Item{id: {:pid, pid}}, _buffers) when is_pid(pid), do: pid
  defp item_pid(%Item{id: idx}, buffers) when is_integer(idx), do: Enum.at(buffers, idx)
  defp item_pid(_item, _buffers), do: nil

  @spec stop_buffer(pid()) :: :ok
  defp stop_buffer(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec format_candidate(pid(), term()) :: Item.t()
  defp format_candidate(buf, key) do
    name = display_name(buf)
    ft = Buffer.filetype(buf)
    {icon, color} = Devicon.icon_and_color(ft)
    desc = Buffer.file_path(buf) || ""
    dirty = if Buffer.dirty?(buf), do: " [+]", else: ""
    ro = if Buffer.read_only?(buf), do: " [RO]", else: ""

    %Item{
      id: key,
      label: "#{icon} #{name}#{dirty}#{ro}",
      description: desc,
      icon_color: color,
      two_line: true
    }
  end

  @spec display_name(pid()) :: String.t()
  defp display_name(buf) do
    case Buffer.buffer_name(buf) do
      nil -> Path.basename(Buffer.file_path(buf) || "[no file]")
      name -> name
    end
  end
end
