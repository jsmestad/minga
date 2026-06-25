defmodule MingaEditor.Frontend.Resolve do
  @moduledoc """
  Resolves renderer binary and tty paths for the frontend port.

  Extracted from `MingaEditor.Frontend.Manager` so that path resolution
  (including `System.cmd` calls) happens in the supervisor before the
  GenServer starts, keeping the GenServer init free of blocking I/O.
  """

  @type backend :: :tui | :gui

  @spec renderer_path(backend()) :: String.t()
  def renderer_path(backend) do
    binary_name = renderer_binary_name(backend)

    case find_app_bundle_binary(binary_name, backend) do
      {:ok, path} ->
        path

      :not_in_bundle ->
        priv_path = Application.app_dir(:minga, "priv/#{binary_name}")
        if File.exists?(priv_path), do: priv_path, else: dev_fallback_path(backend)
    end
  end

  @spec tty_path() :: String.t() | nil
  def tty_path do
    System.get_env("MINGA_TTY") || detect_tty()
  end

  @spec detect_tty() :: String.t() | nil
  defp detect_tty do
    case System.cmd("ps", ["-o", "tty=", "-p", to_string(:os.getpid())]) do
      {output, 0} -> MingaEditor.Frontend.Manager.tty_path_for(String.trim(output))
      _ -> nil
    end
  end

  @spec renderer_binary_name(backend()) :: String.t()
  defp renderer_binary_name(:tui) do
    validate_tui_frontend!()
    "minga-renderer-go"
  end

  defp renderer_binary_name(:gui), do: "Minga"

  @spec validate_tui_frontend!() :: :ok
  defp validate_tui_frontend! do
    case System.get_env("MINGA_FRONTEND") do
      nil -> :ok
      "go" -> :ok
      value -> raise ArgumentError, "MINGA_FRONTEND=#{value} is not valid. Only \"go\" is valid."
    end
  end

  @spec find_app_bundle_binary(String.t(), backend()) :: {:ok, String.t()} | :not_in_bundle
  defp find_app_bundle_binary(binary_name, :gui) do
    case app_bundle_root() do
      {:ok, bundle_root} ->
        gui_path = Path.join([bundle_root, "Contents", "MacOS", binary_name])
        if File.exists?(gui_path), do: {:ok, gui_path}, else: :not_in_bundle

      :not_in_bundle ->
        :not_in_bundle
    end
  end

  defp find_app_bundle_binary(_binary_name, _tui), do: :not_in_bundle

  @spec app_bundle_root() :: {:ok, String.t()} | :not_in_bundle
  defp app_bundle_root do
    release_root = :code.root_dir() |> to_string()

    if String.contains?(release_root, ".app/Contents/Resources/release") do
      bundle_root =
        release_root
        |> Path.join("..")
        |> Path.join("..")
        |> Path.join("..")
        |> Path.expand()

      {:ok, bundle_root}
    else
      :not_in_bundle
    end
  end

  @spec dev_fallback_path(backend()) :: String.t()
  defp dev_fallback_path(:gui), do: find_xcode_build_product("Minga")

  defp dev_fallback_path(:tui),
    do: Path.join([File.cwd!(), "go", "tui", "bin", "minga-renderer-go"])

  @spec find_xcode_build_product(String.t()) :: String.t()
  defp find_xcode_build_product(product_name) do
    project_path = Path.join([File.cwd!(), "macos", "Minga.xcodeproj"])

    case System.cmd(
           "xcodebuild",
           [
             "-project",
             project_path,
             "-scheme",
             "Minga",
             "-configuration",
             "Debug",
             "-showBuildSettings"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        resolve_build_product_path(output, product_name)

      _ ->
        Path.join([File.cwd!(), "macos", "build", "Debug", product_name])
    end
  end

  @spec resolve_build_product_path(String.t(), String.t()) :: String.t()
  defp resolve_build_product_path(build_settings, product_name) do
    built_dir = parse_build_setting(build_settings, "BUILT_PRODUCTS_DIR")
    full_product = parse_build_setting(build_settings, "FULL_PRODUCT_NAME")

    case {built_dir, full_product} do
      {dir, app_name} when is_binary(dir) and is_binary(app_name) ->
        resolve_executable_in_product(dir, app_name, product_name)

      {dir, _} when is_binary(dir) ->
        Path.join(dir, product_name)

      _ ->
        Path.join([File.cwd!(), "macos", "build", "Debug", product_name])
    end
  end

  @spec resolve_executable_in_product(String.t(), String.t(), String.t()) :: String.t()
  defp resolve_executable_in_product(dir, app_name, product_name) do
    if String.ends_with?(app_name, ".app") do
      Path.join([dir, app_name, "Contents", "MacOS", product_name])
    else
      Path.join(dir, product_name)
    end
  end

  @spec parse_build_setting(String.t(), String.t()) :: String.t() | nil
  defp parse_build_setting(output, key) do
    case Regex.run(~r/\s+#{Regex.escape(key)} = (.+)/, output) do
      [_, value] -> String.trim(value)
      _ -> nil
    end
  end
end
