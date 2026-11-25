defmodule MingaEditor.UI.Picker.BufferSource do
  @moduledoc """
  Picker source for switching between open buffers.

  Provides the list of open buffers as picker candidates with file name,
  path, and dirty status. Supports live preview — navigating the picker
  temporarily switches to the highlighted buffer.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source
  alias MingaEditor.UI.Picker.SwitcherNextSteps

  alias Minga.Buffer
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Buffers
  alias Minga.Language.Devicon

  @impl true
  @spec opens_in_window?() :: boolean()
  def opens_in_window?, do: true

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
    `*Warnings*`, etc.), even when unlisted. Ordinary unlisted buffers stay hidden.
    Defaults to `false`.
  """
  @spec build_candidates(Context.t(), keyword()) :: [Item.t()]
  def build_candidates(%Context{buffers: buffers_state}, opts \\ []) do
    %{list: buffers} = buffers_state
    include_special = Keyword.get(opts, :include_special, false)

    listed =
      for pid <- buffers,
          info = read_listing_info(pid),
          listed?(info, include_special) do
        format_candidate(pid, {:buffer, pid}, info)
      end

    if include_special do
      listed ++ extra_special_buffers(buffers_state)
    else
      listed
    end
  end

  @doc """
  Returns an entry for the messages singleton when it is not already listed and
  its listing metadata can be read. The `{:pid, pid}` key distinguishes it from
  registered `{:buffer, pid}` items.
  """
  @spec extra_special_buffers(Buffers.t()) :: [Item.t()]
  def extra_special_buffers(%Buffers{list: list}) do
    pid = Minga.Log.MessagesBuffer.pid()

    if is_pid(pid) and not Enum.member?(list, pid) do
      case read_listing_info(pid) do
        nil -> []
        info -> [format_candidate(pid, {:pid, pid}, info)]
      end
    else
      []
    end
  end

  @impl true
  @spec empty(Empty.request()) :: Empty.t() | nil
  def empty(%{query: query, total: total}),
    do: SwitcherNextSteps.empty(query, SwitcherNextSteps.count(total, "open buffer"))

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:next_step, _step}} = item, state),
    do: SwitcherNextSteps.run(item, state)

  def on_select(%Item{id: {:pid, pid}}, state) do
    # Special buffer not yet in the list: add it (which also switches to it)
    MingaEditor.Handlers.BufferRegistry.add_buffer(state, pid)
  end

  def on_select(%Item{id: {:buffer, pid}}, state) when is_pid(pid) do
    buffers = state.workspace.buffers

    if Enum.member?(buffers.list, pid) do
      MingaEditor.BufferActivation.activate(state, Buffers.switch_to_pid(buffers, pid))
    else
      state
    end
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

  @spec kill_items([Item.t()], term()) :: term()
  defp kill_items(items, %{workspace: %{buffers: %Buffers{} = bs}} = state) do
    pids = items |> Enum.map(&item_pid(&1, bs.list)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    kill_pids(pids, bs, state)
  end

  defp kill_items(_items, state), do: state

  @spec kill_pids([pid()], Buffers.t(), term()) :: term()
  defp kill_pids([], _bs, state), do: state

  defp kill_pids(pids, bs, state) do
    pids
    |> Enum.reduce(bs, fn pid, acc -> Buffers.remove(acc, pid) end)
    |> apply_kill_result(pids, bs, state)
  end

  @spec apply_kill_result(Buffers.t(), [pid()], Buffers.t(), term()) :: term()
  defp apply_kill_result(%Buffers{list: []}, pids, _bs, state) do
    Enum.each(pids, &stop_buffer/1)
    EditorState.enter_empty_state(state)
  end

  defp apply_kill_result(%Buffers{} = new_bs, pids, _bs, state) do
    Enum.each(pids, &stop_buffer/1)

    MingaEditor.BufferActivation.activate(state, new_bs, notify_shell?: false)
  end

  @spec item_pid(Item.t(), [pid()]) :: pid() | nil
  defp item_pid(%Item{id: {:pid, pid}}, _buffers) when is_pid(pid), do: pid

  defp item_pid(%Item{id: {:buffer, pid}}, buffers) when is_pid(pid) do
    if Enum.member?(buffers, pid), do: pid
  end

  defp item_pid(_item, _buffers), do: nil

  @spec stop_buffer(pid()) :: :ok
  defp stop_buffer(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec read_listing_info(pid()) :: Buffer.listing_info() | nil
  defp read_listing_info(pid) do
    Buffer.listing_info(pid)
  catch
    :exit, _ -> nil
  end

  @spec listed?(Buffer.listing_info(), boolean()) :: boolean()
  defp listed?(info, true), do: not info.unlisted or special_name?(info.name)
  defp listed?(info, false), do: not info.unlisted and not special_name?(info.name)

  @spec special_name?(String.t() | nil) :: boolean()
  defp special_name?(nil), do: false
  defp special_name?(name), do: String.match?(name, ~r/^\*.+\*$/)

  @spec format_candidate(pid(), term(), Buffer.listing_info()) :: Item.t()
  defp format_candidate(pid, key, info) do
    name = info.name || Path.basename(info.file_path || "[no file]")
    {icon, color} = Devicon.icon_and_color(info.filetype)
    desc = info.file_path || content_preview(pid)
    dirty = if info.dirty, do: " [+]", else: ""
    ro = if info.read_only, do: " [RO]", else: ""

    %Item{
      id: key,
      label: "#{icon} #{name}#{dirty}#{ro}",
      description: desc,
      icon_color: color
    }
  end

  # First non-blank line of a pathless buffer, truncated for the picker's
  # description column. Zed-style preview so several untitled buffers are
  # tellable apart without opening them.
  @preview_scan_lines 20
  @preview_max_chars 40

  @spec content_preview(pid()) :: String.t()
  defp content_preview(buf) do
    lines =
      try do
        Buffer.lines(buf, 0, @preview_scan_lines)
      catch
        :exit, _ -> []
      end

    lines
    # Cap before trimming so a pathologically long first line doesn't get
    # fully traversed on every picker rebuild.
    |> Enum.map(&(&1 |> String.slice(0, 200) |> String.trim()))
    |> Enum.find("", &(&1 != ""))
    |> String.slice(0, @preview_max_chars)
  end
end
