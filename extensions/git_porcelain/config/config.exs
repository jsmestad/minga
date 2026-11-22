import Config

if config_env() == :test do
  # Mix does not load core's config/test.exs for a path dependency, so the standalone suite
  # mirrors its isolation: Minga resolves config, data, cache, and state paths from XDG
  # variables, and each run gets a fresh private root. HOME stays unchanged because Mix and
  # tools such as asdf need it.
  test_profile =
    Path.join(
      System.tmp_dir!(),
      "minga-git-porcelain-test-" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    )

  File.mkdir!(test_profile)

  for {env, subdir} <- [
        {"XDG_CONFIG_HOME", "config"},
        {"XDG_DATA_HOME", "data"},
        {"XDG_CACHE_HOME", "cache"},
        {"XDG_STATE_HOME", "state"}
      ] do
    path = Path.join(test_profile, subdir)
    File.mkdir!(path)
    System.put_env(env, path)
  end

  File.mkdir!(Path.join([test_profile, "config", "minga"]))

  # Git porcelain is opt-in, so the standalone suite enables it the way users do: through a
  # config file that declares `extension :git_porcelain`. The fixture also keeps the
  # developer's own ~/.config/minga/config.exs out of the suite.
  config :minga,
    cli_startup_flags: %{config_file: Path.expand("../test/fixtures/config.exs", __DIR__)}
end
