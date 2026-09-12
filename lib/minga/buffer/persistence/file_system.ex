defmodule Minga.Buffer.Persistence.FileSystem do
  @moduledoc "File-system boundary used by the atomic local-save workflow."

  @type device :: term()

  @callback lstat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  @callback read_link(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback stat(String.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, term()}
  @callback mkdir_p(String.t(), keyword()) :: :ok | {:error, term()}
  @callback open_exclusive(String.t(), keyword()) :: {:ok, device()} | {:error, term()}
  @callback write(device(), binary(), keyword()) :: :ok | {:error, term()}
  @callback preserve_metadata(String.t(), File.Stat.t() | nil, keyword()) ::
              :ok | {:error, term()}
  @callback flush(device(), keyword()) :: :ok | {:error, term()}
  @callback close(device(), keyword()) :: :ok | {:error, term()}
  @callback rename(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback link(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback remove(String.t(), keyword()) :: :ok | {:error, term()}
end
