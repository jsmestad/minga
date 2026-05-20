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
    ProjectView.read_file(view, project_view_relative_path(view, path))
  end

  def read_file(%Context{fork_store: fs} = ctx, path) when fs != nil do
    case BufferForkStore.get(fs, path) do
      nil -> read_file_changeset_or_passthrough(ctx, path)
      fork_pid -> {:ok, Minga.Buffer.Fork.content(fork_pid)}
    end
  catch
    :exit, _ -> read_file_changeset_or_passthrough(ctx, path)
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
    ProjectView.write_file(view, project_view_relative_path(view, path), content)
  end

  def write_file(%Context{fork_store: fs} = ctx, path, content) when fs != nil do
    case try_fork_write(fs, path, content) do
      {:ok, :forked} -> :ok
      :no_buffer -> write_file_changeset(ctx, path, content)
    end
  end

  def write_file(ctx, path, content), do: write_file_changeset(ctx, path, content)

  @doc """
  Edits a file by find-and-replace, routing through fork or changeset.
  """
  @spec edit_file(context(), String.t(), String.t(), String.t()) ::
          :ok | :passthrough | {:error, term()}
  def edit_file(%Context{project_view: %ProjectView{} = view}, path, old_text, new_text) do
    ProjectView.edit_file(view, project_view_relative_path(view, path), old_text, new_text)
  end

  def edit_file(%Context{fork_store: fs} = ctx, path, old_text, new_text) when fs != nil do
    case try_fork_edit(fs, path, old_text, new_text) do
      {:ok, :forked} -> :ok
      {:error, _} = err -> err
      :no_buffer -> edit_file_changeset(ctx, path, old_text, new_text)
    end
  end

  def edit_file(ctx, path, old_text, new_text) do
    edit_file_changeset(ctx, path, old_text, new_text)
  end

  @doc """
  Deletes a file, routing through changeset if active.

  Buffer forks don't support deletion (you can't delete an open buffer
  through a fork). Falls through to changeset or passthrough.
  """
  @spec delete_file(context(), String.t()) :: :ok | :passthrough | {:error, term()}
  def delete_file(%Context{project_view: %ProjectView{} = view}, path) do
    ProjectView.delete_file(view, project_view_relative_path(view, path))
  end

  def delete_file(%Context{changeset: cs}, path) when cs != nil and is_pid(cs) do
    relative = normalize_path(cs, path)
    Changeset.delete_file(cs, relative)
  end

  def delete_file(_ctx, _path), do: :passthrough

  @doc """
  Lists a directory through ProjectView when available.
  """
  @spec list_directory(context(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | :passthrough | {:error, term()}
  def list_directory(%Context{project_view: %ProjectView{} = view}, path) do
    ProjectView.list_directory(view, project_view_relative_path(view, path))
  end

  def list_directory(%Context{}, _path), do: :passthrough

  @doc "Returns the filesystem path corresponding to `path` in the routed view."
  @spec filesystem_path(context(), String.t()) :: String.t()
  def filesystem_path(%Context{project_view: %ProjectView{} = view}, path) do
    Path.join(ProjectView.working_dir(view), project_view_relative_path(view, path))
  end

  def filesystem_path(%Context{}, path), do: path

  @doc "Returns the working directory for shell commands."
  @spec working_dir(context()) :: String.t() | nil
  def working_dir(%Context{project_view: %ProjectView{} = view}),
    do: ProjectView.working_dir(view)

  def working_dir(%Context{changeset: cs}) when cs != nil and is_pid(cs) do
    Changeset.overlay_path(cs)
  end

  def working_dir(_ctx), do: nil

  @doc "Returns environment variables for shell commands."
  @spec command_env(context()) :: [{String.t(), String.t()}]
  def command_env(%Context{project_view: %ProjectView{} = view}),
    do: ProjectView.command_env(view)

  def command_env(%Context{}), do: []

  @doc "Returns true when the context includes a ProjectView."
  @spec project_view?(context()) :: boolean()
  def project_view?(%Context{project_view: %ProjectView{}}), do: true
  def project_view?(%Context{}), do: false

  @doc "Returns a short label for routed workspace output."
  @spec workspace_label(context()) :: String.t() | nil
  def workspace_label(%Context{project_view: %ProjectView{} = view}) do
    workspace =
      if view.workspace_id == nil, do: "unbound", else: Integer.to_string(view.workspace_id)

    "ProjectView workspace #{workspace} cwd=#{ProjectView.working_dir(view)}"
  end

  def workspace_label(%Context{}), do: nil

  @doc "Returns true if any routing is active."
  @spec active?(context()) :: boolean()
  def active?(%Context{project_view: %ProjectView{}}), do: true

  def active?(%Context{fork_store: fs, changeset: cs}) do
    (fs != nil and Process.alive?(fs)) or (cs != nil and Process.alive?(cs))
  end

  def active?(_), do: false

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

  # ── Private: fork operations ────────────────────────────────────────────────

  @spec try_fork_write(pid(), String.t(), binary()) :: {:ok, :forked} | :no_buffer
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
    :exit, _ -> :no_buffer
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
    :exit, _ -> :no_buffer
  end

  # ── Private: changeset fallback ─────────────────────────────────────────────

  @spec read_file_changeset_or_passthrough(context(), String.t()) ::
          {:ok, binary()} | {:error, term()} | :passthrough
  defp read_file_changeset_or_passthrough(%Context{changeset: cs}, path)
       when cs != nil and is_pid(cs) do
    relative = normalize_path(cs, path)
    Changeset.read_file(cs, relative)
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
    relative = normalize_path(cs, path)
    Changeset.write_file(cs, relative, content)
  end

  defp write_file_changeset(_ctx, _path, _content), do: :passthrough

  @spec edit_file_changeset(context(), String.t(), String.t(), String.t()) ::
          :ok | :passthrough | {:error, term()}
  defp edit_file_changeset(%Context{changeset: cs}, path, old_text, new_text)
       when cs != nil and is_pid(cs) do
    relative = normalize_path(cs, path)
    Changeset.edit_file(cs, relative, old_text, new_text)
  end

  defp edit_file_changeset(_ctx, _path, _old_text, _new_text), do: :passthrough

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
