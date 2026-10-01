defmodule Minga.Search.IndexGeneration do
  @moduledoc "Exact source-owned search-index generation shared across editor and renderer workflows."

  @enforce_keys [:token, :buffer, :query_revision, :version, :sequence]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          token: reference(),
          buffer: pid(),
          query_revision: non_neg_integer(),
          version: non_neg_integer(),
          sequence: non_neg_integer()
        }

  @doc "Creates the next exact generation stamp."
  @spec new(pid(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: t()
  def new(buffer, query_revision, version, sequence)
      when is_pid(buffer) and is_integer(query_revision) and query_revision >= 0 and
             is_integer(version) and version >= 0 and is_integer(sequence) and sequence >= 0 do
    %__MODULE__{
      token: make_ref(),
      buffer: buffer,
      query_revision: query_revision,
      version: version,
      sequence: sequence
    }
  end

  @doc "Returns the exact buffer revision represented by this generation."
  @spec buffer_revision(t()) :: {non_neg_integer(), non_neg_integer()}
  def buffer_revision(%__MODULE__{version: version, sequence: sequence}), do: {version, sequence}
end
