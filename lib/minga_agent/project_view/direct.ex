# credo:disable-for-this-file Credo.Check.Refactor.RedundantWithClauseResult

defmodule MingaAgent.ProjectView.Direct do
  @moduledoc """
  Direct project view backend.

  Legacy non-model writes mutate the project root immediately. Conditional mutations use an owned overlay view, including unsaved open-buffer drafts, and publish through its reconciliation path.
  """

  @behaviour MingaAgent.ProjectView.Backend

  alias Minga.Buffer.Document
  alias Minga.Buffer.Replace
  alias MingaAgent.ProjectView
  alias MingaAgent.ProjectView.Overlay
  alias MingaAgent.ProjectView.Source

  @type direct_state :: %{
          modified: MapSet.t(String.t()),
          deleted: MapSet.t(String.t()),
          owned_view: ProjectView.t()
        }

  @doc "Creates a direct backend view."
  @spec create(String.t(), keyword()) :: {:ok, ProjectView.t()} | {:error, term()}
  def create(project_root, opts \\ []) when is_binary(project_root) do
    root = Path.expand(project_root)

    if File.dir?(root) do
      with {:ok, owned_view} <- Overlay.create(root, opts),
           {:ok, ref} <- start_tracking_view(owned_view) do
        {:ok, ProjectView.new(__MODULE__, root, ref, opts)}
      end
    else
      {:error, {:not_a_directory, root}}
    end
  end

  @spec start_tracking_view(ProjectView.t()) :: GenServer.on_start()
  defp start_tracking_view(owned_view) do
    Agent.start_link(fn ->
      %{modified: MapSet.new(), deleted: MapSet.new(), owned_view: owned_view}
    end)
  end

  @impl true
  @spec read_file(ProjectView.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(%ProjectView{} = view, relative_path) do
    with {:ok, owned} <- owned_view(view), do: Overlay.read_file(owned, relative_path)
  end

  @impl true
  @spec resolve_source(ProjectView.t(), String.t()) :: {:ok, Source.t()} | {:error, term()}
  def resolve_source(%ProjectView{} = view, relative_path) do
    with {:ok, owned} <- owned_view(view), do: Overlay.resolve_source(owned, relative_path)
  end

  @impl true
  @spec conditional_mutate(
          ProjectView.t(),
          String.t(),
          Minga.Buffer.FileMutation.expectation(),
          Minga.Buffer.FileMutation.operation()
        ) :: {:ok, Minga.Buffer.FileMutation.Receipt.t()} | {:error, term()}
  def conditional_mutate(%ProjectView{} = view, relative_path, expected, operation) do
    with {:ok, owned} <- owned_view(view) do
      Overlay.conditional_mutate(owned, relative_path, expected, operation)
    end
  end

  @impl true
  @spec write_file(ProjectView.t(), String.t(), binary()) :: :ok | {:error, term()}
  def write_file(%ProjectView{} = view, relative_path, content) do
    target = target_path(view, relative_path)

    with :ok <- ensure_tracking_agent_available(view),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target, content),
         :ok <- track_modified(view, relative_path) do
      :ok
    end
  end

  @impl true
  @spec edit_file(ProjectView.t(), String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def edit_file(%ProjectView{} = view, relative_path, old_text, new_text) do
    with {:ok, content} <- read_file(view, relative_path),
         {:ok, edited_doc, _msg} <- Replace.apply(Document.new(content), old_text, new_text, nil),
         :ok <- write_file(view, relative_path, Document.content(edited_doc)) do
      :ok
    end
  end

  @impl true
  @spec delete_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def delete_file(%ProjectView{} = view, relative_path) do
    target = target_path(view, relative_path)

    with :ok <- ensure_tracking_agent_available(view),
         :ok <- File.rm(target),
         :ok <- track_deleted(view, relative_path) do
      :ok
    end
  end

  @impl true
  @spec list_directory(ProjectView.t(), String.t()) ::
          {:ok, [ProjectView.Backend.directory_entry()]} | {:error, term()}
  def list_directory(%ProjectView{} = view, relative_path) do
    with {:ok, owned} <- owned_view(view), do: Overlay.list_directory(owned, relative_path)
  end

  @impl true
  @spec working_dir(ProjectView.t()) :: String.t()
  def working_dir(%ProjectView{project_root: project_root}), do: project_root

  @impl true
  @spec prepare_working_dir(ProjectView.t()) :: {:ok, String.t()} | {:error, term()}
  def prepare_working_dir(%ProjectView{} = view) do
    with {:ok, owned} <- owned_view(view) do
      case Overlay.diff(owned) do
        {:ok, []} -> {:ok, view.project_root}
        {:ok, [_ | _]} -> Overlay.prepare_working_dir(owned)
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  @spec command_env(ProjectView.t()) :: [{String.t(), String.t()}] | {:error, term()}
  def command_env(%ProjectView{} = view) do
    with {:ok, owned} <- owned_view(view) do
      case Overlay.diff(owned) do
        {:ok, []} -> []
        {:ok, [_ | _]} -> Overlay.command_env(owned)
        {:error, _} = error -> error
      end
    end
  end

  @impl true
  @spec diff(ProjectView.t()) :: {:ok, [map()]} | {:error, term()}
  def diff(%ProjectView{} = view) do
    state = Agent.get(view.ref, & &1)

    modified =
      state.modified
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&%{path: &1, kind: :modified})

    deleted =
      state.deleted
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map(&%{path: &1, kind: :deleted})

    with {:ok, entries} <- Overlay.diff(state.owned_view) do
      {:ok, Enum.uniq_by(entries ++ modified ++ deleted, & &1.path)}
    end
  end

  @impl true
  @spec promote(ProjectView.t(), term()) :: :ok | {:conflict, map()} | {:error, term()}
  def promote(%ProjectView{} = view, :project_root) do
    with {:ok, owned} <- owned_view(view) do
      case Overlay.diff(owned) do
        {:ok, []} -> :ok
        {:ok, [_ | _]} -> Overlay.promote(owned, :project_root)
        {:error, _} = error -> error
      end
    end
  end

  def promote(%ProjectView{project_root: root} = view, target) when is_binary(target) do
    if Path.expand(target) == root,
      do: promote(view, :project_root),
      else: {:error, {:unsupported_target, target}}
  end

  def promote(%ProjectView{}, target), do: {:error, {:unsupported_target, target}}

  @impl true
  @spec discard_file(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  def discard_file(%ProjectView{} = _view, _relative_path) do
    {:error, :discard_not_supported}
  end

  @impl true
  @spec discard(ProjectView.t()) :: :ok | {:error, term()}
  def discard(%ProjectView{} = _view) do
    {:error, :discard_not_supported}
  end

  @impl true
  @spec close(ProjectView.t()) :: :ok | {:error, term()}
  def close(%ProjectView{} = view) do
    with {:ok, owned} <- owned_view(view),
         :ok <- Overlay.close(owned) do
      Agent.stop(view.ref)
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  @spec capabilities(ProjectView.t()) :: ProjectView.Backend.capabilities()
  def capabilities(%ProjectView{}) do
    %{
      isolation: :none,
      mutates_project_root: true,
      supports_promote: true,
      supports_discard: false,
      supports_command_env: true
    }
  end

  @spec target_path(ProjectView.t(), String.t()) :: String.t()
  defp target_path(%ProjectView{project_root: project_root}, relative_path) do
    Path.join(project_root, relative_path)
  end

  @spec owned_view(ProjectView.t()) :: {:ok, ProjectView.t()} | {:error, term()}
  defp owned_view(%ProjectView{} = view) do
    {:ok, Agent.get(view.ref, & &1.owned_view)}
  catch
    :exit, reason -> {:error, {:direct_view_unavailable, reason}}
  end

  @spec ensure_tracking_agent_available(ProjectView.t()) :: :ok | {:error, term()}
  defp ensure_tracking_agent_available(%ProjectView{} = view) do
    if Process.alive?(view.ref) do
      :ok
    else
      {:error, {:direct_view_unavailable, :agent_dead}}
    end
  end

  @spec track_modified(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  defp track_modified(%ProjectView{} = view, relative_path) do
    Agent.update(view.ref, fn state ->
      state
      |> Map.update!(:modified, &MapSet.put(&1, relative_path))
      |> Map.update!(:deleted, &MapSet.delete(&1, relative_path))
    end)

    :ok
  catch
    :exit, reason -> {:error, {:direct_view_unavailable, reason}}
  end

  @spec track_deleted(ProjectView.t(), String.t()) :: :ok | {:error, term()}
  defp track_deleted(%ProjectView{} = view, relative_path) do
    Agent.update(view.ref, fn state ->
      state
      |> Map.update!(:modified, &MapSet.delete(&1, relative_path))
      |> Map.update!(:deleted, &MapSet.put(&1, relative_path))
    end)

    :ok
  catch
    :exit, reason -> {:error, {:direct_view_unavailable, reason}}
  end
end
