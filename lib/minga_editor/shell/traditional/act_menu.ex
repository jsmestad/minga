defmodule MingaEditor.Shell.Traditional.ActMenu do
  @moduledoc "Owns one menu offer, its filter, and what its displayed choices can activate."

  alias Minga.Buffer.Process, as: BufferProcess
  alias Minga.Mode.VisualState
  alias Minga.RenderModel.UI.ActMenu, as: Model
  alias Minga.RenderModel.UI.ActMenu.Row
  alias MingaEditor.VimState.PendingKeep
  alias MingaEditor.Window

  @type file_source :: {Window.id(), pid(), non_neg_integer(), Minga.Buffer.position()}
  @type source ::
          {:file, file_source()}
          | {:review, file_source(), BufferProcess.review_target(), pos_integer(),
             PendingKeep.continuation()}
          | {:selection, file_source(), VisualState.t()}
          | {:picker, MingaEditor.PickerUI.act_source()}
          | {:file_tree, MingaEditor.Target.t()}
          | {:fold, Window.id(), pos_integer(), non_neg_integer(), pid(), non_neg_integer()}
          | {:prompt, pos_integer()}
          | {:input, atom(), term(), Window.id()}
          | {:composer, file_source(), MingaEditor.Agent.PromptInput.submission_owner() | nil,
             pos_integer() | nil}
          | {:approval, MingaAgent.ToolApproval.Target.t()}
          | {:task, String.t(), {pid(), MingaAgent.ToolApproval.Target.t()} | nil}
  @type action ::
          {:command, atom()}
          | :attach_file_diagnostics
          | {:review,
             :keep
             | :reject
             | :preview
             | :copy_link
             | :ask
             | :rewrite
             | {:conversation, String.t()}}
          | {:clipboard, :cut | :copy | :paste}
          | {:picker, :default | {:source, term()}}
          | {:fold, :toggle}
          | {:file_tree,
             :primary
             | :open_in_split
             | :new_file
             | :new_folder
             | :rename
             | :duplicate
             | :delete
             | :copy_path
             | :copy_relative
             | :reveal
             | :terminal}
          | {:prompt, String.t()}
          | {:input, 13 | 27}
          | {:composer, :submit | :newline}
          | {:approval, MingaAgent.Session.approval_decision()}
          | {:task, String.t()}
          | {:task_approval, MingaAgent.Session.approval_decision()}
  @type choice ::
          {String.t(), String.t(), String.t(), String.t(), String.t(), boolean(), action()}
  @type entry :: {Row.t(), action()}
  @opaque t :: %__MODULE__{
            id: pos_integer(),
            title: String.t(),
            role: Model.role(),
            anchor: Model.anchor() | nil,
            source: source(),
            lead: [entry()],
            rows: [entry()],
            query: String.t(),
            selected: pos_integer() | nil,
            filtering?: boolean()
          }

  @enforce_keys [:id, :title, :role, :anchor, :source, :lead, :rows, :selected]
  defstruct @enforce_keys ++ [query: "", filtering?: false]

  @spec new(String.t(), Model.role(), Model.anchor() | nil, source(), [choice()], [choice()]) ::
          t()
  def new(title, role, anchor, source, lead, rows) do
    lead = entries(lead, 1)
    {destructive, ordinary} = Enum.split_with(rows, &elem(&1, 5))
    rows = entries(ordinary ++ destructive, 1 + length(lead))

    %__MODULE__{
      id: System.unique_integer([:positive, :monotonic]),
      title: title,
      role: role,
      anchor: anchor,
      source: source,
      lead: lead,
      rows: rows,
      selected: first_safe(lead ++ rows)
    }
  end

  @spec source(t()) :: source()
  def source(%__MODULE__{source: source}), do: source

  @spec model(t()) :: Model.t()
  def model(%__MODULE__{} = menu) do
    {lead, rows} = visible(menu)

    %Model{
      id: menu.id,
      title: menu.title,
      role: menu.role,
      anchor: menu.anchor,
      query: menu.query,
      selected: menu.selected,
      lead: Enum.map(lead, &elem(&1, 0)),
      rows: Enum.map(rows, &elem(&1, 0))
    }
  end

  @spec begin_filter(t()) :: t()
  def begin_filter(%__MODULE__{} = menu), do: %{menu | filtering?: true}

  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = menu, text), do: put_query(menu, menu.query <> text)

  @spec backspace(t()) :: t()
  def backspace(%__MODULE__{} = menu), do: put_query(menu, String.slice(menu.query, 0..-2//1))

  @spec move(t(), -1 | 1) :: t()
  def move(%__MODULE__{} = menu, step) do
    entries = visible_entries(menu)
    current = Enum.find_index(entries, fn {row, _} -> row.id == menu.selected end)

    index =
      case {current, step} do
        {nil, -1} -> length(entries) - 1
        {nil, 1} -> 0
        {current, step} -> max(0, current + step)
      end

    case Enum.at(entries, index) do
      {row, _} -> %{menu | selected: row.id}
      nil -> menu
    end
  end

  @spec shortcut(t(), String.t()) :: action() | nil
  def shortcut(%__MODULE__{filtering?: true}, _key), do: nil

  def shortcut(%__MODULE__{} = menu, key) do
    Enum.find_value(visible_entries(menu), fn {row, action} -> row.key == key && action end)
  end

  @spec selected(t()) :: action() | nil
  def selected(%__MODULE__{} = menu), do: action(menu, menu.id, menu.selected)

  @spec action(t(), non_neg_integer(), non_neg_integer() | nil) :: action() | nil
  def action(%__MODULE__{id: offer} = menu, offer, id) do
    Enum.find_value(visible_entries(menu), fn {row, action} -> row.id == id && action end)
  end

  def action(%__MODULE__{}, _stale_offer, _action), do: nil

  @spec same_offer?(t(), non_neg_integer()) :: boolean()
  def same_offer?(%__MODULE__{id: offer}, offer), do: true
  def same_offer?(%__MODULE__{}, _offer), do: false

  @spec put_query(t(), String.t()) :: t()
  defp put_query(menu, query) do
    next = %{menu | query: query, filtering?: true}
    %{next | selected: first_safe(visible_entries(next))}
  end

  @spec visible(t()) :: {[entry()], [entry()]}
  defp visible(%__MODULE__{query: ""} = menu), do: {menu.lead, menu.rows}

  defp visible(%__MODULE__{query: query} = menu) do
    query = String.downcase(query)

    matches =
      Enum.filter(menu.lead ++ menu.rows, fn {row, _} ->
        String.contains?(String.downcase(row.label), query)
      end)

    {[], matches}
  end

  @spec visible_entries(t()) :: [entry()]
  defp visible_entries(menu) do
    {lead, rows} = visible(menu)
    lead ++ rows
  end

  @spec first_safe([entry()]) :: pos_integer() | nil
  defp first_safe(entries) do
    Enum.find_value(entries, fn {row, _} -> if !row.destructive?, do: row.id end)
  end

  @spec entries([choice()], pos_integer()) :: [entry()]
  defp entries(choices, first) do
    {entries, _} =
      Enum.map_reduce(choices, first, fn {section, key, label, hint, detail, dangerous?, action},
                                         id ->
        row = %Row{
          id: id,
          key: key,
          label: label,
          hint: hint,
          detail: detail,
          section: section,
          destructive?: dangerous?
        }

        {{row, action}, id + 1}
      end)

    entries
  end
end
