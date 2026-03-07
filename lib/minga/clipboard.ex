defmodule Minga.Clipboard do
  @moduledoc """
  Platform clipboard integration.

  Delegates to the configured clipboard backend. In production this is
  `Minga.Clipboard.System` (which shells out to `pbcopy`/`pbpaste`,
  `xclip`, etc.). In tests it can be swapped to a mock via:

      Application.put_env(:minga, :clipboard_module, Minga.Clipboard.Mock)

  See `Minga.Clipboard.Behaviour` for the callback contract.
  """

  @typedoc "Result of a clipboard read."
  @type read_result :: String.t() | nil

  @typedoc "Result of a clipboard write."
  @type write_result :: :ok | :unavailable | {:error, term()}

  @doc """
  Reads the current system clipboard contents.

  Returns `nil` if no clipboard tool is available or the read fails.
  """
  @spec read() :: read_result()
  def read, do: impl().read()

  @doc """
  Writes `text` to the system clipboard.

  Returns `:ok` on success, `:unavailable` if no clipboard tool is found,
  or `{:error, reason}` on failure.
  """
  @spec write(String.t()) :: write_result()
  def write(text) when is_binary(text), do: impl().write(text)

  @spec impl() :: module()
  defp impl do
    Application.get_env(:minga, :clipboard_module, Minga.Clipboard.System)
  end
end
