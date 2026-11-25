defmodule MingaAgent.WorkingFolder do
  @moduledoc """
  Where one Agent session may read, search, edit and run commands.

  A session works in a detected project, or in a plain folder the user chose by opening it or a file inside it. When neither exists, or the only candidate is as broad as the user's home directory or a filesystem or volume root, the session has no folder: it can still chat, and every tool that needs a folder answers with one fixed line.

  The caller that starts a session decides this value once and passes it down. Nothing below reads the process working directory: an application started from a desktop launcher has `/` there, which is not a folder the user chose.
  """

  alias Minga.Project
  alias Minga.Project.Detector
  alias Minga.Project.Root
  alias Minga.Project.Trust

  @typedoc """
  Why a session has no folder.

  A new conversation has none when nothing was opened (`:none`) or the only candidate is too broad to work in. Such a conversation can still chat.

  The other reasons belong to a restored conversation that cannot continue where it was restored: it works in another place than this session (`:elsewhere`, with the folder decision its record holds), its folder is gone, its folder is one Minga does not work in (`:refused`), or its record names none (`:not_recorded`). See `read_only?/1`.
  """
  @type reason ::
          :none
          | {:too_broad, String.t()}
          | {:elsewhere, t()}
          | {:gone, :project | :folder, String.t()}
          | {:refused, String.t()}
          | :not_recorded

  @typedoc "A folder as a saved conversation records it. `nil` is a record without a folder entry."
  @type stored :: %{optional(String.t()) => String.t()} | nil

  # The line of the system prompt that names the session's root, in the one form Minga writes it.
  # `recovered/1` reads the same form back from a record saved before folders were recorded.
  @root_line "- Project root: "
  @max_path_bytes 4096
  @root_line_in_prompt ~r/\n## Environment\n\n- Project root: ([^\n]*)(?:\n|\z)/

  @typedoc "A detected project, a plain folder, or no folder with the reason."
  @type t :: {:project, String.t()} | {:folder, String.t()} | {:unavailable, reason()}

  @typedoc "Tells what marks a root as a project: version control, another project marker, or nothing."
  @type evidence :: (String.t() -> :version_control | :marker | :none)

  @typedoc "The parts of a tool declaration that decide whether it runs without a folder."
  @type tool :: %{
          required(:name) => String.t(),
          required(:source) => term(),
          optional(atom()) => term()
        }

  # The tools known to stay away from the user's files. Every other tool needs a folder.
  @folder_free_tools [
    "ask_user",
    "todo_read",
    "todo_write",
    "describe_runtime",
    "describe_tools",
    "memory_read",
    "fetch_url"
  ]

  @doc """
  A project the caller detected or was given explicitly.

  A version-controlled project is trusted wherever it is, a repository rooted at the home directory included. Any other marker does not make a too-broad folder acceptable: a `package.json` or a `.minga` file in the home directory does not give Minga all of it. The breadth is judged by the canonical path, so a link to the home directory is as broad as the home directory.

  The private root of a session without a folder is not a project: a child session that inherits it has no folder either.

  `version_controlled?` tells whether a root is under version control. It is a parameter so a test can decide it without touching a real home directory.
  """
  @spec project(String.t()) :: t()
  @spec project(String.t(), (String.t() -> boolean())) :: t()
  def project(root, version_controlled? \\ &Detector.version_controlled?/1)

  def project(root, version_controlled?)
      when is_binary(root) and is_function(version_controlled?, 1) do
    if root == placeholder_root(),
      do: {:unavailable, :none},
      else: trusted_project(root, Trust.project_root(root, version_controlled?))
  end

  # `Minga.Project.Trust` holds the rule, shared with the configuration load.
  @spec trusted_project(String.t(), {:ok, String.t()} | {:error, Trust.refusal()}) :: t()
  defp trusted_project(root, {:ok, _canonical}), do: {:project, root}

  defp trusted_project(_root, {:error, {:too_broad, canonical}}),
    do: {:unavailable, {:too_broad, canonical}}

  # A root that does not resolve is not a place tools can reach. The caller's start fails on it as before.
  defp trusted_project(root, {:error, :unresolvable}), do: {:project, root}

  @spec classify_project(String.t(), String.t(), boolean()) :: t()
  defp classify_project(_root, canonical, true), do: {:unavailable, {:too_broad, canonical}}
  defp classify_project(root, _canonical, false), do: {:project, root}

  @doc """
  The private, empty directory a session without a folder uses as its root.

  Prompt assembly, skills and the editable view need some root. This one holds nothing of the user's, so nothing is in reach even if a tool ran.
  """
  @spec placeholder_root() :: String.t()
  def placeholder_root, do: Path.join(Minga.UserPaths.data_dir(), "no-folder")

  @doc """
  The root a session's internals use: its folder, or the private empty directory when it has none.

  The directory is created on first use and is readable by the user only.
  """
  @spec root_or_placeholder(t()) :: String.t()
  def root_or_placeholder({:unavailable, _reason}) do
    root = placeholder_root()
    File.mkdir_p!(root)
    :ok = File.chmod(root, 0o700)
    :ok = verify_placeholder(root)
    root
  end

  def root_or_placeholder({kind, root}) when kind in [:project, :folder], do: root

  @doc """
  A plain folder with no project marker: the folder the editor was opened on, or the folder of the file the task started from.

  The folder is compared by its canonical path, so a symlink to a broad folder is as broad as its target. A missing candidate, a relative path, or one that cannot be read as a directory, leaves the session without a folder.
  """
  @spec folder(String.t() | nil) :: t()
  def folder(nil), do: {:unavailable, :none}

  def folder(path) when is_binary(path) do
    case canonical_directory(path) do
      {:ok, canonical} -> classify(canonical, Trust.broad?(canonical))
      :error -> {:unavailable, :none}
    end
  end

  @doc """
  The folder a conversation gets at `root` today. The one decision for a new conversation and a restored one.

  A root under version control is a project wherever it is: a repository whose root is the home directory is a project like any other. A root with any other project marker is a project unless it is too broad, the rule of `project/2`. A root without a marker is a plain folder, and a plain folder as broad as the home directory or a filesystem root gives no folder. The root must be an absolute path to a directory that exists.

  A new conversation asks with the folder the editor has open. A restored one asks with the folder its record names, so a record is accepted exactly when starting there now would be.

  `evidence` tells what marks a root as a project. It is a parameter so a test can decide it without touching a real home directory.
  """
  @spec at(String.t() | nil) :: t()
  @spec at(String.t() | nil, evidence()) :: t()
  def at(root, evidence \\ &project_evidence/1)
  def at(nil, _evidence), do: {:unavailable, :none}

  def at(root, evidence) when is_binary(root) and is_function(evidence, 1) do
    case canonical_directory(root) do
      # The evidence is looked for where the root really is, the same directory the breadth is judged by.
      {:ok, canonical} -> at_directory(root, canonical, evidence.(canonical))
      :error -> {:unavailable, :none}
    end
  end

  @spec at_directory(String.t(), String.t(), :version_control | :marker | :none) :: t()
  defp at_directory(root, _canonical, :version_control), do: {:project, root}

  defp at_directory(root, canonical, :marker),
    do: classify_project(root, canonical, Trust.broad?(canonical))

  defp at_directory(_root, canonical, :none), do: classify(canonical, Trust.broad?(canonical))

  # What marks the root itself as a project, by the detector the editor uses to find projects.
  @spec project_evidence(String.t()) :: :version_control | :marker | :none
  defp project_evidence(root) do
    expanded = Path.expand(root)

    cond do
      Detector.version_controlled?(expanded) -> :version_control
      match?({:ok, ^expanded, _type}, Detector.detect(Path.join(expanded, "probe"))) -> :marker
      true -> :none
    end
  end

  @doc "The plain folder that holds `file_path`, under the same rules as `folder/1`."
  @spec for_file(String.t() | nil) :: t()
  def for_file(nil), do: {:unavailable, :none}
  def for_file(file_path) when is_binary(file_path), do: folder(Path.dirname(file_path))

  @doc "The system prompt line that names the root a session works in."
  @spec root_line(String.t()) :: String.t()
  def root_line(root) when is_binary(root), do: @root_line <> root

  @doc """
  The form a saved conversation records, or `nil` when there is nothing to record.

  A conversation without a folder is recorded with its reason, because its instructions quote that reason and it can only continue under the same instructions. A folder that is gone keeps its path, so the conversation works there again once the folder is back.
  """
  @spec stored(t()) :: stored()
  def stored({kind, root}) when kind in [:project, :folder],
    do: %{"kind" => Atom.to_string(kind), "root" => root}

  def stored({:unavailable, :none}), do: %{"kind" => "none"}
  def stored({:unavailable, {:too_broad, path}}), do: %{"kind" => "too_broad", "root" => path}
  def stored({:unavailable, {:refused, path}}), do: %{"kind" => "refused", "root" => path}

  def stored({:unavailable, {:gone, kind, root}}),
    do: %{"kind" => Atom.to_string(kind), "root" => root}

  # A conversation shown somewhere else keeps the folder its record names, never this session's.
  def stored({:unavailable, {:elsewhere, recorded}}), do: stored(recorded)
  def stored({:unavailable, :not_recorded}), do: nil

  @doc """
  The folder a saved conversation names, from what its record holds.

  The folder entry decides (`restored/2`). A record without one was saved before folders were recorded, and the system instructions it ran with name its folder (`recovered/2`). A record with neither and without history has never run a turn: it has no folder of its own yet, which is `:undecided`. History with neither names no folder, so that conversation is not one to continue.
  """
  @spec of_record(stored() | term(), [String.t()], boolean()) :: t() | :undecided
  @spec of_record(stored() | term(), [String.t()], boolean(), evidence()) :: t() | :undecided
  def of_record(entry, instructions, history?, evidence \\ &project_evidence/1)
  def of_record(nil, [], false, _evidence), do: :undecided
  def of_record(nil, [], true, _evidence), do: {:unavailable, :not_recorded}

  def of_record(nil, instructions, _history?, evidence) when is_list(instructions),
    do: recovered(instructions, evidence)

  def of_record(entry, _instructions, _history?, evidence), do: restored(entry, evidence)

  @doc """
  The folder a saved conversation names in its record's folder entry.

  The entry is input, and it gets the answer a new conversation would get there today, through `at/2`: the project marker is looked for again, a plain folder must not be too broad, and the directory must exist. What the record claims about the kind decides nothing. An entry that does not read as a folder, or a path with control characters, gives no folder.
  """
  @spec restored(stored() | term()) :: t()
  @spec restored(stored() | term(), evidence()) :: t()
  def restored(entry, evidence \\ &project_evidence/1)
  def restored(%{"kind" => "none"}, _evidence), do: {:unavailable, :none}

  def restored(%{"kind" => kind, "root" => root}, evidence) when is_binary(root) do
    if printable_path?(root),
      do: restored_entry(kind, root, evidence),
      else: {:unavailable, :not_recorded}
  end

  def restored(_missing_or_unreadable, _evidence), do: {:unavailable, :not_recorded}

  @spec restored_entry(term(), String.t(), evidence()) :: t()
  defp restored_entry("too_broad", path, _evidence), do: {:unavailable, {:too_broad, path}}
  defp restored_entry("refused", path, _evidence), do: {:unavailable, {:refused, path}}
  defp restored_entry("project", root, evidence), do: recorded_root(:project, root, evidence)
  defp restored_entry("folder", root, evidence), do: recorded_root(:folder, root, evidence)
  defp restored_entry(_other_kind, _root, _evidence), do: {:unavailable, :not_recorded}

  # The folder a record names, as a new conversation would get it now, in the words of a restore.
  @spec recorded_root(:project | :folder, String.t(), evidence()) :: t()
  defp recorded_root(kind, root, evidence) do
    case at(root, evidence) do
      {:unavailable, :none} -> {:unavailable, {:gone, kind, root}}
      {:unavailable, {:too_broad, _canonical}} -> {:unavailable, {:refused, root}}
      decided -> decided
    end
  end

  # A path from a record reaches the instructions and what the person reads.
  # It is plain text of a sane length: no control characters, no invisible or direction-changing ones,
  # and no line separators.
  @spec printable_path?(String.t()) :: boolean()
  defp printable_path?(path) do
    byte_size(path) <= @max_path_bytes and String.valid?(path) and
      not String.match?(path, ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u)
  end

  @doc """
  The folder of a conversation whose record has no folder entry, read from the instructions it ran with.

  Minga writes the root into every system prompt as one line under the Environment heading. `instructions` are the system instructions captured with the conversation, never its messages or tool output. Only that exact form counts. No such line, more than one root, or a relative path gives no folder.

  The root is then checked like a stored folder, and more strictly: before folders were recorded a session could run in the process directory, so a root as broad as the home directory or a filesystem root is refused.
  """
  @spec recovered([String.t()]) :: t()
  @spec recovered([String.t()], evidence()) :: t()
  def recovered(instructions, evidence \\ &project_evidence/1) when is_list(instructions) do
    roots =
      instructions
      |> Enum.flat_map(&Regex.scan(@root_line_in_prompt, &1, capture: :all_but_first))
      |> List.flatten()
      |> Enum.uniq()

    case roots do
      [root] -> recovered_root(root, evidence)
      _none_or_several -> {:unavailable, :not_recorded}
    end
  end

  @spec recovered_root(String.t(), evidence()) :: t()
  defp recovered_root(root, evidence) do
    if printable_path?(root) and Path.type(root) == :absolute,
      do: recorded_root(:project, root, evidence),
      else: {:unavailable, :not_recorded}
  end

  @doc """
  The folder of a restored conversation, given the place the session that shows it works in.

  A restore never moves a session. The conversation continues only when its folder is the place the session already works in, named by the same path: the conversation's instructions name its folder, and the session's tools, hooks and edit view belong to its own. Anywhere else the conversation can be read but not continued, and it keeps the folder its record names.

  `recorded` is `:undecided` for a record that never ran a turn. It has no folder of its own yet and takes the session's.
  """
  @spec in_place(t() | :undecided, t() | nil) :: t() | nil
  def in_place(:undecided, place), do: place

  def in_place({:unavailable, _reason} = recorded, place) do
    if read_only?(recorded) or recorded == place,
      do: recorded,
      else: {:unavailable, {:elsewhere, recorded}}
  end

  def in_place({recorded_kind, root} = recorded, {place_kind, root})
      when recorded_kind in [:project, :folder] and place_kind in [:project, :folder],
      do: recorded

  def in_place({kind, _root} = recorded, _another_place_or_none) when kind in [:project, :folder],
    do: {:unavailable, {:elsewhere, recorded}}

  @doc """
  Tells whether a restored conversation can only be read.

  A conversation continues only under the instructions it ran with, and those name its folder. One that came back without that folder cannot continue, with or without tools.
  """
  @spec read_only?(t() | nil) :: boolean()
  def read_only?({:unavailable, {:elsewhere, _recorded}}), do: true
  def read_only?({:unavailable, {:gone, _kind, _path}}), do: true
  def read_only?({:unavailable, {:refused, _path}}), do: true
  def read_only?({:unavailable, :not_recorded}), do: true
  def read_only?(_folder_or_new_without), do: false

  @doc "The first candidate that gives the session a folder, or the first candidate's reason when none does."
  @spec first_available([t(), ...]) :: t()
  def first_available([first | _rest] = candidates) do
    Enum.find(candidates, first_refusal(candidates, first), &available?/1)
  end

  @doc "The folder's path, or `nil` when the session has none."
  @spec root(t()) :: String.t() | nil
  def root({kind, root}) when kind in [:project, :folder], do: root
  def root({:unavailable, _reason}), do: nil

  @doc "Tells whether the session has a folder."
  @spec available?(t()) :: boolean()
  def available?({kind, _root}) when kind in [:project, :folder], do: true
  def available?({:unavailable, _reason}), do: false

  @doc """
  Tells whether a tool may run in a session that has no folder.

  The answer is no unless the tool is one of the few known to stay away from the user's files: asking the person, the checklist, describing Minga itself, reading memory, fetching a URL, and returning an inline rewrite. The name must be Minga's own declaration: a tool from configuration or an extension never qualifies under a listed name, because Minga cannot see its reach.
  """
  @spec runs_without_folder?(tool()) :: boolean()
  def runs_without_folder?(%{name: name, source: :builtin}), do: name in @folder_free_tools
  def runs_without_folder?(%{name: name, source: {:bundle, _}}), do: name in @folder_free_tools
  # The inline rewrite result is declared by Minga's own inline session as a session tool.
  def runs_without_folder?(%{name: "produce_rewrite", source: :config}), do: true
  def runs_without_folder?(%{name: _name, source: _other}), do: false

  @doc """
  The one line a tool that needs a folder answers with, or `nil` when the session has a folder.

  The conversation shows the same line once, so the person and the model read the same sentence.
  """
  # The lines of a conversation that can only be read say what to do first and name the folder last,
  # with the home directory written as `~`.
  # A surface that cuts a long line then cuts the end of the path.
  @spec refusal(t()) :: String.t() | nil
  def refusal({:unavailable, :none}),
    do: "Minga has no folder to work in. Open a file or a folder."

  def refusal({:unavailable, {:too_broad, path}}) do
    "Minga has no folder to work in: #{Project.collapse_home(path)} is too broad. " <>
      "Open a folder inside it, or move the file into a folder."
  end

  def refusal({:unavailable, {:elsewhere, {kind, root}}}) when kind in [:project, :folder] do
    "This conversation can only be read here. " <>
      "Start a new conversation, or restore it in #{Project.collapse_home(root)}."
  end

  # A conversation that started without a folder continues only where it would start without one again.
  def refusal({:unavailable, {:elsewhere, {:unavailable, {:too_broad, path}}}}) do
    "This conversation can only be read here. Start a new conversation, " <>
      "or restore it where it started without a folder: #{Project.collapse_home(path)}."
  end

  def refusal({:unavailable, {:elsewhere, {:unavailable, _reason}}}) do
    "This conversation can only be read here. " <>
      "Start a new conversation, or restore it with no file or folder open: it started without a folder."
  end

  def refusal({:unavailable, {:gone, _kind, path}}) do
    "This conversation can only be read: its folder is gone. " <>
      "Start a new conversation, or put the folder back and restore it there: #{Project.collapse_home(path)}."
  end

  def refusal({:unavailable, {:refused, path}}) do
    "This conversation can only be read: its folder is too broad for Minga to work in. " <>
      "Start a new conversation. The folder was #{Project.collapse_home(path)}."
  end

  def refusal({:unavailable, :not_recorded}) do
    "This conversation can only be read: it has no saved folder. Start a new conversation."
  end

  def refusal({kind, _root}) when kind in [:project, :folder], do: nil

  @doc """
  The line the conversation shows once when the session does not work in a detected project, or `nil` for a project.
  """
  @spec notice(t()) :: String.t() | nil
  def notice({:project, _root}), do: nil

  def notice({:folder, root}),
    do: "Minga is working in #{Project.collapse_home(root)}. No project was detected there."

  def notice({:unavailable, _reason} = unavailable), do: refusal(unavailable)

  # The placeholder must be a real directory of this user with no access for anyone else.
  # A link or a shared directory there could put another person's files in front of the session.
  @spec verify_placeholder(String.t()) :: :ok
  defp verify_placeholder(root) do
    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory, mode: mode}} when Bitwise.band(mode, 0o077) == 0 ->
        :ok

      other ->
        raise "the private root for a session without a folder is not private: #{inspect(other)}"
    end
  end

  @spec classify(String.t(), boolean()) :: t()
  defp classify(canonical, true), do: {:unavailable, {:too_broad, canonical}}
  defp classify(canonical, false), do: {:folder, canonical}

  @spec canonical_directory(String.t()) :: {:ok, String.t()} | :error
  defp canonical_directory(path) do
    with :absolute <- Path.type(path),
         {:ok, canonical} <- Root.canonical_path(path),
         {:ok, %File.Stat{type: :directory}} <- File.stat(canonical) do
      {:ok, canonical}
    else
      _relative_missing_or_not_a_directory -> :error
    end
  end

  # A too-broad candidate explains more than a missing one, so it wins over `:none`.
  @spec first_refusal([t()], t()) :: t()
  defp first_refusal(candidates, first) do
    Enum.find(candidates, first, &match?({:unavailable, {:too_broad, _path}}, &1))
  end
end
