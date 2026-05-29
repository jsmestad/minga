defmodule MingaEditor.RenderModel.UI.ExtensionPanelBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.ExtensionPanel
  alias Minga.RenderModel.UI.ExtensionPanel.Content
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

  @spec build() :: ExtensionPanel.t()
  def build do
    panels = Minga.Extension.Panel.visible()
    %ExtensionPanel{panels: Enum.map(panels, &panel_model/1)}
  end

  @spec panel_model(Minga.Extension.Panel.entry()) :: Panel.t()
  defp panel_model(panel) do
    %Panel{
      extension: to_string(panel.extension),
      panel_id: to_string(panel.panel_id),
      title: to_string(panel.title),
      position: panel_position(panel.position),
      size: panel_size(panel.size),
      visible?: panel.visible,
      content: Enum.map(panel.content, &content_block_model/1)
    }
  end

  @spec content_block_model(Minga.Extension.Panel.content_block() | term()) :: Content.t()
  defp content_block_model({:text, text}), do: %Text{text: to_string(text)}

  defp content_block_model({:styled_text, runs}) when is_list(runs) do
    %StyledText{runs: Enum.map(runs, &styled_run_model/1)}
  end

  defp content_block_model({:table, %{columns: cols, rows: rows} = table})
       when is_list(cols) and is_list(rows) do
    %Table{
      columns: Enum.map(cols, &to_string/1),
      rows: Enum.map(rows, &table_row_model/1),
      selected: non_negative_integer(Map.get(table, :selected, 0xFFFF))
    }
  end

  defp content_block_model({:key_value, pairs}) when is_list(pairs) do
    %KeyValue{pairs: Enum.map(pairs, &key_value_pair_model/1)}
  end

  defp content_block_model({:separator}), do: %Separator{}

  defp content_block_model({:progress, %{label: label, percent: percent}}) do
    %Progress{label: to_string(label), percent: number_or_zero(percent)}
  end

  defp content_block_model({:tree, %{nodes: nodes}}) when is_list(nodes) do
    %Tree{nodes: Enum.map(nodes, &tree_node_model/1)}
  end

  defp content_block_model(_unknown), do: %Unknown{}

  @spec styled_run_model(term()) :: StyledRun.t()
  defp styled_run_model({text, fg, attrs}) when is_list(attrs) do
    %StyledRun{
      text: to_string(text),
      fg: non_negative_integer(fg),
      attrs: %{
        bold?: Keyword.get(attrs, :bold, false),
        italic?: Keyword.get(attrs, :italic, false)
      }
    }
  end

  defp styled_run_model(_run),
    do: %StyledRun{text: "", fg: 0, attrs: %{bold?: false, italic?: false}}

  @spec tree_node_model(term()) :: TreeNode.t()
  defp tree_node_model(node) when is_map(node) do
    children = Map.get(node, :children, [])
    children = if is_list(children), do: children, else: []

    %TreeNode{
      label: node |> Map.get(:label, "") |> to_string(),
      expanded?: Map.get(node, :expanded, false) == true,
      children: Enum.map(children, &tree_node_model/1)
    }
  end

  defp tree_node_model(_node), do: %TreeNode{label: "", expanded?: false, children: []}

  @spec table_row_model(term()) :: [String.t()]
  defp table_row_model(row) when is_list(row), do: Enum.map(row, &to_string/1)
  defp table_row_model(cell), do: [to_string(cell)]

  @spec key_value_pair_model(term()) :: KeyValue.pair()
  defp key_value_pair_model({key, value}), do: {to_string(key), to_string(value)}
  defp key_value_pair_model(value), do: {to_string(value), ""}

  @spec panel_position(term()) :: Panel.position()
  defp panel_position(position) when position in [:bottom, :right, :float], do: position
  defp panel_position(_position), do: :bottom

  @spec panel_size(term()) :: Panel.size()
  defp panel_size({:percent, n}) when is_integer(n) and n >= 1, do: {:percent, min(n, 100)}
  defp panel_size({:lines, n}) when is_integer(n) and n >= 1, do: {:lines, n}
  defp panel_size(_size), do: {:percent, 30}

  @spec non_negative_integer(term()) :: non_neg_integer()
  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0

  @spec number_or_zero(term()) :: number()
  defp number_or_zero(value) when is_number(value), do: value
  defp number_or_zero(_value), do: 0
end
