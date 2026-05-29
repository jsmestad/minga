defmodule Minga.Frontend.Adapter.GUI.TabBarEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.TabBar
  alias Minga.RenderModel.UI.TabBar.Tab

  @op_gui_tab_bar Opcodes.gui_tab_bar()
  @no_visible_active_tab 255

  @spec encode(TabBar.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%TabBar{visible?: false}, %Caches{} = caches), do: {nil, caches}

  def encode(%TabBar{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_tab_bar_fp do
      {encode_command(model), %{caches | last_tab_bar_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(TabBar.t()) :: binary()
  def encode_command(%TabBar{} = model) do
    active_index = active_index(model)
    entries = Enum.map(model.tabs, &encode_tab_entry(&1, model.active_tab_id))
    IO.iodata_to_binary([@op_gui_tab_bar, <<active_index::8, length(model.tabs)::8>> | entries])
  end

  @spec fingerprint(TabBar.t()) :: integer()
  defp fingerprint(%TabBar{} = model), do: :erlang.phash2({model.active_tab_id, model.tabs})

  @spec active_index(TabBar.t()) :: non_neg_integer()
  defp active_index(%TabBar{tabs: tabs, active_tab_id: active_id}) do
    case Enum.find_index(tabs, &(&1.id == active_id)) do
      nil -> @no_visible_active_tab
      index -> index
    end
  end

  @spec encode_tab_entry(Tab.t(), non_neg_integer() | nil) :: binary()
  defp encode_tab_entry(%Tab{} = tab, active_id) do
    is_active = if tab.id == active_id, do: 1, else: 0
    flags = build_tab_flags(tab, is_active)
    icon_bytes = :erlang.iolist_to_binary([tab.icon])
    label_bytes = :erlang.iolist_to_binary([tab.label])

    <<flags::8, tab.id::32, tab.workspace_id::16, byte_size(icon_bytes)::8, icon_bytes::binary,
      byte_size(label_bytes)::16, label_bytes::binary, tab.tint_color::32>>
  end

  @spec build_tab_flags(Tab.t(), 0 | 1) :: non_neg_integer()
  defp build_tab_flags(%Tab{} = tab, is_active) do
    is_dirty = if tab.dirty?, do: 1, else: 0
    is_agent = if tab.kind == :agent, do: 1, else: 0
    has_attention = if tab.attention?, do: 1, else: 0
    is_pinned = if tab.pinned?, do: 1, else: 0
    agent_status = encode_agent_status(tab.agent_status)

    tab_flags(is_active, is_dirty, is_agent, has_attention, agent_status, is_pinned)
  end

  @spec tab_flags(0 | 1, 0 | 1, 0 | 1, 0 | 1, non_neg_integer(), 0 | 1) :: non_neg_integer()
  defp tab_flags(is_active, is_dirty, is_agent, has_attention, agent_status, is_pinned) do
    bor(
      bor(is_active, bsl(is_dirty, 1)),
      bor(
        bor(bsl(is_agent, 2), bsl(has_attention, 3)),
        bor(bsl(band(agent_status, 0x07), 4), bsl(is_pinned, 7))
      )
    )
  end

  @spec encode_agent_status(Tab.agent_status()) :: non_neg_integer()
  defp encode_agent_status(:idle), do: 0
  defp encode_agent_status(:thinking), do: 1
  defp encode_agent_status(:tool_executing), do: 2
  defp encode_agent_status(:error), do: 3
  defp encode_agent_status(:plan), do: 4
  defp encode_agent_status(_), do: 0
end
