defmodule Minga.Extension.ArtifactInventoryTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Artifact
  alias Minga.Extension.ArtifactInventory

  @moduletag :tmp_dir

  test "an empty inventory fails before capacity admission", %{tmp_dir: dir} do
    assert {:error, :empty_inventory} =
             ArtifactInventory.validate_in_disposable(dir, {:staging, []},
               max_total_bytes: 1,
               host_atom_reserve: :erlang.system_info(:atom_limit)
             )
  end

  test "a running byte limit fails before a later malformed BEAM", %{tmp_dir: dir} do
    modules = [Artifact, ArtifactInventory]

    sizes =
      for module <- modules do
        {^module, bytecode, _path} = :code.get_object_code(module)
        File.write!(Path.join(dir, Atom.to_string(module) <> ".beam"), bytecode)
        byte_size(bytecode)
      end

    trailing = "Elixir.ZzzTrailingArtifact.beam"
    File.write!(Path.join(dir, trailing), "not a BEAM")

    total = Enum.sum(sizes)
    max = Enum.max(sizes)
    staging = {:staging, Enum.map(modules, &Atom.to_string/1)}

    assert {:error, {:total_artifact_bytes_exceeded, ^total, ^max}} =
             ArtifactInventory.validate_in_disposable(dir, staging, max_total_bytes: max)

    assert {:error, {:invalid_beam, ^trailing, :invalid_container}} =
             ArtifactInventory.validate_in_disposable(dir, staging, max_total_bytes: total)
  end
end
