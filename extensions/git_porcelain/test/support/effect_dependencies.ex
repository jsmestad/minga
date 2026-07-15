defmodule MingaGitPorcelain.Test.EffectDependencies do
  @moduledoc "Deterministic module dependencies for Git Porcelain effect tests."

  @table __MODULE__

  @type action ::
          {:return, term()}
          | {:raise, String.t()}
          | {:exit, term()}
          | {:block, term()}

  @doc "Resets dependency behavior and records calls for one test process."
  @spec reset(pid()) :: :ok
  def reset(owner) when is_pid(owner) do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ets.insert(@table, {:owner, owner})
    :ok
  end

  @doc "Configures one dependency action."
  @spec put(term(), action()) :: :ok
  def put(key, action) do
    :ets.insert(@table, {{:action, key}, action})
    :ok
  end

  @doc "Returns the configured project root."
  @spec resolve_root() :: String.t()
  def resolve_root, do: call(:project_root, nil, {:return, "/tmp/project"})

  @doc "Resolves the configured Git root."
  @spec root_for(String.t()) :: {:ok, String.t()} | :not_git | {:error, term()}
  def root_for(path), do: call(:git_root, path, {:return, {:ok, "/tmp/repo"}})

  @doc "Reads the configured staged diff."
  @spec diff(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(root, opts), do: call(:staged_diff, {root, opts}, {:return, {:ok, "diff --git"}})

  @doc "Invokes the configured synchronous generator behavior."
  @spec generate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(diff), do: call(:generator, diff, {:return, {:ok, "feat: generated"}})

  @doc "Runs a configured push."
  @spec push(String.t()) :: :ok | {:error, term()}
  def push(root), do: call({:remote, :push}, root, {:return, :ok})

  @doc "Runs a configured pull."
  @spec pull(String.t()) :: :ok | {:error, term()}
  def pull(root), do: call({:remote, :pull}, root, {:return, :ok})

  @doc "Runs a configured fetch."
  @spec fetch_remotes(String.t()) :: :ok | {:error, term()}
  def fetch_remotes(root), do: call({:remote, :fetch}, root, {:return, :ok})

  @doc "Records repository refresh requests."
  @spec refresh_git_repo(String.t()) :: :ok
  def refresh_git_repo(root), do: call(:refresh, root, {:return, :ok})

  @spec ensure_table() :: :ok
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @spec call(term(), term(), action()) :: term()
  defp call(key, payload, default) do
    owner = :ets.lookup_element(@table, :owner, 2)
    send(owner, {:dependency_called, key, self(), payload})

    action =
      case :ets.lookup(@table, {:action, key}) do
        [{_, configured}] -> configured
        [] -> default
      end

    perform(action, key)
  end

  @spec perform(action(), term()) :: term()
  defp perform({:return, result}, _key), do: result
  defp perform({:raise, message}, _key), do: raise(message)
  defp perform({:exit, reason}, _key), do: exit(reason)

  defp perform({:block, result}, key) do
    receive do
      {:release_dependency, ^key} -> result
    end
  end
end
