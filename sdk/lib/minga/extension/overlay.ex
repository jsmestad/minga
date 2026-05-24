defmodule Minga.Extension.Overlay do
  @moduledoc """
  Registry for extension-owned overlays on the editor surface.

  Extensions register overlays anchored to buffer positions. The editor
  reads this registry during rendering and displays the overlays on the
  appropriate frontend surface.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type shape :: :cursor | :cursor_with_label | :label | :indicator

  @type style :: %{
          optional(:fg) => non_neg_integer(),
          optional(:opacity) => 0..255
        }

  @type entry :: %{
          extension: atom(),
          overlay_id: term(),
          buffer: pid(),
          position: {non_neg_integer(), non_neg_integer()},
          content: String.t(),
          style: style(),
          shape: shape()
        }

  @spec set(atom(), term(), pid(), keyword()) :: :ok
  def set(_extension_name, _overlay_id, _buffer_pid, _opts),
    do: raise("minga_sdk is compile-time only")

  @spec remove(atom(), term()) :: :ok
  def remove(_extension_name, _overlay_id),
    do: raise("minga_sdk is compile-time only")

  @spec remove_all(atom()) :: :ok
  def remove_all(_extension_name),
    do: raise("minga_sdk is compile-time only")

  @spec for_buffer(pid()) :: [entry()]
  def for_buffer(_buffer_pid),
    do: raise("minga_sdk is compile-time only")

  @spec all() :: [entry()]
  def all, do: raise("minga_sdk is compile-time only")

  @spec empty?() :: boolean()
  def empty?, do: raise("minga_sdk is compile-time only")
end
