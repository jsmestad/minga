defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire
  alias Minga.Protocol.Opcodes
  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Content.KeyValue
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Progress
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Separator
  alias Minga.RenderModel.UI.ExtensionPanel.Content.StyledRun
  alias Minga.RenderModel.UI.ExtensionPanel.Content.StyledText
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Table
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Tree
  alias Minga.RenderModel.UI.ExtensionPanel.Content.TreeNode
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Unknown
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
    {panel_binaries, _remaining_budget} =
      Wire.bounded_entries(model.panels, &encode_panel/1, Wire.max_u8(), Wire.max_u16() - 1)

    payload = IO.iodata_to_binary([<<length(panel_binaries)::8>> | panel_binaries])
    <<@op_gui_extension_panel, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(ExtensionPanel.t()) :: term()
  defp fingerprint(%ExtensionPanel{} = model), do: model.panels

  @spec encode_panel(Panel.t()) :: binary()
  defp encode_panel(%Panel{} = panel) do
    ext = Wire.utf8_prefix_bytes(panel.extension, Wire.max_u8())
    panel_id = Wire.utf8_prefix_bytes(panel.panel_id, Wire.max_u8())
    title = Wire.utf8_prefix_bytes(panel.title, Wire.max_u8())
    {size_type, size_val} = encode_size(panel.size)
    position = encode_position(panel.position)
    visible = if panel.visible?, do: 1, else: 0
    {blocks, block_count} = encode_content_blocks(panel.content)

    <<byte_size(ext)::8, ext::binary, byte_size(panel_id)::8, panel_id::binary,
      byte_size(title)::8, title::binary, position::8, size_type::8, size_val::8, visible::8,
      block_count::8, blocks::binary>>
  end

  @spec encode_size(Panel.size()) :: {non_neg_integer(), non_neg_integer()}
  defp encode_size({:percent, n}), do: {0, Wire.clamp_u8(n)}
  defp encode_size({:lines, n}), do: {1, Wire.clamp_u8(n)}

  @spec encode_position(Panel.position()) :: non_neg_integer()
  defp encode_position(:bottom), do: 0
  defp encode_position(:right), do: 1
  defp encode_position(:float), do: 2

  @spec encode_content_blocks([Panel.content_block()]) :: {binary(), non_neg_integer()}
  defp encode_content_blocks(blocks) do
    {block_binaries, _remaining_budget} =
      Wire.bounded_entries(blocks, &encode_content_block/1, Wire.max_u8(), Wire.max_u16())

    {IO.iodata_to_binary(block_binaries), length(block_binaries)}
  end

  @spec encode_content_block(Panel.content_block()) :: binary()
  defp encode_content_block(%Text{text: text}) do
    text = Wire.utf8_prefix_bytes(text, Wire.max_u16())
    <<0::8, byte_size(text)::16, text::binary>>
  end

  defp encode_content_block(%StyledText{runs: runs}) do
    {run_binaries, _remaining_budget} =
      Wire.bounded_entries(runs, &encode_styled_run/1, Wire.max_u8(), Wire.max_u16())

    run_data = IO.iodata_to_binary(run_binaries)
    <<1::8, length(run_binaries)::8, run_data::binary>>
  end

  defp encode_content_block(%Table{} = table) do
    columns = Enum.take(table.columns, Wire.max_u8())
    rows = Enum.take(table.rows, Wire.max_u16())

    col_data =
      IO.iodata_to_binary(Enum.map(columns, fn col -> encode_string16(col) end))

    row_data =
      IO.iodata_to_binary(
        Enum.map(rows, fn row ->
          IO.iodata_to_binary(Enum.map(row, fn cell -> encode_string16(cell) end))
        end)
      )

    <<2::8, length(columns)::8, length(rows)::16, Wire.clamp_u16(table.selected)::16,
      col_data::binary, row_data::binary>>
  end

  defp encode_content_block(%KeyValue{pairs: pairs}) do
    pairs = Enum.take(pairs, Wire.max_u8())

    pair_data =
      IO.iodata_to_binary(
        Enum.map(pairs, fn {key, value} ->
          [encode_string16(key), encode_string16(value)]
        end)
      )

    <<3::8, length(pairs)::8, pair_data::binary>>
  end

  defp encode_content_block(%Separator{}) do
    <<4::8>>
  end

  defp encode_content_block(%Progress{label: label, percent: percent}) do
    label = Wire.utf8_prefix_bytes(label, Wire.max_u16())
    percent_int = percent |> Kernel.*(100) |> round() |> Wire.clamp_u16()
    <<5::8, byte_size(label)::16, label::binary, percent_int::16>>
  end

  defp encode_content_block(%Tree{nodes: nodes}) do
    node_data = encode_tree_nodes(nodes, Wire.max_u16() - 2)
    <<6::8, byte_size(node_data)::16, node_data::binary>>
  end

  defp encode_content_block(%Unknown{}), do: <<255::8>>

  @spec encode_styled_run(StyledRun.t()) :: binary()
  defp encode_styled_run(%StyledRun{} = run) do
    text = Wire.utf8_prefix_bytes(run.text, Wire.max_u16())
    bold = if Map.get(run.attrs, :bold?, false), do: 1, else: 0
    italic = if Map.get(run.attrs, :italic?, false), do: 1, else: 0
    {r, g, b} = Wire.rgb(run.fg)
    <<byte_size(text)::16, text::binary, r::8, g::8, b::8, bold::8, italic::8>>
  end

  @spec encode_tree_nodes([TreeNode.t()], non_neg_integer()) :: binary()
  defp encode_tree_nodes(nodes, budget) do
    {data, count} = encode_tree_node_list(nodes, budget)
    IO.iodata_to_binary([<<count::8>>, data])
  end

  @spec encode_tree_node_list([TreeNode.t()], non_neg_integer()) :: {binary(), non_neg_integer()}
  defp encode_tree_node_list(nodes, budget) do
    {node_binaries, _remaining_budget} =
      Wire.bounded_entries(nodes, &encode_tree_node/1, Wire.max_u8(), max(budget - 1, 0))

    {IO.iodata_to_binary(node_binaries), length(node_binaries)}
  end

  @spec encode_tree_node(TreeNode.t()) :: binary()
  defp encode_tree_node(%TreeNode{} = node) do
    label = Wire.utf8_prefix_bytes(node.label, Wire.max_u16())
    expanded = if node.expanded?, do: 1, else: 0
    child_budget = max(Wire.max_u16() - byte_size(label) - 4, 0)
    {child_nodes, child_count} = encode_tree_node_list(node.children, child_budget)
    child_data = IO.iodata_to_binary([<<child_count::8>>, child_nodes])

    <<byte_size(label)::16, label::binary, expanded::8, child_count::8, child_data::binary>>
  end

  @spec encode_string16(iodata()) :: binary()
  defp encode_string16(value) do
    bytes = Wire.utf8_prefix_bytes(value, Wire.max_u16())
    <<byte_size(bytes)::16, bytes::binary>>
  end
end
