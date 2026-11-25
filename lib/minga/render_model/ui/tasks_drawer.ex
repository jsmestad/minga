defmodule Minga.RenderModel.UI.TasksDrawer do
  @moduledoc """
  Semantic model of `*minga-tasks*`, the bottom drawer that lists every task Minga is working on.

  The BEAM decides everything the drawer says: the rows in order, each row's state, words and age, which row is selected, the one action each row offers, the request a needs-you row expands to show, the state counts in the header and the key hints. Frontends draw it: a real split along the bottom of the window (`docs/design/anatomy.md`, "Drawer" and "List row"), with the state shapes and glyphs from the design tokens. `Minga.Frontend.Adapter.GUI.TasksDrawerEncoder` owns the wire encoding.

  `note` names a drawer this one hid ("Messages hidden · q returns"), or is empty. `view` is what the drawer shows: its list, or one task's request diff or output, as `view_title` and `view_lines` scrolled to `view_offset`. `prompt` is a question the drawer is asking ("Stop …? y stop · n keep"), or empty. `empty` is the empty-state anatomy when there are no tasks.
  """

  alias __MODULE__.Row

  @typedoc "A state and how many tasks and subagents show it, for the header."
  @type count :: {Minga.Design.Tokens.state_id(), pos_integer()}

  @typedoc ~S(A key and what it does: `{"y", "Approve once"}`.)
  @type hint :: {key :: String.t(), label :: String.t()}

  @type t :: %__MODULE__{
          visible?: boolean(),
          focused?: boolean(),
          name: String.t(),
          title: String.t(),
          note: String.t(),
          counts: [count()],
          rows: [Row.t()],
          hints: [hint()],
          view: :list | :diff | :output,
          view_title: String.t(),
          view_lines: [String.t()],
          view_offset: non_neg_integer(),
          prompt: String.t(),
          empty: Minga.RenderModel.UI.EmptyList.t() | nil
        }

  defstruct visible?: false,
            focused?: false,
            name: "*minga-tasks*",
            title: "Minga Tasks",
            note: "",
            counts: [],
            rows: [],
            hints: [],
            view: :list,
            view_title: "",
            view_lines: [],
            view_offset: 0,
            prompt: "",
            empty: nil

  @doc "The drawer when it is not on screen."
  @spec hidden() :: t()
  def hidden, do: %__MODULE__{}

  @doc "The selected row, if any."
  @spec selected(t()) :: Row.t() | nil
  def selected(%__MODULE__{rows: rows}), do: Enum.find(rows, & &1.selected?)
end
