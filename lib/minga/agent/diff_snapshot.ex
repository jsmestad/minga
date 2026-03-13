defmodule Minga.Agent.DiffSnapshot do
  @moduledoc """
  File-backed snapshots for large-file diff review.

  When a file exceeds the `:agent_diff_size_threshold` config, the before/after
  content is written to temp files instead of held in memory. The DiffReview
  reads lines lazily from these files. Temp files are cleaned up when the
  diff review is dismissed or the session ends.
  """

  alias Minga.Config.Options

  @typedoc "A diff snapshot, either memory-backed or file-backed."
  @type t ::
          {:memory, String.t()}
          | {:file, String.t()}

  @doc """
  Creates a snapshot from file content. If the content exceeds the threshold,
  writes it to a temp file. Otherwise, keeps it in memory.
  """
  @spec from_content(String.t()) :: t()
  def from_content(content) when is_binary(content) do
    threshold = read_threshold()

    if byte_size(content) > threshold do
      path = write_temp(content)
      {:file, path}
    else
      {:memory, content}
    end
  end

  @doc "Returns the lines from a snapshot."
  @spec lines(t()) :: [String.t()]
  def lines({:memory, content}), do: String.split(content, "\n")

  def lines({:file, path}) do
    path
    |> File.stream!()
    |> Enum.map(&String.trim_trailing(&1, "\n"))
  end

  @doc "Returns the raw content from a snapshot."
  @spec content(t()) :: String.t()
  def content({:memory, c}), do: c
  def content({:file, path}), do: File.read!(path)

  @doc "Cleans up temp files for file-backed snapshots."
  @spec cleanup(t()) :: :ok
  def cleanup({:file, path}) do
    File.rm(path)
    :ok
  end

  def cleanup({:memory, _}), do: :ok

  @spec write_temp(String.t()) :: String.t()
  defp write_temp(content) do
    dir = System.tmp_dir!()
    filename = "minga_diff_#{:erlang.unique_integer([:positive])}.tmp"
    path = Path.join(dir, filename)
    File.write!(path, content)
    path
  end

  @default_threshold 1_048_576

  @spec read_threshold() :: pos_integer()
  defp read_threshold do
    Options.get(:agent_diff_size_threshold)
  rescue
    ArgumentError -> @default_threshold
  catch
    :exit, _ -> @default_threshold
  end
end
