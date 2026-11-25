defmodule MingaEditor.UI.Picker.ProjectSearchSource do
  @moduledoc """
  Picker source for project-wide search results.

  The scan runs off the editor input path: this source is async, so
  `PickerUI.open/3` shows the picker immediately with a "Searching…" indicator
  and `async_fetch/1` runs `Minga.Project.ProjectSearch.search/2` in a background
  task. The query is read from the stashed `search.project_query`. Each match is
  embedded directly in its `Item.id`, so selecting a result resolves the file and
  position without a separate cached-results lookup. When the in-process result
  cap is hit, the fetch reports a truncated status.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Buffer
  alias Minga.Language
  alias Minga.Language.Devicon
  alias Minga.Project.ProjectSearch
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Empty
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source

  @truncated_status "Results truncated to #{ProjectSearch.max_results()}"

  @impl true
  @spec title() :: String.t()
  def title, do: "Search project"

  @impl true
  @spec preview?() :: boolean()
  def preview?, do: true

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(ctx) do
    case async_fetch(ctx) do
      {:ok, items, _meta} -> items
      {:error, _reason} -> []
    end
  end

  @impl true
  @spec async_fetch(Context.t()) ::
          {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{search: %{project_query: query}} = ctx)
      when is_binary(query) and query != "" do
    search_project(query, Minga.Project.resolve_root() || file_tree_root(ctx))
  end

  def async_fetch(_ctx), do: {:ok, [], %{}}

  # Without a directory workspace, the next best root is the one this editor's file tree opened on.
  @spec file_tree_root(Context.t()) :: String.t() | nil
  defp file_tree_root(%Context{file_tree: %{project_root: root}}) when is_binary(root), do: root
  defp file_tree_root(%Context{}), do: nil

  @spec search_project(String.t(), String.t() | nil) ::
          {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  defp search_project(_query, nil), do: {:error, "No directory workspace active"}

  defp search_project(query, root) do
    case search_module().search(query, root) do
      {:ok, matches, truncated?} ->
        {:ok, build_items(matches, root), fetch_meta(truncated?)}

      {:error, message} ->
        {:error, message}
    end
  end

  # Each way to widen a search that found nothing.
  # A step lists what it adds, how the row reads, the key it teaches, and the flags that already cover it.
  @widen_steps [
    {["-u"], "Search ignored files too", "-- -u", [["-u"], ["-uu"], ["-uuu"]]},
    {["--hidden"], "Search hidden files too", "--hidden", [["--hidden"], ["-uu"], ["-uuu"]]},
    {["-uu"], "Search all files", "-- -uu", [["-uu"], ["-uuu"], ["-u", "--hidden"]]}
  ]

  @doc """
  When a search finds nothing, says what was searched and what was skipped, then offers the next wider search as rows: ignored files (`-- -u`), hidden files (`--hidden`), or every file (`-- -uu`). Each row reruns the same pattern with its flags added after `--`, as in Doom. Once nothing is left to widen, the one row edits the search instead.
  """
  @impl true
  @spec empty(Empty.request()) :: Empty.t() | nil
  # Results came back, but the filter matches none of them: say so and keep the prompt.
  def empty(%{context: %{project_query: query}, query: filter, total: total})
      when is_binary(query) and query != "" and total > 0 do
    {pattern, _flags} = ProjectSearch.parse_query(query)

    %Empty{
      title: "No result matches #{Empty.quoted(String.trim(filter))}.",
      why: "#{result_count(total)} for #{Empty.quoted(pattern)}; keep typing to filter them.",
      rows: [
        Empty.row(
          {:edit, query},
          "Change the search",
          Minga.Keymap.Active.leader_key(:search_project)
        )
      ]
    }
  end

  def empty(%{context: %{project_query: query}}) when is_binary(query) and query != "" do
    {pattern, flags} = ProjectSearch.parse_query(query)

    widen =
      for {added, label, key, covered_by} <- @widen_steps,
          not covered?(flags, covered_by),
          do: {added, label, key}

    %Empty{
      title: "No results for #{Empty.quoted(pattern)}.",
      why: skipped(widen),
      rows: next_steps(widen, pattern, flags, query)
    }
  end

  def empty(_request), do: nil

  @spec covered?([String.t()], [[String.t()]]) :: boolean()
  defp covered?(flags, covered_by),
    do: Enum.any?(covered_by, fn set -> Enum.all?(set, &(&1 in flags)) end)

  @spec skipped([{[String.t()], String.t(), String.t()}]) :: String.t()
  defp skipped(widen) do
    case Enum.map(widen, fn {added, _label, _key} -> added end) do
      [] -> "Every file was searched, ignored and hidden ones too."
      [["-u"], ["--hidden"] | _] -> "Ignored and hidden files were skipped."
      [["--hidden"] | _] -> "Hidden files were skipped."
      _ignored_only -> "Ignored files were skipped."
    end
  end

  @spec next_steps([{[String.t()], String.t(), String.t()}], String.t(), [String.t()], String.t()) ::
          [Item.t()]
  defp next_steps([], _pattern, _flags, query),
    do: [
      Empty.row(
        {:edit, query},
        "Change the search",
        Minga.Keymap.Active.leader_key(:search_project)
      )
    ]

  defp next_steps(widen, pattern, flags, _query) do
    for {added, label, key} <- widen do
      Empty.row({:search, pattern <> " -- " <> Enum.join(flags ++ added, " ")}, label, key)
    end
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{id: {:next_step, {:search, query}}}, state), do: search(state, query)

  def on_select(%Item{id: {:next_step, {:edit, query}}}, state) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.transition_mode(
            state.workspace,
            :search_prompt,
            %Minga.Mode.SearchPromptState{input: query}
          )
    }
  end

  def on_select(%Item{id: %{file: _file} = match}, state) do
    open_match(state, match)
  end

  def on_select(_item, state), do: state

  @impl true
  def on_cancel(state), do: Source.restore_or_keep(state)

  @doc "Runs a project search for `query` (flags after ` -- ` pass through to ripgrep) and opens its results."
  @spec search(MingaEditor.State.t(), String.t()) :: MingaEditor.State.t()
  def search(state, query) when is_binary(query) do
    %{
      state
      | workspace:
          MingaEditor.Session.State.set_search(
            state.workspace,
            MingaEditor.State.Search.set_project_query(state.workspace.search, query)
          )
    }
    |> MingaEditor.PickerUI.open(__MODULE__, %{project_query: query})
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  # The search runs in `root` and reports paths relative to it, so each item carries the absolute path.
  # Opening and previewing a match then never depend on the editor's working directory.
  @spec build_items([ProjectSearch.match()], String.t()) :: [Item.t()]
  defp build_items(matches, root) do
    Enum.map(matches, fn match ->
      filename = Path.basename(match.file)
      ft = Language.detect_filetype(filename)
      {icon, color} = Devicon.icon_and_color(ft)
      label = "#{icon} #{match.file}:#{match.line}"
      desc = String.trim(match.text)

      %Item{
        id: %{match | file: Path.expand(match.file, root)},
        label: label,
        description: desc,
        icon_color: color
      }
    end)
  end

  @spec result_count(pos_integer()) :: String.t()
  defp result_count(1), do: "1 result"
  defp result_count(total), do: "#{total} results"

  # Tests swap the search for a stub, so a storyboard scenario never spawns ripgrep while tests run concurrently.
  @spec search_module() :: module()
  defp search_module, do: Application.get_env(:minga, :project_search_module, ProjectSearch)

  @spec fetch_meta(boolean()) :: Source.fetch_meta()
  defp fetch_meta(true), do: %{status: @truncated_status}
  defp fetch_meta(false), do: %{}

  @spec open_match(map(), ProjectSearch.match()) :: map()
  defp open_match(state, match) do
    abs_path = Path.expand(match.file)
    line = max(match.line - 1, 0)
    col = match.col

    case MingaEditor.Handlers.BufferRegistry.open_or_activate_path(state, abs_path) do
      {:ok, new_state, pid, _status} ->
        Buffer.move_to(pid, {line, col})
        new_state

      {:error, reason} ->
        Minga.Log.error(:editor, "Failed to open file: #{inspect(reason)}")
        state
    end
  end
end
