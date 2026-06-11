defmodule Minga.LSP.PositionEncoding do
  @moduledoc """
  Converts between Minga's byte-indexed positions and LSP positions.

  LSP historically uses UTF-16 code unit offsets for character positions, a legacy of the JavaScript/TypeScript origins. Modern servers support UTF-8 offset encoding via capability negotiation in LSP 3.17+.

  The conversion implementation lives in `Minga.Core.PositionEncoding` so pure diagnostics and other Layer 0 modules can use the same rules without depending on LSP services.
  """

  alias Minga.Core.PositionEncoding, as: CorePositionEncoding

  @typedoc "The negotiated offset encoding for a server session."
  @type encoding :: CorePositionEncoding.encoding()

  @doc """
  Negotiates the best offset encoding from the server's supported list.

  Prefers UTF-8, then UTF-16, then UTF-32. Falls back to UTF-16 if the server does not advertise support.
  """
  @spec negotiate([String.t()]) :: encoding()
  defdelegate negotiate(server_encodings), to: CorePositionEncoding

  @doc "Returns the LSP encoding strings for capability advertisement."
  @spec client_supported_encodings() :: [String.t()]
  defdelegate client_supported_encodings, to: CorePositionEncoding

  @doc "Converts a Minga `{line, byte_col}` position to an LSP position map."
  @spec to_lsp({non_neg_integer(), non_neg_integer()}, String.t(), encoding()) :: map()
  defdelegate to_lsp(position, line_text, encoding), to: CorePositionEncoding

  @doc "Converts an LSP position map back to a Minga `{line, byte_col}` tuple."
  @spec from_lsp(map(), String.t(), encoding()) :: {non_neg_integer(), non_neg_integer()}
  defdelegate from_lsp(position, line_text, encoding), to: CorePositionEncoding
end
