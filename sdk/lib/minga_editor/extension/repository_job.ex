defmodule MingaEditor.Extension.RepositoryJob do
  @moduledoc "Compile-time declaration for proposing repository work from an extension command or editor action."

  alias MingaEditor.Extension.EditorAPI

  @typedoc "An opaque proposal; the editor validates it before starting work."
  @type t :: term()
  @type lane :: :remote | :commit_message | :diff_open
  @type result ::
          {:ok, t()} | {:error, :source_unavailable | :invalid_repository | :invalid_arguments}

  @spec propose(EditorAPI.state(), lane(), String.t(), module(), term()) :: result()
  def propose(_state, _lane, _root, _handler, _args), do: raise("minga_sdk is compile-time only")
end
