defmodule Minga.Git.Stub do
  @moduledoc """
  High-fidelity in-memory git backend for tests.

  Returns realistic structured data without spawning OS processes. Tests
  configure responses via `set_root/2`, `set_status/2`, etc. Unconfigured
  paths get safe defaults (`:not_git`, empty lists).

  State lives in a public ETS table so it works across processes (e.g.,
  Git.Tracker reads it from its own process). Different tests use different
  tmp_dir paths as keys, so async tests don't collide.

  ## Usage

      setup %{tmp_dir: dir} do
        Minga.Git.Stub.set_root(dir, dir)
        Minga.Git.Stub.set_status(dir, [
          %Minga.Git.StatusEntry{path: "file.txt", status: :modified, staged: false}
        ])
        on_exit(fn -> Minga.Git.Stub.clear(dir) end)
      end
  """

  @behaviour Minga.Git.Backend

  @table __MODULE__

  # ── Table lifecycle ────────────────────────────────────────────────────

  @doc "Creates the ETS table. Call once from test_helper.exs."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  # ── Configuration API (called from test setup) ────────────────────────

  @doc "Registers `path` as being inside a git repo rooted at `root`."
  @spec set_root(String.t(), String.t()) :: :ok
  def set_root(path, root) do
    :ets.insert(@table, {{:root, Path.expand(path)}, Path.expand(root)})
    :ok
  end

  @doc "Sets the status entries returned for `git_root`."
  @spec set_status(String.t(), [Minga.Git.status_entry()]) :: :ok
  def set_status(git_root, entries) when is_list(entries) do
    :ets.insert(@table, {{:status, Path.expand(git_root)}, entries})
    :ok
  end

  @doc "Sets the HEAD content for a file in a git root."
  @spec set_head(String.t(), String.t(), String.t()) :: :ok
  def set_head(git_root, relative_path, content) do
    :ets.insert(@table, {{:head, Path.expand(git_root), relative_path}, content})
    :ok
  end

  @doc "Sets the log entries returned for `git_root`."
  @spec set_log(String.t(), [Minga.Git.log_entry()]) :: :ok
  def set_log(git_root, entries) when is_list(entries) do
    :ets.insert(@table, {{:log, Path.expand(git_root)}, entries})
    :ok
  end

  @doc "Sets the diff output returned for `git_root`."
  @spec set_diff(String.t(), String.t()) :: :ok
  def set_diff(git_root, diff_text) when is_binary(diff_text) do
    :ets.insert(@table, {{:diff, Path.expand(git_root)}, diff_text})
    :ok
  end

  @doc "Sets the branch name returned for `git_root`."
  @spec set_branch(String.t(), String.t()) :: :ok
  def set_branch(git_root, branch) when is_binary(branch) do
    :ets.insert(@table, {{:branch, Path.expand(git_root)}, branch})
    :ok
  end

  @doc "Removes all stub entries for a given root path."
  @spec clear(String.t()) :: :ok
  def clear(git_root) do
    expanded = Path.expand(git_root)
    :ets.match_delete(@table, {{:root, expanded}, :_})
    :ets.match_delete(@table, {{:status, expanded}, :_})
    :ets.match_delete(@table, {{:head, expanded, :_}, :_})
    :ets.match_delete(@table, {{:log, expanded}, :_})
    :ets.match_delete(@table, {{:diff, expanded}, :_})
    :ets.match_delete(@table, {{:branch, expanded}, :_})
    :ok
  end

  # ── Backend callbacks ──────────────────────────────────────────────────

  @impl true
  @spec root_for(String.t()) :: {:ok, String.t()} | :not_git
  def root_for(path) do
    walk_ancestors({:root, Path.expand(path)})
  end

  @impl true
  @spec show_head(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_head(git_root, relative_path) do
    case :ets.lookup(@table, {:head, Path.expand(git_root), relative_path}) do
      [{_, content}] -> {:ok, content}
      [] -> :error
    end
  end

  @impl true
  @spec blame_line(String.t(), String.t(), non_neg_integer()) :: :error
  def blame_line(_git_root, _relative_path, _line_number), do: :error

  @impl true
  @spec status(String.t()) :: {:ok, [Minga.Git.status_entry()]}
  def status(git_root) do
    case :ets.lookup(@table, {:status, Path.expand(git_root)}) do
      [{_, entries}] -> {:ok, entries}
      [] -> {:ok, []}
    end
  end

  @impl true
  @spec diff(String.t(), keyword()) :: {:ok, String.t()}
  def diff(git_root, _opts \\ []) do
    case :ets.lookup(@table, {:diff, Path.expand(git_root)}) do
      [{_, text}] -> {:ok, text}
      [] -> {:ok, ""}
    end
  end

  @impl true
  @spec log(String.t(), keyword()) :: {:ok, [Minga.Git.log_entry()]}
  def log(git_root, _opts \\ []) do
    case :ets.lookup(@table, {:log, Path.expand(git_root)}) do
      [{_, entries}] -> {:ok, entries}
      [] -> {:ok, []}
    end
  end

  @impl true
  @spec stage(String.t(), String.t() | [String.t()]) :: :ok
  def stage(_git_root, _paths), do: :ok

  @impl true
  @spec commit(String.t(), String.t()) :: {:ok, String.t()}
  def commit(_git_root, _message), do: {:ok, "stub000"}

  @impl true
  @spec stage_patch(String.t(), String.t()) :: :ok
  def stage_patch(_git_root, _patch), do: :ok

  @impl true
  @spec current_branch(String.t()) :: {:ok, String.t()} | :error
  def current_branch(git_root) do
    case :ets.lookup(@table, {:branch, Path.expand(git_root)}) do
      [{_, branch}] -> {:ok, branch}
      [] -> {:ok, "main"}
    end
  end

  # ── Private ────────────────────────────────────────────────────────────

  # Walks up the directory tree looking for a registered root, just like
  # real git walks up looking for .git/.
  @spec walk_ancestors({:root, String.t()}) :: {:ok, String.t()} | :not_git
  defp walk_ancestors({:root, path}) do
    case :ets.lookup(@table, {:root, path}) do
      [{_, root}] -> {:ok, root}
      [] when path == "/" -> :not_git
      [] -> walk_ancestors({:root, Path.dirname(path)})
    end
  end
end
