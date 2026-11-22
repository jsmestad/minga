defmodule Minga.Extension.Bundled do
  @moduledoc """
  Catalog of optional extensions that ship inside Minga.

  A shipped extension is never loaded by default. A user turns it on with a source-free declaration such as `extension :git_porcelain`, which this module resolves to the extension's registry name, shipped source directory, and default load policy. Trust for the shipped OTP application stays in `Minga.Extension.BundledApplications`.
  """

  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Log
  alias Minga.Project.Detector

  @typedoc "Spec for one extension that ships inside Minga."
  @type spec :: %{
          registry_name: atom(),
          directory: String.t(),
          load_policy: Minga.Extension.load_policy()
        }

  @catalog %{
    git_porcelain: %{
      registry_name: :minga_git_porcelain,
      directory: "git_porcelain",
      load_policy: :deferred
    }
  }

  @git_porcelain_upgrade_notice "Git porcelain (status panel, staging, commit, branch, and conflict workflows) is now opt-in. Add `extension :git_porcelain` to config.exs and restart to turn it on."

  @doc "Returns the config names of every shipped extension, sorted."
  @spec names() :: [atom()]
  def names, do: @catalog |> Map.keys() |> Enum.sort()

  @doc "Returns the spec for a shipped extension config name."
  @spec fetch(atom()) :: {:ok, spec()} | :error
  def fetch(name) when is_atom(name), do: Map.fetch(@catalog, name)

  @doc "Returns true when the shipped extension `name` is declared in the extension registry."
  @spec declared?(atom(), GenServer.server()) :: boolean()
  def declared?(name, registry \\ ExtRegistry) when is_atom(name) do
    case fetch(name) do
      {:ok, %{registry_name: registry_name}} -> ExtRegistry.get(registry, registry_name) != :error
      :error -> false
    end
  end

  @doc """
  Declares a shipped extension in the extension registry.

  Extra keyword options are passed to the extension as config. The catalog load policy applies unless the declaration sets `:load_policy`.
  """
  @spec register(GenServer.server(), spec(), keyword()) :: :ok
  def register(registry \\ ExtRegistry, %{} = spec, config) when is_list(config) do
    config = Keyword.put_new(config, :load_policy, spec.load_policy)
    ExtRegistry.register(registry, spec.registry_name, source_path(spec), config)
  end

  @doc """
  Returns the one-time upgrade notice for a project, or `nil`.

  The notice applies only when `project_root` is inside a git repository and git porcelain is not declared in the extension registry.
  """
  @spec git_porcelain_upgrade_notice(String.t() | nil, GenServer.server()) :: String.t() | nil
  def git_porcelain_upgrade_notice(project_root, registry \\ ExtRegistry)

  def git_porcelain_upgrade_notice(nil, _registry), do: nil

  def git_porcelain_upgrade_notice(project_root, registry) when is_binary(project_root) do
    if git_repository?(project_root) and not declared?(:git_porcelain, registry) do
      @git_porcelain_upgrade_notice
    end
  end

  @spec git_repository?(String.t()) :: boolean()
  defp git_repository?(project_root) do
    # Detector walks up from the parent of the given path, so probe a child of the root.
    case Detector.detect(Path.join(project_root, ".minga-probe"), [{".git", :git}]) do
      {:ok, _root, :git} -> true
      :none -> false
    end
  end

  @spec source_path(spec()) :: String.t()
  defp source_path(%{directory: directory}) do
    priv_path = Application.app_dir(:minga, Path.join(["priv", "extensions", directory, "lib"]))

    if File.dir?(priv_path) do
      priv_path
    else
      source_fallback_path(directory, priv_path)
    end
  end

  @spec source_fallback_path(String.t(), String.t()) :: String.t()
  defp source_fallback_path(directory, priv_path) do
    source_path = Path.expand("../../../extensions/#{directory}/lib", __DIR__)

    if source_fallback_allowed?() and File.dir?(source_path) do
      source_path
    else
      Log.warning(
        :config,
        "Bundled extension #{directory} is missing at #{priv_path}; source-tree fallback is disabled"
      )

      priv_path
    end
  end

  @spec source_fallback_allowed?() :: boolean()
  defp source_fallback_allowed? do
    Application.get_env(:minga, :allow_source_extension_fallback, false)
  end
end
