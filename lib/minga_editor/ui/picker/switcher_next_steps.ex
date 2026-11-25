defmodule MingaEditor.UI.Picker.SwitcherNextSteps do
  @moduledoc """
  The next steps the switcher (`SPC ,`) and the file pickers offer when a query matches nothing: create the file the query names, or search the project for the query.

  The prompt owns every typed key, so these are result rows reached with `⌃J` / `⌃K`, never chords. Create is first, so `↩` on a query with no match creates the file (`docs/design/keys.md`, "File switcher").
  """

  alias MingaEditor.Shell.Traditional.NoticeWorkflow
  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.ProjectSearchSource

  @typedoc "A switcher next step, carried in the row's item id."
  @type step :: {:create, relative_path :: String.t()} | {:search_project, String.t()}

  @doc """
  The offer for a query that matched nothing, or `nil` for an empty query. `searched` says what was searched, such as `"3 open buffers"`.
  """
  @spec empty(String.t(), String.t()) :: Empty.t() | nil
  def empty(query, searched) when is_binary(query) and is_binary(searched) do
    case String.trim(query) do
      "" ->
        nil

      name ->
        %Empty{
          title: "Nothing matches #{Empty.quoted(name)}.",
          why: "Searched #{searched}.",
          rows: [
            Empty.row({:create, name}, "Create #{name}", "new file"),
            Empty.row(
              {:search_project, name},
              "Search the project for #{name}",
              Minga.Keymap.Active.leader_key(:search_project)
            )
          ]
        }
    end
  end

  @doc "Counts a noun for the why line: `1 open buffer`, `3 open buffers`."
  @spec count(non_neg_integer(), String.t()) :: String.t()
  def count(1, noun), do: "1 #{noun}"
  def count(n, noun) when is_integer(n) and n >= 0, do: "#{n} #{noun}s"

  @doc "Runs a next step after the picker closes."
  @spec run(Item.t(), MingaEditor.State.t()) :: MingaEditor.State.t()
  def run(%Item{id: {:next_step, {:create, relative}}}, state), do: create(state, relative)

  def run(%Item{id: {:next_step, {:search_project, query}}}, state),
    do: ProjectSearchSource.search(state, query)

  # Buffers open existing files, so Create makes the file and its folders first, as the file tree's New file does.
  # A file that already exists is opened, never touched; a folder is not a file to create.
  @spec create(MingaEditor.State.t(), String.t()) :: MingaEditor.State.t()
  defp create(state, relative) do
    path = Path.expand(relative, project_root(state))

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> open(state, path, relative)
      {:ok, %File.Stat{}} -> NoticeWorkflow.publish(state, "#{relative} is not a file")
      {:error, :enoent} -> create_file(state, path, relative)
      {:error, reason} -> could_not_create(state, path, relative, reason)
    end
  end

  @spec create_file(MingaEditor.State.t(), String.t(), String.t()) :: MingaEditor.State.t()
  defp create_file(state, path, relative) do
    backend = state.interaction.file_tree_new_file_backend

    with :ok <- backend.mkdir_p(Path.dirname(path)),
         :ok <- backend.touch(path) do
      open(state, path, relative)
    else
      {:error, reason} -> could_not_create(state, path, relative, reason)
    end
  end

  @spec open(MingaEditor.State.t(), String.t(), String.t()) :: MingaEditor.State.t()
  defp open(state, path, relative) do
    case MingaEditor.Handlers.BufferRegistry.open_or_activate_path(state, path) do
      {:ok, new_state, _pid, _status} -> new_state
      {:error, reason} -> could_not_create(state, path, relative, reason)
    end
  end

  @spec could_not_create(MingaEditor.State.t(), String.t(), String.t(), term()) ::
          MingaEditor.State.t()
  defp could_not_create(state, path, relative, reason) do
    Minga.Log.warning(:editor, "Could not create #{path}: #{inspect(reason)}")
    NoticeWorkflow.publish(state, "Could not create #{relative}")
  end

  # The directory workspace, or without one the root this editor's file tree opened on.
  @spec project_root(MingaEditor.State.t()) :: String.t()
  defp project_root(state) do
    Minga.Project.resolve_root() || MingaEditor.Session.State.project_root(state.workspace) ||
      File.cwd!()
  end
end
