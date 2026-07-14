defmodule Minga.MacOSLauncherTest do
  # Not async: these tests spawn real shell processes, which can hit the BEAM child-process race.
  use ExUnit.Case, async: false

  @launcher Path.expand("../../macos/Resources/bin/minga", __DIR__)
  @tui_wrapper Path.expand("../../macos/Resources/bin/minga-tui", __DIR__)

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "minga-macos-launcher-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace = Path.join(root, "workspace")
    app = Path.join(root, "Minga.app")
    open_log = Path.join(root, "open.log")
    standalone_log = Path.join(root, "standalone.log")
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

    env = [
      {"MINGA_APP_PATH", app},
      {"MINGA_OPEN_BIN", open_bin},
      {"MINGA_STANDALONE_BIN", standalone_bin},
      {"MINGA_TEST_OPEN_LOG", open_log},
      {"MINGA_TEST_STANDALONE_LOG", standalone_log}
    ]

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     root: root,
     workspace: workspace,
     app: app,
     open_log: open_log,
     standalone_log: standalone_log,
     env: env}
  end

  test "a directory target uses Launch Services without forcing a second app instance", ctx do
    assert {_, 0} = run_launcher(["."], ctx)

    assert read_args(ctx.open_log) == ["-a", ctx.app, ctx.workspace]
    refute "-n" in read_args(ctx.open_log)
  end

  test "a loose file target is handed to the running app as a file open", ctx do
    assert {_, 0} = run_launcher(["README.md"], ctx)

    assert read_args(ctx.open_log) == [
             "-a",
             ctx.app,
             Path.join(ctx.workspace, "README.md")
           ]
  end

  test "GUI flags and path-valued flags preserve the target", ctx do
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
             Path.join(ctx.workspace, "README.md"),
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
             Path.join(ctx.workspace, "other.log")
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

  test "--wait keeps the existing private wait handoff and forwards GUI flags", ctx do
    wait_open =
      write_script!(ctx.root, "wait-open", """
      : > "$MINGA_TEST_OPEN_LOG"
      for arg in "$@"; do printf '[%s]\\n' "$arg" >> "$MINGA_TEST_OPEN_LOG"; done
      python3 - "$@" <<'PY'
      import base64
      import os
      import sys

      for arg in sys.argv[1:]:
          if not arg.startswith("minga://wait/"):
              continue
          encoded = arg.split("/")[3]
          encoded += "=" * (-len(encoded) % 4)
          result = base64.urlsafe_b64decode(encoded).decode()
          open(os.path.join(os.path.dirname(result), "ack"), "w").close()
          with open(result, "w") as handle:
              handle.write("0\\tclosed\\n")
      PY
      """)

    pgrep = write_script!(ctx.root, "pgrep", "echo 1\n")

    env =
      ctx.env
      |> put_env("MINGA_OPEN_BIN", wait_open)
      |> put_env("MINGA_PGREP_BIN", pgrep)

    assert {_, 0} = run_launcher(["--wait", "--minimal", "README.md"], %{ctx | env: env})

    app = ctx.app
    assert ["-a", ^app, wait_url, "--args", "--minimal"] = read_args(ctx.open_log)
    assert String.starts_with?(wait_url, "minga://wait/")
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
