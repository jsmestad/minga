defmodule Minga.Extension.JsonLoaderTest do
  # Exercises real FIFOs and atomic filesystem replacement races.
  use ExUnit.Case, async: false

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.JsonLoader

  @moduletag :tmp_dir

  _ = :session_start

  @valid_manifest Jason.encode!(%{
                    "name" => "hello-world",
                    "description" => "A simple greeting plugin",
                    "version" => "0.1.0",
                    "hooks" => [
                      %{
                        "event" => "session_start",
                        "command" => "${MINGA_PLUGIN_ROOT}/hooks/hello.sh"
                      }
                    ],
                    "skills" => ["${MINGA_PLUGIN_ROOT}/skills/greet"],
                    "mcp_servers" => [
                      %{
                        "name" => "my_mcp",
                        "command" => "${MINGA_PLUGIN_ROOT}/servers/my-mcp",
                        "args" => ["--port", "3000"]
                      }
                    ],
                    "slash_commands" => [
                      %{
                        "name" => "greet",
                        "description" => "Say hello",
                        "command" => "${MINGA_PLUGIN_ROOT}/commands/greet.sh"
                      }
                    ]
                  })

  setup %{tmp_dir: dir} do
    suffix = System.unique_integer([:positive])
    owner_name = String.to_atom("json_loader_generation_#{suffix}")
    admission_name = String.to_atom("json_loader_admission_#{suffix}")
    admission_id = String.to_atom("json_loader_admission_child_#{suffix}")
    persistence_key = {__MODULE__, suffix, make_ref()}

    _owner =
      start_supervised!(
        {ArtifactGenerationState, name: owner_name, persistence_key: persistence_key},
        id: owner_name
      )

    _admission =
      start_supervised!(
        {ArtifactAdmission, name: admission_name, state_owner: owner_name},
        id: admission_id
      )

    on_exit(fn ->
      assert :ok = ArtifactGenerationState.reset_for_test(persistence_key)
    end)

    %{
      dir: dir,
      admission: admission_name,
      admission_id: admission_id,
      owner_name: owner_name
    }
  end

  test "loads a complete manifest into a working extension", %{dir: dir, admission: admission} do
    write_manifest(dir, @valid_manifest)

    assert {:ok, module} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert module == Minga.Extension.Plugin.HelloWorld
    assert module.name() == module
    assert module.description() == "A simple greeting plugin"
    assert module.version() == "0.1.0"
    assert module.init([]) == {:ok, %{}}
    assert [{:session_start, hook_opts}] = module.__hook_schema__()
    assert hook_opts[:command] == Path.join(dir, "hooks/hello.sh")
    assert module.__skill_schema__() == [Path.join(dir, "skills/greet")]
    assert [{"my_mcp", mcp_opts}] = module.__mcp_server_schema__()
    assert mcp_opts[:command] == Path.join(dir, "servers/my-mcp")
    assert mcp_opts[:args] == ["--port", "3000"]
    assert [{"greet", "Say hello", command_opts}] = module.__slash_command_schema__()
    assert command_opts[:command] == Path.join(dir, "commands/greet.sh")

    manifest = Minga.Extension.Manifest.from_module(module, :path)

    assert {length(manifest.hooks), length(manifest.skills), length(manifest.mcp_servers),
            length(manifest.slash_commands)} == {1, 1, 1, 1}
  end

  test "uses the trusted registry name when provided", %{dir: dir, admission: admission} do
    write_manifest(dir, @valid_manifest)

    assert {:ok, module} =
             JsonLoader.load(dir, :trusted_plugin, artifact_admission: admission)

    assert module.name() == :trusted_plugin
  end

  test "claims deterministic provenance before creation and rejects same-VM replacement", %{
    dir: dir,
    admission: admission
  } do
    extension_name = String.to_atom("json_generation_#{System.unique_integer([:positive])}")
    write_manifest(dir, Jason.encode!(%{"name" => "generation", "version" => "1"}))

    assert {:ok, module} =
             JsonLoader.load(dir, extension_name, artifact_admission: admission)

    assert module.version() == "1"

    assert {:ok, ^module} =
             JsonLoader.load(dir, extension_name, artifact_admission: admission)

    write_manifest(dir, Jason.encode!(%{"name" => "generation", "version" => "2"}))

    assert {:error, message} =
             JsonLoader.load(dir, extension_name, artifact_admission: admission)

    assert message =~ "source_artifact_changed"
    assert module.version() == "1"
  end

  test "reports invalid manifest input without generating a module", %{
    dir: dir,
    admission: admission
  } do
    assert {:error, missing} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert missing =~ "failed to read"

    File.write!(Path.join(dir, "plugin.json"), "{not valid json!!!")
    assert {:error, malformed} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert malformed =~ "malformed JSON"

    File.write!(Path.join(dir, "plugin.json"), "[1, 2, 3]")
    assert {:error, shape} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert shape =~ "must be a JSON object"
  end

  test "rejects oversized symlinked and FIFO manifests without following or hanging", %{
    dir: dir,
    admission: admission
  } do
    path = Path.join(dir, "plugin.json")
    File.write!(path, String.duplicate("x", 1_048_577))
    assert {:error, oversized} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert oversized =~ "file_too_large"

    target = Path.join(dir, "external.json")
    File.write!(target, Jason.encode!(%{"name" => "external"}))
    File.rm!(path)
    File.ln_s!(target, path)
    assert {:error, symlinked} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert symlinked =~ "non_regular_file"
    assert symlinked =~ "symlink"

    File.rm!(path)
    {_output, 0} = System.cmd("mkfifo", [path], stderr_to_stdout: true)
    assert {:error, fifo} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert fifo =~ "non_regular_file"
  end

  test "manifest replacement races never admit bytes from a replaced descriptor", %{
    dir: dir,
    admission: admission
  } do
    path = Path.join(dir, "plugin.json")
    external = Path.join(dir, "external.json")
    safe = Jason.encode!(%{"name" => "safe", "version" => "safe"})
    File.write!(external, Jason.encode!(%{"name" => "external", "version" => "external"}))

    Enum.each(1..20, fn index ->
      File.write!(path, safe)
      parent = self()

      racer =
        spawn(fn ->
          Enum.each(1..100, fn _iteration ->
            File.rm(path)
            File.ln_s(external, path)
            File.rm(path)
            File.write(path, safe)
          end)

          send(parent, {:race_finished, self()})
        end)

      extension_name = String.to_atom("json_race_#{System.unique_integer([:positive])}_#{index}")

      case JsonLoader.load(dir, extension_name, artifact_admission: admission) do
        {:ok, module} -> assert module.version() == "safe"
        {:error, message} -> assert message =~ "failed to read"
      end

      assert_receive {:race_finished, ^racer}, 1_000
    end)
  end

  test "removes the created module when admission stops before commit", context do
    assert_json_commit_failure_rollback(context, :unavailable)
  end

  test "removes the created module when the generation fails before commit", context do
    assert_json_commit_failure_rollback(context, :generation_failed)
  end

  test "fills defaults and empty schemas for a minimal manifest", %{
    dir: dir,
    admission: admission
  } do
    write_manifest(dir, Jason.encode!(%{"name" => "minimal"}))

    assert {:ok, module} = JsonLoader.load(dir, nil, artifact_admission: admission)
    assert module.description() =~ "Plugin from"
    assert module.version() == "0.1.0"
    assert module.__hook_schema__() == []
    assert module.__skill_schema__() == []
    assert module.__mcp_server_schema__() == []
    assert module.__slash_command_schema__() == []
    assert module.__option_schema__() == []
  end

  defp assert_json_commit_failure_rollback(context, failure_mode) do
    unrelated = unique_json_module("Unrelated")
    unrelated_source = {:extension, unique_json_name("unrelated")}
    fingerprint = :crypto.hash(:sha256, "json-unrelated-#{failure_mode}")

    assert {:ok, unrelated_claim} =
             ArtifactAdmission.claim_source_modules(
               unrelated_source,
               [unrelated],
               fingerprint,
               server: context.admission
             )

    assert :ok = ArtifactAdmission.mark_loading(unrelated_claim, server: context.admission)

    Module.create(
      unrelated,
      quote(do: def(marker, do: :unrelated)),
      Macro.Env.location(__ENV__)
    )

    assert :ok = ArtifactAdmission.commit_attempt(unrelated_claim, server: context.admission)

    extension_name = unique_json_name("commit_attempt")

    module_name =
      Module.concat(Minga.Extension.Plugin, Macro.camelize(Atom.to_string(extension_name)))

    source = {:extension, extension_name}
    write_manifest(context.dir, Jason.encode!(%{"name" => Atom.to_string(extension_name)}))

    module_creator = fn module, contents, location ->
      result = Module.create(module, contents, location)
      force_json_commit_failure(context, failure_mode)
      result
    end

    assert {:error, message} =
             JsonLoader.load(context.dir, extension_name,
               artifact_admission: context.admission,
               module_creator: module_creator
             )

    assert message =~ "plugin module provenance commit failed"
    assert_explicit_json_commit_failure(message, failure_mode)
    admission = ensure_json_admission_available(context, failure_mode)

    refute Code.ensure_loaded?(module_name)
    assert unrelated.marker() == :unrelated

    assert {:ok, [^unrelated]} =
             ArtifactAdmission.source_modules(unrelated_source, server: admission)

    assert {:ok, [^module_name]} = ArtifactAdmission.source_modules(source, server: admission)
    assert :sys.get_state(admission).failed?
  end

  defp force_json_commit_failure(context, :unavailable) do
    stop_supervised!(context.admission_id)
  end

  defp force_json_commit_failure(context, :generation_failed) do
    admission = Process.whereis(context.admission)
    monitor = Process.monitor(admission)
    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^admission, :killed}, 1_000
    _restarted = await_json_admission_restart(context.admission, admission, 1_000)
    :ok
  end

  defp ensure_json_admission_available(context, :unavailable) do
    start_supervised!(
      {ArtifactAdmission, name: context.admission, state_owner: context.owner_name},
      id: context.admission_id
    )
  end

  defp ensure_json_admission_available(context, :generation_failed),
    do: Process.whereis(context.admission)

  defp assert_explicit_json_commit_failure(message, :unavailable),
    do: assert(message =~ "artifact_admission_unavailable")

  defp assert_explicit_json_commit_failure(message, :generation_failed),
    do: assert(message =~ "generation_failed")

  defp await_json_admission_restart(name, old_pid, remaining) when remaining > 0 do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _other ->
        receive do
        after
          10 -> await_json_admission_restart(name, old_pid, remaining - 10)
        end
    end
  end

  defp await_json_admission_restart(name, _old_pid, 0),
    do: flunk("#{inspect(name)} did not restart")

  defp unique_json_name(prefix),
    do: String.to_atom("json_#{prefix}_#{System.unique_integer([:positive])}")

  defp unique_json_module(prefix),
    do: Module.concat(["JsonLoader#{prefix}#{System.unique_integer([:positive])}"])

  defp write_manifest(dir, json), do: File.write!(Path.join(dir, "plugin.json"), json)
end
