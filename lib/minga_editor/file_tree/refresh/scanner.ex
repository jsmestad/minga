defmodule MingaEditor.FileTree.Refresh.Scanner do
  @moduledoc "Contract for filesystem scanners used by the typed file-tree refresh effect."

  alias Minga.Project.FileTree

  @callback scan(FileTree.t(), term()) :: FileTree.t() | {:error, term()}
end
