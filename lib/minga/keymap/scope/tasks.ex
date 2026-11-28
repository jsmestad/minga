defmodule Minga.Keymap.Scope.Tasks do
  @moduledoc """
  Keymap scope for `*minga-tasks*`, the tasks drawer.

  The drawer is a special buffer: nothing in it takes typed text, so single letters act (design rule 3). `j` / `k` and the arrows move, `y` `a` `t` `n` answer the selected task's approval the way the conversation does and `=` shows what it would change, `c` starts a new task, `r` retries, `o` shows output, `i` inspects, `x` stops after asking, `↩` opens the conversation, and `q` or `esc` steps back, then closes. `n` is deny, so a new task is `c`. Leader sequences still reach `SPC`.

  `MingaEditor.Input.TasksDrawer` resolves keys here while the drawer has the keyboard, so user overrides for `{:tasks, :normal}` apply.
  """

  # Like a picker's or a prompt's, these keys resolve only in their own handler.
  # The drawer is never the workspace scope.
  use Minga.Keymap.Scope.Builder,
    name: :tasks,
    display_name: "Tasks",
    modal: true

  alias Minga.Keymap.Bindings

  import Minga.Keymap.Sigil

  @arrow_up 57_352
  @arrow_down 57_353
  @arrow_up_mac 0xF700
  @arrow_down_mac 0xF701

  @impl true
  @spec keymap(Minga.Keymap.Scope.vim_state(), Minga.Keymap.Scope.context()) ::
          Bindings.node_t()
  def keymap(state, _context) when state in [:normal, :cua], do: trie()
  def keymap(_state, _context), do: Bindings.new()

  @impl true
  @spec shared_keymap() :: Bindings.node_t()
  def shared_keymap, do: Bindings.new()

  @impl true
  @spec help_groups(atom()) :: [Minga.Keymap.Scope.help_group()]
  def help_groups(_focus) do
    [
      {"Tasks",
       [
         {"j / k", "Move"},
         {"y", "Approve once"},
         {"a", "Always for this session"},
         {"t", "This turn"},
         {"n", "Deny"},
         {"=", "Show the request's diff"},
         {"c", "New task"},
         {"r", "Retry"},
         {"o", "Output"},
         {"i", "Inspect"},
         {"x", "Stop, after asking"},
         {"↩", "Open the conversation, or review a done task"},
         {"]h / [h", "Next / previous change in a diff"},
         {"q / esc", "Back, then close"}
       ]}
    ]
  end

  @spec trie() :: Bindings.node_t()
  defp trie do
    Bindings.new()
    |> Bindings.bind(~k(j), :tasks_next, "Next task")
    |> Bindings.bind(~k(k), :tasks_prev, "Previous task")
    |> Bindings.bind([{@arrow_down, 0}], :tasks_next, "Next task")
    |> Bindings.bind([{@arrow_down_mac, 0}], :tasks_next, "Next task")
    |> Bindings.bind([{@arrow_up, 0}], :tasks_prev, "Previous task")
    |> Bindings.bind([{@arrow_up_mac, 0}], :tasks_prev, "Previous task")
    |> Bindings.bind(~k(y), :tasks_approve, "Approve once")
    |> Bindings.bind(~k(a), :tasks_approve_session, "Always for this session")
    |> Bindings.bind(~k(t), :tasks_approve_turn, "This turn")
    |> Bindings.bind(~k(n), :tasks_deny, "Deny")
    |> Bindings.bind(~k(=), :tasks_show_diff, "Show diff")
    |> Bindings.bind(~k(c), :tasks_new, "New task")
    |> Bindings.bind(~k(r), :tasks_retry, "Retry")
    |> Bindings.bind(~k(o), :tasks_output, "Output")
    |> Bindings.bind(~k(i), :tasks_inspect, "Inspect")
    |> Bindings.bind(~k(x), :tasks_stop, "Stop")
    |> Bindings.bind(~k(RET), :tasks_open, "Open")
    |> Bindings.bind(~k(g .), :tasks_act_menu, "Act on the selected task")
    |> Bindings.bind(~k(] h), :tasks_next_change, "Next change")
    |> Bindings.bind(~k([ h), :tasks_prev_change, "Previous change")
    |> Bindings.bind(~k(q), :tasks_back, "Back or close")
    |> Bindings.bind(~k(ESC), :tasks_back, "Back or close")
  end
end
