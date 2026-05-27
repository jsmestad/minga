defmodule MingaEditor.RenderModel.UI.WhichKeyBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.WhichKey
  alias MingaEditor.State.WhichKey, as: WhichKeyState
  alias MingaEditor.UI.WhichKey, as: WhichKeyUI

  @page_size 20

  @spec build(WhichKeyState.t()) :: WhichKey.t()
  def build(%WhichKeyState{show: false}) do
    %WhichKey{visible: false}
  end

  def build(%WhichKeyState{show: true, node: nil}) do
    %WhichKey{visible: false}
  end

  def build(%WhichKeyState{show: true, node: node, prefix_keys: prefix_keys, page: page}) do
    bindings = WhichKeyUI.bindings_from_node(node)
    prefix = prefix_keys |> Enum.join(" ")
    page_count = max(div(length(bindings) + @page_size - 1, @page_size), 1)

    page_bindings =
      bindings
      |> Enum.drop(page * @page_size)
      |> Enum.take(@page_size)
      |> Enum.map(fn b ->
        %{key: b.key, description: b.description, kind: b.kind, icon: b.icon}
      end)

    %WhichKey{
      visible: true,
      prefix: prefix,
      page: page,
      page_count: page_count,
      bindings: page_bindings
    }
  end
end
