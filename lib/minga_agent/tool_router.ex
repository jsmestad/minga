# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry

defmodule MingaAgent.ToolRouter do
  @moduledoc """
  Routes file tool operations through ProjectView, buffer forks, and changesets.

  Tools call this module instead of directly doing filesystem I/O.
  Reads select the session's ProjectView, existing fork, or changeset before a direct buffer or disk source. Mutations require an owned editable view and never return a filesystem passthrough. The selected buffer, fork, or changeset compares the full-source revision and commits the complete mutation in its serialized callback.

  This module is stateless. The fork store pid and changeset pid come
  from the caller (stored in session state, captured in tool closures).
  """

  alias MingaAgent.BufferForkStore
  alias MingaAgent.Changeset
  alias MingaAgent.ProjectView
  alias MingaAgent.ToolRouter.Context
  alias MingaAgent.ToolRouter.SearchContext
  alias MingaAgent.ToolRouter.SourceCapture

  @typedoc "Fork store reference (nil when fork routing is disabled)."
  @type fork_store :: pid() | nil

  @typedoc "Changeset reference (nil when changeset is disabled)."
  @type changeset :: pid() | nil

  @typedoc "Routing context passed by tool callbacks."
  @type context :: Context.t()

  @typedoc "Trusted execution and filtering context for search tools."
  @type search_context :: SearchContext.t()

  @typep route_result(value) :: {:ok, value} | {:error, term()}

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
    with {:ok, logical_path} <- ProjectView.logical_path(view, path) do
      project_view_result(fn -> ProjectView.read_file(view, logical_path) end)
    end
  end

  def read_file(%Context{fork_store: store} = context, path) when is_pid(store) do
    case claim_owner(context, path) do
      {:ok, {:fork, fork}} ->
        Minga.Buffer.Fork.read_file(fork)

      {:ok, {:changeset, changeset}} ->
        with {:ok, relative} <- normalize_changeset_path(changeset, path, false) do
          Changeset.read_file(changeset, relative)
        end

      :not_found ->
        read_file_changeset_or_passthrough(context, path)

      {:error, _} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:source_unavailable, reason}}
  end

  def read_file(ctx, path), do: read_file_changeset_or_passthrough(ctx, path)

  @doc "Captures a routed source with exact retained bytes and an atomic revision."
  @spec capture_file(
          context(),
          String.t(),
          GenServer.server() | nil,
          MingaAgent.Tool.Context.capture_key() | nil,
          keyword()
        ) ::
          {:ok, MingaAgent.Tool.Output.t()}
          | {:error, MingaAgent.Tool.Output.t() | term()}
  def capture_file(%Context{} = context, path, artifact_store, capture_key, opts \\ []) do
    SourceCapture.capture(context, path, artifact_store, capture_key, opts)
  end

  @doc "Pins a session path to one writer, preserving that claim if buffers open or owners die."
  @spec claim_owner(context(), String.t()) ::
          {:ok, BufferForkStore.owner()} | :not_found | {:error, term()}
  def claim_owner(%Context{fork_store: store, changeset: changeset}, path) when is_pid(store) do
    buffer =
      case Minga.Buffer.pid_for_path(path) do
        {:ok, pid} -> pid
        :not_found -> nil
      end

    BufferForkStore.claim_owner(store, path, buffer, changeset)
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  @doc "Commits one complete conditional file mutation at the selected content owner."
  @spec conditional_mutate(
          context(),
          String.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  def conditional_mutate(%Context{project_view: %ProjectView{} = view}, path, expected, operation) do
    with {:ok, logical_path} <- ProjectView.logical_path(view, path) do
      project_view_result(fn ->
        ProjectView.conditional_mutate(view, logical_path, expected, operation)
      end)
    end
  end

  def conditional_mutate(%Context{fork_store: store} = context, path, expected, operation)
      when is_pid(store) do
    case claim_owner(context, path) do
      {:ok, {:fork, fork}} ->
        Minga.Buffer.Fork.conditional_mutate(fork, expected, operation, {:fork, path})

      {:ok, {:changeset, changeset}} ->
        conditional_mutate_changeset(changeset, path, expected, operation)

      :not_found ->
        conditional_mutate_without_fork(context, path, expected, operation)

      {:error, _} = error ->
        error
    end
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
  end

  def conditional_mutate(%Context{} = context, path, expected, operation),
    do: conditional_mutate_without_fork(context, path, expected, operation)

  @spec conditional_mutate_without_fork(
          context(),
          String.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  defp conditional_mutate_without_fork(%Context{changeset: changeset}, path, expected, operation)
       when is_pid(changeset) do
    conditional_mutate_changeset(changeset, path, expected, operation)
  end

  defp conditional_mutate_without_fork(%Context{}, path, expected, operation) do
    case Minga.Buffer.pid_for_path(path) do
      {:ok, buffer} ->
        Minga.Buffer.conditional_mutate(buffer, expected, operation, {:buffer, path})

      :not_found ->
        {:error, :editable_view_unavailable}
    end
  catch
    :exit, reason -> {:error, {:buffer_unavailable, reason}}
  end

  @spec conditional_mutate_changeset(
          pid(),
          String.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  defp conditional_mutate_changeset(changeset, path, expected, operation) do
    with {:ok, relative} <- normalize_changeset_path(changeset, path, false) do
      Changeset.conditional_mutate(changeset, relative, expected, operation, {:changeset, path})
    end
  catch
    :exit, reason -> {:error, {:changeset_unavailable, reason}}
  end

  @doc """
  Lists a directory through ProjectView when available.
  """
  @spec list_directory(context(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | :passthrough | {:error, term()}
  def list_directory(%Context{project_view: %ProjectView{} = view}, path) do
    with {:ok, logical_path} <- ProjectView.logical_path(view, path) do
      project_view_result(fn -> ProjectView.list_directory(view, logical_path) end)
    end
  end

  def list_directory(%Context{changeset: cs}, path) when cs != nil and is_pid(cs) do
    with :ok <- changeset_available(cs),
         {:ok, relative_path} <- normalize_changeset_path(cs, path, true) do
      Changeset.list_directory(cs, relative_path)
    end
  end

  def list_directory(%Context{}, _path), do: :passthrough

  @doc "Returns the filesystem path corresponding to `path` in the routed view."
  @spec filesystem_path(context(), String.t()) :: String.t()
  def filesystem_path(%Context{} = ctx, path) do
    case resolve_filesystem_path(ctx, path) do
      {:ok, resolved_path} -> resolved_path
      {:error, _reason} -> path
    end
  end

  @doc "Returns the working directory for shell commands."
  @spec working_dir(context()) :: String.t() | nil
  def working_dir(%Context{} = ctx) do
    case resolve_working_dir(ctx) do
      {:ok, cwd} -> cwd
      {:error, _reason} -> nil
    end
  end

  @doc "Returns environment variables for shell commands."
  @spec command_env(context()) :: [{String.t(), String.t()}]
  def command_env(%Context{} = ctx) do
    case resolve_command_env(ctx) do
      {:ok, env} -> env
      {:error, _reason} -> []
    end
  end

  @doc "Returns the filesystem path for search tools, or a tagged error if ProjectView is unavailable."
  @spec filesystem_path_result(context(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def filesystem_path_result(%Context{} = ctx, path) do
    with :ok <- prepare_execution_routing(ctx) do
      resolve_filesystem_path(ctx, path)
    end
  end

  @doc "Returns the trusted execution and logical filtering context for search tools."
  @spec search_context(context(), String.t()) :: {:ok, search_context()} | {:error, term()}
  def search_context(%Context{} = ctx, path) do
    with :ok <- prepare_execution_routing(ctx),
         {:ok, exec_path} <- resolve_filesystem_path(ctx, path) do
      {:ok, %SearchContext{exec_path: exec_path, filter_root: path}}
    end
  end

  @doc "Returns the working directory for shell commands, or a tagged error if ProjectView is unavailable."
  @spec working_dir_result(context()) :: {:ok, String.t() | nil} | {:error, term()}
  def working_dir_result(%Context{} = ctx) do
    with :ok <- prepare_execution_routing(ctx) do
      resolve_working_dir(ctx)
    end
  end

  @doc "Returns environment variables for shell commands, or a tagged error if ProjectView is unavailable."
  @spec command_env_result(context()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def command_env_result(%Context{} = ctx), do: resolve_command_env(ctx)

  @spec resolve_filesystem_path(context(), String.t()) :: route_result(String.t())
  defp resolve_filesystem_path(%Context{project_view: %ProjectView{} = view} = ctx, path) do
    with {:ok, logical_path} <- ProjectView.logical_path(view, path),
         {:ok, cwd} <- resolve_working_dir(ctx) do
      {:ok, Path.expand(logical_path, cwd)}
    end
  end

  defp resolve_filesystem_path(%Context{changeset: cs}, path) when cs != nil and is_pid(cs) do
    try do
      with {:ok, cwd} <- Changeset.prepare_working_dir(cs),
           {:ok, relative_path} <- normalize_changeset_path(cs, path, true) do
        {:ok, Path.expand(relative_path, cwd)}
      end
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  defp resolve_filesystem_path(%Context{}, path), do: {:ok, path}

  @spec resolve_working_dir(context()) :: route_result(String.t() | nil)
  defp resolve_working_dir(%Context{project_view: %ProjectView{} = view}) do
    case project_view_result(fn -> ProjectView.prepare_working_dir(view) end) do
      {:ok, cwd} -> {:ok, cwd}
      {:error, {:project_view_unavailable, _}} = error -> error
      {:error, reason} -> {:error, {:project_view_unavailable, {:working_dir_failed, reason}}}
    end
  end

  defp resolve_working_dir(%Context{changeset: cs}) when cs != nil and is_pid(cs) do
    try do
      Changeset.prepare_working_dir(cs)
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  defp resolve_working_dir(%Context{}), do: {:ok, nil}

  @spec resolve_command_env(context()) :: route_result([{String.t(), String.t()}])
  defp resolve_command_env(%Context{project_view: %ProjectView{} = view}) do
    case project_view_result(fn -> ProjectView.command_env(view) end) do
      {:ok, env} -> {:ok, env}
      env when is_list(env) -> {:ok, env}
      {:error, {:project_view_unavailable, _}} = error -> error
      {:error, reason} -> {:error, {:project_view_unavailable, {:command_env_failed, reason}}}
    end
  end

  defp resolve_command_env(%Context{changeset: cs}) when cs != nil and is_pid(cs) do
    try do
      {:ok, Changeset.command_env(cs)}
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  defp resolve_command_env(%Context{}), do: {:ok, []}

  @spec prepare_execution_routing(context()) :: :ok | {:error, term()}
  defp prepare_execution_routing(%Context{project_view: %ProjectView{}}), do: :ok

  defp prepare_execution_routing(%Context{changeset: cs} = ctx) when cs != nil and is_pid(cs) do
    try do
      materialize_forks_for_command(ctx)
    catch
      :exit, reason -> {:error, {:changeset_unavailable, reason}}
    end
  end

  defp prepare_execution_routing(%Context{}), do: :ok

  @doc "Returns true when the context includes a ProjectView."
  @spec project_view?(context()) :: boolean()
  def project_view?(%Context{project_view: %ProjectView{}}), do: true
  def project_view?(%Context{}), do: false

  @doc "Returns a short label for routed workspace output."
  @spec workspace_label(context()) :: String.t() | nil
  def workspace_label(%Context{project_view: %ProjectView{} = view}) do
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

  def workspace_label(%Context{}), do: nil

  @doc "Returns true if any routing is active."
  @spec active?(context()) :: boolean()
  def active?(%Context{project_view: %ProjectView{}}), do: true

  def active?(%Context{fork_store: fs, changeset: cs}) do
    (fs != nil and Process.alive?(fs)) or (cs != nil and Process.alive?(cs))
  end

  def active?(_), do: false

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

  @spec read_file_changeset_or_passthrough(context(), String.t()) ::
          {:ok, binary()} | {:error, term()} | :passthrough
  defp read_file_changeset_or_passthrough(%Context{changeset: cs}, path)
       when cs != nil and is_pid(cs) do
    with :ok <- changeset_available(cs),
         {:ok, relative} <- normalize_changeset_path(cs, path, false) do
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

  @spec fetch_command_forks(pid()) ::
          {:ok, %{String.t() => pid()}} | {:error, {:fork_unavailable, term()}}
  defp fetch_command_forks(fork_store) do
    {:ok, BufferForkStore.all(fork_store)}
  catch
    :exit, reason -> {:error, {:fork_unavailable, reason}}
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

  @spec materialize_forks_for_command(context()) :: :ok | {:error, term()}
  defp materialize_forks_for_command(%Context{fork_store: nil}), do: :ok

  defp materialize_forks_for_command(%Context{fork_store: fs, changeset: cs})
       when fs != nil and cs != nil do
    with {:ok, forks} <- fetch_command_forks(fs) do
      materialize_command_forks(forks, cs)
    end
  end

  @spec materialize_command_forks(%{String.t() => pid()}, pid()) :: :ok | {:error, term()}
  defp materialize_command_forks(forks, changeset) do
    Enum.reduce_while(forks, :ok, fn {path, fork_pid}, :ok ->
      case materialize_fork_for_command(changeset, path, fork_pid) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec materialize_fork_for_command(pid(), String.t(), pid()) :: :ok | {:error, term()}
  defp materialize_fork_for_command(changeset, path, fork_pid) do
    with {:ok, relative_path} <- normalize_changeset_path(changeset, path, false) do
      Changeset.materialize_command_file(
        changeset,
        relative_path,
        Minga.Buffer.Fork.content(fork_pid)
      )
    end
  end

  # ── Private: path normalization ─────────────────────────────────────────────

  @spec normalize_changeset_path(pid(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp normalize_changeset_path(cs, path, allow_root?) do
    root = Changeset.project_root(cs)
    target = Path.expand(path, root)
    normalize_changeset_target(root, target, allow_root?)
  end

  @spec normalize_changeset_target(String.t(), String.t(), boolean()) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_traversal}
  defp normalize_changeset_target(root, root, true), do: {:ok, "."}
  defp normalize_changeset_target(root, root, false), do: {:error, :invalid_path}

  defp normalize_changeset_target(root, target, _allow_root?) do
    if String.starts_with?(target, root <> "/") do
      {:ok, Path.relative_to(target, root)}
    else
      {:error, :path_traversal}
    end
  end
end
