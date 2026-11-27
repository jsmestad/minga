defmodule MingaEditor.Renderer.TranscriptUpdate do
  @moduledoc """
  Editor-to-Renderer transport for the active Agent transcript presentation.

  The Editor owns the indexed display and computes exact display changes. A submission carries one of three values instead of the retained history:

  * `{:seed, identity, revision, epoch, entries}` replaces the renderer's resident base with the complete keyed display. The Editor sends it for a new renderer connection, a new presentation identity, or an explicit renderer reseed request.
  * `{:unchanged, identity, revision, epoch}` states that the display did not change since `revision`.
  * `{:changes, identity, from, to, epoch, changes}` carries the ordered keyed display changes from revision `from` to revision `to`, including display-only changes such as separators and paging.

  A renderer applies an update only when its base has the exact identity and revision. A fingerprint is never a continuity check. `epoch` is the existing wire change token for the resident transcript stream; it is a scalar, not history.
  """

  alias MingaEditor.Agent.UIState.TranscriptProjection
  alias MingaEditor.Agent.UIState.TranscriptProjection.Index
  alias MingaEditor.RenderPipeline.Intent
  alias MingaEditor.RenderPipeline.WorkspaceIntent

  @type identity :: TranscriptProjection.presentation_identity()
  @type revision :: non_neg_integer()
  @type epoch :: non_neg_integer()
  @type key :: TranscriptProjection.display_key()
  @type item :: Index.item()
  @type change :: TranscriptProjection.display_change()

  @type t ::
          {:seed, identity(), revision(), epoch(), [{key(), item()}]}
          | {:unchanged, identity(), revision(), epoch()}
          | {:changes, identity(), revision(), revision(), epoch(), nonempty_list(change())}

  @typedoc """
  The Editor's base for one connected renderer process: the revision and projection last submitted to it.

  It is not a frontend acknowledgement or a Session cursor. The revision never rewinds across renderer connections.
  """
  @type base :: {:unseeded, revision()} | {:submitted, revision(), TranscriptProjection.t()}

  @doc """
  Packs the transcript update for one intent and returns the base the renderer holds after admitting it.

  An unseeded base sends a seed. An intent without a transcript source leaves the base unchanged.
  """
  @spec advance_base(base(), Intent.t()) :: {base(), t() | nil}
  def advance_base(base, %Intent{workspace: workspace}),
    do: advance_source(base, WorkspaceIntent.transcript_source(workspace))

  @doc "Advances the child transcript or closes its base when the pane disappears."
  @spec advance_peek_base(base(), Intent.t()) :: {base(), t() | nil}
  def advance_peek_base(base, %Intent{workspace: workspace}) do
    case WorkspaceIntent.peek_source(workspace) do
      nil -> {unseeded(base), nil}
      source -> advance_source(base, source)
    end
  end

  @doc "Requires the next submission to seed this base without losing its revision."
  @spec unseeded(base()) :: base()
  def unseeded({:unseeded, _revision} = base), do: base
  def unseeded({:submitted, revision, _projection}), do: {:unseeded, revision}

  @doc "Advances a separate transcript source using the same seed and delta contract."
  @spec advance_source(base(), TranscriptProjection.t() | nil) :: {base(), t() | nil}
  def advance_source(base, nil), do: {base, nil}

  def advance_source({:unseeded, revision}, projection) do
    revision = revision + 1
    {{:submitted, revision, projection}, seed(projection, revision)}
  end

  def advance_source({:submitted, revision, previous}, projection) do
    {update, revision} = advance(previous, revision, projection)
    {{:submitted, revision, projection}, update}
  end

  @doc "Builds a complete keyed display for a renderer that has no valid base."
  @spec seed(TranscriptProjection.t(), revision()) :: t()
  def seed(%TranscriptProjection{} = projection, revision)
      when is_integer(revision) and revision >= 0 do
    {:seed, TranscriptProjection.presentation_identity(projection), revision,
     TranscriptProjection.presentation_epoch(projection),
     TranscriptProjection.presentation_entries(projection)}
  end

  @doc """
  Advances from the projection last submitted at `revision` to `current`.

  Returns the update and the revision the renderer base holds after applying it. A different presentation identity always produces a seed.
  """
  @spec advance(TranscriptProjection.t(), revision(), TranscriptProjection.t()) ::
          {t(), revision()}
  def advance(%TranscriptProjection{} = previous, revision, %TranscriptProjection{} = current) do
    identity = TranscriptProjection.presentation_identity(current)

    if TranscriptProjection.presentation_identity(previous) == identity do
      epoch = TranscriptProjection.presentation_epoch(current)

      case TranscriptProjection.presentation_changes(previous, current) do
        [] ->
          {{:unchanged, identity, revision, epoch}, revision}

        [_ | _] = changes ->
          {{:changes, identity, revision, revision + 1, epoch, changes}, revision + 1}
      end
    else
      {seed(current, revision + 1), revision + 1}
    end
  end
end
