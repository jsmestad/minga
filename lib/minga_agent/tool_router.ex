# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry

defmodule MingaAgent.ToolRouter do
  @moduledoc """
  Routes file tool operations through ProjectView, buffer forks, and changesets.

  Tools call this module instead of directly doing filesystem I/O.
  The routing decision tree for each file operation:

  1. Is there a ProjectView?
     YES: route through ProjectView so every tool sees workspace-local state.
  2. Is there an open buffer for this path AND a fork store is active?
     YES: route through Buffer.Fork (in-memory, instant, undo integration).
  3. Is there an active changeset?
     YES: route through Changeset overlay (filesystem-level isolation).
  4. Neither: fall through to direct I/O (returns `:passthrough` for writes).

  Buffer.Fork handles files the user has open in a buffer. Changeset
  handles files that aren't open, or external tools that need a coherent
  filesystem view. A session can use both simultaneously.

  This module is stateless. The fork store pid and changeset pid come
  from the caller (stored in session state, captured in tool closures).
  """

  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ToolRouter.Context

  @typedoc "Fork store reference (nil when fork routing is disabled)."
  @type fork_store :: pid() | nil

  @typedoc "Changeset reference (nil when changeset is disabled)."
  @type changeset :: pid() | nil

  @typedoc "Routing context passed by tool callbacks."
  @type context :: Context.t()

  @doc """
  Builds a routing context from the fork store and changeset pids.
  """
  @spec context(fork_store(), changeset()) :: context()
  def context(fork_store, changeset) do
    context(nil, fork_store, changeset)
  end

  @doc "Builds a routing context with ProjectView as the first routing layer."
  @spec context(ProjectView.t() | nil, fork_store(), changeset()) :: context()
  def context(project_view, fork_store, changeset) do
    %Context{project_view: project_view, fork_store: fork_store, changeset: changeset}
  end

  @doc """
  Reads a file, routing through fork or changeset if active.

  Forks take priority: if there's a fork for this path, read from it.
  Otherwise try the changeset. If neither, fall through to buffer/filesystem.
  """
  @spec read_file(context(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%Context{project_view: %ProjectView{} = view}, path) do
    project_view_result(fn ->
      ProjectView.read_file(view, project_view_relative_path(view, path))
    end)
  end

  def read_file(%Context{fork_store: fs} = ctx, path) when fs != nil do
    with :ok <- fork_store_available(fs) do
      case BufferForkStore.get(fs, path) do
        nil -> read_file_changeset_or_passthrough(ctx, path)
        fork_pid -> {:ok, Minga.Buffer.Fork.content(fork_pid)}
      end
    end
  end

  def read_file(ctx, path), do: read_file_changeset_or_passthrough(ctx, path)

  @doc """
  Writes a file, routing through fork or changeset if active.

  If a buffer is open for this path and a fork store exists, creates
  a fork (lazily) and writes to it. Otherwise tries changeset.
  Returns `:passthrough` if neither is active.
  """
  @spec write_file(context(), String.t(), binary()) :: :ok | :passthrough | {:error, term()}
  def write_file(%Context{project_view: %ProjectView{} = view}, path, content) do
    project_view_result(fn ->
      ProjectView.write_file(view, project_view_relative_path(view, path), content)
    end)
  end

  def write_file(%Context{fork_store: fs} = ctx, path, content) when fs != nil do
    case fork_store_available(fs) do
      :ok ->
        case try_fork_write(fs, path, content) do
          {:ok, :forked} -> :ok
          {:error, _} = error -> error
          :no_buffer -> write_file_changeset(ctx, path, content)
        end

      {:error, _} = error ->
        error
    end
  end

  def write_file(ctx, path, content), do: write_file_changeset(ctx, path, content)

  @doc """
  Edits a file by find-and-replace, routing through fork or changeset.
  """
  @spec edit_file(context(), String.t(), String.t(), String.t()) ::
          :ok | :passthrough | {:error, term()}
  def edit_file(%Context{project_view: %ProjectView{} = view}, path, old_text, new_text) do
    project_view_result(fn ->
      ProjectView.edit_file(view, project_view_relative_path(view, path), old_text, new_text)
    end)
  end

  def edit_file(%Context{fork_store: fs} = ctx, path, old_text, new_text) when fs != nil do
    case fork_store_available(fs) do
      :ok ->
        case try_fork_edit(fs, path, old_text, new_text) do
          {:ok, :forked} -> :ok
          {:error, _} = err -> err
          :no_buffer -> edit_file_changeset(ctx, path, old_text, new_text)
        end

      {:error, _} = error ->
        error
    end
  end

  def edit_file(ctx, path, old_text, new_text) do
    edit_file_changeset(ctx, path, old_text, new_text)
  end

  @doc """
  Deletes a file, refusing to remove an open buffered file.

  No safe buffer-aware deletion route exists yet, so deleting a file that
  is open in a live buffer would leave that buffer stale and able to
  recreate the file later. ProjectView, changeset, and direct fallback all
  share that guard.
  """
  @spec delete_file(context(), String.t()) :: :ok | :passthrough | {:error, term()}
  def delete_file(%Context{project_view: %ProjectView{} = view}, path) do
    project_view_result(fn ->
      ProjectView.delete_file(view, project_view_relative_path(view, path))
    end)
  end

  def delete_file(%Context{changeset: cs}, path) when cs != nil and is_pid(cs) do
    with :ok <- changeset_available(cs) do
      relative = normalize_path(cs, path)
      Changeset.delete_file(cs, relative)
    end
  end

  defp delete_file_unchecked(_ctx, _path), do: :passthrough

  @doc """
  Lists a directory through ProjectView when available.
  """
  @spec list_directory(context(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | :passthrough | {:error, term()}
  def list_directory(%Context{project_view: %ProjectView{} = view}, path) do
    project_view_result(fn ->
      ProjectView.list_directory(view, project_view_relative_path(view, path))
    end)
  end

  def list_directory(%Context{} = _ctx, _path), do: :passthrough

  @doc "Returns the filesystem path corresponding to `path` in the routed view."
  @spec filesystem_path(context(), String.t()) :: String.t()
  def filesystem_path(%Context{project_view: %ProjectView{} = view}, path) do
    case ProjectView.working_dir(view) do
      {:error, _reason} -> path
      cwd -> Path.join(cwd, project_view_relative_path(view, path))
    end
  end

  def filesystem_path(%Context{} = _ctx, path), do: path

  @doc "Returns the working directory for shell commands."
  @spec working_dir(context()) :: String.t() | nil
  def working_dir(%Context{project_view: %ProjectView{} = view}) do
    case ProjectView.working_dir(view) do
      {:error, _reason} -> nil
      cwd -> cwd
    end
  end

  def working_dir(%Context{changeset: cs}) when cs != nil and is_pid(cs) do
    try do
      Changeset.overlay_path(cs)
    catch
      :exit, _ -> nil
    end
  end

  def working_dir(_ctx), do: nil

  @doc "Returns environment variables for shell commands."
  @spec command_env(context()) :: [{String.t(), String.t()}]
  def command_env(%Context{project_view: %ProjectView{} = view}) do
    case ProjectView.command_env(view) do
      {:error, _reason} -> []
      env -> env
    end
  end

  def command_env(%Context{}), do: []

  @doc "Returns the filesystem path for search tools, or a tagged error if ProjectView is unavailable."
  @spec filesystem_path_result(context(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def filesystem_path_result(%Context{project_view: %ProjectView{} = view}, path) do
    case project_view_result(fn -> ProjectView.working_dir(view) end) do
      {:ok, cwd} -> {:ok, Path.join(cwd, project_view_relative_path(view, path))}
      cwd when is_binary(cwd) -> {:ok, Path.join(cwd, project_view_relative_path(view, path))}
      {:error, {:project_view_unavailable, _}} = error -> error
      {:error, reason} -> {:error, {:project_view_unavailable, {:working_dir_failed, reason}}}
    end
  end

  def filesystem_path_result(%Context{}, path), do: {:ok, path}

  @doc "Returns the working directory for shell commands, or a tagged error if ProjectView is unavailable."
  @spec working_dir_result(context()) :: {:ok, String.t() | nil} | {:error, term()}
  def working_dir_result(%Context{project_view: %ProjectView{} = view}) do
    case project_view_result(fn -> ProjectView.working_dir(view) end) do
      {:ok, cwd} -> {:ok, cwd}
      cwd when is_binary(cwd) -> {:ok, cwd}
      {:error, {:project_view_unavailable, _}} = error -> error
      {:error, reason} -> {:error, {:project_view_unavailable, {:working_dir_failed, reason}}}
    end
  end

  def working_dir_result(%Context{changeset: cs}) when cs != nil and is_pid(cs) do
    try do
      {:ok, Changeset.overlay_path(cs)}
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  def working_dir_result(_ctx), do: {:ok, nil}

  @doc "Returns environment variables for shell commands, or a tagged error if ProjectView is unavailable."
  @spec command_env_result(context()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def command_env_result(%Context{project_view: %ProjectView{} = view}) do
    case project_view_result(fn -> ProjectView.command_env(view) end) do
      {:ok, env} -> {:ok, env}
      env when is_list(env) -> {:ok, env}
      {:error, {:project_view_unavailable, _}} = error -> error
      {:error, reason} -> {:error, {:project_view_unavailable, {:command_env_failed, reason}}}
    end
  end

  def command_env_result(%Context{changeset: cs}) when cs != nil and is_pid(cs) do
    try do
      {:ok, Changeset.command_env(cs)}
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  def command_env_result(_ctx), do: {:ok, []}

  @doc "Returns true when the context includes a ProjectView."
  @spec project_view?(context()) :: boolean()
  def project_view?(%Context{} = ctx), do: live_project_view(ctx) != nil

  @doc "Returns true when the context was configured with a ProjectView, even if its backend is dead."
  @spec project_view_configured?(context()) :: boolean()
  def project_view_configured?(%Context{project_view: %ProjectView{}}), do: true
  def project_view_configured?(%Context{}), do: false

  @doc "Returns a short label for routed workspace output."
  @spec workspace_label(context()) :: String.t() | nil
  def workspace_label(%Context{} = ctx) do
    case live_project_view(ctx) do
      %ProjectView{} = view ->
        workspace =
          if view.workspace_id == nil, do: "unbound", else: Integer.to_string(view.workspace_id)

    cwd =
      try do
        case ProjectView.working_dir(view) do
          {:error, _reason} -> "unavailable"
          path -> path
        end
      catch
        :exit, _ -> "unavailable"
      end

    "ProjectView workspace #{workspace} cwd=#{cwd}"
  end

  @doc "Returns true if any routing is active."
  @spec active?(context()) :: boolean()
  def active?(%Context{} = ctx) do
    live_project_view(ctx) != nil or active_forks_or_changeset?(ctx)
  end

  @spec live_project_view(context()) :: ProjectView.t() | nil
  defp live_project_view(%Context{project_view: %ProjectView{} = view}) do
    if ProjectView.active?(view), do: view, else: nil
  catch
    :exit, _ -> nil
  end

  defp live_project_view(%Context{}), do: nil

  @spec active_forks_or_changeset?(context()) :: boolean()
  defp active_forks_or_changeset?(%Context{fork_store: fs, changeset: cs}) do
    (fs != nil and Process.alive?(fs)) or (cs != nil and Process.alive?(cs))
  end

  @doc "Returns true if the context has any routing configured, even if it is currently dead."
  @spec routing_configured?(context()) :: boolean()
  def routing_configured?(%Context{project_view: %ProjectView{}}), do: true
  def routing_configured?(%Context{fork_store: fs, changeset: cs}), do: fs != nil or cs != nil
  def routing_configured?(_), do: false

  @doc """
  Returns true if a fork store is active and has forks.
  """
  @spec has_forks?(context()) :: boolean()
  def has_forks?(%Context{fork_store: nil}), do: false

  def has_forks?(%Context{fork_store: fs}) do
    Process.alive?(fs) and map_size(BufferForkStore.all(fs)) > 0
  catch
    :exit, _ -> false
  end

  @spec project_view_result((-> term())) :: term() | {:error, term()}
  defp project_view_result(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:project_view_unavailable, reason}}
    end
  end

  # ── Private: fork operations ────────────────────────────────────────────────

  @spec try_fork_write(pid(), String.t(), binary()) ::
          {:ok, :forked} | {:error, term()} | :no_buffer
  defp try_fork_write(fork_store, path, content) do
    case Minga.Buffer.pid_for_path(path) do
      {:ok, buf_pid} ->
        {:ok, fork_pid} = BufferForkStore.get_or_create(fork_store, path, buf_pid)
        # replace_content is a handle_call on the fork GenServer
        Minga.Buffer.Fork.replace_content(fork_pid, content)
        {:ok, :forked}

      :not_found ->
        :no_buffer
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  @spec try_fork_edit(pid(), String.t(), String.t(), String.t()) ::
          {:ok, :forked} | {:error, term()} | :no_buffer
  defp try_fork_edit(fork_store, path, old_text, new_text) do
    case Minga.Buffer.pid_for_path(path) do
      {:ok, buf_pid} ->
        {:ok, fork_pid} = BufferForkStore.get_or_create(fork_store, path, buf_pid)

        case Minga.Buffer.Fork.find_and_replace(fork_pid, old_text, new_text) do
          {:ok, _msg} -> {:ok, :forked}
          {:error, _} = err -> err
        end

      :not_found ->
        :no_buffer
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  # ── Private: changeset fallback ─────────────────────────────────────────────

  @spec read_file_changeset_or_passthrough(context(), String.t()) ::
          {:ok, binary()} | {:error, term()} | :passthrough
  defp read_file_changeset_or_passthrough(%Context{changeset: cs}, path)
       when cs != nil and is_pid(cs) do
    with :ok <- changeset_available(cs) do
      relative = normalize_path(cs, path)
      Changeset.read_file(cs, relative)
    end
  end

  defp read_file_changeset_or_passthrough(_ctx, path) do
    # No routing active: try buffer, then filesystem
    case Minga.Buffer.pid_for_path(path) do
      {:ok, pid} -> {:ok, Minga.Buffer.content(pid)}
      :not_found -> File.read(path)
    end
  rescue
    _ -> File.read(path)
  end

  @spec write_file_changeset(context(), String.t(), binary()) ::
          :ok | :passthrough | {:error, term()}
  defp write_file_changeset(%Context{changeset: cs}, path, content)
       when cs != nil and is_pid(cs) do
    with :ok <- changeset_available(cs) do
      relative = normalize_path(cs, path)
      Changeset.write_file(cs, relative, content)
    end
  end

  defp write_file_changeset(_ctx, _path, _content), do: :passthrough

  @spec edit_file_changeset(context(), String.t(), String.t(), String.t()) ::
          :ok | :passthrough | {:error, term()}
  defp edit_file_changeset(%Context{changeset: cs}, path, old_text, new_text)
       when cs != nil and is_pid(cs) do
    with :ok <- changeset_available(cs) do
      relative = normalize_path(cs, path)
      Changeset.edit_file(cs, relative, old_text, new_text)
    end
  end

  defp edit_file_changeset(_ctx, _path, _old_text, _new_text), do: :passthrough

  @spec fork_store_available(pid()) :: :ok | {:error, {:fork_unavailable, term()}}
  defp fork_store_available(fork_store) do
    try do
      _ = BufferForkStore.all(fork_store)
      :ok
    catch
      :exit, reason -> {:error, {:fork_unavailable, reason}}
    end
  end

  @spec changeset_available(pid()) :: :ok | {:error, {:changeset_unavailable, term()}}
  defp changeset_available(changeset) do
    try do
      _ = Changeset.overlay_path(changeset)
      :ok
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  # ── Private: path normalization ─────────────────────────────────────────────

  @spec project_view_relative_path(ProjectView.t(), String.t()) :: String.t()
  defp project_view_relative_path(%ProjectView{} = view, path) do
    path
    |> Path.relative_to(view.project_root)
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end

  @spec normalize_path(pid(), String.t()) :: String.t()
  defp normalize_path(cs, path) do
    root = Changeset.project_root(cs)

    path
    |> Path.relative_to(root)
    |> String.trim_leading("/")
    |> String.trim_leading("./")
  end
end
