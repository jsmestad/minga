defmodule Minga.Extension.Entry do
  @moduledoc """
  Data structure representing a declared extension in the registry.

  Each entry carries a tagged `source` value that makes invalid source
  combinations unrepresentable: `{:path, path}`, `{:git, git_opts}`,
  `{:hex, hex_opts}`, or `{:module, module}`. The `module` field holds
  the runtime-loaded module identity, which is separate from the source
  module in `:module` entries.
  """

  alias Minga.Extension

  @typedoc "Git-specific source options."
  @type git_opts :: %{
          url: String.t(),
          branch: String.t() | nil,
          ref: String.t() | nil,
          path: String.t() | nil
        }

  @typedoc "Hex-specific source options."
  @type hex_opts :: %{
          package: String.t(),
          version: String.t() | nil,
          app: atom()
        }

  @typedoc "Tagged source identity for an extension."
  @type source ::
          {:path, String.t()}
          | {:git, git_opts()}
          | {:hex, hex_opts()}
          | {:module, module()}

  @enforce_keys [:source]
  defstruct [
    :source,
    :module,
    :pid,
    :manifest,
    :last_error,
    config: [],
    status: :stopped,
    load_policy: nil
  ]

  @type t :: %__MODULE__{
          source: source(),
          module: module() | nil,
          pid: pid() | nil,
          manifest: Extension.Manifest.t() | nil,
          last_error: term() | nil,
          config: keyword(),
          status: Extension.extension_status(),
          load_policy: Extension.load_policy() | nil
        }

  @doc "Creates a path-sourced entry."
  @spec from_path(String.t(), keyword()) :: t()
  def from_path(path, config) when is_binary(path) and is_list(config) do
    {load_policy, config} = Keyword.pop(config, :load_policy)
    %__MODULE__{source: {:path, path}, config: config, load_policy: load_policy}
  end

  @doc "Creates a module-sourced entry for a bundled extension already on the code path."
  @spec from_module(module(), keyword()) :: t()
  def from_module(module, config) when is_atom(module) and is_list(config) do
    {load_policy, config} = Keyword.pop(config, :load_policy)

    %__MODULE__{
      source: {:module, module},
      module: module,
      config: config,
      load_policy: load_policy
    }
  end

  @doc "Creates a git-sourced entry."
  @spec from_git(String.t(), keyword()) :: t()
  def from_git(url, opts) when is_binary(url) and is_list(opts) do
    {branch, opts} = Keyword.pop(opts, :branch)
    {ref, opts} = Keyword.pop(opts, :ref)
    {load_policy, config} = Keyword.pop(opts, :load_policy)

    %__MODULE__{
      source: {:git, %{url: url, branch: branch, ref: ref, path: nil}},
      config: config,
      load_policy: load_policy
    }
  end

  @doc "Creates a hex-sourced entry."
  @spec from_hex(String.t(), atom(), keyword()) :: t()
  def from_hex(package, app, opts) when is_binary(package) and is_atom(app) and is_list(opts) do
    {version, opts} = Keyword.pop(opts, :version)
    {_app, opts} = Keyword.pop(opts, :app)
    {load_policy, config} = Keyword.pop(opts, :load_policy)

    %__MODULE__{
      source: {:hex, %{package: package, version: version, app: app}},
      config: config,
      load_policy: load_policy
    }
  end

  # -- Accessors --------------------------------------------------------------

  @doc "Returns the source type tag."
  @spec source_type(t()) :: :path | :git | :hex | :module
  def source_type(%__MODULE__{source: {tag, _}}), do: tag

  @doc "Returns the source path for path and resolved git entries, nil otherwise."
  @spec source_path(t()) :: String.t() | nil
  def source_path(%__MODULE__{source: {:path, path}}), do: path
  def source_path(%__MODULE__{source: {:git, %{path: path}}}), do: path
  def source_path(%__MODULE__{}), do: nil

  @doc "Returns git-specific source options, nil for non-git entries."
  @spec git_opts(t()) :: git_opts() | nil
  def git_opts(%__MODULE__{source: {:git, opts}}), do: opts
  def git_opts(%__MODULE__{}), do: nil

  @doc "Returns hex-specific source options, nil for non-hex entries."
  @spec hex_opts(t()) :: hex_opts() | nil
  def hex_opts(%__MODULE__{source: {:hex, opts}}), do: opts
  def hex_opts(%__MODULE__{}), do: nil

  @doc "Returns the declared module for module-sourced entries, nil otherwise."
  @spec source_module(t()) :: module() | nil
  def source_module(%__MODULE__{source: {:module, mod}}), do: mod
  def source_module(%__MODULE__{}), do: nil

  # -- Transitions ------------------------------------------------------------

  @doc "Sets the resolved checkout path on a git-sourced entry."
  @spec resolve_git_path(t(), String.t()) :: t()
  def resolve_git_path(%__MODULE__{source: {:git, opts}} = entry, path) when is_binary(path) do
    %{entry | source: {:git, %{opts | path: path}}}
  end
end
