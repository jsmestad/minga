defmodule MingaEditor.Extension.RepositoryJob.Handler do
  @moduledoc """
  Runs repository work in a supervised worker and receives accepted results in the editor.

  `run/2` receives the exact repository and the arguments captured at dispatch, not the current project or editor state. `on_result/4` runs only for the source activation and project that submitted the job. Keep it short and return the updated editor state.
  """

  alias MingaEditor.Extension.EditorAPI

  @type result :: {:ok, term()} | {:error, term()}
  @type outcome :: {:completed, term()} | {:failed, term()} | {:canceled, term()}

  @callback run(root :: String.t(), args :: term()) :: result()

  @doc "Publishes progress after the editor admits and starts the job."
  @callback on_start(EditorAPI.state(), root :: String.t(), args :: term()) :: EditorAPI.state()

  @callback on_result(EditorAPI.state(), root :: String.t(), outcome(), args :: term()) ::
              EditorAPI.state()

  @optional_callbacks on_start: 3
end
