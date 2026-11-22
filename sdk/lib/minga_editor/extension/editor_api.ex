defmodule MingaEditor.Extension.EditorAPI do
  @moduledoc """
  High-level editor actions for extensions.

  Extensions call these functions from command callbacks to trigger
  common editor operations without reaching into EditorState internals.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type state :: term()

  @doc "Shows a short notice in the editor."
  @spec notice(state(), String.t()) :: state()
  def notice(_state, _message), do: raise("minga_sdk is compile-time only")

  @doc "Returns the current directory workspace, or `nil` when there is none."
  @spec project_root(state()) :: String.t() | nil
  def project_root(_state), do: raise("minga_sdk is compile-time only")

  @doc "Resolves Git for the selected project, or the active file when no project is open."
  @spec git_root(state()) :: {:ok, String.t()} | :not_git
  def git_root(_state), do: raise("minga_sdk is compile-time only")

  @spec open_file(state(), String.t()) :: state()
  def open_file(_state, _path), do: raise("minga_sdk is compile-time only")

  @spec focus_buffer(state(), pid()) :: state()
  def focus_buffer(_state, _buffer_pid), do: raise("minga_sdk is compile-time only")

  @spec navigate_to(state(), String.t(), non_neg_integer(), non_neg_integer()) :: state()
  def navigate_to(_state, _path, _line, _col \\ 0), do: raise("minga_sdk is compile-time only")

  @spec active_path(state()) :: String.t() | nil
  def active_path(_state), do: raise("minga_sdk is compile-time only")

  @doc "Returns the active buffer pid, or nil. Read its unsaved text with `Minga.Buffer.content/1`."
  @spec active_buffer(state()) :: pid() | nil
  def active_buffer(_state), do: raise("minga_sdk is compile-time only")
end
