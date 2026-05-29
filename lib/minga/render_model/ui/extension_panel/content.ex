defmodule Minga.RenderModel.UI.ExtensionPanel.Content do
  @moduledoc """
  Semantic content blocks for GUI extension panels.
  """

  alias Minga.RenderModel.UI.ExtensionPanel.Content.KeyValue
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Progress
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Separator
  alias Minga.RenderModel.UI.ExtensionPanel.Content.StyledText
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Table
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Text
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Tree
  alias Minga.RenderModel.UI.ExtensionPanel.Content.Unknown

  @type t ::
          Text.t()
          | StyledText.t()
          | Table.t()
          | KeyValue.t()
          | Separator.t()
          | Progress.t()
          | Tree.t()
          | Unknown.t()
end
