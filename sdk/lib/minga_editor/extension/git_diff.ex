defmodule MingaEditor.Extension.GitDiff do
  @moduledoc """
  Open or inspect semantic Git diff views without depending on editor layout.

  Read repository content in an extension worker and pass the exact `{base,
  revised}` texts to the editor callback. Minga owns projection, navigation,
  and saved-buffer synchronization. The extension owns repository policy and
  any user confirmation or Git mutation.
  """

  alias MingaEditor.Extension.EditorAPI
  alias MingaEditor.Extension.GitDiff.Origin
  alias MingaEditor.Extension.GitDiff.Target

  @type state :: EditorAPI.state()
  @type change_result :: {:ok, state()} | {:error, term()}
  @type target_result :: nil | {:ok, Target.t()} | {:error, {:stale_source, Target.t()}}

  @doc "Opens and activates a unified diff for exact base and revised texts."
  @spec open(state(), Origin.t(), Target.contents()) :: change_result()
  def open(_state, _origin, _contents), do: raise("minga_sdk is compile-time only")

  @doc "Replaces the exact snapshots in a named view, preserving its projection."
  @spec replace(state(), pid(), Origin.section(), Target.contents()) :: change_result()
  def replace(_state, _diff_buffer, _section, _contents),
    do: raise("minga_sdk is compile-time only")

  @doc "Reprojects the displayed snapshots. Side-by-side is available on GUI frontends."
  @spec set_layout(state(), pid(), Target.layout()) :: change_result()
  def set_layout(_state, _diff_buffer, _layout), do: raise("minga_sdk is compile-time only")

  @doc """
  Returns the exact target at the diff buffer's cursor, or nil for non-views.

  A stale source returns the origin and snapshots but no actionable hunk.
  Pass the active diff buffer to inspect the currently rendered cursor.
  """
  @spec target(state(), pid() | nil) :: target_result()
  def target(_state, _diff_buffer), do: raise("minga_sdk is compile-time only")

  @doc "Moves the view's cursor to the next or previous changed region without wrapping."
  @spec navigate(state(), pid(), :next | :previous) :: change_result()
  def navigate(_state, _diff_buffer, _direction), do: raise("minga_sdk is compile-time only")
end
