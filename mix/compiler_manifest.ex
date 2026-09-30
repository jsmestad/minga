defmodule Minga.Mix.CompilerManifest do
  @moduledoc """
  Content-hash staleness tracking for Minga's generator compilers.

  Each generator compiler owns one manifest file under `Mix.Project.manifest_path/0`. The manifest stores a fingerprint of every source and every output as they were right after the last successful run. The compiler runs its generator when the current fingerprint differs (a source changed, an output was hand-edited or deleted, a file was added or removed from a tracked directory) or when `--force` is passed. Hashes, not mtimes, so copied `_build` directories and branch switches can never hide a change.
  """

  @doc "Returns the manifest path for the named compiler."
  @spec path(String.t()) :: Path.t()
  def path(name), do: Path.join(Mix.Project.manifest_path(), "compile.#{name}")

  @doc "Returns true when the generator must run: forced, or the recorded fingerprint no longer matches the tracked files."
  @spec stale?(Path.t(), [Path.t()], [String.t()]) :: boolean()
  def stale?(manifest, tracked, args) do
    "--force" in args or File.read(manifest) != {:ok, fingerprint(tracked)}
  end

  @doc "Records the fingerprint of the tracked files after a successful generator run."
  @spec record(Path.t(), [Path.t()]) :: :ok
  def record(manifest, tracked) do
    File.mkdir_p!(Path.dirname(manifest))
    File.write!(manifest, fingerprint(tracked))
  end

  @doc "Forgets the last successful run so the next compile regenerates."
  @spec remove(Path.t()) :: :ok
  def remove(manifest) do
    File.rm(manifest)
    :ok
  end

  @doc "Expands a directory into itself plus every file and directory beneath it, so additions and removals change the fingerprint."
  @spec tree(Path.t()) :: [Path.t()]
  def tree(dir), do: [dir | Path.wildcard(Path.join(dir, "**"))]

  @spec fingerprint([Path.t()]) :: String.t()
  defp fingerprint(tracked) do
    entries = tracked |> Enum.sort() |> Enum.map(&entry/1)
    Base.encode16(:crypto.hash(:sha256, entries), case: :lower)
  end

  # Missing files and directories still contribute their path, so deleting or renaming one changes the fingerprint.
  @spec entry(Path.t()) :: iodata()
  defp entry(path) do
    case File.read(path) do
      {:ok, contents} -> [path, 0, :crypto.hash(:sha256, contents), 0]
      {:error, reason} -> [path, 0, Atom.to_string(reason), 0]
    end
  end
end
