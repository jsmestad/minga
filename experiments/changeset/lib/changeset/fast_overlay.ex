defmodule Changeset.FastOverlay do
  @moduledoc """
  Optimized overlay using APFS clones and a persistent BEAM node.

  Three key optimizations over the basic overlay:

  1. **APFS clone** (`cp -Rc`): clones the entire project in one
     syscall. The clone shares disk blocks with the original via
     copy-on-write. Writing to a cloned file automatically allocates
     new blocks without affecting the original. ~50ms for 500 files
     vs ~250ms for hardlink-by-hardlink mirroring.

  2. **Warm `_build`**: The clone includes the project's `_build`
     directory. Incremental compilation works immediately, no cold
     compile needed. Writes to `.beam` files trigger CoW automatically.

  3. **Persistent BEAM node**: Instead of spawning `mix compile` as a
     new OS process each time (250ms BEAM startup per invocation), a
     long-lived Elixir node runs in the overlay. Commands are sent via
     distributed Erlang RPC. The node startup is a one-time cost.

  ## Platform support

  APFS clones require macOS 10.13+ (APFS filesystem). On Linux or
  non-APFS volumes, falls back to the hardlink overlay.
  """

  @typedoc "Fast overlay state."
  @type t :: %__MODULE__{
          overlay_dir: String.t(),
          project_root: String.t(),
          mode: :apfs_clone | :hardlink,
          node_name: atom() | nil,
          node_port: port() | nil
        }

  @enforce_keys [:overlay_dir, :project_root, :mode]
  defstruct [:overlay_dir, :project_root, :mode, :node_name, :node_port]

  @doc """
  Creates a fast overlay via APFS clone (falls back to hardlinks).

  The clone includes `_build` for warm compilation. `deps` is replaced
  with a symlink to the original (shared, read-only).
  """
  @spec create(String.t()) :: {:ok, t()} | {:error, term()}
  def create(project_root) do
    id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    overlay_dir = Path.join(System.tmp_dir!(), "cs-fast-#{id}")

    case try_apfs_clone(project_root, overlay_dir) do
      :ok ->
        # Replace deps with symlink to original (save disk, share deps)
        deps_overlay = Path.join(overlay_dir, "deps")
        deps_real = Path.join(project_root, "deps")

        if File.dir?(deps_overlay) do
          File.rm_rf!(deps_overlay)
          if File.dir?(deps_real), do: File.ln_s!(deps_real, deps_overlay)
        end

        # Remove .git clone (don't need git state in overlay)
        git_overlay = Path.join(overlay_dir, ".git")
        if File.dir?(git_overlay), do: File.rm_rf!(git_overlay)

        {:ok, %__MODULE__{
          overlay_dir: overlay_dir,
          project_root: project_root,
          mode: :apfs_clone
        }}

      {:error, _reason} ->
        # Fall back to hardlink overlay
        case Changeset.Overlay.create(project_root) do
          {:ok, basic_overlay} ->
            {:ok, %__MODULE__{
              overlay_dir: basic_overlay.overlay_dir,
              project_root: project_root,
              mode: :hardlink
            }}

          error -> error
        end
    end
  end

  @doc """
  Starts a persistent BEAM node in the overlay for fast command execution.

  Returns the node name. Subsequent calls to `rpc/3` execute in this node
  without paying BEAM startup cost.
  """
  @spec start_node(t()) :: {:ok, t()} | {:error, term()}
  def start_node(%__MODULE__{} = overlay) do
    # Ensure epmd is running and this node is distributed
    ensure_distributed()

    node_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    node_name = :"cs_#{node_id}@127.0.0.1"

    # Start a detached Elixir node in the overlay directory
    port = Port.open(
      {:spawn_executable, System.find_executable("elixir") |> String.to_charlist()},
      [
        :binary,
        :stderr_to_stdout,
        args: [
          "--name", Atom.to_string(node_name),
          "--cookie", Atom.to_string(Node.get_cookie()),
          "-S", "mix", "run", "--no-halt"
        ],
        cd: String.to_charlist(overlay.overlay_dir),
        env: build_env(overlay)
      ]
    )

    # Wait for the node to come up
    case wait_for_node(node_name, 15_000) do
      :ok ->
        {:ok, %{overlay | node_name: node_name, node_port: port}}

      :timeout ->
        Port.close(port)
        {:error, :node_start_timeout}
    end
  end

  @doc """
  Executes a Mix task on the persistent node via RPC.

  Returns `{output, exit_code}` to match the Changeset.run/3 interface.
  """
  @spec rpc_mix(t(), String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def rpc_mix(%__MODULE__{node_name: node} = _overlay, task, args \\ []) when not is_nil(node) do
    result = :rpc.call(node, __MODULE__, :remote_mix_task, [task, args], 60_000)

    case result do
      {:ok, output} -> {output, 0}
      {:error, output} -> {output, 1}
      {:badrpc, reason} -> {"RPC failed: #{inspect(reason)}", 1}
    end
  end

  @doc false
  # Runs on the remote node
  def remote_mix_task(task, args) do
    try do
      # Capture IO output
      output = ExUnit.CaptureIO.capture_io(fn ->
        Mix.Task.rerun(task, args)
      end)

      {:ok, output}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end

  @doc "Runs a shell command in the overlay (fallback when no persistent node)."
  @spec shell(t(), String.t(), keyword()) :: {String.t(), non_neg_integer()}
  def shell(%__MODULE__{} = overlay, command, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    port = Port.open(
      {:spawn_executable, ~c"/bin/sh"},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command],
        cd: String.to_charlist(overlay.overlay_dir),
        env: build_env(overlay)
      ]
    )

    collect_output(port, [], timeout)
  end

  @doc "Writes a file into the overlay. CoW handles the rest."
  @spec write_file(t(), String.t(), binary()) :: :ok
  def write_file(%__MODULE__{} = overlay, relative_path, content) do
    target = Path.join(overlay.overlay_dir, relative_path)
    File.mkdir_p!(Path.dirname(target))
    File.write!(target, content)
    :ok
  end

  @doc "Reads a file from the overlay."
  @spec read_file(t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%__MODULE__{} = overlay, relative_path) do
    File.read(Path.join(overlay.overlay_dir, relative_path))
  end

  @doc "Cleans up the overlay and stops the persistent node."
  @spec cleanup(t()) :: :ok
  def cleanup(%__MODULE__{} = overlay) do
    if overlay.node_name do
      :rpc.call(overlay.node_name, System, :halt, [0], 5000)
    end

    if overlay.node_port do
      try do
        Port.close(overlay.node_port)
      catch
        _, _ -> :ok
      end
    end

    # Remove symlinks before rm_rf to avoid following them
    deps = Path.join(overlay.overlay_dir, "deps")
    case File.lstat(deps) do
      {:ok, %{type: :symlink}} -> File.rm!(deps)
      _ -> :ok
    end

    File.rm_rf!(overlay.overlay_dir)
    :ok
  end

  # ── Private ──────────────────────────────────────────────────────

  defp try_apfs_clone(source, target) do
    case System.cmd("cp", ["-Rc", source, target], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {err, _} -> {:error, err}
    end
  end

  defp build_env(%__MODULE__{} = _overlay) do
    [
      {~c"TERM", ~c"dumb"},
      {~c"PAGER", ~c"cat"},
      {~c"GIT_PAGER", ~c"cat"}
    ]
  end

  defp ensure_distributed do
    unless Node.alive?() do
      id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      Node.start(:"cs_host_#{id}@127.0.0.1", :longnames)
    end
  end

  defp wait_for_node(node_name, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_node(node_name, deadline)
  end

  defp do_wait_for_node(node_name, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :timeout
    else
      if Node.ping(node_name) == :pong do
        :ok
      else
        Process.sleep(100)
        do_wait_for_node(node_name, deadline)
      end
    end
  end

  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect_output(port, [data | acc], timeout)
      {^port, {:exit_status, code}} ->
        {acc |> Enum.reverse() |> IO.iodata_to_binary(), code}
    after
      timeout ->
        Port.close(port)
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {output <> "\n[timeout]", 1}
    end
  end
end
