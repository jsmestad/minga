defmodule Minga.Extension.Storage do
  @moduledoc """
  Sanctioned per-extension persistent storage.

  Each extension gets a private data directory plus atomic read/write
  helpers for durable state.

  This is a compile-time stub. At runtime, the real module in Minga's
  BEAM VM provides the implementation.
  """

  @spec data_dir(atom()) :: String.t()
  def data_dir(_name), do: raise("minga_sdk is compile-time only")

  @spec read(atom(), Path.t()) :: {:ok, binary()} | {:error, File.posix() | :invalid_path}
  def read(_name, _rel), do: raise("minga_sdk is compile-time only")

  @spec write(atom(), Path.t(), iodata()) :: :ok | {:error, File.posix() | :invalid_path}
  def write(_name, _rel, _contents), do: raise("minga_sdk is compile-time only")
end
