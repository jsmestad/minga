defmodule MingaEditor.RenderModel.UI.BreadcrumbBuilder do
  @moduledoc false

  alias Minga.RenderModel.UI.Breadcrumb

  @spec build(String.t() | nil, String.t()) :: Breadcrumb.t()
  def build(file_path, root) do
    %Breadcrumb{segments: segments(file_path, root)}
  end

  # Derive the wire-ready path segment list (ruling 4). A nil file_path means no
  # breadcrumb, encoded as an empty segment list.
  @spec segments(String.t() | nil, String.t()) :: [String.t()]
  defp segments(nil, _root), do: []
  defp segments(file_path, root), do: file_path |> Path.relative_to(root) |> Path.split()
end
