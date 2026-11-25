defmodule Minga.Project.Sources do
  @moduledoc """
  Everything Minga loads from one project, found and examined in one place.

  A project can carry configuration that is code: `.minga.exs` is evaluated, `.minga/mcp.json` lists programs Minga starts, and each folder in `.minga/plugins` is a plugin. `admit/2` applies the rules of `Minga.Project.Trust` to all of it once and returns what may be used: the bytes of each file as they were read from the examined open file, and the canonical root of each plugin. A caller uses what it is given and never goes back to the disk with a name of its own, so what was examined is what is loaded.

  Some things a project declares are only known once its files are read: the programs behind its MCP servers. `process/5` turns such a declaration into the facts needed to start it. `Minga.Project.Trust.code_root/3` does the same for the folder an `extension ..., path:` names.

  The rule is a floor against other accounts on the machine. It says nothing about whether the project's own code deserves to run: a project you open runs its config.
  """

  alias Minga.Project.Trust

  @config_file ".minga.exs"
  @config_folder ".minga"
  @mcp_file "mcp.json"
  @plugins_folder "plugins"

  @enforce_keys [:root, :user_id, :config, :mcp, :plugins]
  defstruct [:root, :user_id, :config, :mcp, :plugins]

  @typedoc "One thing a project may carry: not there, usable, or refused with the path and the reason."
  @type part(found) ::
          :absent | {:ok, found} | {:refused, path :: String.t(), Trust.code_refusal()}

  @typedoc "A configuration file: its canonical path and the bytes read from the open file that was examined."
  @type file :: %{path: String.t(), content: binary()}

  @typedoc "One plugin by its folder name: the canonical root to register, or why it is left out."
  @type plugin :: {name :: String.t(), {:ok, String.t()} | {:error, Trust.code_refusal()}}

  @typedoc "The canonical plugins folder and the plugins in it, by name."
  @type plugins :: %{folder: String.t(), plugins: [plugin()]}

  @typedoc """
  A process a project declares, as the facts needed to start it.

  `executable` is an absolute path that was examined, and `cwd` is the canonical project root. Neither can be supplied by the project's own data. `args` and `env` are passed on as declared.
  """
  @type process :: %{
          executable: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          cwd: String.t()
        }

  @type t :: %__MODULE__{
          root: String.t(),
          user_id: Trust.user_id() | nil,
          config: part(file()),
          mcp: part(file()),
          plugins: part(plugins())
        }

  @doc """
  Examines `root` and everything Minga would load from it.

  A root that fails the rule gives a refusal, and then nothing of it is read. Otherwise each part is judged on its own: a refused file or plugin leaves the rest usable.
  """
  @spec admit(String.t()) :: {:ok, t()} | {:error, Trust.config_refusal()}
  @spec admit(String.t(), [Trust.option()]) :: {:ok, t()} | {:error, Trust.config_refusal()}
  def admit(root, opts \\ []) when is_binary(root) and is_list(opts) do
    opts = Keyword.put_new_lazy(opts, :user_id, &Trust.current_user_id/0)
    user_id = Keyword.fetch!(opts, :user_id)

    with {:ok, canonical} <- Trust.config_root(root, opts) do
      {:ok,
       %__MODULE__{
         root: canonical,
         user_id: user_id,
         config: file(Path.join(canonical, @config_file), user_id, opts),
         mcp: file_in_folder(Path.join(canonical, @config_folder), @mcp_file, user_id, opts),
         plugins: plugins(Path.join([canonical, @config_folder, @plugins_folder]), user_id, opts)
       }}
    end
  end

  @doc """
  Turns a program a project declares into the facts needed to start it.

  The program is found and judged by `Minga.Project.Trust.executable/4` against the project root, and the working directory is that root. Arguments and environment values are the project's own and are passed on untouched.
  """
  @spec process(t(), String.t(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, process()} | {:error, Trust.code_refusal()}
  @spec process(t(), String.t(), [String.t()], %{String.t() => String.t()}, [Trust.option()]) ::
          {:ok, process()} | {:error, Trust.code_refusal()}
  def process(%__MODULE__{root: root, user_id: user_id}, command, args, env, opts \\ [])
      when is_binary(command) and is_list(args) and is_map(env) and is_list(opts) do
    with {:ok, executable} <- Trust.executable(root, command, user_id, opts) do
      {:ok, %{executable: executable, args: args, env: env, cwd: root}}
    end
  end

  @doc "The folder names of the project's plugins, whether or not each one may be used."
  @spec plugin_names(t()) :: [String.t()]
  def plugin_names(%__MODULE__{plugins: {:ok, %{plugins: plugins}}}),
    do: Enum.map(plugins, fn {name, _root} -> name end)

  def plugin_names(%__MODULE__{}), do: []

  @spec file(String.t(), Trust.user_id() | nil, [Trust.option()]) :: part(file())
  defp file(path, user_id, opts) do
    if File.exists?(path), do: read(path, user_id, opts), else: :absent
  end

  @spec read(String.t(), Trust.user_id() | nil, [Trust.option()]) :: part(file())
  defp read(path, user_id, opts) do
    case Trust.read_config_file(path, user_id, opts) do
      {:ok, content, canonical} -> {:ok, %{path: canonical, content: content}}
      {:error, reason} -> {:refused, path, reason}
    end
  end

  # The folder is held to the rule for a folder that configuration is read from, and the file is then read by
  # its name inside the canonical folder.
  @spec file_in_folder(String.t(), String.t(), Trust.user_id() | nil, [Trust.option()]) ::
          part(file())
  defp file_in_folder(folder, name, user_id, opts) do
    path = Path.join(folder, name)

    if File.exists?(path) do
      case Trust.config_folder(folder, user_id, opts) do
        {:ok, canonical} -> read(Path.join(canonical, name), user_id, opts)
        {:error, reason} -> {:refused, path, reason}
      end
    else
      :absent
    end
  end

  # Only a folder is a plugin. A stray file in the plugins folder is passed over.
  @spec plugins(String.t(), Trust.user_id() | nil, [Trust.option()]) :: part(plugins())
  defp plugins(dir, user_id, opts) do
    if File.dir?(dir) do
      with {:ok, folder} <- Trust.config_folder(dir, user_id, opts),
           {:ok, names} <- list(folder) do
        {:ok, %{folder: folder, plugins: Enum.map(names, &plugin(folder, &1, user_id, opts))}}
      else
        {:error, reason} -> {:refused, dir, reason}
      end
    else
      :absent
    end
  end

  @spec list(String.t()) :: {:ok, [String.t()]} | {:error, Trust.code_refusal()}
  defp list(folder) do
    case File.ls(folder) do
      {:ok, names} ->
        {:ok, names |> Enum.filter(&File.dir?(Path.join(folder, &1))) |> Enum.sort()}

      {:error, reason} ->
        {:error, {:unreadable, folder, reason}}
    end
  end

  @spec plugin(String.t(), String.t(), Trust.user_id() | nil, [Trust.option()]) :: plugin()
  defp plugin(folder, name, user_id, opts),
    do: {name, Trust.code_root(Path.join(folder, name), user_id, opts)}
end
