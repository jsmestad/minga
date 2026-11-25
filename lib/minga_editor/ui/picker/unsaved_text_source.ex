defmodule MingaEditor.UI.Picker.UnsavedTextSource do
  @moduledoc """
  Picker source that lists unsaved text waiting in swap files, so it can be recovered or discarded.

  A start recovers only the text of the project it opens. Everything else waits on disk: text of another project, of a project whose directory is gone, or text that was held back because its file changed afterwards. This list is where a person sees all of it and decides. Selecting a row puts the text into a buffer for its file, even when the file or its directory no longer exists. The act menu also offers to discard it, after a confirmation that says what is deleted.

  The scan reads every swap file and its file, so it runs in the picker's background task, never in the Editor process.
  """

  @behaviour MingaEditor.UI.Picker.Source

  alias Minga.Session
  alias MingaEditor.Handlers.SessionRestore
  alias MingaEditor.PromptUI
  alias MingaEditor.UI.Picker.Context
  alias MingaEditor.UI.Picker.Item
  alias MingaEditor.UI.Picker.Source
  alias MingaEditor.UI.Prompt.UnsavedTextDiscardConfirm

  @impl true
  @spec title() :: String.t()
  def title, do: "Unsaved text"

  @impl true
  @spec layout() :: Source.layout()
  def layout, do: :centered

  @impl true
  @spec async?() :: boolean()
  def async?, do: true

  @impl true
  @spec candidates(Context.t()) :: [Item.t()]
  def candidates(_context), do: []

  @impl true
  @spec async_fetch(Context.t()) :: {:ok, [Item.t()], Source.fetch_meta()} | {:error, String.t()}
  def async_fetch(%Context{picker_ui: %{context: %{swap_opts: swap_opts}}}) do
    {:ok, swap_opts |> Session.waiting_unsaved_text() |> items(System.os_time(:second)), %{}}
  end

  def async_fetch(%Context{}), do: {:ok, [empty_item()], %{}}

  @doc "Builds the rows for the waiting entries, or the one row that says nothing is waiting. `now` is in seconds."
  @spec items([Session.waiting_unsaved_text()], integer()) :: [Item.t()]
  def items([], _now), do: [empty_item()]

  def items(entries, now) do
    entries
    |> Enum.sort_by(&{is_nil(&1.project), &1.project})
    |> Enum.map(&item(&1, now))
  end

  @impl true
  @spec on_select(Item.t(), term()) :: term()
  def on_select(%Item{meta: %{entry: entry}}, state),
    do: SessionRestore.recover_waiting(state, entry)

  def on_select(%Item{}, state), do: state

  @impl true
  @spec actions(Item.t()) :: [Source.action_entry()]
  def actions(%Item{meta: %{entry: _entry}}), do: [{"Recover", :recover}, {"Discard", :discard}]
  def actions(%Item{}), do: []

  @impl true
  @spec on_action(term(), Item.t(), term()) :: term()
  def on_action(:recover, item, state), do: on_select(item, state)

  def on_action(:discard, %Item{meta: %{entry: entry}}, state) do
    PromptUI.open(state, UnsavedTextDiscardConfirm,
      label: UnsavedTextDiscardConfirm.label(entry),
      context: %{path: entry.path, swap_path: entry.swap_path}
    )
  end

  def on_action(_action, _item, state), do: state

  @spec item(Session.waiting_unsaved_text(), integer()) :: Item.t()
  defp item(entry, now) do
    %Item{
      id: entry.swap_path,
      label: label(entry),
      description: "#{difference(entry)} · #{age(now - entry.swap_mtime)}",
      group: group(entry),
      search_text: entry.path,
      meta: %{entry: entry}
    }
  end

  @spec empty_item() :: Item.t()
  defp empty_item do
    %Item{
      id: :empty,
      label: "No unsaved text is waiting",
      description: "Text kept after a crash is listed here until you recover or discard it."
    }
  end

  # A file inside a project is named from the project root, and the project names the section.
  @spec label(Session.waiting_unsaved_text()) :: String.t()
  defp label(%{project: nil, path: path}), do: home_relative(path)
  defp label(%{project: project, path: path}), do: Path.relative_to(path, project)

  @spec group(Session.waiting_unsaved_text()) :: String.t()
  defp group(%{project: nil}), do: "Outside a project"

  # The project's name comes first, so a narrow list that cuts the section header still tells projects apart.
  defp group(%{project: project}),
    do: "#{Path.basename(project)} · #{home_relative(Path.dirname(project))}"

  @spec home_relative(String.t()) :: String.t()
  defp home_relative(path) do
    home = Path.expand("~")

    case Path.relative_to(path, home) do
      ^path -> path
      relative -> Path.join("~", relative)
    end
  end

  # How the unsaved text stands against the file on disk.
  @spec difference(Session.waiting_unsaved_text()) :: String.t()
  defp difference(%{file_exists?: false} = entry), do: "#{lines(entry.lines)}, the file is gone"

  defp difference(%{changed_since?: true} = entry),
    do: "#{changed(entry)}, the file changed after this text was kept"

  defp difference(entry), do: changed(entry)

  @spec changed(Session.waiting_unsaved_text()) :: String.t()
  defp changed(%{changed_lines: nil, lines: count}), do: "#{lines(count)}, differs from the file"
  defp changed(%{changed_lines: 1}), do: "1 line differs"
  defp changed(%{changed_lines: count}), do: "#{count} lines differ"

  @spec lines(non_neg_integer()) :: String.t()
  defp lines(1), do: "1 line"
  defp lines(count), do: "#{count} lines"

  # When the text was written, to the coarsest unit that still tells two crashes apart.
  @spec age(integer()) :: String.t()
  defp age(seconds) when seconds < 60, do: "just now"
  defp age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min ago"
  defp age(seconds) when seconds < 86_400, do: "#{div(seconds, 3_600)} h ago"
  defp age(seconds) when seconds < 172_800, do: "1 day ago"
  defp age(seconds), do: "#{div(seconds, 86_400)} days ago"
end
