defmodule MingaEditor.Renderer.HighlightCache do
  @moduledoc """
  Retains composed syntax and semantic presentation by source revision.

  Preparation visits each displayed buffer once, independent of its span count on a cache hit. Raw frame sources remain immutable. Hidden buffers retain their composition until their sources are removed; frontend acknowledgement and reset do not affect this derived state.
  """

  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.UI.Highlight

  @type highlights :: %{pid() => Highlight.t() | nil}
  @typep revision :: {reference() | {:theme, term()}, reference() | nil}
  @typep entry :: {revision(), Highlight.t() | nil}
  @type t :: %__MODULE__{entries: %{pid() => entry()}}
  defstruct entries: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Composes only displayed buffers whose source revisions changed."
  @spec prepare(t(), Intent.t()) :: {t(), highlights()}
  def prepare(%__MODULE__{} = cache, %Intent{} = intent) do
    buffers =
      for {_id, %{content: {:buffer, buffer}}} <- intent.windows, uniq: true, do: buffer

    cache = retain(cache, intent)

    Enum.reduce(buffers, {cache, %{}}, fn buffer, {cache, prepared} ->
      revision = source_revision(intent.frame, buffer)

      case Map.get(cache.entries, buffer) do
        {^revision, highlight} ->
          {cache, Map.put(prepared, buffer, highlight)}

        _changed ->
          highlight = compose(intent.frame, buffer)
          cache = %{cache | entries: Map.put(cache.entries, buffer, {revision, highlight})}
          {cache, Map.put(prepared, buffer, highlight)}
      end
    end)
  end

  @doc "Discards outdated compositions without evaluating their replacement."
  @spec retain(t(), Intent.t()) :: t()
  def retain(%__MODULE__{} = cache, %Intent{} = intent) do
    visible = for {_id, %{content: {:buffer, buffer}}} <- intent.windows, do: buffer

    retained =
      Map.keys(intent.frame.highlighting.highlights) ++
        Map.keys(intent.frame.semantic_tokens) ++ visible

    entries =
      cache.entries
      |> Map.take(retained)
      |> Map.filter(fn {buffer, {revision, _highlight}} ->
        revision == source_revision(intent.frame, buffer)
      end)

    %{cache | entries: entries}
  end

  @spec drop_buffer(t(), pid()) :: t()
  def drop_buffer(%__MODULE__{} = cache, buffer),
    do: %{cache | entries: Map.delete(cache.entries, buffer)}

  defp source_revision(frame, buffer) do
    syntax =
      if Map.has_key?(frame.highlighting.highlights, buffer),
        do: Map.fetch!(frame.highlighting.revisions, buffer),
        else: {:theme, frame.theme}

    semantic =
      if Map.has_key?(frame.semantic_tokens, buffer),
        do: Map.fetch!(frame.semantic_token_revisions, buffer),
        else: nil

    {syntax, semantic}
  end

  defp compose(frame, buffer) do
    highlight =
      case Map.fetch(frame.highlighting.highlights, buffer) do
        {:ok, highlight} -> highlight
        :error -> Highlight.from_theme(frame.theme)
      end

    compose_layer(highlight, Map.get(frame.semantic_tokens, buffer))
  end

  defp compose_layer(%Highlight{capture_names: {}}, nil), do: nil
  defp compose_layer(highlight, nil), do: highlight

  defp compose_layer(highlight, semantic),
    do: Highlight.compose_semantic_layer(highlight, semantic)
end
