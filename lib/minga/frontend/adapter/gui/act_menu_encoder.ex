defmodule Minga.Frontend.Adapter.GUI.ActMenuEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
  alias Minga.Protocol.{Encode, Opcodes}
  alias Minga.RenderModel.UI.ActMenu
  alias Minga.RenderModel.UI.ActMenu.Row

  @opcode Opcodes.gui_act_menu()

  @spec encode(ActMenu.t() | :hidden, Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(:hidden, %Caches{last_act_menu: nil} = caches), do: {nil, caches}

  def encode(:hidden, %Caches{} = caches),
    do: {command(%{visible: 0}), %{caches | last_act_menu: nil}}

  def encode(%ActMenu{} = menu, %Caches{last_act_menu: menu} = caches), do: {nil, caches}

  def encode(%ActMenu{} = menu, %Caches{} = caches) do
    {row, column} = wire_anchor(menu.anchor)

    packet =
      command(%{
        visible: 1,
        offer_id: menu.id,
        role: role(menu.role),
        anchor_row: row,
        anchor_column: column,
        selected: menu.selected || 0,
        title: menu.title,
        query: menu.query,
        lead: Enum.map(menu.lead, &wire_row/1),
        rows: Enum.map(menu.rows, &wire_row/1)
      })

    {packet, %{caches | last_act_menu: menu}}
  end

  @spec wire_anchor(ActMenu.anchor() | nil) :: {non_neg_integer(), non_neg_integer()}
  defp wire_anchor(nil), do: {0xFFFF, 0xFFFF}
  defp wire_anchor(:caret), do: {0xFFFE, 0xFFFE}
  defp wire_anchor({_, _} = anchor), do: anchor

  @spec command(map()) :: binary()
  defp command(fields) do
    payload = Encode.encode_gui_act_menu(fields)

    :gui_act_menu
    |> Writer.new()
    |> Writer.uint8(:opcode, @opcode)
    |> Writer.payload32(:payload, payload)
    |> Writer.finish()
  end

  @spec wire_row(Row.t()) :: map()
  defp wire_row(%Row{} = row),
    do: %{
      id: row.id,
      key: row.key,
      label: row.label,
      hint: row.hint,
      detail: row.detail,
      section: row.section,
      destructive: if(row.destructive?, do: 1, else: 0)
    }

  @spec role(ActMenu.role()) :: 0..2
  defp role(:neutral), do: 0
  defp role(:minga), do: 1
  defp role(:failure), do: 2
end
