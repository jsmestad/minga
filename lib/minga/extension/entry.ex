defmodule Minga.Extension.Entry do
  @moduledoc """
  Data structure representing a declared extension in the registry.

  Each entry tracks the extension's source (path, git, or hex), its
  runtime status, the loaded module, and the config passed to `init/1`.
  """

  alias Minga.Extension

  @typedoc "How the extension source code is obtained."
  @type source_type :: :path | :git | :hex

  @typedoc "Git-specific source options."
  @type git_opts :: %{
          url: String.t(),
          branch: String.t() | nil,
          ref: String.t() | nil
        }

  @typedoc "Hex-specific source options."
  @type hex_opts :: %{
          package: String.t(),
          version: String.t() | nil
        }

  @enforce_keys [:source_type]
  defstruct [
    :source_type,
    :path,
    :git,
    :hex,
    :module,
    :pid,
    config: [],
    status: :stopped
  ]

  @type t :: %__MODULE__{
          source_type: source_type(),
          path: String.t() | nil,
          git: git_opts() | nil,
          hex: hex_opts() | nil,
          module: module() | nil,
          pid: pid() | nil,
          config: keyword(),
          status: Extension.extension_status()
        }

  @doc "Creates a path-sourced entry."
  @spec from_path(String.t(), keyword()) :: t()
  def from_path(path, config) when is_binary(path) and is_list(config) do
    %__MODULE__{source_type: :path, path: path, config: config}
  end

  @doc "Creates a git-sourced entry."
  @spec from_git(String.t(), keyword()) :: t()
  def from_git(url, opts) when is_binary(url) and is_list(opts) do
    {branch, opts} = Keyword.pop(opts, :branch)
    {ref, config} = Keyword.pop(opts, :ref)

    %__MODULE__{
      source_type: :git,
      git: %{url: url, branch: branch, ref: ref},
      config: config
    }
  end

  @doc "Creates a hex-sourced entry."
  @spec from_hex(String.t(), keyword()) :: t()
  def from_hex(package, opts) when is_binary(package) and is_list(opts) do
    {version, config} = Keyword.pop(opts, :version)

    %__MODULE__{
      source_type: :hex,
      hex: %{package: package, version: version},
      config: config
    }
  end
end
