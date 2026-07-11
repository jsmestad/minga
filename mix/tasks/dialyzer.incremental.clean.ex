defmodule Mix.Tasks.Dialyzer.Incremental.Clean do
  @shortdoc "Removes Minga's native incremental Dialyzer cache"

  @moduledoc """
  Removes the incremental Dialyzer cache for the active Mix environment.

  Refuse to remove an active cache lock by default. Pass `--force` only after an interrupted run leaves a stale lock behind.
  """

  use Mix.Task

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run([]), do: remove_cache(false)
  def run(["--force"]), do: remove_cache(true)

  def run(_args) do
    Mix.raise("mix dialyzer.incremental.clean accepts only --force")
  end

  defp remove_cache(force?) do
    cache = Mix.Tasks.Dialyzer.Incremental.cache_paths()
    remove_stale_lock!(force?, cache.lock)

    Mix.Tasks.Dialyzer.Incremental.with_lock(cache.lock, fn ->
      File.rm_rf!(cache.root)
      Mix.shell().info("Removed incremental Dialyzer cache: #{cache.root}")
      :ok
    end)
  end

  defp remove_stale_lock!(false, _lock_path), do: :ok

  defp remove_stale_lock!(true, lock_path) do
    case File.rm(lock_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.raise(
          "could not remove incremental Dialyzer cache lock #{lock_path}: #{:file.format_error(reason)}"
        )
    end
  end
end
