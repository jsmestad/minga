import Config

if config_env() == :test do
  # Git porcelain is opt-in, so the standalone suite enables it the way users do: through a
  # config file that declares `extension :git_porcelain`. The fixture also keeps the
  # developer's own ~/.config/minga/config.exs out of the suite.
  config :minga,
    cli_startup_flags: %{config_file: Path.expand("../test/fixtures/config.exs", __DIR__)}
end
