defmodule Minga.Frontend.Adapter.GUI.FileTreeEncoder do
  @moduledoc false

  alias Minga.Frontend.Adapter.GUI.Caches
  alias Minga.RenderModel.UI.FileTree

  @spec encode(FileTree.t(), Caches.t()) :: {binary() | nil, Caches.t()}

  # Ready state: three-way comparison for selection-only fast path
  def encode(
        %FileTree{fingerprint: {:ready, structural_fp, selection_fp}} = model,
        %Caches{} = caches
      ) do
    case caches.last_file_tree_fp do
      {:ready, ^structural_fp, ^selection_fp} ->
        # Nothing changed
        {nil, caches}

      {:ready, ^structural_fp, _previous_selection_fp} ->
        # Only selection changed: send lightweight selection command
        {model.selection_encoded,
         %{caches | last_file_tree_fp: {:ready, structural_fp, selection_fp}}}

      _previous_fp ->
        # Structural change or first render: send full tree
        {model.encoded,
         %{caches | last_file_tree_fp: {:ready, structural_fp, selection_fp}}}
    end
  end

  # Non-ready states: simple fingerprint comparison
  def encode(%FileTree{} = model, %Caches{} = caches) do
    if model.fingerprint != caches.last_file_tree_fp do
      {model.encoded, %{caches | last_file_tree_fp: model.fingerprint}}
    else
      {nil, caches}
    end
  end
end
