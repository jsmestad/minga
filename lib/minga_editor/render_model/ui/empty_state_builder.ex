defmodule MingaEditor.RenderModel.UI.EmptyStateBuilder do
  @moduledoc """
  Builds the launchpad render model from workspace state (#2689).

  Pure over the `MingaEditor.State.Launchpad` snapshot: session and recents
  data were captured when the empty state was entered, so no filesystem or
  process calls happen per frame except cheap ETS keymap reads. Chords are
  resolved from the live keymap so hints always match user overrides.
  """

  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings
  alias Minga.Language.Devicon
  alias Minga.Language.Filetype
  alias Minga.RenderModel.UI.EmptyState
  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.State.Launchpad
  alias MingaEditor.State.Windows
  alias MingaEditor.Window.Content

  # {item id, label, leader-bound command} for the start section, in order.
  @actions [
    {"action-find-file", "open file", :find_file},
    {"action-file-tree", "file tree", :toggle_file_tree},
    {"action-palette", "command palette", :command_palette}
  ]

  @spec build(Context.t()) :: EmptyState.t()
  def build(%Context{workspace: %{launchpad: %Launchpad{} = lp}, windows: %Windows{} = windows}) do
    with %{content: content} <- Windows.active_struct(windows),
         true <- Content.empty?(content) do
      %EmptyState{
        visible?: true,
        crashed?: lp.crashed?,
        focused_id: lp.focused_id,
        version: version(),
        sections: sections(lp)
      }
    else
      _other -> %EmptyState{visible?: false}
    end
  end

  def build(%Context{}), do: %EmptyState{visible?: false}

  @spec sections(Launchpad.t()) :: [Section.t()]
  defp sections(%Launchpad{} = lp) do
    [session_section(lp), recent_section(lp), start_section(lp), footer_section(lp)]
    |> Enum.reject(&(&1.items == []))
  end

  @spec session_section(Launchpad.t()) :: Section.t()
  defp session_section(%Launchpad{session_file_count: 0} = lp) do
    if first_run?(lp) do
      %Section{
        id: :session,
        title: "Get started",
        items: [
          %Item{
            id: "action-tutor",
            kind: :action,
            label: "open the tutorial",
            detail: ":Tutor",
            jump_key: "RET"
          }
        ]
      }
    else
      %Section{id: :session, items: []}
    end
  end

  defp session_section(%Launchpad{} = lp) do
    {title, label} =
      if lp.crashed? do
        {"Crashed session", "restore session"}
      else
        {"Session", "resume last session"}
      end

    %Section{
      id: :session,
      title: title,
      items: [
        %Item{
          id: Launchpad.resume_id(),
          kind: :resume,
          label: label,
          detail: file_count_label(lp.session_file_count),
          jump_key: "r"
        }
      ]
    }
  end

  @spec recent_section(Launchpad.t()) :: Section.t()
  defp recent_section(%Launchpad{recents: recents}) do
    items =
      recents
      |> Enum.with_index(1)
      |> Enum.map(fn {path, i} ->
        {icon, color} = Devicon.icon_and_color(Filetype.detect(path))

        %Item{
          id: Launchpad.recent_id(i),
          kind: :recent_file,
          label: Path.basename(path),
          detail: Path.dirname(path),
          jump_key: Integer.to_string(i),
          icon: icon,
          icon_color: color
        }
      end)

    %Section{id: :recent, title: "Recent", items: items}
  end

  @spec start_section(Launchpad.t()) :: Section.t()
  defp start_section(%Launchpad{} = lp) do
    trie = leader_trie()

    action_items =
      Enum.map(@actions, fn {id, label, command} ->
        {icon, color} = action_icon(command)

        %Item{
          id: id,
          kind: :action,
          label: label,
          chord: leader_chord(trie, command),
          icon: icon,
          icon_color: color
        }
      end)

    items =
      if first_run?(lp) do
        action_items
      else
        Enum.concat(action_items, [
          %Item{id: "action-tutor", kind: :action, label: "tutorial", detail: ":Tutor"}
        ])
      end

    %Section{id: :start, title: "Start", items: items}
  end

  @spec footer_section(Launchpad.t()) :: Section.t()
  defp footer_section(%Launchpad{} = lp) do
    write_label = if first_run?(lp), do: "to start writing", else: "write"
    quit_label = if first_run?(lp), do: "to quit", else: "quit"

    %Section{
      id: :footer,
      items: [
        %Item{id: "hint-write", kind: :hint, label: write_label, jump_key: "i"},
        %Item{id: "hint-quit", kind: :hint, label: quit_label, detail: ":q"}
      ]
    }
  end

  @spec first_run?(Launchpad.t()) :: boolean()
  defp first_run?(%Launchpad{session_file_count: 0, recents: []}), do: true
  defp first_run?(%Launchpad{}), do: false

  @spec file_count_label(pos_integer()) :: String.t()
  defp file_count_label(1), do: "1 file"
  defp file_count_label(n), do: "#{n} files"

  @spec leader_trie() :: Bindings.node_t() | nil
  defp leader_trie do
    Active.leader_trie()
  catch
    :exit, _ -> nil
  end

  @spec leader_chord(Bindings.node_t() | nil, atom()) :: String.t()
  defp leader_chord(nil, _command), do: ""

  defp leader_chord(trie, command) do
    case Bindings.sequences_for_command(trie, command) do
      [keys | _rest] -> "SPC " <> Bindings.format_sequence(keys)
      [] -> ""
    end
  end

  @spec action_icon(atom()) :: {String.t(), non_neg_integer()}
  defp action_icon(:find_file), do: {"\u{F0224}", 0x61AFEF}
  defp action_icon(:toggle_file_tree), do: {"\u{F0256}", 0x78909C}
  defp action_icon(:command_palette), do: {"\u{F0633}", 0x51AFEF}
  defp action_icon(_command), do: {"", 0}

  @spec version() :: String.t()
  defp version do
    case Application.spec(:minga, :vsn) do
      vsn when is_list(vsn) -> "v" <> List.to_string(vsn)
      _ -> ""
    end
  end
end
