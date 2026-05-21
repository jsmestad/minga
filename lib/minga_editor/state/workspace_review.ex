defmodule MingaEditor.State.WorkspaceReview do
  @moduledoc """
  Review state for workspace-local agent drafts.

  The state field is intentionally limited to stable states. Promote, apply, discard, and resolve are transitions, not stored states.
  """

  alias Minga.Project.FileRef

  @type state :: :clean | :draft | :needs_review | :conflict

  @type error :: term()

  @type t :: %__MODULE__{
          state: state(),
          changed_files: [FileRef.t()],
          conflict_files: [FileRef.t()],
          last_error: error() | nil,
          in_progress?: boolean()
        }

  @enforce_keys [:state]
  defstruct state: :clean,
            changed_files: [],
            conflict_files: [],
            last_error: nil,
            in_progress?: false

  @doc "Creates a clean review state."
  @spec new() :: t()
  def new, do: %__MODULE__{state: :clean}

  @doc "Returns true when the review has unapplied drafts, conflicts, or a recorded error."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{changed_files: changed, conflict_files: conflicts, last_error: error}) do
    changed != [] or conflicts != [] or not is_nil(error)
  end

  @doc "Returns the number of changed draft files."
  @spec draft_count(t()) :: non_neg_integer()
  def draft_count(%__MODULE__{changed_files: files}), do: length(files)

  @doc "Returns the number of conflicting files."
  @spec conflict_count(t()) :: non_neg_integer()
  def conflict_count(%__MODULE__{conflict_files: files}), do: length(files)

  @doc "Sets changed files without changing the stable state."
  @spec set_changed_files(t(), [FileRef.t()]) :: t()
  def set_changed_files(%__MODULE__{} = review, files) when is_list(files) do
    %{review | changed_files: files}
  end

  @doc "Clears all draft and conflict metadata and returns to clean."
  @spec clean(t()) :: t()
  def clean(%__MODULE__{} = review) do
    %{
      review
      | state: :clean,
        changed_files: [],
        conflict_files: [],
        last_error: nil,
        in_progress?: false
    }
  end

  @doc "Marks the workspace as needing review, optionally recording an error."
  @spec mark_needs_review(t(), [FileRef.t()], error() | nil) :: t()
  def mark_needs_review(%__MODULE__{} = review, files, error \\ nil) when is_list(files) do
    %{
      review
      | state: :needs_review,
        changed_files: files,
        conflict_files: [],
        last_error: error,
        in_progress?: false
    }
  end

  @doc "Moves a clean workspace into draft mode."
  @spec agent_started_editing(t(), [FileRef.t()]) :: {:ok, t()} | {:error, term()}
  def agent_started_editing(%__MODULE__{state: :clean} = review, files) when is_list(files) do
    {:ok, %{review | state: :draft, changed_files: files, conflict_files: [], last_error: nil}}
  end

  def agent_started_editing(%__MODULE__{state: from}, _files), do: invalid(from, :draft)

  @doc "Records more draft edits while staying in draft mode."
  @spec agent_made_more_edits(t(), [FileRef.t()]) :: {:ok, t()} | {:error, term()}
  def agent_made_more_edits(%__MODULE__{state: :draft} = review, files) when is_list(files) do
    {:ok, %{review | changed_files: files, last_error: nil}}
  end

  def agent_made_more_edits(%__MODULE__{state: from}, _files), do: invalid(from, :draft)

  @doc "Marks draft work as ready for review, or clean when no drafts exist."
  @spec agent_completed(t(), [FileRef.t()]) :: {:ok, t()} | {:error, term()}
  def agent_completed(%__MODULE__{state: :draft} = review, []) do
    {:ok, clean(review)}
  end

  def agent_completed(%__MODULE__{state: :draft} = review, files) when is_list(files) do
    {:ok,
     %{review | state: :needs_review, changed_files: files, conflict_files: [], last_error: nil}}
  end

  def agent_completed(%__MODULE__{state: from}, _files), do: invalid(from, :needs_review)

  @doc "Moves review or conflict work back to draft mode when an agent resumes."
  @spec agent_resumed(t()) :: {:ok, t()} | {:error, term()}
  def agent_resumed(%__MODULE__{state: state} = review)
      when state in [:needs_review, :conflict] do
    {:ok, %{review | state: :draft, last_error: nil}}
  end

  def agent_resumed(%__MODULE__{state: from}), do: invalid(from, :draft)

  @doc "Marks a successful promote as clean."
  @spec promote_succeeded(t()) :: {:ok, t()} | {:error, term()}
  def promote_succeeded(%__MODULE__{state: state} = review)
      when state in [:needs_review, :conflict] do
    {:ok, clean(review)}
  end

  def promote_succeeded(%__MODULE__{state: from}), do: invalid(from, :clean)

  @doc "Marks an overlap detected during promote."
  @spec promote_found_overlaps(t(), [FileRef.t()], term()) :: {:ok, t()} | {:error, term()}
  def promote_found_overlaps(%__MODULE__{state: state} = review, files, error)
      when state in [:needs_review, :conflict] and is_list(files) do
    {:ok,
     %{review | state: :conflict, conflict_files: files, last_error: error, in_progress?: false}}
  end

  def promote_found_overlaps(%__MODULE__{state: from}, _files, _error),
    do: invalid(from, :conflict)

  @doc "Discards one file from draft and conflict metadata."
  @spec discard_file(t(), FileRef.t()) :: t()
  def discard_file(%__MODULE__{} = review, %FileRef{} = file_ref) do
    changed_files = Enum.reject(review.changed_files, &FileRef.equal?(&1, file_ref))
    conflict_files = Enum.reject(review.conflict_files, &FileRef.equal?(&1, file_ref))

    review
    |> Map.merge(%{changed_files: changed_files, conflict_files: conflict_files})
    |> normalize_state_after_file_discard()
  end

  @doc "Clears drafts or conflicts without applying them."
  @spec discard(t()) :: {:ok, t()} | {:error, term()}
  def discard(%__MODULE__{state: state} = review)
      when state in [:draft, :needs_review, :conflict] do
    {:ok, clean(review)}
  end

  def discard(%__MODULE__{state: from}), do: invalid(from, :clean)

  @doc "Marks conflicts as resolved and promoted."
  @spec resolved_and_promoted(t()) :: {:ok, t()} | {:error, term()}
  def resolved_and_promoted(%__MODULE__{state: :conflict} = review), do: {:ok, clean(review)}
  def resolved_and_promoted(%__MODULE__{state: from}), do: invalid(from, :clean)

  @spec normalize_state_after_file_discard(t()) :: t()
  defp normalize_state_after_file_discard(%__MODULE__{conflict_files: [_ | _]} = review) do
    %{review | state: :conflict, last_error: nil, in_progress?: false}
  end

  defp normalize_state_after_file_discard(
         %__MODULE__{state: :draft, changed_files: [_ | _]} = review
       ) do
    %{review | last_error: nil, in_progress?: false}
  end

  defp normalize_state_after_file_discard(%__MODULE__{changed_files: [_ | _]} = review) do
    %{review | state: :needs_review, last_error: nil, in_progress?: false}
  end

  defp normalize_state_after_file_discard(%__MODULE__{} = review), do: clean(review)

  @spec invalid(state(), state()) :: {:error, {:invalid_transition, state(), state()}}
  defp invalid(from, to), do: {:error, {:invalid_transition, from, to}}
end
