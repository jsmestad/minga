defmodule MingaEditor.FeatureStateWorkflow do
  @moduledoc """
  Resolves shell registrations before atomic feature-state cleanup.

  Registry reads stay outside the pure root transition so active and stashed
  shell values receive one coherent, already-resolved entry set.
  """

  alias MingaEditor.FeatureState
  alias MingaEditor.Shell.Workflow, as: ShellWorkflow
  alias MingaEditor.State, as: EditorState

  @doc "Drops one feature-state source from all Editor-owned live and stashed values."
  @spec drop_source(EditorState.t(), FeatureState.source()) :: EditorState.t()
  def drop_source(%EditorState{} = state, source) do
    EditorState.drop_feature_state_source(state, ShellWorkflow.resolved_entries(), source)
  end

  @doc "Drops every extension-owned feature-state source from all Editor values."
  @spec drop_extension_sources(EditorState.t()) :: EditorState.t()
  def drop_extension_sources(%EditorState{} = state) do
    EditorState.drop_extension_feature_state_sources(state, ShellWorkflow.resolved_entries())
  end
end
