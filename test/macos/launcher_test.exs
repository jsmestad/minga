defmodule Minga.MacOSLauncherTest do
  # Not async: these tests spawn real shell processes, which can hit the BEAM child-process race.
  use ExUnit.Case, async: false

  @launcher Path.expand("../../macos/Resources/bin/minga", __DIR__)
  @tui_wrapper Path.expand("../../macos/Resources/bin/minga-tui", __DIR__)

  setup do
    tmp_dir = File.cd!(System.tmp_dir!(), &File.cwd!/0)

    root =
      Path.join(
        tmp_dir,
        "minga-macos-launcher-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(root, "workspace")
    app = Path.join(root, "Minga.app")
    open_log = Path.join(root, "open.log")
    standalone_log = Path.join(root, "standalone.log")
    ipc_log = Path.join(root, "ipc.log")
    File.mkdir_p!(Path.join(app, "Contents/MacOS"))
    File.mkdir_p!(workspace)
    File.write!(Path.join(app, "Contents/MacOS/Minga"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(app, "Contents/MacOS/Minga"), 0o755)
    File.write!(Path.join(workspace, "README.md"), "hello\n")

    open_bin =
      write_script!(root, "open", """
      : > "$MINGA_TEST_OPEN_LOG"
      for arg in "$@"; do printf '[%s]\\n' "$arg" >> "$MINGA_TEST_OPEN_LOG"; done
      exit "${MINGA_TEST_OPEN_STATUS:-0}"
      """)

    standalone_bin =
      write_script!(root, "standalone", """
      : > "$MINGA_TEST_STANDALONE_LOG"
      for arg in "$@"; do printf '[%s]\\n' "$arg" >> "$MINGA_TEST_STANDALONE_LOG"; done
      """)

    ipc_bin =
      write_script!(root, "minga-ipc", """
      command="$1"
      shift
      case "$command" in
        probe) exit "${MINGA_TEST_PROBE_STATUS:-3}" ;;
        nonce) printf '%s\\n' "launch-nonce-test" ;;
        open|wait)
          : > "$MINGA_TEST_IPC_LOG"
          for arg in "$@"; do printf '[%s]\\n' "$arg" >> "$MINGA_TEST_IPC_LOG"; done
          if [ -n "${MINGA_TEST_RETRYABLE_ONCE_FILE:-}" ] && [ ! -e "$MINGA_TEST_RETRYABLE_ONCE_FILE" ]; then
            : > "$MINGA_TEST_RETRYABLE_ONCE_FILE"
            exit 5
          fi
          printf '%s' "${MINGA_TEST_WAIT_MESSAGE:-}"
          exit "${MINGA_TEST_WAIT_STATUS:-0}"
          ;;
      esac
      """)

    env = [
      {"MINGA_APP_PATH", app},
      {"MINGA_OPEN_BIN", open_bin},
      {"MINGA_STANDALONE_BIN", standalone_bin},
      {"MINGA_IPC_BIN", ipc_bin},
      {"MINGA_TEST_OPEN_LOG", open_log},
      {"MINGA_TEST_STANDALONE_LOG", standalone_log},
      {"MINGA_TEST_IPC_LOG", ipc_log}
    ]

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     root: root,
     workspace: workspace,
     app: app,
     open_log: open_log,
     standalone_log: standalone_log,
     ipc_log: ipc_log,
     env: env}
  end

  test "a directory target uses Launch Services without forcing a second app instance", ctx do
    assert {_, 0} = run_launcher(["."], ctx)

    assert read_args(ctx.open_log) == ["-a", ctx.app, ctx.workspace]
    refute "-n" in read_args(ctx.open_log)
  end

  test "a probe that loses the app before acceptance falls back to a cold launch", ctx do
    env = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "5")

    assert {_, 0} = run_launcher(["README.md"], %{ctx | env: env})

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "a loose file target is handed to the running app as a file open", ctx do
    assert {_, 0} = run_launcher(["README.md"], ctx)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "cold startup flags launch without targets then deliver paths over IPC", ctx do
    args = [
      "--editor",
      "--minimal",
      "--safe",
      "-Q",
      "--config",
      "config.exs",
      "--debug-log",
      "debug.log",
      "-D",
      "other.log",
      "README.md"
    ]

    assert {_, 0} = run_launcher(args, ctx)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             "--args",
             "--editor",
             "--minimal",
             "--safe",
             "-Q",
             "--config",
             Path.join(ctx.workspace, "config.exs"),
             "--debug-log",
             Path.join(ctx.workspace, "debug.log"),
             "-D",
             Path.join(ctx.workspace, "other.log"),
             "--minga-launch-nonce",
             "launch-nonce-test"
           ]

    assert read_args(ctx.ipc_log) == [
             "--expected-launch-nonce",
             "launch-nonce-test",
             "--editor",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "terminal commands and headless mode never invoke Launch Services", ctx do
    invocations = [
      ["--headless", "--port", "4821"],
      ["attach", "ssh://devbox/work/app"],
      ["sessions", "ssh://devbox"],
      ["detach"],
      ["kill-session", "ssh://devbox/work/app"],
      ["login", "--manual"]
    ]

    for args <- invocations do
      File.rm(ctx.open_log)
      assert {_, 0} = run_launcher(args, ctx)
      assert read_args(ctx.standalone_log) == args
      refute File.exists?(ctx.open_log)
    end
  end

  test "--tui and --standalone force the standalone runtime and are not forwarded", ctx do
    assert {_, 0} = run_launcher(["--tui", "README.md"], ctx)
    assert read_args(ctx.standalone_log) == ["README.md"]
    refute File.exists?(ctx.open_log)

    assert {_, 0} = run_launcher(["--standalone", "--safe", "README.md"], ctx)
    assert read_args(ctx.standalone_log) == ["--safe", "README.md"]
  end

  test "a symlinked launcher resolves an app installed in a custom directory", ctx do
    bundled_launcher = Path.join(ctx.app, "Contents/Resources/bin/minga")
    symlinked_launcher = Path.join(ctx.root, "bin/minga")
    File.mkdir_p!(Path.dirname(bundled_launcher))
    File.mkdir_p!(Path.dirname(symlinked_launcher))
    File.cp!(@launcher, bundled_launcher)
    File.chmod!(bundled_launcher, 0o755)
    File.ln_s!(bundled_launcher, symlinked_launcher)

    env = Enum.reject(ctx.env, fn {key, _value} -> key == "MINGA_APP_PATH" end)

    assert {_, 0} =
             System.cmd(symlinked_launcher, ["README.md"],
               cd: ctx.workspace,
               env: env,
               stderr_to_stdout: true
             )

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "a damaged app and an open failure produce explicit errors", ctx do
    damaged_env = put_env(ctx.env, "MINGA_APP_PATH", Path.join(ctx.root, "Damaged.app"))

    assert {output, 1} = run_launcher(["README.md"], %{ctx | env: damaged_env})
    assert output =~ "Minga.app is missing or damaged"
    assert output =~ "minga --tui"
    refute File.exists?(ctx.standalone_log)

    failing_env = [{"MINGA_TEST_OPEN_STATUS", "23"} | ctx.env]
    assert {output, 1} = run_launcher(["README.md"], %{ctx | env: failing_env})
    assert output =~ "failed to launch or hand off to Minga.app"
  end

  test "cold request-local editor opens launch without targets and safely reconnect on conflict",
       ctx do
    assert {_, 0} = run_launcher(["--editor", "README.md"], ctx)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             "--args",
             "--editor",
             "--minga-launch-nonce",
             "launch-nonce-test"
           ]

    assert read_args(ctx.ipc_log) == [
             "--expected-launch-nonce",
             "launch-nonce-test",
             "--allow-launch-conflict",
             "--editor",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "wait rejects directory targets before launching the app", ctx do
    assert {output, 2} = run_launcher(["--wait", "."], ctx)
    assert output =~ "--wait requires a file target, not a directory"
    refute File.exists?(ctx.open_log)
    refute File.exists?(ctx.ipc_log)
  end

  test "cold --wait launches with a nonce then delegates the lifecycle to native IPC", ctx do
    assert {_, 0} = run_launcher(["--wait", "--minimal", "README.md"], ctx)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             "--args",
             "--minimal",
             "--minga-launch-nonce",
             "launch-nonce-test"
           ]

    assert read_args(ctx.ipc_log) == [
             "--expected-launch-nonce",
             "launch-nonce-test",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "cold wait without startup-only flags permits a nonce-conflict reconnect", ctx do
    assert {_, 0} = run_launcher(["--wait", "--editor", "README.md"], ctx)

    assert read_args(ctx.ipc_log) == [
             "--expected-launch-nonce",
             "launch-nonce-test",
             "--allow-launch-conflict",
             "--editor",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "running app receives file opens and --editor through authenticated IPC", ctx do
    env = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "0")
    assert {_, 0} = run_launcher(["--editor", "README.md"], %{ctx | env: env})
    assert read_args(ctx.open_log) == ["-a", ctx.app]

    assert read_args(ctx.ipc_log) == [
             "--editor",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "running app receives a directory through authenticated IPC", ctx do
    env = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "0")
    assert {_, 0} = run_launcher(["."], %{ctx | env: env})
    assert read_args(ctx.open_log) == ["-a", ctx.app]
    assert read_args(ctx.ipc_log) == [ctx.workspace]
  end

  test "running app wait activates the exact instance and accepts --editor per request", ctx do
    env = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "0")
    assert {_, 0} = run_launcher(["--wait", "--editor", "README.md"], %{ctx | env: env})
    assert read_args(ctx.open_log) == ["-a", ctx.app]
    assert read_args(ctx.ipc_log) == ["--editor", Path.join(ctx.workspace, "README.md")]
  end

  test "running open relaunches and retries once after pre-acceptance app loss", ctx do
    retry_marker = Path.join(ctx.root, "open-retry.marker")

    env =
      ctx.env
      |> put_env("MINGA_TEST_PROBE_STATUS", "0")
      |> put_env("MINGA_TEST_RETRYABLE_ONCE_FILE", retry_marker)

    assert {_, 0} = run_launcher(["README.md"], %{ctx | env: env})
    assert File.exists?(retry_marker)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             "--args",
             "--minga-launch-nonce",
             "launch-nonce-test"
           ]

    assert read_args(ctx.ipc_log) == [
             "--expected-launch-nonce",
             "launch-nonce-test",
             "--allow-launch-conflict",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "running wait relaunches and retries once only before acceptance", ctx do
    retry_marker = Path.join(ctx.root, "wait-retry.marker")

    env =
      ctx.env
      |> put_env("MINGA_TEST_PROBE_STATUS", "0")
      |> put_env("MINGA_TEST_RETRYABLE_ONCE_FILE", retry_marker)

    assert {_, 0} = run_launcher(["--wait", "README.md"], %{ctx | env: env})
    assert File.exists?(retry_marker)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             "--args",
             "--minga-launch-nonce",
             "launch-nonce-test"
           ]

    assert read_args(ctx.ipc_log) == [
             "--expected-launch-nonce",
             "launch-nonce-test",
             "--allow-launch-conflict",
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "probe distinguishes insecure endpoints from inspection failures", ctx do
    insecure = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "4")
    assert {insecure_output, 1} = run_launcher(["README.md"], %{ctx | env: insecure})
    assert insecure_output =~ "failed security validation"

    unavailable = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "1")
    assert {unavailable_output, 1} = run_launcher(["README.md"], %{ctx | env: unavailable})
    assert unavailable_output =~ "could not inspect"
  end

  test "startup-only flags fail clearly when an authenticated endpoint exists", ctx do
    env = put_env(ctx.env, "MINGA_TEST_PROBE_STATUS", "0")

    assert {output, 2} =
             run_launcher(["--minimal", "--config", "config.exs", "README.md"], %{
               ctx
               | env: env
             })

    assert output =~ "startup-only flag(s)"
    assert output =~ "--minimal"
    assert output =~ "--config"
    assert output =~ "Quit Minga.app first"
    refute File.exists?(ctx.open_log)
  end

  test "wait helper disconnect is returned without launcher polling or process guessing", ctx do
    env =
      ctx.env
      |> put_env("MINGA_TEST_PROBE_STATUS", "0")
      |> put_env("MINGA_TEST_WAIT_STATUS", "1")
      |> put_env("MINGA_TEST_WAIT_MESSAGE", "endpoint disconnected")

    assert {output, 1} = run_launcher(["--wait", "README.md"], %{ctx | env: env})
    assert output =~ "endpoint disconnected"
    assert read_args(ctx.open_log) == ["-a", ctx.app]
  end

  test "the bundled TUI wrapper classifies editor and terminal startup", ctx do
    release_log = Path.join(ctx.root, "release.log")

    release_bin =
      write_script!(ctx.root, "release", """
      printf 'editor=[%s]\\n' "$MINGA_STANDALONE_EDITOR" > "$MINGA_TEST_RELEASE_LOG"
      printf 'mode=[%s]\\n' "$MINGA_STANDALONE_TUI" >> "$MINGA_TEST_RELEASE_LOG"
      printf 'args=[%s]\\n' "$MINGA_CLI_ARGS_B64" >> "$MINGA_TEST_RELEASE_LOG"
      for arg in "$@"; do printf '[%s]\\n' "$arg" >> "$MINGA_TEST_RELEASE_LOG"; done
      """)

    env = [
      {"MINGA_RELEASE_BIN", release_bin},
      {"MINGA_TEST_RELEASE_LOG", release_log}
    ]

    assert {_, 0} = System.cmd(@tui_wrapper, ["README.md"], env: env, stderr_to_stdout: true)

    assert File.read!(release_log) ==
             "editor=[1]\nmode=[1]\nargs=[#{encode_args(["README.md"])}]\n[start]\n"

    attach_args = ["attach", "ssh://devbox/work/app"]
    assert {_, 0} = System.cmd(@tui_wrapper, attach_args, env: env, stderr_to_stdout: true)

    assert File.read!(release_log) ==
             "editor=[1]\nmode=[1]\nargs=[#{encode_args(attach_args)}]\n[start]\n"

    login_args = ["login", "--manual"]
    assert {_, 0} = System.cmd(@tui_wrapper, login_args, env: env, stderr_to_stdout: true)

    assert File.read!(release_log) ==
             "editor=[0]\nmode=[1]\nargs=[#{encode_args(login_args)}]\n[start]\n"

    headless_args = ["--headless", "--port", "4821"]
    assert {_, 0} = System.cmd(@tui_wrapper, headless_args, env: env, stderr_to_stdout: true)

    assert File.read!(release_log) ==
             "editor=[0]\nmode=[1]\nargs=[#{encode_args(headless_args)}]\n[start]\n"
  end

  test "the TUI wrapper installs explicit cookies before the release VM starts", ctx do
    release_log = Path.join(ctx.root, "cookie-release.log")

    release_bin =
      write_script!(ctx.root, "cookie-release", """
      printf 'cookie=[%s]\n' "${RELEASE_COOKIE:-}" > "$MINGA_TEST_RELEASE_LOG"
      """)

    base_env = [
      {"MINGA_RELEASE_BIN", release_bin},
      {"MINGA_TEST_RELEASE_LOG", release_log}
    ]

    env_cookie = "abcdefghijklmnopqrstuvwxyz123456"

    assert {_, 0} =
             System.cmd(@tui_wrapper, ["--headless"],
               env: [{"MINGA_COOKIE", env_cookie} | base_env],
               stderr_to_stdout: true
             )

    assert File.read!(release_log) == "cookie=[#{env_cookie}]\n"

    file_cookie = "zyxwvutsrqponmlkjihgfedcba654321"
    cookie_file = Path.join(ctx.root, "distribution.cookie")
    File.write!(cookie_file, file_cookie <> "\n")
    File.chmod!(cookie_file, 0o600)

    assert {_, 0} =
             System.cmd(@tui_wrapper, ["--headless", "--cookie-file", cookie_file],
               env: [{"MINGA_COOKIE", env_cookie} | base_env],
               stderr_to_stdout: true
             )

    assert File.read!(release_log) == "cookie=[#{file_cookie}]\n"
  end

  test "all bundled TUI boots clear pre-VM flags and assert local preboot distribution", ctx do
    release_log = Path.join(ctx.root, "local-release.log")

    release_bin =
      write_script!(ctx.root, "local-release", """
      printf 'expected=[%s]\n' "${MINGA_EXPECT_DISTRIBUTION:-}" > "$MINGA_TEST_RELEASE_LOG"
      printf 'erl_aflags=[%s]\n' "${ERL_AFLAGS:-}" >> "$MINGA_TEST_RELEASE_LOG"
      printf 'erl_flags=[%s]\n' "${ERL_FLAGS:-}" >> "$MINGA_TEST_RELEASE_LOG"
      printf 'erl_zflags=[%s]\n' "${ERL_ZFLAGS:-}" >> "$MINGA_TEST_RELEASE_LOG"
      printf 'elixir_erl_options=[%s]\n' "${ELIXIR_ERL_OPTIONS:-}" >> "$MINGA_TEST_RELEASE_LOG"
      printf 'release_vm_args=[%s]\n' "${RELEASE_VM_ARGS:-}" >> "$MINGA_TEST_RELEASE_LOG"
      printf 'cookie_length=[%s]\n' "${#RELEASE_COOKIE}" >> "$MINGA_TEST_RELEASE_LOG"
      """)

    env = [
      {"MINGA_RELEASE_BIN", release_bin},
      {"MINGA_TEST_RELEASE_LOG", release_log},
      {"ERL_AFLAGS", "-sname inherited"},
      {"ERL_FLAGS", "-name inherited@example"},
      {"ERL_ZFLAGS", "-sname inherited_zflags"},
      {"ELIXIR_ERL_OPTIONS", "-sname inherited_elixir"},
      {"RELEASE_VM_ARGS", "/tmp/inherited.vm.args"},
      {"RELEASE_COOKIE", ""}
    ]

    expected =
      "expected=[0]\nerl_aflags=[]\nerl_flags=[]\nerl_zflags=[]\n" <>
        "elixir_erl_options=[]\nrelease_vm_args=[]\ncookie_length=[64]\n"

    for args <- [["README.md"], ["--headless"], ["attach", "ssh://devbox/work/app"]] do
      assert {_, 0} = System.cmd(@tui_wrapper, args, env: env, stderr_to_stdout: true)
      assert File.read!(release_log) == expected
    end
  end

  test "the TUI wrapper resolves the standalone runtime from an installed app", ctx do
    release_log = Path.join(ctx.root, "installed-release.log")
    release_bin = Path.join(ctx.app, "Contents/Resources/release/bin/minga_macos")
    File.mkdir_p!(Path.dirname(release_bin))

    File.write!(
      release_bin,
      "#!/bin/sh\nprintf 'args=[%s]\\n' \"$MINGA_CLI_ARGS_B64\" > \"$MINGA_TEST_RELEASE_LOG\"\nprintf '[%s]\\n' \"$@\" >> \"$MINGA_TEST_RELEASE_LOG\"\n"
    )

    File.chmod!(release_bin, 0o755)

    env = [
      {"MINGA_APP_PATH", ctx.app},
      {"MINGA_TEST_RELEASE_LOG", release_log}
    ]

    assert {_, 0} = System.cmd(@tui_wrapper, ["README.md"], env: env, stderr_to_stdout: true)
    assert File.read!(release_log) == "args=[#{encode_args(["README.md"])}]\n[start]\n"
  end

  defp encode_args(args) do
    Enum.map_join(args, ",", &Base.url_encode64(&1, padding: false))
  end

  defp run_launcher(args, ctx) do
    System.cmd(@launcher, args,
      cd: ctx.workspace,
      env: ctx.env,
      stderr_to_stdout: true
    )
  end

  defp put_env(env, key, value) do
    [{key, value} | Enum.reject(env, fn {existing, _value} -> existing == key end)]
  end

  defp read_args(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> line |> String.trim_leading("[") |> String.trim_trailing("]") end)
  end

  defp write_script!(root, name, body) do
    path = Path.join(root, name)
    File.write!(path, "#!/bin/sh\nset -eu\n#{body}")
    File.chmod!(path, 0o755)
    path
  end
end
