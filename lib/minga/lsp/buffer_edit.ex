defmodule Minga.LSP.BufferEdit do
  @moduledoc "Applies LSP text edits against the exact open-buffer snapshot the caller validated."

  alias Minga.Buffer
  alias Minga.LSP.PositionEncoding
  alias Minga.LSP.TextEdit

  @doc "Applies the edits and replaces the buffer only if its revision still matches the snapshot."
  @spec apply(
          pid(),
          {String.t(), non_neg_integer()},
          [map()],
          PositionEncoding.encoding(),
          :agent | :lsp
        ) ::
          {:ok, non_neg_integer()} | {:error, TextEdit.error() | :read_only | :stale}
  def apply(pid, {content, revision}, edits, encoding, source) do
    with {:ok, replacement} <- TextEdit.apply(content, edits, encoding) do
      Buffer.replace_content_if_version(pid, revision, replacement, source)
    end
  end
end
