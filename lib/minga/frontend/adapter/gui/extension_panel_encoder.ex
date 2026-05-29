defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Panel

  @op_gui_extension_panel Opcodes.gui_extension_panel()

  @spec encode(ExtensionPanel.t(), Caches.t()) :: {binary() | nil, Caches.t()}
  def encode(%ExtensionPanel{} = model, %Caches{} = caches) do
    fp = fingerprint(model)

    if fp != caches.last_extension_panel_fp do
      {encode_command(model), %{caches | last_extension_panel_fp: fp}}
    else
      {nil, caches}
    end
  end

  @spec encode_command(ExtensionPanel.t()) :: binary()
  def encode_command(%ExtensionPanel{} = model) do
    panel_binaries = Enum.map(model.panels, &encode_panel/1)
    payload = IO.iodata_to_binary([<<length(model.panels)::8>> | panel_binaries])
    <<@op_gui_extension_panel, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(ExtensionPanel.t()) :: term()
  defp fingerprint(%ExtensionPanel{} = model), do: model.panels

  @spec encode_panel(Panel.t()) :: binary()
  defp encode_panel(%Panel{} = panel) do
    ext = to_string(panel.extension)
    panel_id = to_string(panel.panel_id)
    title = panel.title
    {size_type, size_val} = encode_size(panel.size)
    position = encode_position(panel.position)
    visible = if panel.visible?, do: 1, else: 0
    blocks = encode_content_blocks(panel.content)

    <<byte_size(ext)::8, ext::binary, byte_size(panel_id)::8, panel_id::binary,
      byte_size(title)::8, title::binary, position::8, size_type::8, size_val::8, visible::8,
      length(panel.content)::8, blocks::binary>>
  end

  @spec encode_size(Panel.size()) :: {non_neg_integer(), non_neg_integer()}
  defp encode_size({:percent, n}), do: {0, min(n, 255)}
  defp encode_size({:lines, n}), do: {1, min(n, 255)}

  @spec encode_position(Panel.position()) :: non_neg_integer()
  defp encode_position(:bottom), do: 0
  defp encode_position(:right), do: 1
  defp encode_position(:float), do: 2

  @spec encode_content_blocks([Panel.content_block()]) :: binary()
  defp encode_content_blocks(blocks) do
    IO.iodata_to_binary(Enum.map(blocks, &encode_content_block/1))
  end

  @spec encode_content_block(Panel.content_block()) :: binary()
  defp encode_content_block({:text, text}) do
    <<0::8, byte_size(text)::16, text::binary>>
  end

  defp encode_content_block({:styled_text, runs}) do
    run_data =
      IO.iodata_to_binary(
        Enum.map(runs, fn {text, fg, attrs} ->
          bold = if Keyword.get(attrs, :bold, false), do: 1, else: 0
          italic = if Keyword.get(attrs, :italic, false), do: 1, else: 0
          {r, g, b} = Wire.rgb(fg)
          <<byte_size(text)::16, text::binary, r::8, g::8, b::8, bold::8, italic::8>>
        end)
      )

    <<1::8, length(runs)::8, run_data::binary>>
  end

  defp encode_content_block({:table, %{columns: cols, rows: rows} = table}) do
    selected = Map.get(table, :selected, 0xFFFF)

    col_data =
      IO.iodata_to_binary(Enum.map(cols, fn col -> <<byte_size(col)::16, col::binary>> end))

    row_data =
      IO.iodata_to_binary(
        Enum.map(rows, fn row ->
          IO.iodata_to_binary(
            Enum.map(row, fn cell ->
              cell_str = to_string(cell)
              <<byte_size(cell_str)::16, cell_str::binary>>
            end)
          )
        end)
      )

    <<2::8, length(cols)::8, length(rows)::16, selected::16, col_data::binary, row_data::binary>>
  end

  defp encode_content_block({:key_value, pairs}) do
    pair_data =
      IO.iodata_to_binary(
        Enum.map(pairs, fn {key, value} ->
          key_string = to_string(key)
          value_string = to_string(value)

          <<byte_size(key_string)::16, key_string::binary, byte_size(value_string)::16,
            value_string::binary>>
        end)
      )

    <<3::8, length(pairs)::8, pair_data::binary>>
  end

  defp encode_content_block({:separator}) do
    <<4::8>>
  end

  defp encode_content_block({:progress, %{label: label, percent: percent}}) do
    percent_int = round(percent * 100)
    <<5::8, byte_size(label)::16, label::binary, percent_int::16>>
  end

  defp encode_content_block({:tree, %{nodes: nodes}}) do
    node_data = encode_tree_nodes(nodes)
    <<6::8, byte_size(node_data)::16, node_data::binary>>
  end

  defp encode_content_block(_unknown), do: <<255::8>>

  @spec encode_tree_nodes([map()]) :: binary()
  defp encode_tree_nodes(nodes) do
    count = length(nodes)

    node_binaries =
      IO.iodata_to_binary(
        Enum.map(nodes, fn node ->
          label = node.label
          children = Map.get(node, :children, [])
          expanded = if Map.get(node, :expanded, false), do: 1, else: 0
          child_data = encode_tree_nodes(children)

          <<byte_size(label)::16, label::binary, expanded::8, length(children)::8,
            child_data::binary>>
        end)
      )

    <<count::8, node_binaries::binary>>
  end
end
