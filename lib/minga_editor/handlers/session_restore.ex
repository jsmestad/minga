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

  @doc false
  @spec restore_session(state()) :: state()
  def restore_session(state) do
    case Session.load(EditorSessionState.session_opts(state.session)) do
      {:ok, session} ->
        state = MingaEditor.log_message(state, "Restored from previous session")
        Enum.reduce(session.buffers, state, &restore_session_buffer/2)

      {:error, _} ->
        state
    end
  end

  @doc false
  @spec recover_swap_entries(state(), [Minga.Session.swap_entry()]) :: state()
  def recover_swap_entries(state, entries) do
    count = length(entries)

    state =
      MingaEditor.log_message(
        state,
        "Found #{count} file(s) with unsaved changes from a previous session"
      )

    Enum.reduce(entries, state, &recover_swap_entry/2)
  end

  @doc false
  @spec maybe_check_swap_recovery(state()) :: :ok
  def maybe_check_swap_recovery(state) do
    if EditorSessionState.swap_enabled?(state.session) and state.backend != :headless do
      send(self(), :check_swap_recovery)
    end

    :ok
  end

  # ── Private helpers ──────────────────────────────────────────────────

  @spec restore_session_buffer(Session.buffer_entry(), state()) :: state()
  defp restore_session_buffer(%{file: file} = entry, state) do
    if File.exists?(file) do
      case Commands.start_buffer(file, EditorState.options_server(state)) do
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

  @spec recover_swap_entry(Minga.Session.swap_entry(), state()) :: state()
  defp recover_swap_entry(entry, state) do
    case Minga.Session.recover_swap_file(entry.swap_path) do
      {:ok, file_path, content} ->
        state = MingaEditor.log_message(state, "Recovered: #{Path.basename(file_path)}")
        recover_buffer(state, file_path, content)

      {:error, reason} ->
        MingaEditor.log_message(
          state,
          "Failed to recover #{Path.basename(entry.path)}: #{inspect(reason)}"
        )
    end
  end

  # Opens a file and replaces its content with recovered swap data.
  # The buffer is marked dirty since the recovered content hasn't been saved.
  @spec recover_buffer(state(), String.t(), String.t()) :: state()
  defp recover_buffer(state, file_path, content) do
    case Commands.start_buffer(file_path, EditorState.options_server(state)) do
      {:ok, pid} ->
        # Replace buffer content with the recovered swap data.
        # This marks the buffer dirty (unsaved changes from the crash).
        case Buffer.replace_content(pid, content, :recovery) do
          :ok ->
            BufferRegistry.register_buffer(state, pid, file_path)

          {:error, :read_only} ->
            MingaEditor.log_message(
              state,
              "Cannot recover #{Path.basename(file_path)}: read-only"
            )
        end

      {:error, reason} ->
        MingaEditor.log_message(
          state,
          "Could not open buffer for #{Path.basename(file_path)}: #{inspect(reason)}"
        )
    end
  end
end
