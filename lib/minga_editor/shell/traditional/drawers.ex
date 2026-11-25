defmodule MingaEditor.Shell.Traditional.Drawers do
  @moduledoc """
  The bottom drawers and which one is showing: one drawer at a time, the way Doom's popups behave.

  Opening a drawer while another is open hides the open one beneath it; closing the top drawer brings back the one it replaced. `stack` is ordered top first, so the head is the drawer on screen.

  The Messages panel (`MingaEditor.BottomPanel`) keeps its own visibility for the frontends that draw it; it joins the stack as `:messages`, and the shell keeps the two in step (`MingaEditor.Shell.Traditional.State.install_bottom_panel/2`).

  The tasks drawer's own presentation state lives here too: the selected row, by identity; what the drawer shows (`view`: the list, or the diff or the output of one row's task, scrolled to `offset`); a stop waiting for confirmation (`pending`); and the moment before which single-letter keys are ignored after the drawer opened on its own.
  """

  @typedoc "A kind of drawer."
  @type kind :: :tasks | :messages

  @typedoc "What the tasks drawer shows: its list, or one row's request diff or output."
  @type view :: :list | {:diff, String.t()} | {:output, String.t()}

  @type t :: %__MODULE__{
          stack: [kind()],
          focused?: boolean(),
          selected: String.t() | nil,
          empty_selected: non_neg_integer(),
          view: view(),
          offset: non_neg_integer(),
          pending: {:stop, String.t(), {String.t(), String.t()}} | nil,
          prefix: Minga.Keymap.Bindings.node_t() | nil,
          armed_at: integer() | nil
        }

  defstruct stack: [],
            focused?: false,
            selected: nil,
            empty_selected: 0,
            view: :list,
            offset: 0,
            pending: nil,
            prefix: nil,
            armed_at: nil

  @doc "The drawer on screen, or nil when none is."
  @spec top(t()) :: kind() | nil
  def top(%__MODULE__{stack: [top | _rest]}), do: top
  def top(%__MODULE__{stack: []}), do: nil

  @doc "True when `kind` is the drawer on screen."
  @spec showing?(t(), kind()) :: boolean()
  def showing?(%__MODULE__{} = drawers, kind), do: top(drawers) == kind

  @doc "True when `kind` is on screen and has the keyboard."
  @spec focused?(t(), kind()) :: boolean()
  def focused?(%__MODULE__{focused?: focused?} = drawers, kind),
    do: focused? and showing?(drawers, kind)

  @doc "The drawer `kind` hides, if any: the one directly beneath it."
  @spec hidden_under(t(), kind()) :: kind() | nil
  def hidden_under(%__MODULE__{stack: [kind, under | _rest]}, kind), do: under
  def hidden_under(%__MODULE__{}, _kind), do: nil

  @doc """
  Puts `kind` on screen with the keyboard, hiding the drawer that was showing beneath it.

  A drawer already in the stack moves to the top instead of appearing twice. Returns the drawer it hid, or nil.
  """
  @spec open(t(), kind()) :: {t(), kind() | nil}
  def open(%__MODULE__{stack: stack} = drawers, kind) do
    hidden = top(drawers)
    stack = [kind | List.delete(stack, kind)]
    hidden = if hidden == kind, do: nil, else: hidden
    {%{drawers | stack: stack, focused?: true}, hidden}
  end

  @doc """
  Closes `kind`. When it was on screen, the drawer it replaced comes back with the keyboard; that drawer is returned, or nil.
  """
  @spec close(t(), kind()) :: {t(), kind() | nil}
  def close(%__MODULE__{stack: [kind | rest]} = drawers, kind) do
    revealed = List.first(rest)

    {%{
       drawers
       | stack: rest,
         focused?: revealed != nil,
         armed_at: nil,
         view: :list,
         offset: 0,
         pending: nil,
         empty_selected: 0
     }, revealed}
  end

  def close(%__MODULE__{stack: stack} = drawers, kind),
    do: {%{drawers | stack: List.delete(stack, kind)}, nil}

  @doc "Gives the keyboard back to the window the drawer was opened from; the drawer stays on screen."
  @spec blur(t()) :: t()
  def blur(%__MODULE__{} = drawers), do: %{drawers | focused?: false}

  @doc "Gives the drawer on screen the keyboard."
  @spec focus(t()) :: t()
  def focus(%__MODULE__{stack: []} = drawers), do: drawers
  def focus(%__MODULE__{} = drawers), do: %{drawers | focused?: true}

  @doc "Selects one of the empty state's next steps by its index, for a drawer with no tasks."
  @spec select_empty(t(), non_neg_integer()) :: t()
  def select_empty(%__MODULE__{} = drawers, index) when is_integer(index) and index >= 0,
    do: %{drawers | empty_selected: index}

  @doc "Selects a tasks drawer row by its identity."
  @spec select(t(), String.t() | nil) :: t()
  def select(%__MODULE__{} = drawers, row_id) when is_binary(row_id) or is_nil(row_id),
    do: %{drawers | selected: row_id}

  @doc "Shows `view` in the tasks drawer, scrolled to the top, with no stop pending."
  @spec show(t(), view()) :: t()
  def show(%__MODULE__{} = drawers, view), do: %{drawers | view: view, offset: 0, pending: nil}

  @doc "Scrolls the diff or output view to `offset`."
  @spec scroll(t(), non_neg_integer()) :: t()
  def scroll(%__MODULE__{} = drawers, offset) when is_integer(offset) and offset >= 0,
    do: %{drawers | offset: offset}

  @doc "Remembers the start of a two-key drawer binding (`]h`), or clears it with nil."
  @spec await_key(t(), Minga.Keymap.Bindings.node_t() | nil) :: t()
  def await_key(%__MODULE__{} = drawers, prefix), do: %{drawers | prefix: prefix}

  @doc "Asks to confirm stopping the turn `target` the task on row `row_id` showed; nil clears the question."
  @spec confirm_stop(t(), {String.t(), {String.t(), String.t()}} | nil) :: t()
  def confirm_stop(%__MODULE__{} = drawers, nil), do: %{drawers | pending: nil}

  def confirm_stop(%__MODULE__{} = drawers, {row_id, target}) when is_binary(row_id),
    do: %{drawers | pending: {:stop, row_id, target}}

  @doc """
  Ignores single-letter actions until `until_ms`, for a drawer that opened on its own (from a notification), so a letter typed elsewhere cannot answer an approval.
  """
  @spec arm(t(), integer()) :: t()
  def arm(%__MODULE__{} = drawers, until_ms) when is_integer(until_ms),
    do: %{drawers | armed_at: until_ms}

  @doc "True while single-letter actions are still ignored at wall-clock time `now`."
  @spec arming?(t(), integer()) :: boolean()
  def arming?(%__MODULE__{armed_at: nil}, _now), do: false
  def arming?(%__MODULE__{armed_at: until_ms}, now), do: now < until_ms
end
