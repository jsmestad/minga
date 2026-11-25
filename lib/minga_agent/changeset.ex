defmodule MingaAgent.Changeset do
  @moduledoc """
  In-memory changesets with filesystem overlays for agent editing.

  A changeset tracks file edits without modifying the original project. Edits are held in memory and materialized into a temporary overlay directory (`MingaAgent.Changeset.Overlay`), where external tools (compilers, test runners, linters) see a coherent view of the project with changes applied.

  The overlay copies the project files it needs and never hardlinks them, so a tool that rewrites a copied file changes only the overlay. Build and cache directories such as `_build`, `deps`, `.git` and `node_modules` are not copied, and `deps` stays shared with the project. Commands use the project's `deps` directory through `MIX_DEPS_PATH`, so a command that fetches or changes dependencies changes the project's `deps`. Installed `node_modules` trees are copy-on-write clones of the project's, so a command that writes inside an installed package, such as a postinstall script or `patch-package`, changes only the overlay. When the overlay cannot clone them (another volume, or a file system without copy-on-write such as HFS+ or ext4), the packages are links to the project's copies instead, and a command that writes inside one changes the project's package; the overlay notes that fallback in `*Messages*`. Agent file tools never write through such a link.

  ## Lifecycle

      {:ok, cs} = MingaAgent.Changeset.create("/path/to/project")

      :ok = MingaAgent.Changeset.write_file(cs, "lib/math.ex", new_content)
      :ok = MingaAgent.Changeset.edit_file(cs, "lib/util.ex", "old", "new")

      # External tools see changes through the overlay
      {output, 0} = MingaAgent.Changeset.run(cs, "mix compile")

      # Session ends: merge back with three-way merge
      :ok = MingaAgent.Changeset.merge(cs)

  ## Budget system

      {:ok, cs} = MingaAgent.Changeset.create("/path/to/project", budget: 3)
      {:ok, 1} = MingaAgent.Changeset.record_attempt(cs)
      {:budget_exhausted, 4, 3} = MingaAgent.Changeset.record_attempt(cs)
  """

  alias MingaAgent.Changeset.Server

  @type changeset :: pid()

  @doc """
  Creates a new changeset against `project_root`.

  Starts a `Changeset.Server` GenServer under `MingaAgent.Supervisor`.
  The server creates a filesystem overlay mirroring the project.

  ## Options

    * `:budget` - max verification attempts before exhaustion (default: `:unlimited`)
  """
  @spec create(String.t(), keyword()) :: {:ok, changeset()} | {:error, term()}
  def create(project_root, opts \\ []) do
    project_root = Path.expand(project_root)

    if File.dir?(project_root) do
      DynamicSupervisor.start_child(
        MingaAgent.Supervisor,
        {Server, Keyword.merge(opts, project_root: project_root)}
      )
    else
      {:error, {:not_a_directory, project_root}}
    end
  end

  @doc "Writes `content` to `relative_path` within the changeset."
  @spec write_file(changeset(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(cs, relative_path, content)
      when is_binary(relative_path) and is_binary(content) do
    GenServer.call(cs, {:write_file, relative_path, content}, :infinity)
  end

  @doc "Edits a file by replacing `old_text` with `new_text`."
  @spec edit_file(changeset(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(cs, relative_path, old_text, new_text)
      when is_binary(relative_path) and is_binary(old_text) and is_binary(new_text) do
    GenServer.call(cs, {:edit_file, relative_path, old_text, new_text}, :infinity)
  end

  @doc "Deletes a file from the changeset's view."
  @spec delete_file(changeset(), String.t()) :: :ok | {:error, term()}
  def delete_file(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:delete_file, relative_path}, :infinity)
  end

  @doc "Validates a full-source revision and commits one complete file mutation atomically."
  @spec conditional_mutate(
          changeset(),
          String.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation(),
          Minga.Buffer.FileMutation.identity()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  def conditional_mutate(cs, relative_path, expected, operation, identity)
      when is_binary(relative_path) do
    GenServer.call(
      cs,
      {:conditional_mutate, relative_path, expected, operation, identity},
      :infinity
    )
  end

  @doc "Retains the original disk bytes before a fork is selected for publication."
  @spec capture_original(changeset(), String.t()) :: :ok | {:error, term()}
  def capture_original(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:capture_original, relative_path})
  end

  @doc "Stages a sealed fork's raw draft against its retained disk baseline."
  @spec stage_fork_content(changeset(), String.t(), binary()) :: :ok | {:error, term()}
  def stage_fork_content(cs, relative_path, content)
      when is_binary(relative_path) and is_binary(content) do
    GenServer.call(cs, {:stage_fork_content, relative_path, content}, :infinity)
  end

  @doc "Stages only the accepted fork edits against the current changeset baseline."
  @spec stage_fork_resolution(changeset(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def stage_fork_resolution(cs, relative_path, ancestor, selected) do
    GenServer.call(cs, {:stage_fork_resolution, relative_path, ancestor, selected}, :infinity)
  end

  @doc "Publishes one retained deletion after checking its original disk baseline."
  @spec publish_deletion(changeset(), String.t()) :: :ok | {:conflict, map()} | {:error, term()}
  def publish_deletion(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:publish_deletion, relative_path}, :infinity)
  end

  @doc "Makes a fork tombstone visible to commands without publishing it to the project."
  @spec materialize_command_deletion(changeset(), String.t()) :: :ok | {:error, term()}
  def materialize_command_deletion(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:materialize_command_deletion, relative_path}, :infinity)
  end

  @doc "Reads a file (changeset version if modified, otherwise from project)."
  @spec read_file(changeset(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:read_file, relative_path})
  end

  @doc "Reads changeset content and its monotonic mutation revision atomically."
  @spec read_file_with_version(changeset(), String.t()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def read_file_with_version(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:read_file_with_version, relative_path})
  end

  @doc "Returns an atomic bounded memory prefix or disk descriptor with the changeset revision."
  @spec read_source_prefix_with_version(changeset(), String.t(), pos_integer()) ::
          MingaAgent.Changeset.SourceRead.prefix_result()
  def read_source_prefix_with_version(cs, relative_path, max_bytes)
      when is_binary(relative_path) and is_integer(max_bytes) and max_bytes > 0 do
    GenServer.call(cs, {:read_source_prefix_with_version, relative_path, max_bytes})
  end

  @doc "Returns requested bounded memory lines or a disk descriptor with the atomic revision."
  @spec read_source_lines_with_version(
          changeset(),
          String.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) ::
          MingaAgent.Changeset.SourceRead.lines_result()
  def read_source_lines_with_version(cs, relative_path, start, count, max_bytes)
      when is_binary(relative_path) and is_integer(start) and start >= 0 and is_integer(count) and
             count > 0 and is_integer(max_bytes) and max_bytes > 0 do
    GenServer.call(cs, {:read_source_lines_with_version, relative_path, start, count, max_bytes})
  end

  @doc "Undoes the last edit to a specific file."
  @spec undo(changeset(), String.t()) :: :ok | {:error, :nothing_to_undo | term()}
  def undo(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:undo, relative_path}, :infinity)
  end

  @doc "Resets the entire changeset, restoring all files to their original state."
  @spec reset(changeset()) :: :ok | {:error, term()}
  def reset(cs) do
    GenServer.call(cs, :reset, :infinity)
  end

  @doc """
  Previews the merge back to the real project without applying it.

  This runs the same path resolution and three-way merge planning as `merge/1`
  but writes, deletes, and cleans up nothing on disk, and never stops the
  GenServer. Use it when a caller needs to know whether a merge would succeed
  before mutating other state.

  Returns `{:ok, results}` when every file would merge cleanly, or
  `{:conflict, details}` (same shape as `merge/1`) listing what could not be
  auto-merged. In both cases `results` is the list of per-file decision tuples
  (`{:ok, path, kind}` / `{:conflict, path, reason}`) the merge would produce.
  """
  @spec preflight_merge(changeset()) :: {:ok, [tuple()]} | {:conflict, map()} | {:error, term()}
  def preflight_merge(cs) do
    GenServer.call(cs, :preflight_merge)
  end

  @doc """
  Merges changes back to the real project with three-way merge.

  If someone edited the same files since the changeset was created,
  a three-way merge is attempted. Returns `:ok` for clean merges, or
  `{:conflict, details}` listing what couldn't be auto-merged. Stops the
  GenServer only on success; conflict results keep the changeset alive for review.
  """
  @spec merge(changeset()) :: :ok | {:conflict, map()} | {:error, term()}
  def merge(cs) do
    GenServer.call(cs, :merge, :infinity)
  end

  @doc "Discards one changed file from the changeset view."
  @spec discard_file(changeset(), String.t()) :: :ok | {:error, term()}
  def discard_file(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:discard_file, relative_path})
  end

  @doc "Discards all changes, cleans up the overlay, and stops the GenServer."
  @spec discard(changeset()) :: :ok
  def discard(cs) do
    GenServer.call(cs, :discard)
  end

  @doc """
  Runs a shell command in the overlay directory.

  Materializes a writable project view first and sets `MIX_BUILD_PATH` to an isolated build directory so compilation doesn't contaminate the real project's `_build`.
  """
  @spec run(changeset(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def run(cs, command, opts \\ []) when is_binary(command) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    case materialize_for_command(cs) do
      {:ok, _stats} ->
        run_materialized(cs, command, timeout)

      {:error, reason} ->
        {"[changeset: failed to materialize command view: #{inspect(reason)}]", 1}
    end
  end

  @spec run_materialized(changeset(), String.t(), non_neg_integer()) ::
          {String.t(), non_neg_integer()}
  defp run_materialized(cs, command, timeout) do
    overlay = overlay_path(cs)
    env = GenServer.call(cs, :command_env)
    env_charlist = Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open(
        {:spawn_executable, ~c"/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-c", command],
          cd: overlay,
          env: env_charlist
        ]
      )

    collect_port_output(port, [], timeout)
  end

  @doc "Returns the overlay directory path."
  @spec overlay_path(changeset()) :: String.t()
  def overlay_path(cs) do
    GenServer.call(cs, :overlay_path)
  end

  @doc "Materializes and returns the overlay directory path for shell/search tools."
  @spec prepare_working_dir(changeset()) :: {:ok, String.t()} | {:error, term()}
  def prepare_working_dir(cs) do
    with {:ok, _stats} <- materialize_for_command(cs) do
      {:ok, overlay_path(cs)}
    end
  end

  @doc "Makes fork content visible to commands without changing the changeset's logical draft."
  @spec materialize_command_file(changeset(), String.t(), binary()) :: :ok | {:error, term()}
  def materialize_command_file(cs, relative_path, content)
      when is_binary(relative_path) and is_binary(content) do
    GenServer.call(cs, {:materialize_command_file, relative_path, content}, :infinity)
  end

  @doc "Returns the project root this changeset was created against."
  @spec project_root(changeset()) :: String.t()
  def project_root(cs) do
    GenServer.call(cs, :project_root)
  end

  @doc "Returns environment variables shell commands should use for this changeset."
  @spec command_env(changeset()) :: [{String.t(), String.t()}]
  def command_env(cs) do
    GenServer.call(cs, :command_env)
  end

  @doc "Lists a directory in the changeset's logical project view."
  @spec list_directory(changeset(), String.t()) ::
          {:ok, [%{name: String.t(), type: :directory | :file}]} | {:error, term()}
  def list_directory(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:list_directory, relative_path})
  end

  @doc "Returns modified and deleted file lists."
  @spec modified_files(changeset()) :: %{modified: [String.t()], deleted: [String.t()]}
  def modified_files(cs) do
    GenServer.call(cs, :modified_files)
  end

  @doc "Returns a summary of all changes."
  @spec summary(changeset()) :: [map()]
  def summary(cs) do
    GenServer.call(cs, :summary)
  end

  @doc """
  Records a verification attempt (e.g., after running tests).

  Returns `{:ok, attempt_number}` or `{:budget_exhausted, attempts, budget}`.
  """
  @spec record_attempt(changeset()) ::
          {:ok, pos_integer()} | {:budget_exhausted, pos_integer(), pos_integer()}
  def record_attempt(cs) do
    GenServer.call(cs, :record_attempt)
  end

  @doc """
  Registers `observer` to receive `{:changeset_revised, changeset}` after every staged change.

  One observer at a time; a later call replaces the earlier one. With `{scope, value}`, the changeset also keeps `value` as its staging registration (see `staging/1`) and joins the `:staged_views` group of the `:pg` scope `scope`. Membership lasts as long as the changeset, so a restarted observer can find every live changeset again. `:pg` monitors members rather than linking them.
  """
  @spec observe(changeset(), pid(), {atom(), term()} | nil) :: :ok | {:error, term()}
  def observe(cs, observer, registration \\ nil) when is_pid(observer) do
    GenServer.call(cs, {:observe, observer, registration})
  end

  @doc """
  Tells the observer that a buffer fork draft of this changeset's view changed.

  Fork drafts change without a changeset revision, so the code that edits a fork calls this after each successful edit. The observer receives `{:changeset_revised, changeset}` as it does after a staged change. The changeset's revision does not change.
  """
  @spec fork_draft_changed(changeset()) :: :ok
  def fork_draft_changed(cs), do: GenServer.cast(cs, :fork_draft_changed)

  @doc "Returns the staging registration value given to `observe/3`, or `nil`."
  @spec staging(changeset()) :: term() | nil
  def staging(cs), do: GenServer.call(cs, :staging)

  @doc """
  Returns the staged drafts, with the base each change was staged against, plus the retained baselines of `baseline_paths`.

  Callers that hold drafts elsewhere (buffer forks) read their bases from the returned baseline map. A path without a retained baseline is absent from the map.
  """
  @spec staged_drafts(changeset(), [String.t()]) ::
          {[Minga.Session.StagedDraft.t()], %{String.t() => binary() | nil}}
  def staged_drafts(cs, baseline_paths \\ []) when is_list(baseline_paths) do
    GenServer.call(cs, {:staged_drafts, baseline_paths})
  end

  @doc """
  Restores one persisted draft into the changeset: the base becomes the publication baseline and the content becomes the staged change.

  Publication then merges against the restored base exactly as it would for a draft staged in this run.
  """
  @spec restore_draft(changeset(), Minga.Session.StagedDraft.t()) :: :ok | {:error, term()}
  def restore_draft(cs, %Minga.Session.StagedDraft{} = draft) do
    GenServer.call(cs, {:restore_draft, draft}, :infinity)
  end

  @doc "Returns the current attempt count and budget."
  @spec attempt_info(changeset()) :: %{
          attempts: non_neg_integer(),
          budget: pos_integer() | :unlimited
        }
  def attempt_info(cs) do
    GenServer.call(cs, :attempt_info)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec materialize_for_command(changeset()) :: {:ok, term()} | {:error, term()}
  defp materialize_for_command(cs) do
    GenServer.call(cs, :materialize_for_command, :infinity)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec collect_port_output(port(), [binary()], non_neg_integer()) ::
          {String.t(), non_neg_integer()}
  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | acc], timeout)

      {^port, {:exit_status, code}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {output, code}
    after
      timeout ->
        Port.close(port)
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {output <> "\n[changeset: command timed out after #{timeout}ms]", 1}
    end
  end
end
