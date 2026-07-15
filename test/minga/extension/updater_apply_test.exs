defmodule Minga.Extension.UpdaterApplyTest do
  # Mutates the production extension registry/cache and spawns real git OS processes.
  use ExUnit.Case, async: false

  alias Minga.Extension.ArtifactAdmission
  alias Minga.Extension.ArtifactGenerationState
  alias Minga.Extension.Git, as: ExtGit
  alias Minga.Extension.Manifest
  alias Minga.Extension.Registry, as: ExtRegistry
  alias Minga.Extension.Updater
  alias Minga.Mode.ExtensionConfirmState

  test "accepted local Git update stages checkout without replacing the admitted runtime" do
    suffix = System.unique_integer([:positive])
    name = String.to_atom("updater_apply_#{suffix}")
    generation_name = String.to_atom("updater_generation_#{suffix}")
    admission_name = String.to_atom("updater_admission_#{suffix}")
    persistence_key = {__MODULE__, suffix, make_ref()}

    _generation_owner =
      start_supervised!(
        {ArtifactGenerationState, name: generation_name, persistence_key: persistence_key},
        id: generation_name
      )

    admission =
      start_supervised!(
        {ArtifactAdmission, name: admission_name, state_owner: generation_name},
        id: admission_name
      )

    root = Path.join(System.tmp_dir!(), "minga-updater-#{suffix}")
    origin = Path.join(root, "origin.git")
    work = Path.join(root, "work")
    checkout = ExtGit.extension_path(name)
    File.mkdir_p!(root)

    on_exit(fn ->
      ExtRegistry.unregister(name)
      File.rm_rf!(root)
      File.rm_rf!(checkout)
      assert :ok = ArtifactGenerationState.reset_for_test(persistence_key)
    end)

    git!(root, ["init", "--bare", origin])
    git!(root, ["clone", origin, work])
    git!(work, ["config", "user.email", git_config("user.email", "minga-tests@example.invalid")])
    git!(work, ["config", "user.name", git_config("user.name", "Minga Tests")])
    git!(work, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(work, "version.txt"), "v1")
    git!(work, ["add", "version.txt"])
    git!(work, ["commit", "-m", "v1"])
    git!(work, ["push", "origin", "HEAD:main"])

    git_opts = %{url: origin, branch: "main", ref: nil}
    assert {:ok, ^checkout} = ExtGit.ensure_cloned(name, git_opts)
    ExtRegistry.register_git(name, origin, branch: "main")

    manifest = %Manifest{name: name, version: "1.0.0", source: :git}
    runtime_pid = self()
    runtime_module = Minga.Buffer

    assert :ok =
             ExtRegistry.update(name,
               status: :running,
               pid: runtime_pid,
               module: runtime_module,
               manifest: manifest
             )

    admission_source = {:extension, name}
    admitted_module = Module.concat(["UpdaterAdmission#{suffix}"])
    fingerprint = :crypto.hash(:sha256, "updater-admission-#{suffix}")

    assert {:ok, claim} =
             ArtifactAdmission.claim_source_modules(
               admission_source,
               [admitted_module],
               fingerprint,
               server: admission
             )

    assert :ok = ArtifactAdmission.commit_attempt(claim, server: admission)

    assert {:ok, admitted_before} =
             ArtifactAdmission.source_modules(admission_source, server: admission)

    File.write!(Path.join(work, "version.txt"), "v2")
    git!(work, ["add", "version.txt"])
    git!(work, ["commit", "-m", "v2"])
    git!(work, ["push", "origin", "HEAD:main"])

    assert {:ok, update} = ExtGit.fetch_updates(name, git_opts)
    Minga.Events.subscribe(:extension_restart_required)

    state = %ExtensionConfirmState{
      updates: [
        %{
          name: name,
          source_type: :git,
          old_ref: update.old_ref,
          new_ref: update.new_ref,
          commit_count: update.commit_count,
          branch: update.branch,
          pinned: false
        }
      ],
      accepted: [0]
    }

    assert :ok = Updater.apply_accepted(state)
    assert File.read!(Path.join(checkout, "version.txt")) == "v2"

    assert_receive {:minga_event, :extension_restart_required,
                    %Minga.Events.ExtensionRestartRequiredEvent{
                      extension: ^name,
                      reason: :updated,
                      old_ref: old_ref,
                      new_ref: new_ref
                    }}

    refute old_ref == new_ref
    assert {:ok, entry} = ExtRegistry.get(name)
    assert entry.pid == runtime_pid
    assert entry.module == runtime_module
    assert entry.manifest.version == "1.0.0"

    assert {:ok, ^admitted_before} =
             ArtifactAdmission.source_modules(admission_source, server: admission)
  end

  @spec git_config(String.t(), String.t()) :: String.t()
  defp git_config(key, fallback) do
    case System.cmd("git", ["config", "--get", key], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      {_output, _status} -> fallback
    end
  end

  defp git!(directory, args) do
    case System.cmd("git", args, cd: directory, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
