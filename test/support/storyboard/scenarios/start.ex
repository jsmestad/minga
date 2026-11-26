defmodule Minga.Test.Storyboard.Scenarios.Start do
  @moduledoc """
  Registry entries for the `start` journey: launch, opening a project, quitting.

  `start.open_dir.home` is the factory's cold start: `minga .` in a project with no saved session.
  """

  import ExUnit.Assertions
  import Minga.Test.Storyboard.Assertions

  alias Minga.Test.Storyboard.Check
  alias Minga.Test.Storyboard.Entry
  alias Minga.Test.Storyboard.Model

  @doc "Every `start` entry."
  @spec entries() :: [Entry.t()]
  def entries do
    [
      Entry.built("start.empty",
        reach: "",
        # The recent project has a saved session, so opening it picks up where you left off.
        start: [place: :outside, restored: true],
        recognize: &home_view?(&1, :outside),
        click_reach: [],
        checks: [
          Check.new(
            "the home says there is no project here",
            &assert_header(&1, "Minga", "No project here.")
          ),
          Check.new("recent projects are numbered from 1", &assert_numbered(&1, :projects)),
          Check.new(
            "the next actions are Switch project, Find a file and Add a project, with their keys",
            &assert_actions(&1, [
              {"SPC p p", "Switch project"},
              {"SPC f f", "Find a file"},
              {"SPC p a", "Add a project"}
            ])
          ),
          Check.new("the modeline names the home", &assert_buffer_name/1)
        ]
      ),
      Entry.built("start.open_dir.home",
        reach: "",
        recognize: &home_view?(&1, :project),
        click_reach: [],
        checks: [
          Check.new("the home names the project and its path", &assert_names_root/1),
          Check.new(
            "recent files in the project are numbered from 1",
            &assert_numbered(&1, :recent)
          ),
          Check.new(
            "the next actions with their keys, the first one a file search",
            &assert_actions(&1, [
              {"SPC SPC", "Find a file"},
              {"SPC a n", "New task"},
              {"SPC o p", "File tree"},
              {"SPC p p", "Switch project"}
            ])
          ),
          Check.new("the first row is preselected", &assert_focused(&1, "recent-1")),
          Check.new("the modeline names the home", &assert_buffer_name/1)
        ]
      ),
      Entry.built("start.open_dir.restored",
        reach: "",
        start: [restored: true],
        recognize: &restored?/1,
        click_reach: [],
        checks: [
          Check.new(
            "the echo says what came back",
            &assert_echo(&1, ~r/^Restored 1 file from last time/)
          ),
          Check.new("the restored split is back", &assert_split/1)
        ]
      ),
      Entry.pending(
        "start.open_dir.subdir",
        4056,
        "opening a subdirectory goes to the project root"
      ),
      Entry.built("start.open_dir.not_project",
        reach: "",
        start: [place: :folder],
        recognize: &home_view?(&1, :folder),
        click_reach: [],
        checks: [
          Check.new(
            "the home says the folder is not a project, in one line",
            &assert_status(&1, ~r/^Not a project/)
          ),
          Check.new(
            "nothing recent yet, said in words",
            &assert_empty(&1, :recent, "Nothing opened here yet.")
          ),
          Check.new(
            "the file tree is the first action",
            &assert_focused(&1, "action-toggle_file_tree")
          )
        ]
      ),
      Entry.built("start.project_switcher.empty",
        reach: "SPC p p",
        recognize: &Model.empty_picker?(&1, ~r/switch project/i, ~r/^No projects yet/),
        checks: [
          Check.new(
            "no known projects says how Minga learns them and offers the next steps",
            fn model ->
              assert_empty_state(model,
                title: "No projects yet.",
                description: "Minga remembers folders you open.",
                actions: [{"SPC p a", "Add a folder"}, {"SPC f f", "Open a file"}]
              )
            end
          )
        ]
      ),
      Entry.pending(
        "start.quit.confirm",
        4056,
        "the quit prompt lists what is at stake with s, d and esc"
      ),
      Entry.pending("start.quit.farewell", 4056, "the one-line farewell")
    ]
  end

  @doc "True when the frame shows the project home for `place`: a project, a folder without markers, or no project."
  @spec home_view?(Model.t(), :project | :folder | :outside) :: boolean()
  def home_view?(%Model{ui: %{empty_state: %{visible?: true} = home}} = model, place) do
    place_of(home) == place and not Model.transient_open?(model)
  end

  def home_view?(%Model{}, _place), do: false

  @spec place_of(Minga.RenderModel.UI.EmptyState.t()) :: :project | :folder | :outside
  defp place_of(%{status: "No project here."}), do: :outside
  defp place_of(%{status: "Not a project" <> _}), do: :folder
  defp place_of(_home), do: :project

  # The restored session is plain editing in a split, with the echo saying what came back.
  @spec restored?(Model.t()) :: boolean()
  defp restored?(%Model{echo: echo} = model) when is_binary(echo) do
    String.starts_with?(echo, "Restored ") and model.mode == :normal and
      not Model.transient_open?(model)
  end

  defp restored?(%Model{}), do: false

  @spec assert_header(Model.t(), String.t(), String.t()) :: Model.t()
  defp assert_header(%Model{ui: %{empty_state: home}} = model, title, status) do
    assert {home.title, home.status} == {title, status}
    model
  end

  @spec assert_names_root(Model.t()) :: Model.t()
  defp assert_names_root(%Model{ui: %{empty_state: home}} = model) do
    assert home.title != "" and home.title == Path.basename(home.path)
    model
  end

  @spec assert_status(Model.t(), Regex.t()) :: Model.t()
  defp assert_status(%Model{ui: %{empty_state: home}} = model, pattern) do
    assert home.status =~ pattern
    model
  end

  @spec assert_numbered(Model.t(), atom()) :: Model.t()
  defp assert_numbered(%Model{} = model, section_id) do
    keys = model |> section(section_id) |> Map.fetch!(:items) |> Enum.map(& &1.jump_key)
    assert keys != [] and keys == Enum.map(1..length(keys), &Integer.to_string/1)
    model
  end

  @spec assert_actions(Model.t(), [{String.t(), String.t()}]) :: Model.t()
  defp assert_actions(%Model{} = model, expected) do
    actions = model |> section(:next) |> Map.fetch!(:items) |> Enum.map(&{&1.chord, &1.label})
    assert actions == expected
    model
  end

  @spec assert_empty(Model.t(), atom(), String.t()) :: Model.t()
  defp assert_empty(%Model{} = model, section_id, text) do
    assert %{items: [], empty: ^text} = section(model, section_id)
    model
  end

  @spec assert_focused(Model.t(), String.t()) :: Model.t()
  defp assert_focused(%Model{ui: %{empty_state: home}} = model, id) do
    assert home.focused_id == id
    model
  end

  @spec assert_buffer_name(Model.t()) :: Model.t()
  defp assert_buffer_name(%Model{} = model) do
    names = for %{id: :filename, text: text} <- Model.modeline_segments(model), do: text
    assert names == ["*home*"]
    model
  end

  @spec assert_echo(Model.t(), Regex.t()) :: Model.t()
  defp assert_echo(%Model{echo: echo} = model, pattern) do
    assert echo =~ pattern
    model
  end

  @spec assert_split(Model.t()) :: Model.t()
  defp assert_split(%Model{ui: ui} = model) do
    assert [_one] = ui.split_separators.verticals
    model
  end

  @spec section(Model.t(), atom()) :: map()
  defp section(%Model{ui: %{empty_state: home}}, id) do
    Enum.find(home.sections, &(&1.id == id)) || flunk("no #{id} section in the home")
  end
end
