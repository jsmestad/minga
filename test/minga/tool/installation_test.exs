defmodule Minga.Tool.InstallationTest do
  use ExUnit.Case, async: true

  alias Minga.Tool.Installation

  describe "to_receipt/1 and from_receipt/1" do
    test "round-trips an installation through JSON" do
      dt = ~U[2026-03-17 10:00:00Z]

      inst = %Installation{
        name: :pyright,
        version: "1.1.400",
        installed_at: dt,
        method: :npm,
        path: "/home/user/.local/share/minga/tools/pyright"
      }

      receipt = Installation.to_receipt(inst)
      assert receipt["name"] == "pyright"
      assert receipt["version"] == "1.1.400"
      assert receipt["method"] == "npm"

      # Verify JSON serialization round-trip
      json = Jason.encode!(receipt)
      {:ok, decoded} = Jason.decode(json)
      assert {:ok, restored} = Installation.from_receipt(decoded)

      assert restored.name == :pyright
      assert restored.version == "1.1.400"
      assert restored.method == :npm
      assert restored.path == "/home/user/.local/share/minga/tools/pyright"
    end

    test "from_receipt returns :error for invalid data" do
      assert Installation.from_receipt(%{}) == :error
      assert Installation.from_receipt(%{"name" => "x"}) == :error
    end

    test "from_receipt returns :error for unknown atoms" do
      receipt = %{
        "name" => "definitely_not_an_existing_atom_xyz123",
        "version" => "1.0.0",
        "installed_at" => "2026-03-17T10:00:00Z",
        "method" => "npm",
        "path" => "/tmp/test"
      }

      assert Installation.from_receipt(receipt) == :error
    end
  end
end
