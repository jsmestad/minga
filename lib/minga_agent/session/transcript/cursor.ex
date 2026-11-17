defmodule MingaAgent.Session.Transcript.Cursor do
  @moduledoc "Runtime-only identity of one exact transcript revision; never persisted."

  @enforce_keys [:incarnation, :generation, :revision]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            incarnation: reference(),
            generation: non_neg_integer(),
            revision: non_neg_integer()
          }

  @type reset_reason :: :foreign_incarnation | :reset_generation | :future_cursor
  @type comparison ::
          {:unchanged, t()}
          | {:changes_since, non_neg_integer()}
          | {:reset, reset_reason()}
          | {:error, :invalid_cursor}

  @doc "Creates a cursor from facts supplied by the canonical transcript owner."
  @spec new(reference(), non_neg_integer(), non_neg_integer()) :: t()
  def new(incarnation, generation, revision)
      when is_reference(incarnation) and is_integer(generation) and generation >= 0 and
             is_integer(revision) and revision >= 0 do
    %__MODULE__{incarnation: incarnation, generation: generation, revision: revision}
  end

  @doc "Checks continuity against current source facts without exposing cursor internals."
  @spec compare(term(), reference(), non_neg_integer(), non_neg_integer()) :: comparison()
  def compare(
        %__MODULE__{incarnation: nonce, generation: generation, revision: revision} = cursor,
        current_nonce,
        current_generation,
        current_revision
      )
      when is_reference(nonce) and is_integer(generation) and generation >= 0 and
             is_integer(revision) and revision >= 0 do
    compare_valid(cursor, current_nonce, current_generation, current_revision)
  end

  def compare(_invalid, _nonce, _generation, _revision), do: {:error, :invalid_cursor}

  defp compare_valid(%{incarnation: other}, current, _generation, _revision)
       when other != current, do: {:reset, :foreign_incarnation}

  defp compare_valid(%{generation: old}, _nonce, generation, _revision)
       when old < generation, do: {:reset, :reset_generation}

  defp compare_valid(%{generation: future}, _nonce, generation, _revision)
       when future > generation, do: {:reset, :future_cursor}

  defp compare_valid(%{revision: future}, _nonce, _generation, revision)
       when future > revision, do: {:reset, :future_cursor}

  defp compare_valid(%{revision: revision} = cursor, _nonce, _generation, revision),
    do: {:unchanged, cursor}

  defp compare_valid(%{revision: revision}, _nonce, _generation, _current),
    do: {:changes_since, revision}
end
