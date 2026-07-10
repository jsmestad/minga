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
    validate_uint!(:panel_count, Enum.count(model.panels), Wire.max_u8())
    panel_binaries = Enum.map(model.panels, &encode_panel/1)

    payload = IO.iodata_to_binary([<<Enum.count(panel_binaries)::8>> | panel_binaries])
    validate_uint!(:payload_length, byte_size(payload), Wire.max_u16())
    <<@op_gui_extension_panel, byte_size(payload)::16, payload::binary>>
  end

  @spec fingerprint(ExtensionPanel.t()) :: term()
  defp fingerprint(%ExtensionPanel{} = model), do: model.panels

  @spec encode_panel(Panel.t()) :: binary()
  defp encode_panel(%Panel{} = panel) do
    ext = encode_string8(panel.extension, :extension_length)
    panel_id = encode_string8(panel.panel_id, :panel_id_length)
    title = encode_string8(panel.title, :title_length)
    {size_type, size_val} = encode_size(panel.size)
    position = encode_position(panel.position)
    visible = if panel.visible?, do: 1, else: 0
    {blocks, block_count} = encode_content_blocks(panel.content)

    <<ext::binary, panel_id::binary, title::binary, position::8, size_type::8, size_val::8,
      visible::8, block_count::8, blocks::binary>>
  end

  @spec encode_size(Panel.size()) :: {non_neg_integer(), non_neg_integer()}
  defp encode_size({:percent, n}), do: {0, validate_value!(n, :size_percent, Wire.max_u8())}
  defp encode_size({:lines, n}), do: {1, validate_value!(n, :size_lines, Wire.max_u8())}

  @spec encode_position(Panel.position()) :: non_neg_integer()
  defp encode_position(:bottom), do: 0
  defp encode_position(:right), do: 1
  defp encode_position(:float), do: 2

  @spec encode_content_blocks([Panel.content_block()]) :: {binary(), non_neg_integer()}
  defp encode_content_blocks(blocks) do
    validate_uint!(:block_count, Enum.count(blocks), Wire.max_u8())
    block_binaries = Enum.map(blocks, &encode_content_block/1)

    {IO.iodata_to_binary(block_binaries), Enum.count(block_binaries)}
  end

  @spec encode_content_block(Panel.content_block()) :: binary()
  defp encode_content_block(%Text{text: text}) do
    <<0::8, encode_string16(text, :text_length)::binary>>
  end

  defp encode_content_block(%StyledText{runs: runs}) do
    validate_uint!(:styled_run_count, Enum.count(runs), Wire.max_u8())
    run_binaries = Enum.map(runs, &encode_styled_run/1)

    run_data = IO.iodata_to_binary(run_binaries)
    <<1::8, Enum.count(run_binaries)::8, run_data::binary>>
  end

  defp encode_content_block(%Table{} = table) do
    columns = table.columns
    rows = table.rows
    validate_uint!(:table_column_count, Enum.count(columns), Wire.max_u8())
    validate_uint!(:table_row_count, Enum.count(rows), Wire.max_u16())

    col_data =
      IO.iodata_to_binary(
        Enum.map(columns, fn col -> encode_string16(col, :table_column_length) end)
      )

    row_data =
      IO.iodata_to_binary(
        Enum.map(rows, fn row ->
          IO.iodata_to_binary(
            Enum.map(row, fn cell -> encode_string16(cell, :table_cell_length) end)
          )
        end)
      )

    selected = encode_selected(table.selected)

    <<2::8, Enum.count(columns)::8, Enum.count(rows)::16, selected::16, col_data::binary,
      row_data::binary>>
  end

  defp encode_content_block(%KeyValue{pairs: pairs}) do
    validate_uint!(:key_value_count, Enum.count(pairs), Wire.max_u8())

    pair_data =
      IO.iodata_to_binary(
        Enum.map(pairs, fn {key, value} ->
          [encode_string16(key, :key_length), encode_string16(value, :value_length)]
        end)
      )

    <<3::8, Enum.count(pairs)::8, pair_data::binary>>
  end

  defp encode_content_block(%Separator{}) do
    <<4::8>>
  end

  defp encode_content_block(%Progress{label: label, percent: percent}) do
    percent_int =
      percent |> Kernel.*(100) |> round() |> validate_value!(:progress_percent, Wire.max_u16())

    <<5::8, encode_string16(label, :progress_label_length)::binary, percent_int::16>>
  end

  defp encode_content_block(%Tree{nodes: nodes}) do
    node_data = encode_tree_nodes(nodes)
    validate_uint!(:tree_length, byte_size(node_data), Wire.max_u16())
    <<6::8, byte_size(node_data)::16, node_data::binary>>
  end

  defp encode_content_block(%Unknown{}), do: <<255::8>>

  @spec encode_selected(non_neg_integer() | nil) :: non_neg_integer()
  defp encode_selected(nil), do: 0xFFFF

  defp encode_selected(selected) when is_integer(selected) and selected >= 0,
    do: min(selected, Wire.max_u16() - 1)

  defp encode_selected(_selected), do: 0xFFFF

  @spec encode_styled_run(StyledRun.t()) :: binary()
  defp encode_styled_run(%StyledRun{} = run) do
    bold = if Map.get(run.attrs, :bold?, false), do: 1, else: 0
    italic = if Map.get(run.attrs, :italic?, false), do: 1, else: 0
    {r, g, b} = Wire.rgb(run.fg)

    <<encode_string16(run.text, :styled_run_length)::binary, r::8, g::8, b::8, bold::8,
      italic::8>>
  end

  @spec encode_tree_nodes([TreeNode.t()]) :: binary()
  defp encode_tree_nodes(nodes) do
    {data, count} = encode_tree_node_list(nodes)
    IO.iodata_to_binary([<<count::8>>, data])
  end

  @spec encode_tree_node_list([TreeNode.t()]) :: {binary(), non_neg_integer()}
  defp encode_tree_node_list(nodes) do
    validate_uint!(:tree_node_count, Enum.count(nodes), Wire.max_u8())
    node_binaries = Enum.map(nodes, &encode_tree_node/1)

    {IO.iodata_to_binary(node_binaries), Enum.count(node_binaries)}
  end

  @spec encode_tree_node(TreeNode.t()) :: binary()
  defp encode_tree_node(%TreeNode{} = node) do
    expanded = if node.expanded?, do: 1, else: 0
    {child_nodes, child_count} = encode_tree_node_list(node.children)
    child_data = IO.iodata_to_binary([<<child_count::8>>, child_nodes])

    <<encode_string16(node.label, :tree_label_length)::binary, expanded::8, child_count::8,
      child_data::binary>>
  end

  @spec encode_string16(iodata(), atom()) :: binary()
  defp encode_string16(value, field) do
    bytes = :erlang.iolist_to_binary([value])
    validate_uint!(field, byte_size(bytes), Wire.max_u16())
    <<byte_size(bytes)::16, bytes::binary>>
  end

  @spec encode_string8(iodata(), atom()) :: binary()
  defp encode_string8(value, field) do
    bytes = :erlang.iolist_to_binary([value])
    validate_uint!(field, byte_size(bytes), Wire.max_u8())
    <<byte_size(bytes)::8, bytes::binary>>
  end

  @spec validate_value!(term(), atom(), non_neg_integer()) :: non_neg_integer()
  defp validate_value!(value, field, max) do
    validate_uint!(field, value, max)
    value
  end

  @spec validate_uint!(atom(), term(), non_neg_integer()) :: :ok
  defp validate_uint!(field, value, max),
    do: Wire.validate_uint!(:gui_extension_panel, field, value, max)
end
