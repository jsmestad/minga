defmodule Minga.Buffer do
  @moduledoc """
  Public API for buffer operations.

  Extensions use this module to read buffer content, query cursor
  position, check file paths, and manage decorations.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  alias Minga.Buffer.Conflict

  @type t :: GenServer.server()
  @type position :: {line :: non_neg_integer(), col :: non_neg_integer()}

  @spec content(t()) :: String.t()
  def content(_server), do: raise("minga_sdk is compile-time only")

  @doc "Returns content and its mutation version from the same buffer state."
  @spec content_with_version(t()) :: {String.t(), non_neg_integer()}
  def content_with_version(_server), do: raise("minga_sdk is compile-time only")

  @doc "Replaces the content only at the observed version, returning the new version."
  @spec replace_content_if_version(t(), non_neg_integer(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, :read_only | :stale}
  def replace_content_if_version(_server, _expected_version, _new_content),
    do: raise("minga_sdk is compile-time only")

  @spec conflicts(t()) :: [term()]
  def conflicts(_server), do: raise("minga_sdk is compile-time only")

  @spec conflict_count(t()) :: non_neg_integer()
  def conflict_count(_server), do: raise("minga_sdk is compile-time only")

  @spec conflict_snapshot(t()) :: {String.t(), position(), [term()]}
  def conflict_snapshot(_server), do: raise("minga_sdk is compile-time only")

  @doc "Returns the cursor, inclusive conflict regions, and their shared buffer version."
  @spec conflict_view(t()) :: Conflict.view()
  def conflict_view(_server), do: raise("minga_sdk is compile-time only")

  @doc "Resolves one conflict at the observed version without saving."
  @spec resolve_conflict(t(), non_neg_integer(), Conflict.target(), Conflict.choice()) ::
          {:ok, Conflict.resolution()} | {:error, Conflict.rejection()}
  def resolve_conflict(_server, _expected_version, _target, _choice),
    do: raise("minga_sdk is compile-time only")

  @doc "Saves the file only when the buffer is still at the requested version."
  @spec save_if_version(t(), non_neg_integer()) :: :ok | {:error, term()}
  def save_if_version(_server, _expected_version), do: raise("minga_sdk is compile-time only")

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
