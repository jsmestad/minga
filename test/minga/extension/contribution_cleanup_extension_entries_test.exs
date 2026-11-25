defmodule Minga.Extension.ContributionCleanupExtensionEntriesTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.ContributionCleanup

  describe "remove_extension_entries/2" do
    test "an extension source removes the entries stored under its name" do
      parent = self()

      remove = fn name ->
        send(parent, {:removed, name})
        :ok
      end

      assert :ok =
               ContributionCleanup.remove_extension_entries({:extension, :git_extended}, remove)

      assert_received {:removed, :git_extended}
    end

    test "sources that are not extensions own nothing in such a registry" do
      parent = self()

      remove = fn name ->
        send(parent, {:removed, name})
        :ok
      end

      for source <- [:builtin, :config, {:bundle, :read_only_tools}] do
        assert :ok = ContributionCleanup.remove_extension_entries(source, remove)
      end

      refute_received {:removed, _name}
    end
  end
end
