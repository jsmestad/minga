defmodule MingaEditor.NativeIPC.NavigationFinalizer do
  @moduledoc """
  Contains failures from semantic-navigation work that runs after the buffer cursor commit.

  The cursor commit is the operation's linearization point. Later presentation and persistence failures must remain observable without changing the operation from applied to rejected.
  """

  alias MingaEditor.State, as: EditorState

  @doc "Runs one post-commit transition and preserves the accepted state when it fails."
  @spec run(EditorState.t(), atom(), (EditorState.t() -> EditorState.t())) :: EditorState.t()
  def run(%EditorState{} = state, stage, transition) when is_atom(stage) do
    transition.(state)
  rescue
    error -> report_failure(state, stage, :error, error, __STACKTRACE__)
  catch
    kind, reason -> report_failure(state, stage, kind, reason, __STACKTRACE__)
  end

  @spec report_failure(EditorState.t(), atom(), atom(), term(), list()) :: EditorState.t()
  defp report_failure(state, stage, kind, reason, stacktrace) do
    Minga.Log.warning(
      :editor,
      "Semantic navigation applied, but #{stage} finalization failed: #{Exception.format(kind, reason, stacktrace)}"
    )

    state
  end
end
