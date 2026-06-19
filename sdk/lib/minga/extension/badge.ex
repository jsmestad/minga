defmodule Minga.Extension.Badge do
  @moduledoc """
  Registry for extension-owned decorations on file tree entries and tabs.

  Decorate a file tree entry by path with a badge (colored dot, short text)
  and/or a semantic `level` (a 0..4 familiarity/heat bucket the frontend
  maps to a theme tint), or a tab by buffer PID.

  ## File decoration options

    * `:level` — semantic 0..4 bucket rendered as a row tint
    * `:color` — badge color (RGB integer)
    * `:text` — short badge text
    * `:animation` — `:static` (default) or `:pulse`

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type animation :: :static | :pulse
  @type level :: 0..4

  @spec set_file(atom(), String.t(), keyword()) :: :ok
  def set_file(_extension_name, _path, _opts \\ []), do: raise("minga_sdk is compile-time only")

  @spec remove_file(atom(), String.t()) :: :ok
  def remove_file(_extension_name, _path), do: raise("minga_sdk is compile-time only")

  @spec set_tab(atom(), pid(), keyword()) :: :ok
  def set_tab(_extension_name, _buffer_pid, _opts \\ []),
    do: raise("minga_sdk is compile-time only")

  @spec remove_tab(atom(), pid()) :: :ok
  def remove_tab(_extension_name, _buffer_pid), do: raise("minga_sdk is compile-time only")

  @spec remove_all(atom()) :: :ok
  def remove_all(_extension_name), do: raise("minga_sdk is compile-time only")
end
