defmodule Minga.Parser.BufferConfig do
  @moduledoc """
  Inert parser configuration resolved before a buffer is registered.

  Query text is data rather than callbacks so `Minga.Parser.Manager` can own parser setup, restart, and resynchronization without depending on editor code.
  """

  @enforce_keys [:language]
  defstruct [
    :language,
    :highlight_query,
    :injection_query,
    :fold_query,
    :textobject_query,
    :tags_query
  ]

  @type t :: %__MODULE__{
          language: String.t(),
          highlight_query: String.t() | nil,
          injection_query: String.t() | nil,
          fold_query: String.t() | nil,
          textobject_query: String.t() | nil,
          tags_query: String.t() | nil
        }
end
