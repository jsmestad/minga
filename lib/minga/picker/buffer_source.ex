defmodule Minga.Picker.BufferSource do
  @moduledoc """
  Picker source for switching between open buffers.

  Provides the list of open buffers as picker candidates with file name,
  path, and dirty status. Supports live preview — navigating the picker
  temporarily switches to the highlighted buffer.
  """

  @behaviour Minga.Picker.Source

  alias Minga.Picker.Item
  alias Minga.Picker.Source

  alias Minga.Buffer.Server, as: BufferServer
  alias Minga.Devicon
  alias Minga.Editor.State, as: EditorState
  alias Minga.Editor.State.Buffers

  @impl true
  @spec title() :: String.t()
  def title, do: "Switch buffer"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec candidates(term()) :: [Item.t()]
  def candidates(state), do: build_candidates(state, include_special: false)

  @doc """
  Builds picker candidates from the buffer list.

  ## Options

  * `:include_special` — when `true`, includes special buffers (`*Messages*`,
    `*Warnings*`, etc.) in the results. Defaults to `false`.
  """
  @spec build_candidates(term(), keyword()) :: [Item.t()]
  def build_candidates(%{buffers: buffers_state}, opts \\ []) do
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
  @spec actions(Item.t()) :: [Minga.Picker.Source.action_entry()]
  def actions(_item) do
    [{"Switch", :switch}, {"Kill", :kill}]
  end

  @impl true
  @spec on_action(atom(), Item.t(), term()) :: term()
  def on_action(:switch, item, state), do: on_select(item, state)

  def on_action(
        :kill,
        %Item{id: idx},
        %{buffers: %Minga.Editor.State.Buffers{list: buffers} = bs} = state
      )
      when is_integer(idx) and idx < length(buffers) do
    alias Minga.Editor.State.Buffers

    pid = Enum.at(buffers, idx)

    try do
      DynamicSupervisor.terminate_child(Minga.Buffer.Supervisor, pid)
    catch
      :exit, _ -> :ok
    end

    new_buffers = List.delete_at(buffers, idx)

    case new_buffers do
      [] ->
        state

      _ ->
        new_active = min(bs.active_index, length(new_buffers) - 1)
        new_bs = %Buffers{bs | list: new_buffers}

        %{state | buffers: Buffers.switch_to(new_bs, new_active)}
        |> EditorState.sync_active_window_buffer()
    end
  end

  def on_action(_action, _item, state), do: state

  @doc """
  Returns `true` if the buffer is a special buffer (name matches `*...*` pattern).
  """
  @spec special?(pid()) :: boolean()
  def special?(buf) do
    case BufferServer.buffer_name(buf) do
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
    BufferServer.unlisted?(buf) and not special?(buf)
  end

  defp do_reject?(buf, false = _include_special) do
    # Default: reject unlisted buffers and special buffers
    BufferServer.unlisted?(buf) or special?(buf)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec format_candidate(pid(), term()) :: Item.t()
  defp format_candidate(buf, key) do
    name = display_name(buf)
    ft = BufferServer.filetype(buf)
    {icon, color} = Devicon.icon_and_color(ft)
    desc = BufferServer.file_path(buf) || ""
    dirty = if BufferServer.dirty?(buf), do: " [+]", else: ""
    ro = if BufferServer.read_only?(buf), do: " [RO]", else: ""

    %Item{
      id: key,
      label: "#{icon} #{name}#{dirty}#{ro}",
      description: desc,
      icon_color: color
    }
  end

  @spec display_name(pid()) :: String.t()
  defp display_name(buf) do
    case BufferServer.buffer_name(buf) do
      nil -> Path.basename(BufferServer.file_path(buf) || "[no file]")
      name -> name
    end
  end
end
