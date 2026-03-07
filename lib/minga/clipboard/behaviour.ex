defmodule Minga.Clipboard.Behaviour do
  @moduledoc """
  Behaviour for clipboard backends.

  Implementations must provide `read/0` and `write/1` to integrate with
  a clipboard (system, in-memory, or otherwise).
  """

  @type read_result :: String.t() | nil
  @type write_result :: :ok | :unavailable | {:error, term()}

  @callback read() :: read_result()
  @callback write(String.t()) :: write_result()
end
