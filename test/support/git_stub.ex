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

  @doc "Sets the staged index content for a file in a git root."
  @spec set_staged(String.t(), String.t(), String.t()) :: :ok
  def set_staged(git_root, relative_path, content) do
    :ets.insert(@table, {{:staged, Path.expand(git_root), relative_path}, content})
    :ok
  end

  @doc "Sets the ahead/behind counts returned for `git_root`."
  @spec set_ahead_behind(String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def set_ahead_behind(git_root, ahead, behind) do
    :ets.insert(@table, {{:ahead_behind, Path.expand(git_root)}, {ahead, behind}})
    :ok
  end

  @doc "Sets the last commit message returned for `git_root`."
  @spec set_last_commit_message(String.t(), String.t()) :: :ok
  def set_last_commit_message(git_root, message) when is_binary(message) do
    :ets.insert(@table, {{:last_commit_message, Path.expand(git_root)}, message})
    :ok
  end

  @doc "Sets the default log entries returned for `git_root`."
  @spec set_log(String.t(), [Minga.Git.log_entry()]) :: :ok
  def set_log(git_root, entries) when is_list(entries) do
    :ets.insert(@table, {{:log, Path.expand(git_root)}, entries})
    :ok
  end

  @doc "Sets the log entries returned for `git_root` and a specific options keyword list."
  @spec set_log(String.t(), keyword(), [Minga.Git.log_entry()]) :: :ok
  def set_log(git_root, opts, entries) when is_list(opts) and is_list(entries) do
    :ets.insert(@table, {{:log, Path.expand(git_root), normalize_opts(opts)}, entries})
    :ok
  end

  @doc "Sets the default diff output returned for `git_root`."
  @spec set_diff(String.t(), String.t()) :: :ok
  def set_diff(git_root, diff_text) when is_binary(diff_text) do
    :ets.insert(@table, {{:diff, Path.expand(git_root)}, diff_text})
    :ok
  end

  @doc "Sets the diff output returned for `git_root` and a specific options keyword list."
  @spec set_diff(String.t(), keyword(), String.t()) :: :ok
  def set_diff(git_root, opts, diff_text) when is_list(opts) and is_binary(diff_text) do
    :ets.insert(@table, {{:diff, Path.expand(git_root), normalize_opts(opts)}, diff_text})
    :ok
  end

  @doc "Sets the branch name returned for `git_root`."
  @spec set_branch(String.t(), String.t()) :: :ok
  def set_branch(git_root, branch) when is_binary(branch) do
    :ets.insert(@table, {{:branch, Path.expand(git_root)}, branch})
    :ok
  end

  @doc "Sets stash entries returned for `git_root`."
  @spec set_stashes(String.t(), [Minga.Git.stash_entry()]) :: :ok
  def set_stashes(git_root, entries) when is_list(entries) do
    git_root = Path.expand(git_root)
    stash_state = Enum.map(entries, &{&1, nil})
    :ets.insert(@table, {{:stash_state, git_root}, stash_state})
    :ets.insert(@table, {{:stashes, git_root}, entries})
    :ok
  end

  @doc "Returns paths staged through the stub for `git_root`."
  @spec staged_paths(String.t()) :: [String.t()]
  def staged_paths(git_root) do
    case :ets.lookup(@table, {:staged_paths, Path.expand(git_root)}) do
      [{_, paths}] -> Enum.reverse(paths)
      [] -> []
    end
  end

  @doc "Removes all stub entries for a given root path."
  @spec clear(String.t()) :: :ok
  def clear(git_root) do
    expanded = Path.expand(git_root)
    :ets.match_delete(@table, {{:root, expanded}, :_})
    :ets.match_delete(@table, {{:status, expanded}, :_})
    :ets.match_delete(@table, {{:head, expanded, :_}, :_})
    :ets.match_delete(@table, {{:staged, expanded, :_}, :_})
    :ets.match_delete(@table, {{:staged_paths, expanded}, :_})
    :ets.match_delete(@table, {{:log, expanded}, :_})
    :ets.match_delete(@table, {{:log, expanded, :_}, :_})
    :ets.match_delete(@table, {{:diff, expanded}, :_})
    :ets.match_delete(@table, {{:diff, expanded, :_}, :_})
    :ets.match_delete(@table, {{:branch, expanded}, :_})
    :ets.match_delete(@table, {{:branches, expanded}, :_})
    :ets.match_delete(@table, {{:branch_delete, expanded, :_, :_}, :_})
    :ets.match_delete(@table, {{:stashes, expanded}, :_})
    :ets.match_delete(@table, {{:stash_state, expanded}, :_})
    :ets.match_delete(@table, {{:ahead_behind, expanded}, :_})
    :ets.match_delete(@table, {{:last_commit_message, expanded}, :_})
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
  @spec show_staged(String.t(), String.t()) :: {:ok, String.t()} | :error
  def show_staged(git_root, relative_path) do
    case :ets.lookup(@table, {:staged, Path.expand(git_root), relative_path}) do
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
  @spec diff(String.t(), Minga.Git.diff_opts()) :: {:ok, String.t()}
  def diff(git_root, opts \\ []) do
    expanded = Path.expand(git_root)

    case :ets.lookup(@table, {:diff, expanded, normalize_opts(opts)}) do
      [{_, text}] ->
        {:ok, text}

      [] ->
        case :ets.lookup(@table, {:diff, expanded}) do
          [{_, text}] -> {:ok, text}
          [] -> {:ok, ""}
        end
    end
  end

  @impl true
  @spec log(String.t(), keyword()) :: {:ok, [Minga.Git.log_entry()]}
  def log(git_root, opts \\ []) do
    expanded = Path.expand(git_root)

    case :ets.lookup(@table, {:log, expanded, normalize_opts(opts)}) do
      [{_, entries}] ->
        {:ok, entries}

      [] ->
        case :ets.lookup(@table, {:log, expanded}) do
          [{_, entries}] -> {:ok, entries}
          [] -> {:ok, []}
        end
    end
  end

  @impl true
  @spec stage(String.t(), String.t() | [String.t()]) :: :ok
  def stage(git_root, paths) do
    expanded = Path.expand(git_root)
    new_paths = List.wrap(paths)

    existing =
      case :ets.lookup(@table, {:staged_paths, expanded}) do
        [{_, staged}] -> staged
        [] -> []
      end

    :ets.insert(@table, {{:staged_paths, expanded}, Enum.reverse(new_paths) ++ existing})
    :ok
  end

  @impl true
  @spec commit(String.t(), String.t(), keyword()) :: {:ok, String.t()}
  def commit(_git_root, _message, _opts \\ []), do: {:ok, "stub000"}

  @impl true
  @spec last_commit_message(String.t()) :: {:ok, String.t()}
  def last_commit_message(git_root) do
    case :ets.lookup(@table, {:last_commit_message, Path.expand(git_root)}) do
      [{_, message}] -> {:ok, message}
      [] -> {:ok, "stub commit message"}
    end
  end

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

  @impl true
  @spec ahead_behind(String.t()) :: {:ok, non_neg_integer(), non_neg_integer()} | :error
  def ahead_behind(git_root) do
    case :ets.lookup(@table, {:ahead_behind, Path.expand(git_root)}) do
      [{_, {ahead, behind}}] -> {:ok, ahead, behind}
      [] -> {:ok, 0, 0}
    end
  end

  @impl true
  @spec unstage(String.t(), String.t() | [String.t()]) :: :ok
  def unstage(_git_root, _paths), do: :ok

  @impl true
  @spec unstage_all(String.t()) :: :ok
  def unstage_all(_git_root), do: :ok

  @impl true
  @spec discard(String.t(), String.t()) :: :ok
  def discard(_git_root, _path), do: :ok

  @impl true
  @spec branch_list(String.t()) :: {:ok, [Minga.Git.BranchInfo.t()]}
  def branch_list(git_root) do
    case :ets.lookup(@table, {:branches, Path.expand(git_root)}) do
      [{_, branches}] -> {:ok, branches}
      [] -> {:ok, [%Minga.Git.BranchInfo{name: "main", current: true}]}
    end
  end

  @impl true
  @spec branch_create(String.t(), String.t()) :: :ok
  def branch_create(_git_root, _name), do: :ok

  @impl true
  @spec branch_switch(String.t(), String.t()) :: :ok
  def branch_switch(_git_root, _name), do: :ok

  @impl true
  @spec branch_delete(String.t(), String.t(), boolean()) :: :ok | {:error, String.t()}
  def branch_delete(git_root, name, force \\ false) do
    expanded = Path.expand(git_root)

    case :ets.lookup(@table, {:branch_delete, expanded, name, force}) do
      [{_, result}] ->
        result

      [] ->
        delete_branch_from_list(expanded, name)
        :ok
    end
  end

  @impl true
  @spec stash(String.t(), keyword()) :: :ok | {:error, String.t()}
  def stash(git_root, _opts \\ []) do
    git_root = Path.expand(git_root)

    case status(git_root) do
      {:ok, []} ->
        {:error, "No changes to stash"}

      {:ok, entries} ->
        stash_state = load_stash_state(git_root)
        branch = branch_name(git_root)
        entry = new_stash_entry(branch)

        put_stash_state(git_root, reindex_stash_state([{entry, entries} | stash_state]))
        set_status(git_root, [])
        :ok
    end
  end

  @impl true
  @spec stash_pop(String.t()) :: :ok | {:error, String.t()}
  def stash_pop(git_root) do
    git_root = Path.expand(git_root)

    case load_stash_state(git_root) do
      [] ->
        {:error, "No stash entries to pop"}

      [{_latest_entry, snapshot} | rest] ->
        maybe_restore_status(git_root, snapshot)
        put_stash_state(git_root, reindex_stash_state(rest))
        :ok
    end
  end

  @impl true
  @spec stash_list(String.t()) :: {:ok, [Minga.Git.stash_entry()]}
  def stash_list(git_root) do
    {:ok, Enum.map(load_stash_state(Path.expand(git_root)), fn {entry, _snapshot} -> entry end)}
  end

  @impl true
  @spec stash_drop(String.t(), non_neg_integer()) :: :ok | {:error, String.t()}
  def stash_drop(git_root, index) when is_integer(index) and index >= 0 do
    git_root = Path.expand(git_root)

    case Enum.split(load_stash_state(git_root), index) do
      {prefix, [{_dropped_entry, _snapshot} | suffix]} ->
        put_stash_state(git_root, reindex_stash_state(prefix ++ suffix))
        :ok

      _ ->
        {:error, "No stash entry at stash@{#{index}}"}
    end
  end

  @spec load_stash_state(String.t()) :: [
          {Minga.Git.stash_entry(), [Minga.Git.status_entry()] | nil}
        ]
  defp load_stash_state(git_root) do
    case :ets.lookup(@table, {:stash_state, git_root}) do
      [{_, entries}] -> entries
      [] -> load_legacy_stashes(git_root)
    end
  end

  @spec load_legacy_stashes(String.t()) :: [{Minga.Git.stash_entry(), nil}]
  defp load_legacy_stashes(git_root) do
    case :ets.lookup(@table, {:stashes, git_root}) do
      [{_, entries}] -> Enum.map(entries, &{&1, nil})
      [] -> []
    end
  end

  @spec put_stash_state(String.t(), [{Minga.Git.stash_entry(), [Minga.Git.status_entry()] | nil}]) ::
          true
  defp put_stash_state(git_root, entries) do
    :ets.insert(@table, {{:stash_state, git_root}, entries})

    :ets.insert(
      @table,
      {{:stashes, git_root}, Enum.map(entries, fn {entry, _snapshot} -> entry end)}
    )
  end

  @spec reindex_stash_state([{Minga.Git.stash_entry(), [Minga.Git.status_entry()] | nil}]) :: [
          {Minga.Git.stash_entry(), [Minga.Git.status_entry()] | nil}
        ]
  defp reindex_stash_state(entries) do
    entries
    |> Enum.with_index()
    |> Enum.map(fn {{entry, snapshot}, index} ->
      {%{entry | index: index, ref: "stash@{#{index}}"}, snapshot}
    end)
  end

  @spec maybe_restore_status(String.t(), [Minga.Git.status_entry()] | nil) :: :ok
  defp maybe_restore_status(_git_root, nil), do: :ok

  defp maybe_restore_status(git_root, snapshot) do
    set_status(git_root, snapshot)
  end

  @spec new_stash_entry(String.t()) :: Minga.Git.stash_entry()
  defp new_stash_entry(branch) do
    %Minga.Git.StashEntry{
      index: 0,
      ref: "stash@{0}",
      date: "now",
      message: "WIP on #{branch}"
    }
  end

  @spec branch_name(String.t()) :: String.t()
  defp branch_name(git_root) do
    case current_branch(git_root) do
      {:ok, branch} when is_binary(branch) -> branch
      _ -> "main"
    end
  end

  @impl true
  @spec push(String.t(), keyword()) :: :ok
  def push(_git_root, _opts \\ []), do: :ok

  @impl true
  @spec pull(String.t(), keyword()) :: :ok
  def pull(_git_root, _opts \\ []), do: :ok

  @impl true
  @spec fetch_remotes(String.t(), keyword()) :: :ok
  def fetch_remotes(_git_root, _opts \\ []), do: :ok

  # ── Additional Stub Configuration ─────────────────────────────────────

  @doc "Sets the branches returned for `git_root`."
  @spec set_branches(String.t(), [Minga.Git.BranchInfo.t()]) :: :ok
  def set_branches(git_root, branches) when is_list(branches) do
    :ets.insert(@table, {{:branches, Path.expand(git_root)}, branches})
    :ok
  end

  @doc "Sets the result returned by branch_delete/3 for a branch and force flag."
  @spec set_branch_delete_result(String.t(), String.t(), boolean(), :ok | {:error, String.t()}) ::
          :ok
  def set_branch_delete_result(git_root, name, force, result)
      when is_binary(name) and is_boolean(force) do
    :ets.insert(@table, {{:branch_delete, Path.expand(git_root), name, force}, result})
    :ok
  end

  # ── Private ────────────────────────────────────────────────────────────

  @spec delete_branch_from_list(String.t(), String.t()) :: :ok
  defp delete_branch_from_list(git_root, name) do
    case :ets.lookup(@table, {:branches, git_root}) do
      [{_, branches}] ->
        updated = Enum.reject(branches, fn branch -> branch.name == name end)
        :ets.insert(@table, {{:branches, git_root}, updated})
        :ok

      [] ->
        :ok
    end
  end

  @spec normalize_opts(keyword()) :: keyword()
  defp normalize_opts(opts) do
    Enum.sort_by(opts, fn {key, _value} -> key end)
  end

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
