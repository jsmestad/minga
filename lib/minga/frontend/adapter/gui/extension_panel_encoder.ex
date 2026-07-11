defmodule Minga.Frontend.Adapter.GUI.ExtensionPanelEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.Frontend.Adapter.GUI.Wire.Writer
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
    writer =
      :gui_extension_panel
      |> Writer.new()
      |> Writer.uint8(:panel_count, Enum.count(model.panels))

    payload =
      model.panels
      |> Enum.reduce(writer, &encode_panel/2)
      |> Writer.finish()

    :gui_extension_panel
    |> Writer.new()
    |> Writer.append(<<@op_gui_extension_panel>>)
    |> Writer.payload16(:payload, payload)
    |> Writer.finish()
  end

  @spec fingerprint(ExtensionPanel.t()) :: term()
  defp fingerprint(%ExtensionPanel{} = model), do: model.panels

  @spec encode_panel(Panel.t(), Writer.t()) :: Writer.t()
  defp encode_panel(%Panel{} = panel, %Writer{} = writer) do
    {size_type, size_value} = encode_size(panel.size)
    visible = if panel.visible?, do: 1, else: 0

    writer =
      writer
      |> Writer.string8(:extension, panel.extension)
      |> Writer.string8(:panel_id, panel.panel_id)
      |> Writer.string8(:panel_title, panel.title)
      |> Writer.uint8(:panel_position, encode_position(panel.position))
      |> Writer.uint8(:panel_size_type, size_type)
      |> Writer.uint8(:panel_size_value, size_value)
      |> Writer.uint8(:panel_visible, visible)
      |> Writer.uint8(:panel_block_count, Enum.count(panel.content))

    Enum.reduce(panel.content, writer, &encode_content_block/2)
  end

  @spec encode_size(Panel.size()) :: {non_neg_integer(), non_neg_integer()}
  defp encode_size({:percent, value}), do: {0, value}
  defp encode_size({:lines, value}), do: {1, value}

  @spec encode_position(Panel.position()) :: non_neg_integer()
  defp encode_position(:bottom), do: 0
  defp encode_position(:right), do: 1
  defp encode_position(:float), do: 2

  @spec encode_content_block(Panel.content_block(), Writer.t()) :: Writer.t()
  defp encode_content_block(%Text{text: text}, %Writer{} = writer) do
    writer |> Writer.append(<<0::8>>) |> Writer.string16(:text, text)
  end

  defp encode_content_block(%StyledText{runs: runs}, %Writer{} = writer) do
    writer =
      writer
      |> Writer.append(<<1::8>>)
      |> Writer.uint8(:styled_run_count, Enum.count(runs))

    Enum.reduce(runs, writer, &encode_styled_run/2)
  end

  defp encode_content_block(%Table{} = table, %Writer{} = writer) do
    writer =
      writer
      |> Writer.append(<<2::8>>)
      |> Writer.uint8(:table_column_count, Enum.count(table.columns))
      |> Writer.uint16(:table_row_count, Enum.count(table.rows))
      |> encode_selected(table.selected)

    writer = Enum.reduce(table.columns, writer, &Writer.string16(&2, :table_column, &1))

    Enum.reduce(table.rows, writer, fn row, acc ->
      Enum.reduce(row, acc, &Writer.string16(&2, :table_cell, &1))
    end)
  end

  defp encode_content_block(%KeyValue{pairs: pairs}, %Writer{} = writer) do
    writer =
      writer
      |> Writer.append(<<3::8>>)
      |> Writer.uint8(:key_value_count, Enum.count(pairs))

    Enum.reduce(pairs, writer, fn {key, value}, acc ->
      acc |> Writer.string16(:key, key) |> Writer.string16(:value, value)
    end)
  end

  defp encode_content_block(%Separator{}, %Writer{} = writer),
    do: Writer.append(writer, <<4::8>>)

  defp encode_content_block(%Progress{label: label, percent: percent}, %Writer{} = writer) do
    writer
    |> Writer.append(<<5::8>>)
    |> Writer.string16(:progress_label, label)
    |> Writer.uint16(:progress_percent, round(percent * 100))
  end

  defp encode_content_block(%Tree{nodes: nodes}, %Writer{} = writer) do
    writer
    |> Writer.append(<<6::8>>)
    |> Writer.payload16(:tree, encode_tree_nodes(nodes))
  end

  defp encode_content_block(%Unknown{}, %Writer{} = writer),
    do: Writer.append(writer, <<255::8>>)

  @spec encode_selected(Writer.t(), non_neg_integer() | nil) :: Writer.t()
  defp encode_selected(%Writer{} = writer, nil),
    do: Writer.uint16(writer, :table_selected, 0xFFFF)

  defp encode_selected(%Writer{} = writer, selected),
    do: Writer.uint16(writer, :table_selected, selected, 65_534)

  @spec encode_styled_run(StyledRun.t(), Writer.t()) :: Writer.t()
  defp encode_styled_run(%StyledRun{} = run, %Writer{} = writer) do
    bold = if Map.get(run.attrs, :bold?, false), do: 1, else: 0
    italic = if Map.get(run.attrs, :italic?, false), do: 1, else: 0

    writer
    |> Writer.string16(:styled_run, run.text)
    |> Writer.rgb24(:styled_run_fg, run.fg)
    |> Writer.uint8(:styled_run_bold, bold)
    |> Writer.uint8(:styled_run_italic, italic)
  end

  @spec encode_tree_nodes([TreeNode.t()]) :: binary()
  defp encode_tree_nodes(nodes) do
    writer = Writer.uint8(Writer.new(:gui_extension_panel), :tree_node_count, Enum.count(nodes))

    nodes
    |> Enum.reduce(writer, &encode_tree_node/2)
    |> Writer.finish()
  end

  @spec encode_tree_node(TreeNode.t(), Writer.t()) :: Writer.t()
  defp encode_tree_node(%TreeNode{} = node, %Writer{} = writer) do
    expanded = if node.expanded?, do: 1, else: 0
    child_data = encode_tree_nodes(node.children)

    writer
    |> Writer.string16(:tree_label, node.label)
    |> Writer.uint8(:tree_expanded, expanded)
    |> Writer.uint8(:tree_child_count, Enum.count(node.children))
    |> Writer.append(child_data)
  end
end
