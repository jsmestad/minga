defmodule Mix.Tasks.Release.Tui do
  @moduledoc "Assembles the TUI Mix release from an explicitly qualified native OTP runtime."

  use Mix.Task

  @shortdoc "Assembles the native TUI release"
  @runtime_path {__MODULE__, :runtime_path}

  @impl Mix.Task
  @spec run([String.t()]) :: term()
  def run(args) do
    Minga.ReleaseERTS.with_verified_runtime(fn path ->
      previous = Process.put(@runtime_path, path)

      try do
        Mix.Task.run("release", ["minga" | args])
      after
        if is_nil(previous) do
          Process.delete(@runtime_path)
        else
          Process.put(@runtime_path, previous)
        end
      end
    end)
  end

  @doc "Returns the verified ERTS path during synchronous TUI release assembly."
  @spec erts_path!() :: Path.t()
  def erts_path! do
    Process.get(@runtime_path) ||
      Mix.raise("Run mix release.tui to assemble the qualified TUI release")
  end

  @doc "Rejects any OTP application Mix resolved from the host instead of the qualified tree."
  @spec verify_otp_apps!(Mix.Release.t()) :: Mix.Release.t()
  def verify_otp_apps!(%Mix.Release{} = release) do
    host_lib = Path.expand(:code.lib_dir()) <> "/"
    qualified_lib = Path.join(Path.dirname(release.erts_source), "lib") <> "/"

    host_apps =
      for {app, properties} <- release.applications,
          path = Path.expand(Keyword.fetch!(properties, :path)),
          String.starts_with?(path, host_lib) and not String.starts_with?(path, qualified_lib),
          do: app

    if host_apps != [] do
      Mix.raise(
        "Qualified OTP runtime is missing applications; Mix resolved them from the host: " <>
          Enum.map_join(Enum.sort(host_apps), ", ", &Atom.to_string/1)
      )
    end

    release
  end
end
