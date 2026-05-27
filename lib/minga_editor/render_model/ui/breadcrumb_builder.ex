defmodule MingaEditor.RenderModel.UI.BreadcrumbBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Breadcrumb

  @spec build(String.t() | nil, String.t()) :: Breadcrumb.t()
  def build(file_path, root) do
    %Breadcrumb{file_path: file_path, root: root}
  end
end
