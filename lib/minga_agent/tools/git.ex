defmodule MingaAgent.Tools.Git do
  @moduledoc """
  Structured git tools for the agent.

  Wraps `Minga.Git` functions to provide clean, parseable output instead of
  raw CLI text. Each function returns a formatted string suitable for tool
  results that the model can reason about easily.
  """

  alias Minga.Git
  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.Tools.OutputLimit
  alias MingaAgent.Tools.PathIgnore

  @type diff_entry :: %{path: String.t(), kind: atom()}
  @type diff_opts :: keyword()
  @type result :: {:ok, String.t()} | {:error, String.t()}

  @max_output_bytes OutputLimit.default_max_bytes()
  @max_input_bytes OutputLimit.default_max_bytes()

  @doc """
  Returns a structured list of changed files with their status.
  """
  @spec status(String.t()) :: result()
  def status(project_root) do
    git_root = resolve_git_root(project_root)

    case Git.status(git_root) do
      {:ok, []} ->
        {:ok, "Working tree clean. No changes."}

      {:ok, entries} ->
        staged = Enum.filter(entries, & &1.staged)
        unstaged = Enum.reject(entries, & &1.staged)

        parts =
          [
            if(staged != [],
              do: "Staged changes:\n" <> Enum.map_join(staged, "\n", &format_status_entry/1)
            ),
            if(unstaged != [],
              do: "Unstaged changes:\n" <> Enum.map_join(unstaged, "\n", &format_status_entry/1)
            )
          ]
          |> Enum.reject(&is_nil/1)

        {:ok, Enum.join(parts, "\n\n")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the diff for a specific file or all changes.
  """
  @spec diff(String.t(), diff_opts()) :: result()
  def diff(project_root, opts \\ []) do
    git_root = resolve_git_root(project_root)

    case Git.diff(git_root, opts) do
      {:ok, ""} -> {:ok, "No differences."}
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the effective diff for the routed agent context.
  """
  @spec diff(String.t(), diff_opts(), Context.t() | nil) :: result()
  def diff(project_root, opts, %Context{} = context) do
    if routed_overlay_diff?(context) do
      effective_diff(project_root, opts, context)
    else
      diff(project_root, opts)
    end
  end

  def diff(project_root, opts, _context), do: diff(project_root, opts)

  @doc """
  Returns recent commits as formatted entries.
  """
  @spec log(String.t(), keyword()) :: result()
  def log(project_root, opts \\ []) do
    git_root = resolve_git_root(project_root)

    case Git.log(git_root, opts) do
      {:ok, []} ->
        {:ok, "No commits found."}

      {:ok, entries} ->
        formatted =
          Enum.map_join(entries, "\n", fn e ->
            "#{e.short_hash} #{e.date} #{e.author}: #{e.message}"
          end)

        {:ok, formatted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stages specific files.
  """
  @spec stage(String.t(), [String.t()]) :: result()
  def stage(project_root, paths) when is_list(paths) do
    git_root = resolve_git_root(project_root)

    case Git.stage(git_root, paths) do
      :ok -> {:ok, "Staged #{Enum.count(paths)} file(s): #{Enum.join(paths, ", ")}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Creates a commit with the given message.

  NOTE: This does not verify git identity. When the agent commits code, it
  uses whatever git identity is currently configured. The git-identity skill
  is a human workflow tool and cannot be automated here.
  """
  @spec commit(String.t(), String.t()) :: result()
  def commit(project_root, message) do
    git_root = resolve_git_root(project_root)

    case Git.commit(git_root, message) do
      {:ok, short_hash} -> {:ok, "Committed #{short_hash}: #{message}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec format_status_entry(Git.status_entry()) :: String.t()
  defp format_status_entry(%{path: path, status: status}) do
    label =
      case status do
        :added -> "A"
        :modified -> "M"
        :deleted -> "D"
        :renamed -> "R"
        :copied -> "C"
        :untracked -> "?"
        :unknown -> "!"
      end

    "  #{label} #{path}"
  end

  @spec effective_diff(String.t(), diff_opts(), Context.t()) :: result()
  defp effective_diff(project_root, opts, %Context{} = context) do
    if Keyword.get(opts, :staged, false) do
      staged_overlay_error()
    else
      effective_unstaged_diff(project_root, opts, context)
    end
  end

  @spec staged_overlay_error() :: {:error, String.t()}
  defp staged_overlay_error do
    {:error,
     "git_diff staged=true is unavailable in routed overlay contexts; apply/export the overlay first"}
  end

  @spec effective_unstaged_diff(String.t(), diff_opts(), Context.t()) :: result()
  defp effective_unstaged_diff(project_root, opts, %Context{} = context) do
    max_input_bytes = Keyword.get(opts, :max_input_bytes, @max_input_bytes)

    with {:ok, path_filter} <- path_filter(project_root, Keyword.get(opts, :path)),
         {:ok, entries, new_root} <-
           routed_entries_and_root(project_root, context, max_input_bytes),
         {:ok, entries} <- filter_entries(project_root, entries, path_filter),
         {:ok, output} <- render_effective_diff(project_root, new_root, entries, opts) do
      if output == "", do: {:ok, "No differences."}, else: {:ok, output}
    end
  end

  @spec routed_overlay_diff?(Context.t()) :: boolean()
  defp routed_overlay_diff?(%Context{project_view: %ProjectView{} = view}) do
    caps = ProjectView.capabilities(view)
    caps.isolation != :none or caps.mutates_project_root == false
  catch
    :exit, _ -> true
  end

  defp routed_overlay_diff?(%Context{fork_store: fs, changeset: cs}) do
    fs != nil or cs != nil
  end

  @spec routed_entries_and_root(String.t(), Context.t(), pos_integer()) ::
          {:ok, [diff_entry()], String.t() | {:forks, %{String.t() => binary()}}}
          | {:error, String.t()}
  defp routed_entries_and_root(
         _project_root,
         %Context{project_view: %ProjectView{} = view},
         max_input_bytes
       ) do
    with {:ok, entries} <- project_view_diff_entries(view),
         :ok <- validate_project_view_fork_inputs(view, max_input_bytes),
         {:ok, working_dir} <- project_view_working_dir(view) do
      {:ok, entries, working_dir}
    end
  end

  defp routed_entries_and_root(project_root, %Context{changeset: cs} = context, max_input_bytes)
       when cs != nil and is_pid(cs) do
    with {:ok, working_dir} <- changeset_working_dir(context, max_input_bytes),
         {:ok, entries} <- changeset_entries(cs),
         {:ok, fork_entries} <- fork_entries(project_root, context.fork_store) do
      {:ok, merge_entries(entries, fork_entries), working_dir}
    end
  end

  defp routed_entries_and_root(project_root, %Context{fork_store: fs}, max_input_bytes)
       when fs != nil do
    with :ok <- validate_fork_inputs(project_root, fs, max_input_bytes),
         {:ok, entries} <- fork_entries(project_root, fs),
         {:ok, forks} <- fork_content_by_relative_path(project_root, fs) do
      {:ok, entries, {:forks, forks}}
    end
  end

  defp routed_entries_and_root(_project_root, %Context{}, _max_input_bytes),
    do: {:error, "no routed overlay is active"}

  @spec project_view_diff_entries(ProjectView.t()) :: {:ok, [diff_entry()]} | {:error, String.t()}
  defp project_view_diff_entries(%ProjectView{} = view) do
    case ProjectView.diff(view) do
      {:ok, entries} -> normalize_entries(entries)
      {:error, reason} -> {:error, "project_view_unavailable: diff failed: #{inspect(reason)}"}
    end
  catch
    :exit, reason -> {:error, "project_view_unavailable: diff failed: #{inspect(reason)}"}
  end

  @spec project_view_working_dir(ProjectView.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp project_view_working_dir(%ProjectView{} = view) do
    case ProjectView.prepare_working_dir(view) do
      {:ok, working_dir} ->
        {:ok, working_dir}

      {:error, reason} ->
        {:error, "project view working directory unavailable: #{inspect(reason)}"}
    end
  catch
    :exit, reason -> {:error, "project view working directory unavailable: #{inspect(reason)}"}
  end

  @spec changeset_working_dir(Context.t(), pos_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp changeset_working_dir(%Context{changeset: cs} = context, max_input_bytes) do
    with :ok <- materialize_forks_for_changeset(context, max_input_bytes),
         {:ok, working_dir} <- Changeset.prepare_working_dir(cs) do
      {:ok, working_dir}
    else
      {:error, reason} -> {:error, "changeset working directory unavailable: #{inspect(reason)}"}
    end
  catch
    :exit, reason -> {:error, "changeset working directory unavailable: #{inspect(reason)}"}
  end

  @spec materialize_forks_for_changeset(Context.t(), pos_integer()) :: :ok | {:error, term()}
  defp materialize_forks_for_changeset(%Context{fork_store: nil}, _max_input_bytes), do: :ok

  defp materialize_forks_for_changeset(%Context{fork_store: fs, changeset: cs}, max_input_bytes) do
    case fork_map(fs) do
      {:ok, forks} ->
        materialize_fork_entries(forks, Changeset.project_root(cs), cs, max_input_bytes)

      {:error, _reason} = error ->
        error
    end
  end

  @spec materialize_fork_entries(%{String.t() => pid()}, String.t(), pid(), pos_integer()) ::
          :ok | {:error, term()}
  defp materialize_fork_entries(forks, project_root, changeset, max_input_bytes) do
    Enum.reduce_while(forks, :ok, fn {path, fork_pid}, :ok ->
      relative_path = Path.relative_to(path, project_root)
      content = Minga.Buffer.Fork.content(fork_pid)

      case validate_input_size(relative_path, content, max_input_bytes) do
        {:ok, content} -> materialize_fork_entry(changeset, relative_path, content)
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec materialize_fork_entry(pid(), String.t(), binary()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp materialize_fork_entry(changeset, relative_path, content) do
    case Changeset.materialize_command_file(changeset, relative_path, content) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec changeset_entries(pid()) :: {:ok, [diff_entry()]} | {:error, String.t()}
  defp changeset_entries(changeset) do
    changeset
    |> Changeset.summary()
    |> normalize_entries()
  catch
    :exit, reason -> {:error, "changeset diff unavailable: #{inspect(reason)}"}
  end

  @spec fork_entries(String.t(), pid() | nil) :: {:ok, [diff_entry()]} | {:error, String.t()}
  defp fork_entries(_project_root, nil), do: {:ok, []}

  defp fork_entries(project_root, fork_store) do
    with {:ok, forks} <- fork_map(fork_store) do
      forks
      |> Map.keys()
      |> Enum.map(fn path ->
        %{path: Path.relative_to(path, project_root), kind: fork_kind(path)}
      end)
      |> normalize_entries()
    end
  end

  @spec fork_map(pid()) :: {:ok, %{String.t() => pid()}} | {:error, String.t()}
  defp fork_map(fork_store) do
    {:ok, BufferForkStore.all(fork_store)}
  catch
    :exit, reason -> {:error, "fork diff unavailable: #{inspect(reason)}"}
  end

  @spec validate_project_view_fork_inputs(ProjectView.t(), pos_integer()) ::
          :ok | {:error, String.t()}
  defp validate_project_view_fork_inputs(
         %ProjectView{project_root: project_root, ref: %{fork_store: fork_store}},
         max_input_bytes
       )
       when is_pid(fork_store) do
    validate_fork_inputs(project_root, fork_store, max_input_bytes)
  end

  defp validate_project_view_fork_inputs(%ProjectView{}, _max_input_bytes), do: :ok

  @spec validate_fork_inputs(String.t(), pid(), pos_integer()) :: :ok | {:error, String.t()}
  defp validate_fork_inputs(project_root, fork_store, max_input_bytes) do
    case fork_map(fork_store) do
      {:ok, forks} -> validate_fork_entry_inputs(forks, project_root, max_input_bytes)
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, "fork diff unavailable: #{inspect(reason)}"}
  end

  @spec validate_fork_entry_inputs(%{String.t() => pid()}, String.t(), pos_integer()) ::
          :ok | {:error, String.t()}
  defp validate_fork_entry_inputs(forks, project_root, max_input_bytes) do
    Enum.reduce_while(forks, :ok, fn {path, fork_pid}, :ok ->
      relative_path = Path.relative_to(path, project_root)
      content = Minga.Buffer.Fork.content(fork_pid)

      case validate_input_size(relative_path, content, max_input_bytes) do
        {:ok, _content} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec fork_content_by_relative_path(String.t(), pid()) ::
          {:ok, %{String.t() => binary()}} | {:error, String.t()}
  defp fork_content_by_relative_path(project_root, fork_store) do
    with {:ok, forks} <- fork_map(fork_store) do
      {:ok,
       Map.new(forks, fn {path, fork_pid} ->
         {Path.relative_to(path, project_root), Minga.Buffer.Fork.content(fork_pid)}
       end)}
    end
  catch
    :exit, reason -> {:error, "fork diff unavailable: #{inspect(reason)}"}
  end

  @spec fork_kind(String.t()) :: :modified | :new
  defp fork_kind(path) do
    if File.exists?(path), do: :modified, else: :new
  end

  @spec merge_entries([diff_entry()], [diff_entry()]) :: [diff_entry()]
  defp merge_entries(entries, fork_entries) do
    entries
    |> Enum.concat(fork_entries)
    |> Map.new(fn entry -> {entry.path, entry} end)
    |> Map.values()
    |> Enum.sort_by(& &1.path)
  end

  @spec normalize_entries([map()]) :: {:ok, [diff_entry()]} | {:error, String.t()}
  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1.path)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec normalize_entry(map()) :: {:ok, diff_entry()} | {:error, String.t()}
  defp normalize_entry(%{path: path} = entry) when is_binary(path) do
    with {:ok, path} <- safe_relative_path(path) do
      {:ok, %{path: path, kind: Map.get(entry, :kind, :modified)}}
    end
  end

  defp normalize_entry(entry), do: {:error, "invalid diff entry: #{inspect(entry)}"}

  @spec path_filter(String.t(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, String.t()}
  defp path_filter(_project_root, nil), do: {:ok, nil}

  defp path_filter(project_root, path) when is_binary(path) do
    project_root = Path.expand(project_root)
    target = Path.expand(path, project_root)

    if target == project_root or String.starts_with?(target, project_root <> "/") do
      {:ok, Path.relative_to(target, project_root) |> empty_to_nil()}
    else
      {:error, "path is outside the project root"}
    end
  end

  defp path_filter(_project_root, _path), do: {:error, "path must be a string"}

  @spec filter_entries(String.t(), [diff_entry()], String.t() | nil) ::
          {:ok, [diff_entry()]} | {:error, String.t()}
  defp filter_entries(project_root, entries, path_filter) do
    allowed_paths =
      project_root |> PathIgnore.filter_paths(Enum.map(entries, & &1.path)) |> MapSet.new()

    {:ok,
     Enum.filter(entries, fn entry ->
       MapSet.member?(allowed_paths, entry.path) and path_matches_filter?(entry.path, path_filter)
     end)}
  end

  @spec path_matches_filter?(String.t(), String.t() | nil) :: boolean()
  defp path_matches_filter?(_path, nil), do: true

  defp path_matches_filter?(path, path_filter) do
    path == path_filter or String.starts_with?(path, path_filter <> "/")
  end

  @spec render_effective_diff(
          String.t(),
          String.t() | {:forks, %{String.t() => binary()}},
          [diff_entry()],
          diff_opts()
        ) ::
          {:ok, String.t()} | {:error, String.t()}
  defp render_effective_diff(project_root, new_root, entries, opts) do
    tmp = Path.join(System.tmp_dir!(), "minga-agent-diff-#{unique_id()}")

    try do
      old_dir = Path.join(tmp, "old")
      new_dir = Path.join(tmp, "new")
      File.mkdir_p!(old_dir)
      File.mkdir_p!(new_dir)

      max_input_bytes = Keyword.get(opts, :max_input_bytes, @max_input_bytes)

      with :ok <-
             materialize_diff_side(
               project_root,
               new_root,
               old_dir,
               new_dir,
               entries,
               max_input_bytes
             ),
           {:ok, output} <- run_no_index_diff(tmp, opts) do
        {:ok, normalize_diff_paths(output)}
      end
    after
      File.rm_rf(tmp)
    end
  rescue
    error -> {:error, "effective git diff failed: #{Exception.message(error)}"}
  end

  @spec materialize_diff_side(
          String.t(),
          String.t() | {:forks, %{String.t() => binary()}},
          String.t(),
          String.t(),
          [diff_entry()],
          pos_integer()
        ) ::
          :ok | {:error, String.t()}
  defp materialize_diff_side(project_root, new_root, old_dir, new_dir, entries, max_input_bytes) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case materialize_diff_entry(
             project_root,
             new_root,
             old_dir,
             new_dir,
             entry,
             max_input_bytes
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec materialize_diff_entry(
          String.t(),
          String.t() | {:forks, %{String.t() => binary()}},
          String.t(),
          String.t(),
          diff_entry(),
          pos_integer()
        ) ::
          :ok | {:error, String.t()}
  defp materialize_diff_entry(
         project_root,
         new_root,
         old_dir,
         new_dir,
         %{path: relative_path, kind: kind},
         max_input_bytes
       ) do
    old_content = safe_read_diff_file(project_root, relative_path, max_input_bytes)
    new_content = routed_content(new_root, relative_path, kind, max_input_bytes)

    case maybe_write_diff_file(old_dir, relative_path, old_content) do
      :ok -> maybe_write_diff_file(new_dir, relative_path, new_content)
      {:error, _reason} = error -> error
    end
  end

  @spec routed_content(
          String.t() | {:forks, %{String.t() => binary()}},
          String.t(),
          atom(),
          pos_integer()
        ) ::
          {:ok, binary()} | {:error, term()}
  defp routed_content(_new_root, _relative_path, :deleted, _max_input_bytes),
    do: {:error, :enoent}

  defp routed_content({:forks, forks}, relative_path, _kind, max_input_bytes) do
    case Map.fetch(forks, relative_path) do
      {:ok, content} -> validate_input_size(relative_path, content, max_input_bytes)
      :error -> {:error, :enoent}
    end
  end

  defp routed_content(new_root, relative_path, _kind, max_input_bytes),
    do: safe_read_diff_file(new_root, relative_path, max_input_bytes)

  @spec safe_read_diff_file(String.t(), String.t(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp safe_read_diff_file(root, relative_path, max_input_bytes) do
    path = Path.join(root, relative_path)

    with :ok <- reject_symlink_path(root, relative_path),
         {:ok, stat} <- File.stat(path),
         :ok <- validate_input_size(relative_path, stat.size, max_input_bytes) do
      File.read(path)
    end
  end

  @spec reject_symlink_path(String.t(), String.t()) :: :ok | {:error, String.t() | atom()}
  defp reject_symlink_path(root, relative_path) do
    relative_path
    |> Path.split()
    |> Enum.reduce_while(:ok, fn component, current ->
      current = if current == :ok, do: component, else: Path.join(current, component)

      case File.lstat(Path.join(root, current)) do
        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, "refusing to diff symlink path #{relative_path}"}}

        {:ok, _stat} ->
          {:cont, current}

        {:error, :enoent} ->
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      path when is_binary(path) -> :ok
      result -> result
    end
  end

  @spec validate_input_size(String.t(), binary() | non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | :ok | {:error, String.t()}
  defp validate_input_size(relative_path, content, max_input_bytes) when is_binary(content) do
    with :ok <- validate_input_size(relative_path, byte_size(content), max_input_bytes) do
      {:ok, content}
    end
  end

  defp validate_input_size(relative_path, size, max_input_bytes) when is_integer(size) do
    if size <= max_input_bytes do
      :ok
    else
      {:error, "git_diff input file too large: #{relative_path} exceeds #{max_input_bytes} bytes"}
    end
  end

  @spec maybe_write_diff_file(String.t(), String.t(), {:ok, binary()} | {:error, term()}) ::
          :ok | {:error, String.t()}
  defp maybe_write_diff_file(_root, _relative_path, {:error, :enoent}), do: :ok

  defp maybe_write_diff_file(root, relative_path, {:ok, content}) do
    target = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(target))
    File.write(target, content)
  end

  defp maybe_write_diff_file(_root, relative_path, {:error, reason}) do
    {:error, "failed to read #{relative_path}: #{inspect(reason)}"}
  end

  @spec run_no_index_diff(String.t(), diff_opts()) :: {:ok, String.t()} | {:error, String.t()}
  defp run_no_index_diff(tmp, opts) do
    with {:ok, git} <- git_executable() do
      max_bytes = Keyword.get(opts, :max_output_bytes, @max_output_bytes)

      case OutputLimit.collect_command(git, ["diff", "--no-index", "--", "old", "new"],
             cd: tmp,
             stderr_to_stdout: true,
             max_bytes: max_bytes,
             timeout_ms: Keyword.get(opts, :timeout_ms, OutputLimit.default_timeout_ms())
           ) do
        {output, 0, truncated?} ->
          {:ok, maybe_mark_truncated(output, truncated?, max_bytes)}

        {output, 1, truncated?} ->
          {:ok, maybe_mark_truncated(output, truncated?, max_bytes)}

        {_output, :timeout, _truncated?} ->
          {:error, "git diff --no-index timed out"}

        {output, _code, _truncated?} ->
          {:error, "git diff --no-index failed: #{String.trim(output)}"}
      end
    end
  rescue
    error -> {:error, "git diff --no-index failed: #{Exception.message(error)}"}
  end

  @spec git_executable() :: {:ok, String.t()} | {:error, String.t()}
  defp git_executable do
    case System.find_executable("git") do
      nil -> {:error, "git executable not found"}
      git -> {:ok, git}
    end
  end

  @spec maybe_mark_truncated(String.t(), boolean(), pos_integer()) :: String.t()
  defp maybe_mark_truncated(output, false, _max_bytes), do: output

  defp maybe_mark_truncated(output, true, max_bytes) do
    output <> "\n\n[truncated at #{div(max_bytes, 1000)}KB]"
  end

  @spec normalize_diff_paths(String.t()) :: String.t()
  defp normalize_diff_paths(output) do
    output
    |> String.split("\n", trim: false)
    |> Enum.map_reduce(:body, &normalize_diff_line/2)
    |> elem(0)
    |> Enum.join("\n")
  end

  @spec normalize_diff_line(String.t(), :body | :metadata | :expect_new_header) ::
          {String.t(), :body | :metadata | :expect_new_header}
  defp normalize_diff_line("diff --git " <> rest, _state) do
    {"diff --git " <> normalize_diff_header_paths(rest), :metadata}
  end

  defp normalize_diff_line("--- " <> rest, :metadata) do
    {"--- " <> normalize_diff_file_path(rest, "a"), :expect_new_header}
  end

  defp normalize_diff_line("+++ " <> rest, :expect_new_header) do
    {"+++ " <> normalize_diff_file_path(rest, "b"), :body}
  end

  defp normalize_diff_line("@@" <> _rest = line, _state), do: {line, :body}
  defp normalize_diff_line(line, state), do: {line, state}

  @spec normalize_diff_header_paths(String.t()) :: String.t()
  defp normalize_diff_header_paths("a/old/" <> paths) do
    case normalize_diff_header_pair(paths, " b/new/") do
      {:ok, line} -> line
      :error -> normalize_old_only_diff_header(paths)
    end
  end

  defp normalize_diff_header_paths("a/new/" <> paths) do
    case normalize_diff_header_pair(paths, " b/new/") do
      {:ok, line} -> line
      :error -> "a/new/" <> paths
    end
  end

  defp normalize_diff_header_paths(line), do: line

  @spec normalize_old_only_diff_header(String.t()) :: String.t()
  defp normalize_old_only_diff_header(paths) do
    case normalize_diff_header_pair(paths, " b/old/") do
      {:ok, line} -> line
      :error -> "a/old/" <> paths
    end
  end

  @spec normalize_diff_header_pair(String.t(), String.t()) :: {:ok, String.t()} | :error
  defp normalize_diff_header_pair(paths, separator) do
    case :binary.split(paths, separator) do
      [old_path, new_path] -> {:ok, "a/" <> old_path <> " b/" <> new_path}
      _ -> :error
    end
  end

  @spec normalize_diff_file_path(String.t(), String.t()) :: String.t()
  defp normalize_diff_file_path("/dev/null", _side), do: "/dev/null"
  defp normalize_diff_file_path("a/old/" <> path, "a"), do: "a/" <> strip_diff_timestamp(path)
  defp normalize_diff_file_path("b/new/" <> path, "b"), do: "b/" <> strip_diff_timestamp(path)
  defp normalize_diff_file_path("old/" <> path, "a"), do: "a/" <> strip_diff_timestamp(path)
  defp normalize_diff_file_path("new/" <> path, "b"), do: "b/" <> strip_diff_timestamp(path)
  defp normalize_diff_file_path(path, _side), do: strip_diff_timestamp(path)

  @spec strip_diff_timestamp(String.t()) :: String.t()
  defp strip_diff_timestamp(path) do
    path |> String.split("\t", parts: 2) |> hd()
  end

  @spec safe_relative_path(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp safe_relative_path(path) do
    components =
      path |> String.trim_leading("./") |> Path.split() |> Enum.reject(&(&1 in [".", ""]))

    if String.starts_with?(path, "/") or Enum.member?(components, "..") do
      {:error, "unsafe diff path: #{inspect(path)}"}
    else
      {:ok, Path.join(components)}
    end
  end

  @spec empty_to_nil(String.t()) :: String.t() | nil
  defp empty_to_nil("."), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(path), do: path

  @spec unique_id() :: String.t()
  defp unique_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  @spec resolve_git_root(String.t()) :: String.t()
  defp resolve_git_root(project_root) do
    case Git.root_for(project_root) do
      {:ok, root} -> root
      :not_git -> project_root
    end
  end
end
