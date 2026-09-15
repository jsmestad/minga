defmodule MingaEditor.UI.Picker.DirectorySource do
  @moduledoc """
  Asynchronous shallow filesystem source for the general file finder.

  Each fetch lists one explicitly named directory. It never recurses, activates a project, changes
  process cwd, or opens a file without confirmation.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Language
  alias Minga.Language.Devicon
  alias Minga.Project.Root
  alias MingaEditor.UI.Picker.FilesystemCandidate
  alias MingaEditor.UI.Picker.FilesystemContext
  alias MingaEditor.UI.Picker.FilesystemQuery
  alias MingaEditor.UI.Picker.Item

  @impl true
  @spec title() :: String.t()
  def title, do: "Find file"

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec gui_preview?() :: boolean()
  def gui_preview?, do: false

  @impl true
  @spec candidates(MingaEditor.UI.Picker.Context.t()) :: [Item.t()]
  def candidates(context) do
    case async_fetch(context) do
      {:ok, items, _meta} -> items
      {:error, _reason} -> []
    end
  end

  @impl true
  @spec async_fetch(MingaEditor.UI.Picker.Context.t()) ::
          {:ok, [Item.t()], map()} | {:error, String.t()}
  def async_fetch(%{picker_ui: %{context: %FilesystemContext{query: query}}}) do
    with {:ok, directory} <- FilesystemQuery.directory(query),
         {:ok, names} <- list_directory(directory) do
      items = build_items(query, directory, visible_names(names, query))
      {:ok, items, %{}}
    end
  end

  def async_fetch(_context), do: {:error, "Filesystem finder context is unavailable"}

  @doc "Rebinds already loaded entries for a new query over the same directory without I/O."
  @spec rebind([Item.t()], FilesystemQuery.t()) :: [Item.t()]
  def rebind(items, %FilesystemQuery{} = query) when is_list(items) do
    Enum.map(items, &rebind_item(&1, query))
  end

  @doc "Returns whether a candidate belongs to the current filesystem query."
  @spec current_candidate?(FilesystemCandidate.t(), FilesystemContext.t()) :: boolean()
  def current_candidate?(
        %FilesystemCandidate{query_identity: identity, parent_directory: parent_directory},
        %FilesystemContext{
          query: %FilesystemQuery{
            identity: identity,
            resolution: {:browse, parent_directory, _leaf}
          }
        }
      ),
      do: true

  def current_candidate?(%FilesystemCandidate{}, %FilesystemContext{}), do: false

  @doc "Builds the next source context when a directory or parent entry is confirmed."
  @spec navigate(FilesystemCandidate.t(), FilesystemContext.t()) ::
          {:ok, FilesystemContext.t()} | {:error, String.t()}
  def navigate(
        %FilesystemCandidate{kind: :directory, path: path} = candidate,
        %FilesystemContext{query: query} = context
      ) do
    if current_candidate?(candidate, context) do
      {:ok, FilesystemContext.new(FilesystemQuery.for_directory(query.session, path))}
    else
      {:error, "File finder result changed; select the entry again"}
    end
  end

  def navigate(%FilesystemCandidate{}, %FilesystemContext{}),
    do: {:error, "Selected entry is not a directory"}

  @impl true
  @spec selection_disposition(Item.t(), term()) ::
          MingaEditor.UI.Picker.Source.selection_disposition()
  def selection_disposition(
        %Item{id: %FilesystemCandidate{} = candidate},
        %FilesystemContext{} = context
      ) do
    selection_disposition(candidate.kind, candidate, context)
  end

  def selection_disposition(%Item{}, _context),
    do: {:reject, "Filesystem finder result is unavailable"}

  @impl true
  @spec on_select(Item.t(), MingaEditor.State.t()) :: MingaEditor.State.t()
  def on_select(%Item{} = item, state) do
    case open(item, state) do
      {:ok, new_state} -> new_state
      {:error, new_state, _message} -> new_state
    end
  end

  @doc "Opens a current file candidate through the normal buffer authority."
  @spec open(Item.t(), MingaEditor.State.t()) ::
          {:ok, MingaEditor.State.t()} | {:error, MingaEditor.State.t(), String.t()}
  def open(%Item{id: %FilesystemCandidate{kind: :file} = candidate}, state) do
    case canonical_regular_file(candidate.path) do
      {:ok, canonical_path} ->
        open_canonical_file(state, candidate.path, canonical_path)

      {:error, reason} ->
        message = "Could not open #{candidate.path}: #{format_reason(reason)}"
        {:error, publish_open_error(state, message), message}
    end
  end

  def open(%Item{}, state),
    do: {:error, state, "Selected entry is not a file"}

  @spec open_canonical_file(MingaEditor.State.t(), String.t(), String.t()) ::
          {:ok, MingaEditor.State.t()} | {:error, MingaEditor.State.t(), String.t()}
  defp open_canonical_file(state, selected_path, canonical_path) do
    opts = [existing_target: :tab, start_opts: [history_attribution: :caller_managed]]

    case MingaEditor.Handlers.BufferRegistry.open_or_activate_path(state, canonical_path, opts) do
      {:ok, new_state, _pid, _status} ->
        {:ok, new_state}

      {:error, reason} ->
        message = "Could not open #{selected_path}: #{format_reason(reason)}"
        {:error, publish_open_error(state, message), message}
    end
  end

  @spec canonical_regular_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  defp canonical_regular_file(path) do
    with {:ok, canonical_path} <- Root.canonical_path(path),
         {:ok, %File.Stat{type: type}} <- File.stat(canonical_path),
         :ok <- require_regular_file(type) do
      {:ok, canonical_path}
    end
  end

  @spec require_regular_file(atom()) :: :ok | {:error, :eisdir | :not_regular}
  defp require_regular_file(:regular), do: :ok
  defp require_regular_file(:directory), do: {:error, :eisdir}
  defp require_regular_file(_type), do: {:error, :not_regular}

  @impl true
  @spec on_cancel(MingaEditor.State.t()) :: MingaEditor.State.t()
  def on_cancel(state), do: MingaEditor.UI.Picker.Source.restore_or_keep(state)

  @impl true
  @spec actions(Item.t()) :: [MingaEditor.UI.Picker.Source.action_entry()]
  def actions(%Item{id: %FilesystemCandidate{kind: :directory}}), do: [{"Open folder", :open}]
  def actions(%Item{id: %FilesystemCandidate{kind: :file}}), do: [{"Open", :open}]
  def actions(%Item{}), do: []

  @impl true
  @spec on_action(term(), Item.t(), MingaEditor.State.t()) :: MingaEditor.State.t()
  def on_action(:open, item, state), do: on_select(item, state)
  def on_action(_action, _item, state), do: state

  @spec list_directory(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp list_directory(directory) do
    case File.ls(directory) do
      {:ok, names} -> {:ok, names}
      {:error, :enoent} -> {:error, "Directory does not exist: #{directory}"}
      {:error, :enotdir} -> {:error, "Not a directory: #{directory}"}
      {:error, :eacces} -> {:error, "Directory is not readable: #{directory}"}
      {:error, reason} -> {:error, "Could not list #{directory}: #{:file.format_error(reason)}"}
    end
  end

  @spec visible_names([String.t()], FilesystemQuery.t()) :: [String.t()]
  defp visible_names(names, query) do
    exact_leaf = FilesystemQuery.filter_text(query)

    Enum.reject(names, fn name ->
      String.starts_with?(name, ".") and name != exact_leaf
    end)
  end

  @spec build_items(FilesystemQuery.t(), String.t(), [String.t()]) :: [Item.t()]
  defp build_items(query, directory, names) do
    children =
      names
      |> Enum.flat_map(&build_child(query, directory, &1))
      |> Enum.sort_by(&sort_key/1)

    parent_item(query, directory) ++ children
  end

  @spec build_child(FilesystemQuery.t(), String.t(), String.t()) :: [Item.t()]
  defp build_child(query, directory, name) do
    path = Path.join(directory, name)

    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> [item(query, directory, path, name, :directory)]
      {:ok, %File.Stat{type: :regular}} -> [item(query, directory, path, name, :file)]
      {:ok, %File.Stat{}} -> []
      {:error, _reason} -> []
    end
  end

  @spec parent_item(FilesystemQuery.t(), String.t()) :: [Item.t()]
  defp parent_item(_query, "/"), do: []

  defp parent_item(query, directory) do
    [item(query, directory, Path.dirname(directory), "..", :directory)]
  end

  @spec item(FilesystemQuery.t(), String.t(), String.t(), String.t(), FilesystemCandidate.kind()) ::
          Item.t()
  defp item(query, directory, path, name, kind) do
    candidate = FilesystemCandidate.new(query.identity, directory, path, kind)
    {icon, color} = icon(kind, name)

    %Item{
      id: candidate,
      label: "#{icon} #{name}",
      description: "",
      icon_color: color,
      search_text: name,
      two_line: true,
      meta: %{filesystem_kind: kind}
    }
  end

  @spec rebind_item(Item.t(), FilesystemQuery.t()) :: Item.t()
  defp rebind_item(%Item{id: %FilesystemCandidate{} = candidate} = item, query) do
    rebound = FilesystemCandidate.rebind(candidate, query.identity)
    %{item | id: rebound}
  end

  defp rebind_item(%Item{} = item, _query), do: item

  @spec icon(FilesystemCandidate.kind(), String.t()) :: {String.t(), non_neg_integer()}
  defp icon(:directory, _name), do: {"󰉋", 0x61AFEF}
  defp icon(:file, name), do: Devicon.icon_and_color(Language.detect_filetype(name))

  @spec sort_key(Item.t()) :: {non_neg_integer(), String.t()}
  defp sort_key(%Item{id: %FilesystemCandidate{kind: :directory}, search_text: name}),
    do: {0, String.downcase(name)}

  defp sort_key(%Item{search_text: name}), do: {1, String.downcase(name)}

  @spec publish_open_error(MingaEditor.State.t(), String.t()) :: MingaEditor.State.t()
  defp publish_open_error(state, message),
    do: MingaEditor.Shell.Traditional.NoticeWorkflow.publish(state, message)

  @spec format_reason(term()) :: String.t()
  defp format_reason(:enoent), do: "file does not exist"
  defp format_reason(:eacces), do: "file is not readable"
  defp format_reason(:eisdir), do: "entry is now a directory"
  defp format_reason(reason), do: inspect(reason)

  @spec selection_disposition(
          FilesystemCandidate.kind(),
          FilesystemCandidate.t(),
          FilesystemContext.t()
        ) :: MingaEditor.UI.Picker.Source.selection_disposition()
  defp selection_disposition(:file, candidate, context) do
    if current_candidate?(candidate, context),
      do: :accept,
      else: {:reject, "File finder result changed; select the entry again"}
  end

  defp selection_disposition(:directory, candidate, context) do
    case navigate(candidate, context) do
      {:ok, next_context} -> {:stay_open, next_context}
      {:error, message} -> {:reject, message}
    end
  end
end
