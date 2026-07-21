defmodule MingaEditor.Handlers.SessionRestore do
  @moduledoc """
  Session persistence and swap file recovery: restoring open buffers from a previous session and recovering unsaved changes from swap files.

  Changes when: session persistence format or recovery logic changes.
  """

  alias Minga.Buffer
  alias Minga.Session

  alias MingaEditor.Commands
  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Session, as: EditorSessionState

  @typedoc "Editor state (same as `MingaEditor.state()`)."
  @type state :: EditorState.t()

  # ── Public functions ──────────────────────────────────────────────────

  @spec restore_session(state()) :: state()
  def restore_session(state) do
    case Session.load(EditorSessionState.session_opts(state.session)) do
      {:ok, session} -> apply_session_snapshot(state, session)
      {:error, _} -> state
    end
  end

  @doc "Applies already-loaded session metadata from the Editor process."
  @spec apply_session_snapshot(state(), Session.snapshot()) :: state()
  def apply_session_snapshot(state, session) do
    Minga.Log.info(:editor, "Restored from previous session")

    session.buffers
    |> Enum.reduce(state, &restore_session_buffer/2)
    |> restore_active_file(session.active_file)
  end

  @spec recover_swap_entries(state(), [Minga.Session.swap_entry()]) :: state()
  def recover_swap_entries(state, entries) do
    recovered =
      Enum.map(entries, fn entry -> {entry, Session.recover_swap_file(entry.swap_path)} end)

    apply_recovered_entries(state, recovered)
  end

  @doc "Applies already-read swap contents from the Editor process."
  @spec apply_recovered_entries(state(), [
          {Session.swap_entry(), {:ok, String.t(), String.t()} | {:error, term()}}
        ]) :: state()
  def apply_recovered_entries(state, entries) do
    Minga.Log.info(
      :editor,
      "Found #{length(entries)} file(s) with unsaved changes from a previous session"
    )

    Enum.reduce(entries, state, &apply_recovered_entry/2)
  end

  @spec maybe_check_swap_recovery(state()) :: :ok
  def maybe_check_swap_recovery(state) do
    if EditorSessionState.swap_enabled?(state.session) and state.frontend.backend != :headless do
      send(self(), :check_swap_recovery)
    end

    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec restore_session_buffer(Session.buffer_entry(), state()) :: state()
  defp restore_session_buffer(%{file: file} = entry, state) do
    if File.exists?(file) do
      case Commands.start_buffer(file, state.interaction.options_server,
             events_registry: state.extension_surfaces.events_registry
           ) do
        {:ok, pid} ->
          :ok = Buffer.move_to(pid, {entry.cursor_line, entry.cursor_col})
          BufferRegistry.register_buffer(state, pid, file)

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  @spec restore_active_file(state(), String.t() | nil) :: state()
  defp restore_active_file(state, nil), do: state

  defp restore_active_file(state, active_file) do
    case BufferRegistry.file_tab_for_path_in_active_workspace(state, active_file) do
      %{id: tab_id} ->
        MingaEditor.TabWorkflow.switch(state, tab_id)

      nil ->
        Minga.Log.warning(:editor, "Session active file no longer exists: #{active_file}")
        state
    end
  end

  @spec apply_recovered_entry(
          {Session.swap_entry(), {:ok, String.t(), String.t()} | {:error, term()}},
          state()
        ) :: state()
  defp apply_recovered_entry({_entry, {:ok, file_path, content}}, state) do
    Minga.Log.info(:editor, "Recovered: #{Path.basename(file_path)}")
    recover_buffer(state, file_path, content)
  end

  defp apply_recovered_entry({entry, {:error, reason}}, state) do
    Minga.Log.info(
      :editor,
      "Failed to recover #{Path.basename(entry.path)}: #{inspect(reason)}"
    )

    state
  end

  # Opens a file and replaces its content with recovered swap data.
  # The buffer is marked dirty since the recovered content hasn't been saved.
  @spec recover_buffer(state(), String.t(), String.t()) :: state()
  defp recover_buffer(state, file_path, content) do
    case Commands.start_buffer(file_path, state.interaction.options_server,
           events_registry: state.extension_surfaces.events_registry
         ) do
      {:ok, pid} ->
        # Replace buffer content with the recovered swap data.
        # This marks the buffer dirty (unsaved changes from the crash).
        case Buffer.replace_content(pid, content, :recovery) do
          :ok ->
            BufferRegistry.register_buffer(state, pid, file_path)

          {:error, :read_only} ->
            Minga.Log.info(
              :editor,
              "Cannot recover #{Path.basename(file_path)}: read-only"
            )

            state
        end

      {:error, reason} ->
        Minga.Log.info(
          :editor,
          "Could not open buffer for #{Path.basename(file_path)}: #{inspect(reason)}"
        )

        state
    end
  end
end
