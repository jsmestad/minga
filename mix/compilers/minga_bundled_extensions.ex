defmodule Mix.Tasks.Compile.MingaBundledExtensions do
  @moduledoc false

  use Mix.Task.Compiler

  @impl true
  @spec run([String.t()]) :: {:ok, []}
  def run(_args) do
    Mix.Project.ensure_structure()
    copy_extension("git_porcelain")
    {:ok, []}
  end

  defp copy_extension(name) do
    source = Path.join([File.cwd!(), "extensions", name, "lib"])

    target = Path.join([Mix.Project.app_path(), "priv", "extensions", name, "lib"])

    if File.dir?(source) do
      File.rm_rf!(target)
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target)
    end
  end
end
