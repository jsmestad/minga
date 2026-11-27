defmodule MingaEditor.Renderer.Submission do
  @moduledoc """
  Editor-to-Renderer transport containing only changed bulk highlight data and the transcript update.

  The packed intent is private to this envelope. Materialize it in mailbox order before rejecting or coalescing frames, so every renderer workflow receives a complete immutable Intent. A full submission replaces the retained maps; a delta preserves unchanged buffers and explicitly removes closed ones.

  The packed intent never carries the retained Agent transcript. `transcript` is a `MingaEditor.Renderer.TranscriptUpdate`: a seed, an unchanged marker, or ordered display changes. `Renderer.State.receive_submission/2` admits it against the renderer-local resident root before scheduling.
  """

  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.WorkspaceIntent
  alias MingaEditor.Renderer.TranscriptUpdate
  alias MingaEditor.State.LSP
  alias MingaEditor.UI.Highlight

  @type revisions :: %{pid() => reference()}
  @type highlights :: %{pid() => Highlight.t()}
  @type semantic_tokens :: %{pid() => LSP.semantic_layer()}

  @enforce_keys [
    :intent,
    :mode,
    :highlights,
    :semantic_tokens,
    :removed_highlights,
    :removed_semantic_tokens,
    :transcript
  ]
  defstruct @enforce_keys ++ [peek_transcript: nil]

  @opaque t :: %__MODULE__{
            intent: Intent.t(),
            mode: :full | :delta,
            highlights: highlights(),
            semantic_tokens: semantic_tokens(),
            removed_highlights: [pid()],
            removed_semantic_tokens: [pid()],
            transcript: TranscriptUpdate.t() | nil,
            peek_transcript: TranscriptUpdate.t() | nil
          }

  @doc "Builds a self-contained submission, including a transcript seed, for a new renderer or an independent caller."
  @spec full(Intent.t()) :: t()
  def full(%Intent{} = intent) do
    submission = full(intent, seed(intent))

    case WorkspaceIntent.peek_source(intent.workspace) do
      nil -> submission
      projection -> with_peek_transcript(submission, TranscriptUpdate.seed(projection, 0))
    end
  end

  @doc "Builds a self-contained highlight submission carrying an explicit transcript update."
  @spec full(Intent.t(), TranscriptUpdate.t() | nil) :: t()
  def full(%Intent{} = intent, transcript) do
    %__MODULE__{
      intent: pack(intent),
      mode: :full,
      highlights: intent.frame.highlighting.highlights,
      semantic_tokens: intent.frame.semantic_tokens,
      removed_highlights: [],
      removed_semantic_tokens: [],
      transcript: transcript
    }
  end

  @doc "Builds a delta against the same renderer process's last submitted source revisions."
  @spec delta(Intent.t(), revisions(), revisions(), revisions(), TranscriptUpdate.t() | nil) ::
          t()
  def delta(
        %Intent{} = intent,
        previous_highlights,
        previous_semantics,
        semantic_revisions,
        transcript
      ) do
    highlight_revisions = intent.frame.highlighting.revisions

    %__MODULE__{
      intent: pack(intent),
      transcript: transcript,
      mode: :delta,
      highlights:
        changed_values(
          intent.frame.highlighting.highlights,
          highlight_revisions,
          previous_highlights
        ),
      semantic_tokens:
        changed_values(intent.frame.semantic_tokens, semantic_revisions, previous_semantics),
      removed_highlights: removed_buffers(previous_highlights, highlight_revisions),
      removed_semantic_tokens: removed_buffers(previous_semantics, semantic_revisions)
    }
  end

  @doc "Returns the transcript update the renderer must admit before scheduling this frame."
  @spec transcript(t()) :: TranscriptUpdate.t() | nil
  def transcript(%__MODULE__{transcript: transcript}), do: transcript

  @doc "Adds the independently correlated child transcript to the packed frame."
  @spec with_peek_transcript(t(), TranscriptUpdate.t() | nil) :: t()
  def with_peek_transcript(%__MODULE__{} = submission, transcript),
    do: %{submission | peek_transcript: transcript}

  @doc "Returns the child's update, if the frame has a visible peek."
  @spec peek_transcript(t()) :: TranscriptUpdate.t() | nil
  def peek_transcript(%__MODULE__{peek_transcript: transcript}), do: transcript

  @spec pack(Intent.t()) :: Intent.t()
  defp pack(intent) do
    intent
    |> Intent.with_highlight_payload(%{}, %{})
    |> Intent.with_agent_transcript(nil)
    |> Intent.with_peek_transcript(nil)
  end

  @spec seed(Intent.t()) :: TranscriptUpdate.t() | nil
  defp seed(%Intent{workspace: workspace}) do
    case WorkspaceIntent.transcript_source(workspace) do
      %TranscriptProjection{} = projection -> TranscriptUpdate.seed(projection, 0)
      nil -> nil
    end
  end

  @doc "Installs the update and restores the exact full intent before frame scheduling."
  @spec materialize(t(), highlights(), semantic_tokens()) ::
          {Intent.t(), highlights(), semantic_tokens()}
  def materialize(%__MODULE__{mode: :full} = submission, _highlights, _semantic_tokens) do
    {Intent.with_highlight_payload(
       submission.intent,
       submission.highlights,
       submission.semantic_tokens
     ), submission.highlights, submission.semantic_tokens}
  end

  def materialize(%__MODULE__{mode: :delta} = submission, highlights, semantic_tokens) do
    highlights =
      highlights |> Map.drop(submission.removed_highlights) |> Map.merge(submission.highlights)

    semantic_tokens =
      semantic_tokens
      |> Map.drop(submission.removed_semantic_tokens)
      |> Map.merge(submission.semantic_tokens)

    {Intent.with_highlight_payload(submission.intent, highlights, semantic_tokens), highlights,
     semantic_tokens}
  end

  @spec changed_values(map(), revisions(), revisions()) :: map()
  defp changed_values(values, current, previous) do
    Map.reject(values, fn {buffer, _value} ->
      Map.fetch!(current, buffer) == Map.get(previous, buffer)
    end)
  end

  @spec removed_buffers(revisions(), revisions()) :: [pid()]
  defp removed_buffers(previous, current) do
    previous |> Map.keys() |> Enum.reject(&Map.has_key?(current, &1))
  end
end
