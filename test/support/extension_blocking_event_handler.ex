defmodule MingaEditor.Test.ExtensionBlockingEventHandler do
  @moduledoc false

  @behaviour MingaEditor.Extension.EventHandler
  @behaviour MingaEditor.Extension.RepositoryJob.Handler

  alias MingaEditor.Extension.RepositoryJob

  alias MingaEditor.State, as: EditorState

  @impl true
  @spec handle_editor_event(EditorState.t(), MingaEditor.Extension.EventHandler.event()) ::
          MingaEditor.Extension.EventHandler.callback_result()
  def handle_editor_event(state, {:editor_action, :block, {test_pid, token}}) do
    send(test_pid, {:extension_callback_entered, token, self()})

    receive do
      {:release_extension_callback, ^token} -> {:handled, state}
    end
  end

  def handle_editor_event(state, {:editor_action, :theme, theme}),
    do: {:handled, EditorState.apply_theme(state, theme)}

  def handle_editor_event(state, {:editor_action, action, {:test_theme, theme}})
      when action in [:open_git_diff_for_path, :git_status_remote],
      do: {:handled, EditorState.apply_theme(state, theme)}

  def handle_editor_event(state, {:editor_action, :test_repository_job, {root, recipient}}) do
    {:ok, job} = RepositoryJob.propose(state, :remote, root, __MODULE__, recipient)
    {:schedule, state, job}
  end

  def handle_editor_event(_state, {:source_unload, _source}), do: exit(:unload_failed)
  def handle_editor_event(_state, _event), do: :not_matched

  @impl true
  @spec run(String.t(), binary()) :: {:ok, String.t()}
  def run(root, recipient) do
    send(:erlang.binary_to_term(recipient, [:safe]), {:repository_job_ran, root, self()})
    {:ok, root}
  end

  @impl true
  @spec on_result(EditorState.t(), String.t(), RepositoryJob.Handler.outcome(), binary()) ::
          EditorState.t()
  def on_result(state, root, outcome, recipient) do
    send(:erlang.binary_to_term(recipient, [:safe]), {:repository_job_delivered, root, outcome})
    state
  end
end
