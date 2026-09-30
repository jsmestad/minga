defmodule Mix.Tasks.Compile.MingaBundledExtensions do
  @moduledoc false

  use Mix.Task.Compiler

  alias Minga.Mix.CompilerManifest

  @manifest_name "minga_bundled_extensions"
  @extensions ["git_porcelain", "knowledge_graph", "adversarial"]

  @impl true
  @spec run([String.t()]) :: {:ok, []} | {:noop, []}
  def run(args) do
    Mix.Project.ensure_structure()
    manifest = CompilerManifest.path(@manifest_name)

    if CompilerManifest.stale?(manifest, tracked_paths(), args) do
      Enum.each(@extensions, &copy_extension/1)
      CompilerManifest.record(manifest, tracked_paths())
      {:ok, []}
    else
      {:noop, []}
    end
  end

  @impl true
  @spec manifests() :: [String.t()]
  def manifests, do: [CompilerManifest.path(@manifest_name)]

  @impl true
  @spec clean() :: :ok
  def clean, do: CompilerManifest.remove(CompilerManifest.path(@manifest_name))

  # Both trees are fingerprinted: a file deleted from the source or lingering in the target forces a fresh copy.
  defp tracked_paths do
    Enum.flat_map(@extensions, fn name ->
      CompilerManifest.tree(source_dir(name)) ++ CompilerManifest.tree(target_dir(name))
    end)
  end

  defp source_dir(name), do: Path.join([File.cwd!(), "extensions", name, "lib"])

  defp target_dir(name),
    do: Path.join([Mix.Project.app_path(), "priv", "extensions", name, "lib"])

  defp copy_extension(name) do
    source = source_dir(name)
    target = target_dir(name)

    unless File.dir?(source) do
      Mix.raise("Bundled extension #{name} source is missing: #{source}")
    end

    File.rm_rf!(target)
    File.mkdir_p!(Path.dirname(target))
    File.cp_r!(source, target)
  end
end
