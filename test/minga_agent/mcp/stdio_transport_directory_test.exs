defmodule MingaAgent.MCP.StdioTransportDirectoryTest do
  # Starts real /bin/sh children. OS process tests must not run concurrently because of BEAM child setup races.
  use ExUnit.Case, async: false

  alias MingaAgent.MCP.ServerConfig
  alias MingaAgent.MCP.StdioTransport

  @moduletag timeout: 20_000

  setup do
    project = Path.join(System.tmp_dir!(), "minga_mcp_cwd_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(project, "probe"))
    on_exit(fn -> File.rm_rf!(project) end)
    {:ok, canonical} = Minga.Project.Root.canonical_path(project)

    # The script says where it ran. Its name exists in the project only, not in the directory the tests run in.
    File.write!(Path.join(project, "probe/serve.sh"), "#!/bin/sh\npwd > \"$OUT\"\n")
    File.chmod!(Path.join(project, "probe/serve.sh"), 0o755)
    refute File.exists?(Path.join(File.cwd!(), "probe/serve.sh"))
    {:ok, project: canonical, out: Path.join(canonical, "ran_in")}
  end

  test "a server with a directory starts there: a relative argument names the project's file, not the VM's",
       %{project: project, out: out} do
    refute File.cwd!() == project

    config = %ServerConfig{
      name: "probe",
      command: "/bin/sh",
      args: ["probe/serve.sh"],
      env: %{"OUT" => out},
      cwd: project
    }

    assert {:ok, %StdioTransport{port: port}} = StdioTransport.start(config, self(), [])
    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert String.trim(File.read!(out)) == project
  end

  test "a relative program with a separator is the file in the server's directory", %{
    project: project,
    out: out
  } do
    config = %ServerConfig{
      name: "probe",
      command: "probe/serve.sh",
      env: %{"OUT" => out},
      cwd: project
    }

    assert {:ok, %StdioTransport{port: port}} = StdioTransport.start(config, self(), [])
    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert String.trim(File.read!(out)) == project
  end

  test "a bare program name is found on the PATH of the start, in absolute folders only", %{
    project: project,
    out: out
  } do
    config = %ServerConfig{name: "probe", command: "serve.sh", env: %{"OUT" => out}, cwd: project}
    folder = Path.join(project, "probe")

    # A relative entry would mean the server's own directory. It is passed over.
    assert StdioTransport.start(config, self(), path: "probe") ==
             {:error, "MCP server executable not found: serve.sh"}

    assert {:ok, %StdioTransport{port: port}} = StdioTransport.start(config, self(), path: folder)
    assert_receive {^port, {:exit_status, 0}}, 10_000
    assert String.trim(File.read!(out)) == project
  end

  test "a directory that is no longer there is an error for that server, not a crash", %{out: out} do
    config = %ServerConfig{
      name: "probe",
      command: "/bin/sh",
      args: ["-c", "pwd > \"$OUT\""],
      env: %{"OUT" => out},
      cwd: "/nowhere/at/all"
    }

    # The child cannot enter the directory and exits. The server fails to start; nothing runs anywhere else.
    assert {:ok, %StdioTransport{port: port}} = StdioTransport.start(config, self(), [])
    assert_receive {^port, {:exit_status, status}}, 10_000
    assert status != 0
    refute File.exists?(out)
  end

  test "without a directory a relative program that is not where Minga runs is not found", %{
    out: out
  } do
    config = %ServerConfig{name: "probe", command: "probe/serve.sh", env: %{"OUT" => out}}

    assert StdioTransport.start(config, self(), []) ==
             {:error, "MCP server executable not found: probe/serve.sh"}
  end
end
