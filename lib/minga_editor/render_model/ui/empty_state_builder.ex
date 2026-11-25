defmodule MingaEditor.RenderModel.UI.EmptyStateBuilder do
  @moduledoc """
  Builds the project home render model, `*home*` (#4056), from workspace state, and the empty-state anatomy every empty list surface shows (`empty_list/4`).

  Pure over the `MingaEditor.State.Launchpad` snapshot: project, git and recent data were captured when the home was entered, so no filesystem or process calls happen per frame except cheap ETS keymap reads. Minga's tasks come from the frame's task rows (`MingaEditor.Agent.Tasks`). Chords are resolved from the live keymap so hints always match user overrides.
  """

  alias Minga.Keymap.Active
  alias Minga.Keymap.Bindings
  alias Minga.Language.Devicon
  alias Minga.Language.Filetype
  alias Minga.RenderModel.UI.EmptyList
  alias Minga.RenderModel.UI.EmptyState
  alias Minga.RenderModel.UI.EmptyState.Item
  alias Minga.RenderModel.UI.EmptyState.Section
  alias MingaEditor.Agent.Tasks.Entry
  alias MingaEditor.Frontend.Emit.Context
  alias MingaEditor.State.Launchpad
  alias MingaEditor.State.Windows

  @typedoc """
  One next step of an empty list: the command it runs and its label, with the key that runs it when the surface's own scope binds a bare key. Without a key, the key is the command's leader sequence from the live keymap.
  """
  @type step :: {atom(), String.t()} | {atom(), String.t(), String.t()}

  @doc """
  Builds the empty-state anatomy a list surface shows when it is empty (`docs/design/surfaces.md`, "Empty states and notices with actions"): what happened, why, and the next steps, with the first preselected.

  Each action's id is the command it runs, so a click sends it as the existing `execute_command` GUI action and needs no surface code. Options: `glyph:` (the state glyph before the title) and `selected:` (the preselected action, 0 by default).
  """
  @spec empty_list(String.t(), String.t(), [step()], keyword()) :: EmptyList.t()
  def empty_list(title, why, steps, opts \\ [])
      when is_binary(title) and is_binary(why) and is_list(steps) do
    %EmptyList{
      glyph: Keyword.get(opts, :glyph, ""),
      title: title,
      why: why,
      actions: next_steps(steps),
      selected: Keyword.get(opts, :selected, 0)
    }
  end

  @doc "The actions for next steps, each with its key from the live keymap unless the step names its own; a notice names its next steps with these too."
  @spec next_steps([step()]) :: [EmptyList.Action.t()]
  def next_steps(steps) when is_list(steps), do: Enum.map(steps, &action/1)

  @spec action(step()) :: EmptyList.Action.t()
  defp action({command, label}), do: action({command, label, Active.leader_key(command)})

  defp action({command, label, key})
       when is_atom(command) and is_binary(label) and is_binary(key),
       do: %EmptyList.Action{id: Atom.to_string(command), key: key, label: label}

  @spec build(Context.t()) :: EmptyState.t()
  def build(
        %Context{workspace: %{launchpad: %Launchpad{} = home}, windows: %Windows{} = windows} =
          ctx
      ) do
    case Windows.active_struct(windows) do
      %{content: {:empty, :semantic}} ->
        {status, note} = header_lines(home)

        %EmptyState{
          visible?: true,
          focused_id: home.focused_id,
          title: title(home),
          # Outside a project there is no path to show; the status line says so.
          path: if(home.root, do: display_path(home.root), else: ""),
          status: status,
          note: note,
          sections: sections(home, tasks(ctx, home), keymap_server(ctx))
        }

      _other ->
        %EmptyState{visible?: false}
    end
  end

  def build(%Context{}), do: %EmptyState{visible?: false}

  @doc "The buffer name the modeline shows while the home is in the active window."
  @spec buffer_name() :: String.t()
  def buffer_name, do: "*home*"

  @doc "A path as the home shows it: under the home directory it starts with `~`, as a shell prompt shows it."
  @spec display_path(String.t() | nil) :: String.t()
  def display_path(nil), do: "~"

  def display_path(path) when is_binary(path) do
    home = System.user_home() || ""

    cond do
      home == "" -> path
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
      true -> path
    end
  end

  @spec title(Launchpad.t()) :: String.t()
  defp title(%Launchpad{root: nil}), do: "Minga"
  defp title(%Launchpad{root: root}), do: Path.basename(root)

  @spec header_lines(Launchpad.t()) :: {String.t(), String.t()}
  defp header_lines(%Launchpad{place: :outside}), do: {"No project here.", ""}

  defp header_lines(%Launchpad{place: :folder}) do
    {"Not a project: no .git, mix.exs, package.json or other marker here.",
     "Minga uses this folder as the root for now."}
  end

  defp header_lines(%Launchpad{place: :project, git: nil}), do: {"", ""}

  defp header_lines(%Launchpad{place: :project, git: %{branch: branch, changed: 0}}),
    do: {branch, ""}

  defp header_lines(%Launchpad{place: :project, git: %{branch: branch, changed: changed}}),
    do: {"#{branch} · #{changed} changed", ""}

  @spec sections(Launchpad.t(), [Launchpad.task()], GenServer.server()) :: [Section.t()]
  defp sections(%Launchpad{place: :outside} = home, tasks, keymap) do
    Enum.reject(
      [project_section(home), task_section(tasks), next_section(home, keymap)],
      &is_nil/1
    )
  end

  defp sections(%Launchpad{} = home, tasks, keymap) do
    Enum.reject(
      [recent_section(home), task_section(tasks), next_section(home, keymap)],
      &is_nil/1
    )
  end

  @spec recent_section(Launchpad.t()) :: Section.t()
  defp recent_section(%Launchpad{place: place, recents: recents}) do
    title = if place == :folder, do: "Recent in this folder", else: "Recent in this project"

    items =
      recents
      |> Enum.with_index(1)
      |> Enum.map(fn {path, i} ->
        {icon, color} = Devicon.icon_and_color(Filetype.detect(path))

        %Item{
          id: Launchpad.recent_id(i),
          kind: :recent_file,
          label: Path.basename(path),
          detail: directory(path),
          jump_key: Integer.to_string(i),
          icon: icon,
          icon_color: color
        }
      end)

    %Section{id: :recent, title: title, empty: "Nothing opened here yet.", items: items}
  end

  @spec project_section(Launchpad.t()) :: Section.t()
  defp project_section(%Launchpad{projects: projects} = home) do
    items =
      projects
      |> Enum.with_index(1)
      |> Enum.map(fn {root, i} ->
        %Item{
          id: Launchpad.project_id(i),
          kind: :project,
          label: Path.basename(root),
          detail: display_path(root),
          meta: if(Launchpad.waiting?(home, root), do: "unsaved text to recover", else: ""),
          jump_key: Integer.to_string(i)
        }
      end)

    %Section{id: :projects, title: "Recent projects", empty: "No projects yet.", items: items}
  end

  # Minga's tasks, as the shared task model names and states them, so the home, the drawer and the modeline agree.
  @spec task_section([Launchpad.task()]) :: Section.t() | nil
  defp task_section([]), do: nil

  defp task_section(tasks) do
    now = System.os_time(:millisecond)

    items =
      Enum.map(tasks, fn {workspace_id, %Entry{} = entry} ->
        %Item{
          id: Launchpad.task_id(workspace_id),
          kind: :task,
          label: Entry.title(entry),
          detail: Entry.words(entry, now),
          state: Entry.state(entry)
        }
      end)

    %Section{id: :tasks, title: "Minga tasks", items: items}
  end

  @spec next_section(Launchpad.t(), GenServer.server()) :: Section.t()
  defp next_section(%Launchpad{} = home, keymap) do
    trie = leader_trie(keymap)

    items =
      Enum.map(Launchpad.actions(home), fn {command, label} ->
        %Item{
          id: Launchpad.action_id(command),
          kind: :action,
          label: label,
          chord: leader_chord(trie, command)
        }
      end)

    %Section{id: :next, title: "Next", items: items}
  end

  @spec tasks(Context.t(), Launchpad.t()) :: [Launchpad.task()]
  defp tasks(%Context{intent: %{frame: %{home_tasks: tasks}}}, _home) when is_list(tasks),
    do: tasks

  defp tasks(%Context{}, _home), do: []

  @spec directory(String.t()) :: String.t()
  defp directory(path) do
    case Path.dirname(path) do
      "." -> ""
      dir -> dir
    end
  end

  # The keymap the frame was built with, so the home's chords match the keys this editor runs.
  @spec keymap_server(Context.t()) :: GenServer.server()
  defp keymap_server(%Context{intent: %{frame: %{keymap_server: nil}}}), do: Active
  defp keymap_server(%Context{intent: %{frame: %{keymap_server: server}}}), do: server
  defp keymap_server(%Context{}), do: Active

  @spec leader_trie(GenServer.server()) :: Bindings.node_t() | nil
  defp leader_trie(keymap) do
    Active.leader_trie(keymap)
  catch
    :exit, _ -> nil
  end

  # The shortest binding reads best in the key column (`SPC SPC` over `SPC p f`).
  @spec leader_chord(Bindings.node_t() | nil, atom()) :: String.t()
  defp leader_chord(nil, _command), do: ""

  defp leader_chord(trie, command) do
    case Bindings.sequences_for_command(trie, command) do
      [] -> ""
      sequences -> "SPC " <> Bindings.format_sequence(Enum.min_by(sequences, &length/1))
    end
  end
end
