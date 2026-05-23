defmodule Minga.Buffer do
  @moduledoc """
  Public API for buffer operations.

  Extensions use this module to read buffer content, query cursor
  position, check file paths, and manage decorations.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @type t :: GenServer.server()
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

  @spec content(t()) :: String.t()
  def content(_server), do: raise("minga_sdk is compile-time only")

  @spec cursor(t()) :: position()
  def cursor(_server), do: raise("minga_sdk is compile-time only")

  @spec move_to(t(), position()) :: :ok
  def move_to(_server, _pos), do: raise("minga_sdk is compile-time only")

  @spec file_path(t()) :: String.t() | nil
  def file_path(_server), do: raise("minga_sdk is compile-time only")

  @spec filetype(t()) :: atom()
  def filetype(_server), do: raise("minga_sdk is compile-time only")

  @spec line_count(t()) :: pos_integer()
  def line_count(_server), do: raise("minga_sdk is compile-time only")

  @spec dirty?(t()) :: boolean()
  def dirty?(_server), do: raise("minga_sdk is compile-time only")

  @spec read_only?(t()) :: boolean()
  def read_only?(_server), do: raise("minga_sdk is compile-time only")

  @spec lines(t(), non_neg_integer(), non_neg_integer()) :: [String.t()]
  def lines(_server, _start, _count), do: raise("minga_sdk is compile-time only")

  @spec decorations(t()) :: term()
  def decorations(_server), do: raise("minga_sdk is compile-time only")

  @spec batch_decorations(t(), (term() -> term())) :: :ok
  def batch_decorations(_server, _fun), do: raise("minga_sdk is compile-time only")

  @spec get_option(t(), atom()) :: term()
  def get_option(_server, _name), do: raise("minga_sdk is compile-time only")
end
