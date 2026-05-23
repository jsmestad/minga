defmodule MingaEditor.Extension.EditorAPI do
  @moduledoc """
  High-level editor actions for extensions.

  Extensions call these functions from command callbacks to trigger
  common editor operations without reaching into EditorState internals.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type state :: term()

  @spec open_file(state(), String.t()) :: state()
  def open_file(_state, _path), do: raise("minga_sdk is compile-time only")

  @spec focus_buffer(state(), pid()) :: state()
  def focus_buffer(_state, _buffer_pid), do: raise("minga_sdk is compile-time only")

  @spec navigate_to(state(), String.t(), non_neg_integer(), non_neg_integer()) :: state()
  def navigate_to(_state, _path, _line, _col \\ 0), do: raise("minga_sdk is compile-time only")

  @spec set_status(state(), String.t()) :: state()
  def set_status(_state, _message), do: raise("minga_sdk is compile-time only")
end
