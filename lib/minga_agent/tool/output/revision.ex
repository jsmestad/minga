defmodule MingaAgent.Tool.Output.Revision do
  @moduledoc "Content-based source freshness. A requested range is never a whole-file mutation revision."

  alias MingaAgent.Tool.Output.Range
  alias MingaAgent.Tool.Output.Reference

  @type source_kind :: :disk | :buffer | :fork | :changeset | :project_view | :query_snapshot
  @type t :: %__MODULE__{
          source_kind: source_kind(),
          source_id: String.t(),
          scope: Range.t(),
          generation: non_neg_integer() | nil,
          sha256: String.t()
        }

  @enforce_keys [:source_kind, :source_id, :scope, :sha256]
  defstruct [:source_kind, :source_id, :scope, :sha256, :generation]

  @doc "Builds a revision from the captured content digest and an atomic source generation, when available."
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_revision}
  def new(attrs) when is_list(attrs) do
    build(
      Keyword.get(attrs, :source_kind),
      Keyword.get(attrs, :source_id),
      Keyword.get(attrs, :scope),
      Keyword.get(attrs, :generation),
      Keyword.get(attrs, :sha256)
    )
  end

  @doc "Returns an unambiguous token binding the identity, captured scope, generation, and bytes."
  @spec token(t()) :: String.t()
  def token(%__MODULE__{} = revision) do
    range = revision.scope

    JSON.encode!([
      1,
      Atom.to_string(revision.source_kind),
      revision.source_id,
      Atom.to_string(range.kind),
      Atom.to_string(range.unit),
      range.start,
      range.count,
      total(range.total),
      revision.generation,
      revision.sha256
    ])
    |> Reference.digest()
  end

  @doc "True only when this revision covers the full source rather than a requested range or query page."
  @spec full_source?(t()) :: boolean()
  def full_source?(%__MODULE__{source_kind: :query_snapshot}), do: false

  def full_source?(%__MODULE__{scope: %Range{kind: :full, start: 0, count: count, total: count}}),
    do: true

  def full_source?(%__MODULE__{}), do: false

  @spec total(Range.total()) :: non_neg_integer() | String.t()
  defp total(:unknown), do: "unknown"
  defp total(value), do: value

  @spec build(term(), term(), term(), term(), term()) :: {:ok, t()} | {:error, :invalid_revision}
  defp build(kind, id, %Range{} = scope, generation, sha256)
       when kind in [:disk, :buffer, :fork, :changeset, :project_view, :query_snapshot] and
              is_binary(id) and byte_size(id) > 0 and is_binary(sha256) and
              (is_nil(generation) or (is_integer(generation) and generation >= 0)) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256) do
      {:ok,
       %__MODULE__{
         source_kind: kind,
         source_id: id,
         scope: scope,
         generation: generation,
         sha256: sha256
       }}
    else
      {:error, :invalid_revision}
    end
  end

  defp build(_, _, _, _, _), do: {:error, :invalid_revision}
end
