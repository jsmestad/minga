defmodule MingaEditor.Extension.GitFeedback do
  @moduledoc "Compile-time declarations for remote Git progress, results, and exact retries."

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.RepositoryJob

  @spec progress(EditorAPI.state(), String.t()) :: EditorAPI.state()
  def progress(_state, _message), do: raise("minga_sdk is compile-time only")

  @spec publish(EditorAPI.state(), String.t(), :success | :error, RepositoryJob.t() | nil) ::
          EditorAPI.state()
  def publish(_state, _message, _level, _retry \\ nil),
    do: raise("minga_sdk is compile-time only")
end
