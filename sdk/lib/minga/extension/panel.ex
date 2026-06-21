defmodule Minga.Extension.Panel do
  @moduledoc """
  Registry for extension-owned panels in the editor.

  Extensions register panels with structured content blocks. Position is
  `:bottom`, `:right`, or `:float`; content is a list of blocks the
  frontend renders with native widgets.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type position :: :bottom | :right | :float
  @type size :: {:percent, 1..100} | {:lines, pos_integer()}
  @type content_block ::
          {:text, String.t()}
          | {:styled_text, [{String.t(), non_neg_integer(), keyword()}]}
          | {:table, map()}
          | {:key_value, [{String.t(), String.t()}]}
          | {:separator}
          | {:progress, map()}
          | {:tree, map()}

  @spec set(atom(), term(), map()) :: :ok
  def set(_extension_name, _panel_id, _opts), do: raise("minga_sdk is compile-time only")

  @spec remove(atom(), term()) :: :ok
  def remove(_extension_name, _panel_id), do: raise("minga_sdk is compile-time only")

  @spec remove_all(atom()) :: :ok
  def remove_all(_extension_name), do: raise("minga_sdk is compile-time only")

  @spec hide(atom(), term()) :: :ok
  def hide(_extension_name, _panel_id), do: raise("minga_sdk is compile-time only")

  @spec show(atom(), term()) :: :ok
  def show(_extension_name, _panel_id), do: raise("minga_sdk is compile-time only")
end
