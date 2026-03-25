defmodule Minga.Session.Swap.Recovery do
  @moduledoc """
  Scans the swap directory for orphaned swap files and determines
  which ones are recoverable.

  A swap file is recoverable when:
  - It parses correctly (valid MINGA_SWAP_V1 header)
  - The OS PID that wrote it is no longer alive (`kill -0` check)
  - The original file still exists on disk

  Swap files written by a still-running Minga instance are left alone.
  Corrupt swap files are cleaned up automatically.
  """

  alias Minga.Session.Swap

  @typedoc "A recoverable swap file entry."
  @type entry :: %{
          path: String.t(),
          swap_path: String.t(),
          swap_mtime: integer()
        }

  @typedoc "Options for scan and recovery operations."
  @type option :: {:swap_dir, String.t()} | {:pid_alive?, (integer() -> boolean())}

  @doc """
  Scans the swap directory and returns a list of recoverable entries.

  Each entry contains the original file path, the swap file path,
  and the swap file's mtime. The caller decides what to do with them
  (show a recovery prompt, auto-recover, etc.).

  ## Options

  - `:swap_dir` - override the default swap directory (for testing)
  - `:pid_alive?` - override the PID liveness check (for testing)
  """
  @spec scan([option()]) :: [entry()]
  def scan(opts \\ []) do
    dir = Swap.swap_dir(opts)
    pid_alive? = Keyword.get(opts, :pid_alive?, &Swap.pid_alive?/1)

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".swap"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(&check_recoverable(&1, pid_alive?))

      {:error, _} ->
        []
    end
  end

  @doc "Deletes a swap file (user declined recovery)."
  @spec discard(String.t()) :: :ok
  def discard(swap_path) when is_binary(swap_path) do
    File.rm(swap_path)
    :ok
  end

  @doc """
  Recovers content from a swap file.

  Returns `{:ok, file_path, content}` where content is the unsaved
  buffer text. The caller is responsible for opening a buffer with
  this content and marking it as dirty. The swap file is deleted
  after successful recovery.
  """
  @spec recover(String.t()) :: {:ok, String.t(), binary()} | {:error, term()}
  def recover(swap_path) when is_binary(swap_path) do
    case Swap.read(swap_path) do
      {:ok, meta, content} ->
        # Best-effort: if this fails the file is cleaned up on next scan.
        File.rm(swap_path)
        {:ok, meta.path, content}

      error ->
        error
    end
  end

  @spec check_recoverable(String.t(), (integer() -> boolean())) :: [entry()]
  defp check_recoverable(swap_path, pid_alive?) do
    case Swap.read(swap_path) do
      {:ok, meta, _content} ->
        classify_swap(meta, pid_alive?)

      {:error, _} ->
        # Corrupt swap file. Clean it up.
        File.rm(swap_path)
        []
    end
  end

  @spec classify_swap(Swap.metadata(), (integer() -> boolean())) :: [entry()]
  defp classify_swap(meta, pid_alive?) when is_function(pid_alive?, 1) do
    if pid_alive?.(meta.os_pid) do
      # Another running Minga instance owns this swap file. Leave it.
      []
    else
      classify_by_original_file(meta)
    end
  end

  @spec classify_by_original_file(Swap.metadata()) :: [entry()]
  defp classify_by_original_file(meta) do
    if File.exists?(meta.path) do
      [%{path: meta.path, swap_path: meta.swap_path, swap_mtime: meta.mtime}]
    else
      # Original file was deleted. Discard the swap file.
      File.rm(meta.swap_path)
      []
    end
  end
end
