defmodule Minga.Frontend.Adapter.GUI.TabBarEncoder do
  @moduledoc false

  import Bitwise

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    writer =
      :gui_tab_bar
      |> Writer.new()
      |> Writer.append(<<@op_gui_tab_bar>>)
      |> Writer.uint8(:active_index, active_index(model))
      |> Writer.uint8(:tab_count, Enum.count(model.tabs))

    model.tabs
    |> Enum.reduce(writer, &encode_tab_entry(&1, model.active_tab_id, &2))
    |> Writer.finish()
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

  @spec encode_tab_entry(Tab.t(), non_neg_integer() | nil, Writer.t()) :: Writer.t()
  defp encode_tab_entry(%Tab{} = tab, active_id, %Writer{} = writer) do
    is_active = if tab.id == active_id, do: 1, else: 0

    writer
    |> Writer.uint8(:tab_flags, build_tab_flags(tab, is_active))
    |> Writer.uint32(:tab_id, tab.id)
    |> Writer.uint16(:workspace_id, tab.workspace_id)
    |> Writer.string8(:tab_icon, tab.icon)
    |> Writer.string16(:tab_label, tab.label)
    |> Writer.uint32(:tab_tint_color, tab.tint_color)
  end

  @spec build_tab_flags(Tab.t(), 0 | 1) :: non_neg_integer()
  defp build_tab_flags(%Tab{} = tab, is_active) do
    is_dirty = if tab.dirty?, do: 1, else: 0
    is_agent = if tab.kind == :agent, do: 1, else: 0
    has_attention = if tab.attention?, do: 1, else: 0
    is_pinned = if tab.pinned?, do: 1, else: 0
    kind_status = kind_status_bits(tab)

    tab_flags(is_active, is_dirty, is_agent, has_attention, kind_status, is_pinned)
  end

  # Bits 4-6 of the tab flags byte are kind-scoped: agent tabs carry the
  # agent status there; file tabs use bit 4 as the ephemeral (not-on-disk)
  # marker. Decoders must check the is_agent bit before interpreting them.
  @spec kind_status_bits(Tab.t()) :: non_neg_integer()
  defp kind_status_bits(%Tab{kind: :agent} = tab), do: encode_agent_status(tab.agent_status)
  defp kind_status_bits(%Tab{ephemeral?: true}), do: 1
  defp kind_status_bits(%Tab{}), do: 0

  @spec tab_flags(0 | 1, 0 | 1, 0 | 1, 0 | 1, non_neg_integer(), 0 | 1) :: non_neg_integer()
  defp tab_flags(is_active, is_dirty, is_agent, has_attention, kind_status, is_pinned) do
    bor(
      bor(is_active, bsl(is_dirty, 1)),
      bor(
        bor(bsl(is_agent, 2), bsl(has_attention, 3)),
        bor(bsl(kind_status, 4), bsl(is_pinned, 7))
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
