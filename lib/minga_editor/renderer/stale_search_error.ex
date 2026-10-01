defmodule MingaEditor.Renderer.StaleSearchError do
  @moduledoc "Signals that a render intent refers to a superseded search-index generation."

  defexception [:generation]

  @type t :: %__MODULE__{generation: Minga.Search.IndexGeneration.t()}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{generation: generation}) do
    "search generation became stale during render: #{inspect(generation.token)}"
  end
end
