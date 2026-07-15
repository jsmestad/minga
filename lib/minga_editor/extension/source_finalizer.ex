defmodule MingaEditor.Extension.SourceFinalizer do
  @moduledoc """
  Finalizes Editor-owned work and presentation for one contribution source.

  Extension cleanup calls this workflow before the source is considered
  disabled. The generation-owned effect scheduler is drained synchronously
  first; only then may the live picker owned by that source be dismissed.
  """

  alias Minga.Extension.ContributionCleanup
  alias MingaEditor.EffectScheduler
  alias MingaEditor.PickerUI
  alias MingaEditor.State, as: EditorState

  @cleanup_family :editor_effects

  @type source :: ContributionCleanup.contribution_source()
  @type result :: :ok | {:error, term()}

  @doc "Registers the Editor finalizer with source-owned contribution cleanup."
  @spec ensure_cleanup_registered() :: :ok
  def ensure_cleanup_registered do
    # Register a module capture, not an Editor or scheduler closure. Re-registering
    # on every Editor generation is idempotent and guarantees a restarted Editor
    # repairs a callback that tests or lifecycle code may have removed.
    ContributionCleanup.register(@cleanup_family, &__MODULE__.unregister_source/1)
  end

  @doc "Finalizes a source against the production Editor, if it is running."
  @spec unregister_source(source()) :: result()
  def unregister_source(source), do: unregister_source(source, MingaEditor)

  @doc "Finalizes a source against an explicit Editor server."
  @spec unregister_source(source(), GenServer.server() | nil) :: result()
  def unregister_source(_source, nil), do: :ok

  def unregister_source(source, pid) when is_pid(pid) do
    if pid == self() do
      {:error, :editor_finalizer_called_from_editor}
    else
      call_editor(pid, source)
    end
  end

  def unregister_source(source, name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> call_editor(pid, source)
    end
  end

  @doc "Cancels source work before removing its live picker presentation."
  @spec finalize(EditorState.t(), source()) :: {result(), EditorState.t()}
  def finalize(%EditorState{} = state, source) do
    case EffectScheduler.cancel_source(state.effect_scheduler, source) do
      :ok -> {:ok, PickerUI.remove_source(state, source)}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  @spec call_editor(pid(), source()) :: result()
  defp call_editor(pid, source) do
    GenServer.call(pid, {:finalize_extension_source, source}, :infinity)
  catch
    :exit, reason -> {:error, {:editor_unavailable, reason}}
  end
end
