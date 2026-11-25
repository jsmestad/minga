defmodule Minga.Project.Trust do
  @moduledoc """
  Decides whether a folder may be treated as a project by anything that acts on the project's behalf.

  Two things ask: the Agent, before it works in a project, and the configuration load, before it evaluates a project's own configuration, registers its plugins or starts its MCP servers. They ask the same function, so they cannot disagree about what a project is.

  A folder as broad as the home directory, a folder above it, the filesystem root or the top of a mounted volume holds far more than one project. It is accepted only when it is under version control: a repository rooted at the home directory really is one project. Any other marker there, a stray `package.json` for one, says nothing about the whole folder.

  Breadth is judged by the canonical path, so a link to the home directory is as broad as the home directory.

  Configuration is code that runs, so it has one more condition than the Agent's working folder: the folder and each configuration file in it must belong to the person running Minga, and nobody else may be able to write them. Otherwise another account on the machine could plant a file in a shared folder such as `/tmp` and have it run. `config_root/2` and `owned/2` hold that rule. It is the idea behind Git's `safe.directory`.
  """

  import Bitwise

  alias Minga.Project.Detector
  alias Minga.Project.Root

  @typedoc "Why a folder is not accepted as a project."
  @type refusal :: {:too_broad, canonical :: String.t()} | :unresolvable

  @typedoc """
  Why a folder, or a file in it, may not supply configuration.

  `:not_yours` names a path that belongs to another account. `:writable_by_others` names one that anyone on the machine can write, and `:writable_by_group` one that its group can write on a platform where that group is everyone.
  """
  @type config_refusal ::
          refusal()
          | {:not_yours, path :: String.t()}
          | {:writable_by_others, path :: String.t()}
          | {:writable_by_group, path :: String.t()}

  @typedoc """
  The platform, as far as this rule cares.

  On macOS every local account is a member of the `staff` group, and a new folder gets that group. Write access for the group there is write access for everyone, so it is refused. On other systems an account usually has a group of its own, and a folder shared with a group is shared on purpose.
  """
  @type platform :: :macos | :other

  @typedoc "The id of the account running Minga. A test supplies its own."
  @type user_id :: non_neg_integer()

  @typedoc "Tells whether a folder is under version control. A test supplies its own answer this way."
  @type version_controlled :: (String.t() -> boolean())

  @doc """
  Accepts `root` as a project and returns its canonical path, or says why not.

  A root that does not resolve to an existing path is `:unresolvable`. A caller that reads or runs anything from the root must treat that as a refusal.
  """
  @spec project_root(String.t()) :: {:ok, String.t()} | {:error, refusal()}
  @spec project_root(String.t(), version_controlled()) :: {:ok, String.t()} | {:error, refusal()}
  def project_root(root, version_controlled? \\ &Detector.version_controlled?/1)

  def project_root(root, version_controlled?)
      when is_binary(root) and is_function(version_controlled?, 1) do
    case Root.canonical_path(root) do
      {:ok, canonical} -> accept(canonical, version_controlled?)
      {:error, _reason} -> {:error, :unresolvable}
    end
  end

  @typedoc "Reads what a path is and whose. The filesystem in production; a test supplies another account's answer."
  @type stat :: (String.t() -> {:ok, File.Stat.t()} | {:error, term()})

  @typedoc """
  Options a test uses to decide what the machine looks like.

  `:user_id` is the account running Minga, `:platform` the platform, `:stat` how a path is examined, `:version_controlled?` whether a folder is under version control, `:entry_limit` how many entries a code root may hold, and `:path` the `PATH` a bare program name is looked up on.
  """
  @type option ::
          {:user_id, user_id() | nil}
          | {:platform, platform()}
          | {:stat, stat()}
          | {:version_controlled?, version_controlled()}
          | {:entry_limit, pos_integer()}
          | {:path, String.t()}

  @doc "The platform this VM runs on, decided once for the whole rule."
  @spec platform() :: platform()
  def platform do
    case :os.type() do
      {:unix, :darwin} -> :macos
      _other -> :other
    end
  end

  @doc """
  Accepts `root` as a project whose configuration may be loaded, and returns its canonical path.

  Three things have to hold. The root passes `project_root/2`. The root is the user's own (`owned/3`). And every folder above it, up to the filesystem root, belongs to the user or to the system and cannot be written by others, unless it is a sticky folder such as `/tmp`, where an account cannot rename or remove what another account put there.

  The last condition is what makes a check now still true when the files are read later: no other account can change what a path under the root names.
  """
  @spec config_root(String.t()) :: {:ok, String.t()} | {:error, config_refusal()}
  @spec config_root(String.t(), [option()]) :: {:ok, String.t()} | {:error, config_refusal()}
  def config_root(root, opts \\ []) when is_binary(root) and is_list(opts) do
    version_controlled? = Keyword.get(opts, :version_controlled?, &Detector.version_controlled?/1)
    user_id = Keyword.get_lazy(opts, :user_id, &current_user_id/0)

    with {:ok, canonical} <- project_root(root, version_controlled?),
         :ok <- owned(canonical, user_id, opts),
         :ok <- safe_above(canonical, user_id, opts) do
      {:ok, canonical}
    end
  end

  @doc """
  Says whether `path` belongs to `user_id` and cannot be written by anyone else on the machine.

  A link is judged by what it points at, because that is what would be read. A path that cannot be examined is treated as not the user's. Write access for the group is allowed, except on macOS (see `t:platform/0`).
  """
  @spec owned(String.t(), user_id() | nil) :: :ok | {:error, config_refusal()}
  @spec owned(String.t(), user_id() | nil, [option()]) :: :ok | {:error, config_refusal()}
  def owned(path, user_id, opts \\ []) when is_binary(path) and is_list(opts) do
    judge(path, examine(path, opts), user_id, opts)
  end

  # The rule itself, applied to what was found at `path`.
  @spec judge(String.t(), {:ok, File.Stat.t()} | {:error, term()}, user_id() | nil, [option()]) ::
          :ok | {:error, config_refusal()}
  defp judge(path, {:ok, %File.Stat{uid: user_id, mode: mode}}, user_id, opts)
       when is_integer(user_id),
       do: closed_to_others(path, mode, opts)

  defp judge(path, _another_account_unknown_or_unreadable, _user_id, _opts),
    do: {:error, {:not_yours, path}}

  @spec examine(String.t(), [option()]) :: {:ok, File.Stat.t()} | {:error, term()}
  defp examine(path, opts), do: Keyword.get(opts, :stat, &stat/1).(path)

  # Read in this process, without a trip through the file server: a walk examines thousands of entries.
  @spec stat(String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  defp stat(path), do: found(:file.read_file_info(path, [:raw, {:time, :posix}]))

  # The entry itself, not what it leads to, so a link is seen as a link.
  @spec lstat(String.t()) :: {:ok, File.Stat.t()} | {:error, term()}
  defp lstat(path), do: found(:file.read_link_info(path, [:raw, {:time, :posix}]))

  @spec found({:ok, :file.file_info()} | {:error, term()}) ::
          {:ok, File.Stat.t()} | {:error, term()}
  defp found({:ok, info}), do: {:ok, File.Stat.from_record(info)}
  defp found({:error, _reason} = error), do: error

  @spec closed_to_others(String.t(), non_neg_integer(), [option()]) ::
          :ok | {:error, config_refusal()}
  defp closed_to_others(path, mode, opts) do
    cond do
      (mode &&& 0o002) != 0 -> {:error, {:writable_by_others, path}}
      group_is_everyone?(opts) and (mode &&& 0o020) != 0 -> {:error, {:writable_by_group, path}}
      true -> :ok
    end
  end

  @spec group_is_everyone?([option()]) :: boolean()
  defp group_is_everyone?(opts), do: Keyword.get_lazy(opts, :platform, &platform/0) == :macos

  # Every folder above the root. Each must belong to the user or to the system (user id 0), and others must not
  # be able to write it, unless it is sticky: there an account cannot rename or remove another account's entries.
  @spec safe_above(String.t(), user_id() | nil, [option()]) :: :ok | {:error, config_refusal()}
  defp safe_above(canonical, user_id, opts) do
    canonical
    |> Path.dirname()
    |> Stream.iterate(&Path.dirname/1)
    |> Enum.reduce_while(:ok, fn folder, :ok ->
      case safe_folder_above(folder, user_id, opts) do
        :ok when folder == "/" -> {:halt, :ok}
        :ok -> {:cont, :ok}
        {:error, _reason} = refused -> {:halt, refused}
      end
    end)
  end

  @spec safe_folder_above(String.t(), user_id() | nil, [option()]) ::
          :ok | {:error, config_refusal()}
  defp safe_folder_above(folder, user_id, opts) do
    case examine(folder, opts) do
      {:ok, %File.Stat{uid: uid, mode: mode}} when is_integer(user_id) and uid in [user_id, 0] ->
        if (mode &&& 0o1000) != 0, do: :ok, else: closed_to_others(folder, mode, opts)

      _another_account_unknown_or_unreadable ->
        {:error, {:not_yours, folder}}
    end
  end

  @doc """
  Reads a configuration file, and only if it is the user's own.

  The file is opened first, and the open file itself is what gets examined and then read. Checking a path and reading it afterwards would leave a moment in which the file could be swapped. The path is resolved to its canonical form first, so a link is followed once, here. Only a regular file of a sane size is read.

  Returns the content and the canonical path, which is the name to report and to resolve relative paths against.
  """
  @spec read_config_file(String.t(), user_id() | nil) ::
          {:ok, binary(), canonical :: String.t()}
          | {:error, config_refusal() | {:unreadable, String.t(), term()}}
  @spec read_config_file(String.t(), user_id() | nil, [option()]) ::
          {:ok, binary(), canonical :: String.t()}
          | {:error, config_refusal() | {:unreadable, String.t(), term()}}
  def read_config_file(path, user_id, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, canonical} <- canonical_file(path),
         :ok <- regular_file(canonical),
         {:ok, device} <- open(canonical) do
      try do
        read_open_file(device, canonical, user_id, opts)
      after
        File.close(device)
      end
    end
  end

  @spec canonical_file(String.t()) ::
          {:ok, String.t()} | {:error, {:unreadable, String.t(), term()}}
  defp canonical_file(path) do
    case Root.canonical_path(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  # Opening a named pipe would wait for a writer. Only a regular file is opened.
  @spec regular_file(String.t()) :: :ok | {:error, {:unreadable, String.t(), term()}}
  defp regular_file(canonical) do
    case File.stat(canonical) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: type}} -> {:error, {:unreadable, canonical, {:not_a_file, type}}}
      {:error, reason} -> {:error, {:unreadable, canonical, reason}}
    end
  end

  @spec open(String.t()) :: {:ok, File.io_device()} | {:error, {:unreadable, String.t(), term()}}
  defp open(canonical) do
    case File.open(canonical, [:read, :binary, :raw]) do
      {:ok, device} -> {:ok, device}
      {:error, reason} -> {:error, {:unreadable, canonical, reason}}
    end
  end

  @spec read_open_file(File.io_device(), String.t(), user_id() | nil, [option()]) ::
          {:ok, binary(), String.t()}
          | {:error, config_refusal() | {:unreadable, String.t(), term()}}
  defp read_open_file(device, canonical, user_id, opts) do
    # The open file is examined, not whatever the name points at by now.
    found = stat_open_file(device)

    with :ok <- owned(canonical, user_id, Keyword.put(opts, :stat, fn _path -> found end)),
         :ok <- within_size(found, canonical),
         {:ok, content} <- read_all(device, canonical) do
      {:ok, content, canonical}
    end
  end

  # A configuration file is small. One that is not is refused whole: reading part of it would run part of it.
  @max_config_bytes 16 * 1024 * 1024

  @spec within_size({:ok, File.Stat.t()} | {:error, term()}, String.t()) ::
          :ok | {:error, {:unreadable, String.t(), term()}}
  defp within_size({:ok, %File.Stat{size: size}}, _canonical) when size <= @max_config_bytes,
    do: :ok

  defp within_size(_too_large_or_unknown, canonical),
    do: {:error, {:unreadable, canonical, :too_large}}

  @spec stat_open_file(File.io_device()) :: {:ok, File.Stat.t()} | {:error, term()}
  defp stat_open_file(device) do
    case :file.read_file_info(device) do
      {:ok, info} -> {:ok, File.Stat.from_record(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_all(File.io_device(), String.t()) ::
          {:ok, binary()} | {:error, {:unreadable, String.t(), term()}}
  defp read_all(device, canonical) do
    case :file.read(device, @max_config_bytes) do
      {:ok, content} -> {:ok, content}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, {:unreadable, canonical, reason}}
    end
  end

  @typedoc """
  Why a folder of code, or something a configuration file points at, is not loaded.

  `:unreadable` names a path that cannot be examined or is not a file or a folder. `:too_many_entries` names a code root that holds more files and folders than Minga is willing to examine at each load.
  """
  @type code_refusal ::
          config_refusal()
          | {:unreadable, path :: String.t(), term()}
          | {:too_many_entries, root :: String.t(), limit :: pos_integer()}

  # A plugin is small: at most 128 source files are compiled from one. A folder with more entries than this is a
  # checkout with its dependencies and build output inside, and examining all of it at every load would hold up
  # the start of the editor. Examining 10,000 entries took about 0.65 s on a heavily loaded laptop.
  @code_entry_limit 10_000

  @doc "The number of files and folders a code root may hold."
  @spec code_entry_limit() :: pos_integer()
  def code_entry_limit, do: @code_entry_limit

  @doc """
  Accepts `path` as a folder Minga may load code or tooling from, and returns its canonical path.

  A code root is a plugin, or the folder an `extension ..., path:` in a project's config names. The canonical path that comes back is the only name the folder is known by afterwards: it is what gets registered and later read.

  - **Down:** the folder, every folder under it and every file under it must pass `owned/3`, whether or not it holds code today. A file added later to a folder that others can write would be loaded, and so would a `plugin.json`, or a script it names, that others can edit.
  - **Links:** a link is judged at its target, and so is everything above that target. Each target is examined once.
  - **Up:** every folder above the root, to the filesystem root, must belong to the user or to the system and be closed to others, unless it is sticky.

  When all of that holds, no other account can change what a path under the root names, so a check made now is still true when the code is read later. Anything that is not a file, a folder or a link is refused, and so is a root with more than `code_entry_limit/0` entries.
  """
  @spec code_root(String.t(), user_id() | nil) :: {:ok, String.t()} | {:error, code_refusal()}
  @spec code_root(String.t(), user_id() | nil, [option()]) ::
          {:ok, String.t()} | {:error, code_refusal()}
  def code_root(path, user_id, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, canonical} <- config_folder(path, user_id, opts),
         {:ok, _walk} <- own_entries(canonical, user_id, opts, new_walk(canonical, opts)) do
      {:ok, canonical}
    end
  end

  @doc """
  Accepts `path` as a folder that configuration is read from, and returns its canonical path.

  The folder must be the user's own, and every folder above it must be safe, as for `code_root/3`. What is inside is not examined: each file read from it is checked when it is read (`read_config_file/3`).
  """
  @spec config_folder(String.t(), user_id() | nil) :: {:ok, String.t()} | {:error, code_refusal()}
  @spec config_folder(String.t(), user_id() | nil, [option()]) ::
          {:ok, String.t()} | {:error, code_refusal()}
  def config_folder(path, user_id, opts \\ []) when is_binary(path) and is_list(opts) do
    with {:ok, canonical} <- canonical_file(path),
         :ok <- folder(canonical),
         :ok <- owned(canonical, user_id, opts),
         :ok <- safe_above(canonical, user_id, opts) do
      {:ok, canonical}
    end
  end

  @spec folder(String.t()) :: :ok | {:error, {:unreadable, String.t(), term()}}
  defp folder(canonical) do
    if File.dir?(canonical), do: :ok, else: {:error, {:unreadable, canonical, :not_a_folder}}
  end

  @doc """
  Examines the program a project declares for a process Minga starts, and returns the name to register.

  `root` is the canonical root the declaration belongs to: the project root, or a plugin's root. What comes back is the fact to register, so no caller resolves the name again.

  - A bare name, such as `node`, is the user's own environment, and it is returned as it is. It is looked up when the process starts (`program/3`), on the `PATH` of that moment and only in entries that are absolute paths: a relative or empty entry would mean "whatever directory the process happens to be in". Looking it up at load instead would use a `PATH` the start may not have, and a program installed later would stay missing.
  - A name with a separator is resolved against `root`, never against the directory Minga runs in. It must be an existing file. Inside the root it must pass `owned/3`, with every folder between the root and it, and every link on the way is judged. The canonical path is returned. Outside the root (an absolute path to a tool elsewhere) it is the user's own environment, and it only has to exist.

  A name that leads nowhere is a refusal. Arguments and environment values are not looked at: what the program reads once it runs is the project's own code, like a command in `.minga.exs`.
  """
  @spec executable(String.t(), String.t(), user_id() | nil) ::
          {:ok, String.t()} | {:error, code_refusal()}
  @spec executable(String.t(), String.t(), user_id() | nil, [option()]) ::
          {:ok, String.t()} | {:error, code_refusal()}
  def executable(root, command, user_id, opts \\ [])
      when is_binary(root) and is_binary(command) and is_list(opts) do
    with :ok <- program_name(command) do
      if String.contains?(command, "/"),
        do: named_program(root, Path.expand(command, root), user_id, opts),
        else: {:ok, command}
    end
  end

  @doc """
  Finds the file to run for a program name, without judging who owns it.

  A bare name is looked up on `PATH`, in absolute entries only. The returned path keeps links unresolved because some tools decide what to do by the name they are called by. An absolute path must name an existing file. A relative path with a separator requires a root and is resolved against it, never against Minga's process directory. A declaration that is held to the ownership rule goes through `executable/4` first.
  """
  @spec program(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, code_refusal()}
  @spec program(String.t() | nil, String.t(), [option()]) ::
          {:ok, String.t()} | {:error, code_refusal()}
  def program(root, command, opts \\ [])
      when (is_binary(root) or is_nil(root)) and is_binary(command) and is_list(opts) do
    with :ok <- program_name(command) do
      cond do
        not String.contains?(command, "/") -> program_on_path(command, opts)
        is_binary(root) -> existing_program(Path.expand(command, root))
        Path.type(command) == :absolute -> existing_program(Path.expand(command))
        true -> {:error, {:unreadable, command, :no_working_directory}}
      end
    end
  end

  # Each absolute folder of PATH is searched on its own. `:os.find_executable/2` reads an empty element of a
  # search path as the current directory, so it is never handed a list: with no absolute folder nothing is found.
  @spec program_on_path(String.t(), [option()]) :: {:ok, String.t()} | {:error, code_refusal()}
  defp program_on_path(name, opts) do
    found =
      opts
      |> Keyword.get_lazy(:path, fn -> System.get_env("PATH", "") end)
      |> String.split(":")
      |> Enum.filter(&(Path.type(&1) == :absolute))
      |> Enum.find_value(&program_in_folder(name, &1))

    case found do
      nil -> {:error, {:unreadable, name, :not_on_path}}
      path -> {:ok, path}
    end
  end

  @spec program_in_folder(String.t(), String.t()) :: String.t() | nil
  defp program_in_folder(name, folder) do
    case :os.find_executable(String.to_charlist(name), String.to_charlist(folder)) do
      false -> nil
      found -> List.to_string(found)
    end
  end

  # A name is text a path can be built from: not empty, and without the byte that ends a C string, which would
  # make the system see a shorter name than the one that was examined.
  @spec program_name(String.t()) :: :ok | {:error, code_refusal()}
  defp program_name(command) do
    if command == "" or String.contains?(command, <<0>>),
      do: {:error, {:unreadable, command, :invalid_name}},
      else: :ok
  end

  @spec named_program(String.t(), String.t(), user_id() | nil, [option()]) ::
          {:ok, String.t()} | {:error, code_refusal()}
  defp named_program(root, written, user_id, opts) do
    if inside?(root, written),
      do: program_inside(root, written, user_id, opts),
      else: existing_program(written)
  end

  # The name is followed from the root one step at a time, so a link on the way is judged where it sits.
  # Where it ends up decides the rest: inside the root it must be the user's own, outside it only has to exist.
  @spec program_inside(String.t(), String.t(), user_id() | nil, [option()]) ::
          {:ok, String.t()} | {:error, code_refusal()}
  defp program_inside(root, written, user_id, opts) do
    with {:ok, canonical} <-
           follow(root, Path.split(Path.relative_to(written, root)), user_id, opts, 0),
         {:ok, canonical} <- existing_program(canonical),
         :ok <- owned_if_inside(root, canonical, user_id, opts) do
      {:ok, canonical}
    end
  end

  @spec owned_if_inside(String.t(), String.t(), user_id() | nil, [option()]) ::
          :ok | {:error, config_refusal()}
  defp owned_if_inside(root, canonical, user_id, opts) do
    if inside?(root, canonical), do: owned_below(root, canonical, user_id, opts), else: :ok
  end

  @spec existing_program(String.t()) :: {:ok, String.t()} | {:error, code_refusal()}
  defp existing_program(path) do
    with :ok <- regular_file(path), do: {:ok, path}
  end

  @spec inside?(String.t(), String.t()) :: boolean()
  defp inside?(root, path), do: String.starts_with?(path, root <> "/")

  # The folders between the root and the path, then the path itself.
  @spec owned_below(String.t(), String.t(), user_id() | nil, [option()]) ::
          :ok | {:error, config_refusal()}
  defp owned_below(root, canonical, user_id, opts) do
    with :ok <- each_owned(folders_between(root, canonical), user_id, opts),
         do: owned(canonical, user_id, opts)
  end

  @spec each_owned([String.t()], user_id() | nil, [option()]) :: :ok | {:error, config_refusal()}
  defp each_owned(paths, user_id, opts) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case owned(path, user_id, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = refused -> {:halt, refused}
      end
    end)
  end

  # The folders strictly between `root` and `path`, nearest the root first.
  @spec folders_between(String.t(), String.t()) :: [String.t()]
  defp folders_between(root, path) do
    path
    |> Path.dirname()
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.scan(root, fn part, parent -> Path.join(parent, part) end)
  end

  # What a walk has examined so far: the folders it has been in, so a linked folder is walked once and a cycle
  # of links ends, and how many more entries it may examine before the root counts as too large.
  @typep walk :: %{
           seen: MapSet.t(String.t()),
           left: non_neg_integer(),
           root: String.t(),
           limit: pos_integer()
         }
  @typep walked :: {:ok, walk()} | {:error, code_refusal()}

  @spec new_walk(String.t(), [option()]) :: walk()
  defp new_walk(root, opts) do
    limit = Keyword.get(opts, :entry_limit, @code_entry_limit)
    %{seen: MapSet.new([root]), left: limit, root: root, limit: limit}
  end

  # Walks a folder that is known by its canonical path and has itself passed the rule.
  @spec own_folder_tree(String.t(), user_id() | nil, [option()], walk()) :: walked()
  defp own_folder_tree(folder, user_id, opts, walk) do
    if MapSet.member?(walk.seen, folder),
      do: {:ok, walk},
      else: own_entries(folder, user_id, opts, %{walk | seen: MapSet.put(walk.seen, folder)})
  end

  @spec own_entries(String.t(), user_id() | nil, [option()], walk()) :: walked()
  defp own_entries(folder, user_id, opts, walk) do
    with {:ok, names} <- list_folder(folder) do
      Enum.reduce_while(names, {:ok, walk}, fn name, {:ok, walk} ->
        continue_walk(own_entry(Path.join(folder, name), user_id, opts, walk))
      end)
    end
  end

  @spec continue_walk(walked()) :: {:cont, walked()} | {:halt, walked()}
  defp continue_walk({:ok, _walk} = walked), do: {:cont, walked}
  defp continue_walk({:error, _reason} = refused), do: {:halt, refused}

  @spec list_folder(String.t()) ::
          {:ok, [String.t()]} | {:error, {:unreadable, String.t(), term()}}
  defp list_folder(folder) do
    case File.ls(folder) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, {:unreadable, folder, reason}}
    end
  end

  # One entry of a folder. It is examined once, without following it, and judged by what was found.
  @spec own_entry(String.t(), user_id() | nil, [option()], walk()) :: walked()
  defp own_entry(_path, _user_id, _opts, %{left: 0} = walk),
    do: {:error, {:too_many_entries, walk.root, walk.limit}}

  defp own_entry(path, user_id, opts, walk) do
    walk = %{walk | left: walk.left - 1}

    case lstat(path) do
      {:ok, %File.Stat{type: :directory}} = found ->
        with :ok <- judge(path, found, user_id, opts),
             do: own_folder_tree(path, user_id, opts, walk)

      {:ok, %File.Stat{type: :regular}} = found ->
        walked(judge(path, found, user_id, opts), walk)

      {:ok, %File.Stat{type: :symlink}} ->
        own_link_target(path, user_id, opts, walk)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:unreadable, path, {:not_a_file, type}}}

      {:error, reason} ->
        {:error, {:unreadable, path, reason}}
    end
  end

  # A link leads out of the folder that was checked on the way here. It is followed one step at a time, and
  # every link on the way is judged (`follow/5`). Then its target is checked from the top: everything above
  # it, the target itself, and everything under it when it is a folder.
  @spec own_link_target(String.t(), user_id() | nil, [option()], walk()) :: walked()
  defp own_link_target(link, user_id, opts, walk) do
    with {:ok, target} <- follow(Path.dirname(link), [Path.basename(link)], user_id, opts, 0),
         :ok <- safe_above(target, user_id, opts),
         :ok <- owned(target, user_id, opts) do
      if File.dir?(target), do: own_folder_tree(target, user_id, opts, walk), else: {:ok, walk}
    end
  end

  # The system gives up on a chain of links at about this length.
  @max_link_hops 40

  # Resolves `names` under the folder `resolved`, the way the system would, and returns the canonical path.
  # A reader that comes later walks the same chain again, so each link in it must still lead where it leads now:
  # the link belongs to the user or to the system, and so does the folder that holds it, with everything above.
  # Judging only the final target would miss a link in the middle that another account can point elsewhere.
  @spec follow(String.t(), [String.t()], user_id() | nil, [option()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, code_refusal()}
  defp follow(resolved, [], _user_id, _opts, _hops), do: {:ok, resolved}

  defp follow(resolved, _names, _user_id, _opts, hops) when hops > @max_link_hops,
    do: {:error, {:unreadable, resolved, :too_many_links}}

  defp follow(resolved, ["." | names], user_id, opts, hops),
    do: follow(resolved, names, user_id, opts, hops)

  defp follow(resolved, [".." | names], user_id, opts, hops),
    do: follow(Path.dirname(resolved), names, user_id, opts, hops)

  defp follow(resolved, [name | names], user_id, opts, hops) do
    path = Path.join(resolved, name)

    case lstat(path) do
      {:ok, %File.Stat{type: :symlink, uid: owner}} ->
        with :ok <- owned_link(path, owner, resolved, user_id, opts),
             {:ok, target} <- read_link(path) do
          follow_target(resolved, Path.split(target), names, user_id, opts, hops + 1)
        end

      {:ok, %File.Stat{}} ->
        follow(path, names, user_id, opts, hops)

      {:error, reason} ->
        {:error, {:unreadable, path, reason}}
    end
  end

  # An absolute target starts again at the top. A relative one continues in the folder that holds the link.
  @spec follow_target(
          String.t(),
          [String.t()],
          [String.t()],
          user_id() | nil,
          [option()],
          non_neg_integer()
        ) :: {:ok, String.t()} | {:error, code_refusal()}
  defp follow_target(_resolved, ["/" | target], names, user_id, opts, hops),
    do: follow("/", target ++ names, user_id, opts, hops)

  defp follow_target(resolved, target, names, user_id, opts, hops),
    do: follow(resolved, target ++ names, user_id, opts, hops)

  # In a sticky folder another account cannot remove a link, but it can point its own link elsewhere. So the
  # link itself must be the user's or the system's, besides the folder that holds it.
  @spec owned_link(String.t(), non_neg_integer(), String.t(), user_id() | nil, [option()]) ::
          :ok | {:error, config_refusal()}
  defp owned_link(link, owner, holder, user_id, opts) do
    if is_integer(user_id) and owner in [user_id, 0] do
      with :ok <- safe_folder_above(holder, user_id, opts),
           do: safe_above(holder, user_id, opts)
    else
      {:error, {:not_yours, link}}
    end
  end

  @spec read_link(String.t()) :: {:ok, String.t()} | {:error, {:unreadable, String.t(), term()}}
  defp read_link(path) do
    case File.read_link(path) do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @spec walked(:ok | {:error, config_refusal()}, walk()) :: walked()
  defp walked(:ok, walk), do: {:ok, walk}
  defp walked({:error, _reason} = refused, _walk), do: refused

  @doc """
  Says why something was refused and what makes it loadable, as the end of a sentence for `*Messages*`.

  The sentence names the folder or file that failed, with the home directory written as `~`. A caller that has a shorter name for it (a path relative to the project) passes that as `name`.
  """
  @spec explain(refusal() | code_refusal()) :: String.t()
  @spec explain(refusal() | code_refusal(), String.t() | nil) :: String.t()
  def explain(reason, name \\ nil)

  def explain({:too_broad, path}, name) do
    named = named(name, path)

    "#{named} is too broad and not under version control. " <>
      "Config loads from a project folder inside it, or once #{named} is a Git repository."
  end

  def explain(:unresolvable, _name), do: "the folder cannot be found."

  def explain({:not_yours, path}, name),
    do:
      "#{named(name, path)} belongs to another account. " <>
        "Config loads only from files and folders that are yours."

  def explain({:writable_by_others, path}, name),
    do:
      "anyone on this machine can write #{named(name, path)}. " <>
        "Remove write access for others (chmod o-w, or chmod -R o-w for a whole folder) and reload config."

  def explain({:writable_by_group, path}, name),
    do:
      "its group can write #{named(name, path)}, and on macOS every account is in that group. " <>
        "Remove write access for the group (chmod g-w, or chmod -R g-w for a whole folder) and reload config."

  def explain({:too_many_entries, root, limit}, name),
    do:
      "#{named(name, root)} holds more than #{limit} files and folders, too many to check at each load. " <>
        "Keep dependencies and build output out of it."

  def explain({:unreadable, program, :not_on_path}, _name),
    do:
      "#{program} is not a program in any absolute folder on PATH. Install it and start a new conversation."

  def explain({:unreadable, path, :enoent}, name),
    do: "#{named(name, path)} is not there. Create it, or correct the name, and reload config."

  def explain({:unreadable, path, reason}, name),
    do: "#{named(name, path)} could not be read (#{inspect(reason)})."

  @spec named(String.t() | nil, String.t()) :: String.t()
  defp named(nil, path), do: Minga.Project.collapse_home(path)
  defp named(name, _path) when is_binary(name), do: name

  @doc """
  The id of the account running Minga, or `nil` when it cannot be determined.

  The VM has no call for it. A file this process creates belongs to that account, so one is created in the temporary directory and the open file is examined, not its name: in a shared temporary directory the name could be swapped.
  """
  @spec current_user_id() :: user_id() | nil
  def current_user_id do
    probe =
      Path.join(
        System.tmp_dir!(),
        "minga-uid-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}"
      )

    case File.open(probe, [:write, :exclusive, :raw]) do
      {:ok, device} ->
        found = stat_open_file(device)
        File.close(device)
        _ = File.rm(probe)
        probe_owner(found)

      {:error, _reason} ->
        nil
    end
  end

  @spec probe_owner({:ok, File.Stat.t()} | {:error, term()}) :: user_id() | nil
  defp probe_owner({:ok, %File.Stat{uid: uid}}), do: uid
  defp probe_owner({:error, _reason}), do: nil

  @spec accept(String.t(), version_controlled()) :: {:ok, String.t()} | {:error, refusal()}
  defp accept(canonical, version_controlled?) do
    if broad?(canonical) and not version_controlled?.(canonical),
      do: {:error, {:too_broad, canonical}},
      else: {:ok, canonical}
  end

  @doc """
  Tells whether a canonical path names a folder too broad to be a project on a marker's word alone.

  Names are compared first, then the directories themselves, so another spelling of the home directory or the filesystem root (a different case, a firmlink, an unusual mount point) is as broad as the usual one.
  """
  @spec broad?(String.t()) :: boolean()
  def broad?(canonical) when is_binary(canonical) do
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
      Enum.any?(home_and_above(home), &same_directory?(canonical, &1))
  end

  # The home directory and each folder above it, so another spelling of any of them is recognized.
  @spec home_and_above(String.t()) :: [String.t()]
  defp home_and_above(home) do
    home
    |> Stream.iterate(&Path.dirname/1)
    |> Stream.take_while(&(&1 != "/"))
    |> Enum.to_list()
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
end
