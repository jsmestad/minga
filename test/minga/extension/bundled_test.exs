defmodule Minga.Extension.BundledTest do
  use ExUnit.Case, async: true

  alias Minga.Extension.Bundled
  alias Minga.Extension.Registry, as: ExtRegistry

  setup do
    registry = start_supervised!({ExtRegistry, name: nil})
    root = Path.join(System.tmp_dir!(), "minga-bundled-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{registry: registry, root: root}
  end

  test "git porcelain is the only shipped extension name" do
    assert Bundled.names() == [:git_porcelain]
    assert {:ok, %{registry_name: :minga_git_porcelain}} = Bundled.fetch(:git_porcelain)
    assert Bundled.fetch(:minga_git_porcelain) == :error
  end

  test "declared? follows the registry declaration of a shipped extension", ctx do
    refute Bundled.declared?(:git_porcelain, ctx.registry)
    {:ok, spec} = Bundled.fetch(:git_porcelain)
    :ok = Bundled.register(ctx.registry, spec, [])
    assert Bundled.declared?(:git_porcelain, ctx.registry)
    refute Bundled.declared?(:not_shipped, ctx.registry)
  end

  describe "git_porcelain_upgrade_notice/2" do
    test "tells a git project without git porcelain how to turn it on", ctx do
      File.mkdir_p!(Path.join(ctx.root, ".git"))

      notice = Bundled.git_porcelain_upgrade_notice(ctx.root, ctx.registry)

      assert notice =~ "Git porcelain"
      assert notice =~ "extension :git_porcelain"
      assert notice =~ "config.exs"
    end

    test "detects the repository from a nested project root and a worktree .git file", ctx do
      File.write!(Path.join(ctx.root, ".git"), "gitdir: /elsewhere/.git/worktrees/x\n")

      assert is_binary(
               Bundled.git_porcelain_upgrade_notice(Path.join(ctx.root, "lib"), ctx.registry)
             )
    end

    test "stays silent when git porcelain is declared", ctx do
      File.mkdir_p!(Path.join(ctx.root, ".git"))
      {:ok, spec} = Bundled.fetch(:git_porcelain)
      :ok = Bundled.register(ctx.registry, spec, [])

      assert Bundled.git_porcelain_upgrade_notice(ctx.root, ctx.registry) == nil
    end

    test "stays silent outside a git repository", ctx do
      assert Bundled.git_porcelain_upgrade_notice(ctx.root, ctx.registry) == nil
    end

    test "stays silent without a project root", ctx do
      assert Bundled.git_porcelain_upgrade_notice(nil, ctx.registry) == nil
    end
  end
end
