defmodule MingaAgent.WorkingFolder do
  @moduledoc """
  Where one Agent session may read, search, edit and run commands.

  A session works in a detected project, or in a plain folder the user chose by opening it or a file inside it. When neither exists, or the only candidate is as broad as the user's home directory or a filesystem or volume root, the session has no folder: it can still chat, and every tool that needs a folder answers with one fixed line.

  The caller that starts a session decides this value once and passes it down. Nothing below reads the process working directory: an application started from a desktop launcher has `/` there, which is not a folder the user chose.
  """

  alias Minga.Project
  alias Minga.Project.Detector
  alias Minga.Project.Root

  @typedoc "Why a session has no folder: nothing was opened, or the only candidate is too broad to work in."
  @type reason :: :none | {:too_broad, String.t()}

  @typedoc "A detected project, a plain folder, or no folder with the reason."
  @type t :: {:project, String.t()} | {:folder, String.t()} | {:unavailable, reason()}

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
    cond do
      root == placeholder_root() -> {:unavailable, :none}
      version_controlled?.(root) -> {:project, root}
      true -> project_unless_broad(root, Root.canonical_path(root))
    end
  end

  @spec project_unless_broad(String.t(), {:ok, String.t()} | {:error, term()}) :: t()
  defp project_unless_broad(root, {:ok, canonical}),
    do: classify_project(root, canonical, broad?(canonical))

  # A root that does not resolve is not a place tools can reach. The caller's start fails on it as before.
  defp project_unless_broad(root, {:error, _reason}), do: {:project, root}

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
      {:ok, canonical} -> classify(canonical, broad?(canonical))
      :error -> {:unavailable, :none}
    end
  end

  @doc "The plain folder that holds `file_path`, under the same rules as `folder/1`."
  @spec for_file(String.t() | nil) :: t()
  def for_file(nil), do: {:unavailable, :none}
  def for_file(file_path) when is_binary(file_path), do: folder(Path.dirname(file_path))

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
  @spec refusal(t()) :: String.t() | nil
  def refusal({:unavailable, :none}),
    do: "Minga has no folder to work in. Open a file or a folder."

  def refusal({:unavailable, {:too_broad, path}}) do
    "Minga has no folder to work in: #{Project.collapse_home(path)} is too broad. " <>
      "Open a folder inside it, or move the file into a folder."
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

  # Names are compared first, then the directories themselves, so another spelling of the home directory or
  # the filesystem root (a different case, a firmlink, an unusual mount point) is as broad as the usual one.
  @spec broad?(String.t()) :: boolean()
  defp broad?(canonical) do
    Root.broad_path?(canonical) or contains_home?(canonical) or
      same_directory?(canonical, "/") or volume_root?(canonical)
  end

  # The home directory and every folder above it hold all of the person's files.
  @spec contains_home?(String.t()) :: boolean()
  defp contains_home?(canonical) do
    home = Path.expand("~")

    home_names =
      case Root.canonical_path(home) do
        {:ok, canonical_home} -> [home, canonical_home]
        {:error, _reason} -> [home]
      end

    Enum.any?(home_names, &(&1 == canonical or String.starts_with?(&1, canonical <> "/"))) or
      same_directory?(canonical, home)
  end

  @spec same_directory?(String.t(), String.t()) :: boolean()
  defp same_directory?(left, right) do
    case {File.stat(left), File.stat(right)} do
      {{:ok, a}, {:ok, b}} -> identity(a) == identity(b)
      _unreadable -> false
    end
  end

  # A directory on another device than its parent is the top of a mounted volume.
  @spec volume_root?(String.t()) :: boolean()
  defp volume_root?(directory) do
    case {File.stat(directory), File.stat(Path.dirname(directory))} do
      {{:ok, a}, {:ok, b}} -> device(a) != device(b)
      _unreadable -> false
    end
  end

  @spec identity(File.Stat.t()) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp identity(%File.Stat{} = stat), do: {stat.major_device, stat.minor_device, stat.inode}

  @spec device(File.Stat.t()) :: {non_neg_integer(), non_neg_integer()}
  defp device(%File.Stat{} = stat), do: {stat.major_device, stat.minor_device}

  # A too-broad candidate explains more than a missing one, so it wins over `:none`.
  @spec first_refusal([t()], t()) :: t()
  defp first_refusal(candidates, first) do
    Enum.find(candidates, first, &match?({:unavailable, {:too_broad, _path}}, &1))
  end
end
