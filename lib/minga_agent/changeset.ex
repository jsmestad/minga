defmodule MingaAgent.Changeset do
  @moduledoc """
  In-memory changesets with filesystem overlays for agent editing.

  A changeset tracks file edits without modifying the original project.
  Edits are held in memory and materialized into a hardlink overlay where
  external tools (compilers, test runners, linters) see a coherent view
  of the project with changes applied.

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
    GenServer.call(cs, {:write_file, relative_path, content})
  end

  @doc "Edits a file by replacing `old_text` with `new_text`."
  @spec edit_file(changeset(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(cs, relative_path, old_text, new_text)
      when is_binary(relative_path) and is_binary(old_text) and is_binary(new_text) do
    GenServer.call(cs, {:edit_file, relative_path, old_text, new_text})
  end

  @doc "Deletes a file from the changeset's view."
  @spec delete_file(changeset(), String.t()) :: :ok | {:error, term()}
  def delete_file(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:delete_file, relative_path})
  end

  @doc "Reads a file (changeset version if modified, otherwise from project)."
  @spec read_file(changeset(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:read_file, relative_path})
  end

  @doc "Undoes the last edit to a specific file."
  @spec undo(changeset(), String.t()) :: :ok | {:error, :nothing_to_undo}
  def undo(cs, relative_path) when is_binary(relative_path) do
    GenServer.call(cs, {:undo, relative_path})
  end

  @doc "Resets the entire changeset, restoring all files to their original state."
  @spec reset(changeset()) :: :ok
  def reset(cs) do
    GenServer.call(cs, :reset)
  end

  @doc """
  Merges changes back to the real project with three-way merge.

  If someone edited the same files since the changeset was created,
  a three-way merge is attempted. Returns `:ok` for clean merges, or
  `{:ok, :merged_with_conflicts, details}` listing what couldn't be
  auto-merged. Stops the GenServer on success.
  """
  @spec merge(changeset()) :: :ok | {:ok, :merged_with_conflicts, list()} | {:error, term()}
  def merge(cs) do
    GenServer.call(cs, :merge)
  end

  @doc "Discards all changes, cleans up the overlay, and stops the GenServer."
  @spec discard(changeset()) :: :ok
  def discard(cs) do
    GenServer.call(cs, :discard)
  end

  @doc """
  Runs a shell command in the overlay directory.

  Sets `MIX_BUILD_PATH` to an isolated build directory so compilation
  doesn't contaminate the real project's `_build`.
  """
  @spec run(changeset(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def run(cs, command, opts \\ []) when is_binary(command) do
    overlay = overlay_path(cs)
    env = GenServer.call(cs, :command_env)
    timeout = Keyword.get(opts, :timeout, 30_000)

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

  @doc "Returns the project root this changeset was created against."
  @spec project_root(changeset()) :: String.t()
  def project_root(cs) do
    GenServer.call(cs, :project_root)
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

  @doc "Returns the current attempt count and budget."
  @spec attempt_info(changeset()) :: %{
          attempts: non_neg_integer(),
          budget: pos_integer() | :unlimited
        }
  def attempt_info(cs) do
    GenServer.call(cs, :attempt_info)
  end

  # ── Private ─────────────────────────────────────────────────────────────────

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
