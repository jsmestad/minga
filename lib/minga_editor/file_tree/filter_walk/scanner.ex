defmodule MingaEditor.FileTree.FilterWalk.Scanner do
  @moduledoc "Contract for controllable cache/filesystem scanners used by filter effects."

  alias Minga.Project.FileTree
  alias MingaEditor.FileTree.FilterWalk.Result

  @callback scan(FileTree.t(), term()) :: Result.t() | {:error, term()}
end
