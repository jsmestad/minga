defmodule MingaEditor.Agent.ReviewHighlights do
  @moduledoc """
  Tree-sitter highlight results for the two sides of the staged Diff Review.

  The review shows removed lines from the original text and added lines from the agent's post-image, so each side needs its own parse. This value records which source texts the current review wants, which parses are still pending, and which results arrived. The Editor starts each parse off its own process (see `MingaEditor.Agent.ReviewHighlightWorkflow`) and installs results with `complete/3`; the renderer reads ready results with `sides/1` and renders flat diff colors until they exist.

  Results are keyed by language and a SHA-256 digest of the side's text, so an unchanged side keeps its result across review revisions and a stale result for replaced text is dropped. Spans are packed into one binary so that copying the render snapshot to the Renderer process does not copy one term per span.
  """

  alias Minga.Language.Filetype
  alias Minga.Language.Grammar
  alias Minga.Language.Highlight.Span
  alias MingaEditor.Agent.DiffReview

  @typedoc "Which text a result highlights: the original (removed and context lines) or the post-image (added lines)."
  @type side :: :old | :new

  @typedoc "Identifies one highlighted source text."
  @type key :: {language :: String.t(), digest :: binary()}

  @typedoc "A parse outcome. Spans are packed by `pack_spans/1`."
  @type result :: {:ready, [String.t()], binary()} | :unavailable

  @typedoc "A parse the owning process must start."
  @type request :: {key(), language :: String.t(), source :: String.t()}

  @typedoc "A ready result for one side, as read by the renderer."
  @type ready :: {key(), [String.t()], binary()}

  @typep entry :: :pending | result()
  @typep source :: {String.t(), [String.t()], [Minga.Core.Diff.hunk()]} | nil

  @type t :: %__MODULE__{
          source: source(),
          wanted: %{side() => key()},
          entries: %{key() => entry()}
        }

  defstruct source: nil, wanted: %{}, entries: %{}

  @span_bits 32

  @doc "Creates an empty result set."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Reconciles the wanted parses with the review currently in the preview.

  Returns `:unchanged` without hashing when the review's path, post-image, and hunks are the same terms as the last plan. Otherwise returns the next value and the parses to start; reused results stay, results for replaced text are dropped, and a file without a registered grammar wants nothing.
  """
  @spec plan(t(), DiffReview.t() | nil) :: :unchanged | {:planned, t(), [request()]}
  def plan(%__MODULE__{source: nil, entries: entries}, nil) when map_size(entries) == 0,
    do: :unchanged

  def plan(%__MODULE__{}, nil), do: {:planned, new(), []}

  def plan(%__MODULE__{source: source} = store, %DiffReview{} = review) do
    case review_source(review) do
      ^source -> :unchanged
      next -> plan_source(store, review, next)
    end
  end

  @doc """
  Installs a parse outcome when the result set still waits for it.

  Returns `:stale` when the review moved on to different text before the parse finished, so the caller does not render for it.
  """
  @spec complete(t(), key(), result()) :: {:accepted, t()} | :stale
  def complete(%__MODULE__{entries: entries} = store, key, result) do
    case Map.fetch(entries, key) do
      {:ok, :pending} -> {:accepted, %{store | entries: Map.put(entries, key, result)}}
      _missing_or_done -> :stale
    end
  end

  @doc "Returns the ready result for each side of the review, or `nil` for a side that is pending or has no grammar."
  @spec sides(t()) :: %{side() => ready() | nil}
  def sides(%__MODULE__{wanted: wanted, entries: entries}) do
    Map.new([:old, :new], fn side -> {side, ready(wanted, entries, side)} end)
  end

  @doc "Drops the planning identity, which only the Editor needs, from a renderer snapshot."
  @spec render_snapshot(t()) :: t()
  def render_snapshot(%__MODULE__{source: nil} = store), do: store
  def render_snapshot(%__MODULE__{} = store), do: %{store | source: nil}

  @doc "Converts a parser highlight outcome into a packed result."
  @spec pack_result(Minga.Parser.Manager.highlight_source_result() | term()) :: result()
  def pack_result({:ok, names, spans}) when is_list(names) and is_list(spans),
    do: {:ready, names, pack_spans(spans)}

  def pack_result(_unsupported_or_failed), do: :unavailable

  @doc "Packs highlight spans into one binary."
  @spec pack_spans([Span.t()]) :: binary()
  def pack_spans(spans) when is_list(spans) do
    for %Span{} = span <- spans, into: <<>> do
      <<span.start_byte::@span_bits, span.end_byte::@span_bits, span.capture_id::@span_bits,
        span.pattern_index::@span_bits, span.layer::8>>
    end
  end

  @doc "Unpacks spans produced by `pack_spans/1`."
  @spec unpack_spans(binary()) :: [Span.t()]
  def unpack_spans(packed) when is_binary(packed) do
    for <<start::@span_bits, stop::@span_bits, capture::@span_bits, pattern::@span_bits,
          layer::8 <- packed>> do
      Span.new(start, stop, capture, pattern, layer)
    end
  end

  @spec plan_source(t(), DiffReview.t(), source()) :: {:planned, t(), [request()]}
  defp plan_source(store, review, source) do
    case language(review.path) do
      {:ok, language} ->
        texts = %{
          old: review |> DiffReview.original_lines() |> Enum.join("\n"),
          new: Enum.join(review.after_lines, "\n")
        }

        wanted = Map.new(texts, fn {side, text} -> {side, key(language, text)} end)
        retained = Map.take(store.entries, Map.values(wanted))

        requests =
          texts
          |> Enum.map(fn {side, text} -> {Map.fetch!(wanted, side), language, text} end)
          |> Enum.uniq_by(fn {key, _language, _text} -> key end)
          |> Enum.reject(fn {key, _language, _text} -> Map.has_key?(retained, key) end)

        entries =
          Enum.reduce(requests, retained, fn {key, _language, _text}, entries ->
            Map.put(entries, key, :pending)
          end)

        {:planned, %__MODULE__{source: source, wanted: wanted, entries: entries}, requests}

      :unsupported ->
        {:planned, %__MODULE__{source: source}, []}
    end
  end

  @spec review_source(DiffReview.t()) :: source()
  defp review_source(%DiffReview{path: path, after_lines: lines, hunks: hunks}),
    do: {path, lines, hunks}

  @spec language(String.t()) :: {:ok, String.t()} | :unsupported
  defp language(path), do: path |> Filetype.detect() |> Grammar.language_for_filetype()

  @spec key(String.t(), String.t()) :: key()
  defp key(language, text), do: {language, :crypto.hash(:sha256, text)}

  @spec ready(%{side() => key()}, %{key() => entry()}, side()) :: ready() | nil
  defp ready(wanted, entries, side) do
    with {:ok, key} <- Map.fetch(wanted, side),
         {:ok, {:ready, names, spans}} <- Map.fetch(entries, key) do
      {key, names, spans}
    else
      _pending_or_unwanted -> nil
    end
  end
end
