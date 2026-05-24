defmodule MingaEditor.Extension.EditorAPI do
  @moduledoc """
  High-level editor actions for extensions.

  Extensions call these functions from command callbacks instead of
  reaching into `EditorState` internals. Each function accepts editor
  state and returns modified state, matching the extension command
  contract.

  ## Usage in an extension command

      command :my_open, "Open a specific file",
        execute: {MyExtension.Commands, :open_target}

      # In MyExtension.Commands:
      def open_target(state) do
        MingaEditor.Extension.EditorAPI.open_file(state, "/path/to/file.ex")
      end
  """

  alias MingaEditor.Handlers.BufferRegistry
  alias MingaEditor.State, as: EditorState
  alias MingaEditor.State.Windows
  alias Minga.Buffer

  @typedoc "Editor state (opaque to extensions)."
  @type state :: EditorState.t()

  @doc """
  Opens a file by path in the current window.

  If the file is already open in the active workspace, switches to its
  tab. Otherwise, creates a new buffer and tab for it. Sets a status
  message on failure (file not found, permission error).
  """
  @spec open_file(state(), String.t()) :: state()
  def open_file(state, path) when is_binary(path) do
    abs_path = Path.expand(path)
    BufferRegistry.open_file_by_path(state, abs_path)
  end

  @doc """
  Focuses the window showing a specific buffer.

  Finds the window whose buffer matches `buffer_pid` and switches
  focus to it. Returns state unchanged if no window shows that buffer.
  """
  @spec focus_buffer(state(), pid()) :: state()
  def focus_buffer(state, buffer_pid) when is_pid(buffer_pid) do
    case Windows.find_by_content(state.workspace.windows, &(&1.buffer == buffer_pid)) do
      {window_id, _window} -> EditorState.focus_window(state, window_id)
      nil -> state
    end
  end

  @doc """
  Opens a file and moves the cursor to a specific line and column.

  Combines `open_file/2` with cursor navigation. The cursor moves
  after the file is opened and its buffer is active.
  """
  @spec navigate_to(state(), String.t(), non_neg_integer(), non_neg_integer()) :: state()
  def navigate_to(state, path, line, col \\ 0) when is_binary(path) do
    abs_path = Path.expand(path)
    prev_active = state.workspace.buffers.active
    state = open_file(state, abs_path)

    case state.workspace.buffers.active do
      pid when is_pid(pid) ->
        if pid != prev_active or Buffer.file_path(pid) == abs_path do
          Buffer.move_to(pid, {line, col})
        end

        state

      _ ->
        state
    end
  end

  @doc """
  Sets a transient status bar message.

  The message clears on the next user action, matching the standard
  editor status message behavior.
  """
  @spec set_status(state(), String.t()) :: state()
  def set_status(state, message) when is_binary(message) do
    EditorState.set_status(state, message)
  end
end
