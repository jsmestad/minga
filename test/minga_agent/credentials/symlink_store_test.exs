defmodule MingaAgent.Credentials.SymlinkStoreTest do
  use ExUnit.Case, async: true

  alias MingaAgent.Credentials

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    env = Map.new(Credentials.known_providers(), &{Credentials.env_var_for(&1), nil})

    %{
      opts: [config_dir: directory, env: env],
      path: Path.join([directory, "minga", "credentials.json"])
    }
  end

  test "relative and absolute final-link chains preserve links and merge at the actual target",
       context do
    File.mkdir_p!(Path.dirname(context.path))
    target = Path.join(context.tmp_dir, "private-target.json")
    intermediate = Path.join(context.tmp_dir, "credential-link.json")
    File.write!(target, JSON.encode!(%{"anthropic" => "synthetic-existing"}))
    File.ln_s!(target, intermediate)
    File.ln_s!("../credential-link.json", context.path)

    assert :ok = Credentials.store("openai", "synthetic-openai", context.opts)
    assert File.lstat!(context.path).type == :symlink
    assert File.lstat!(intermediate).type == :symlink

    assert JSON.decode!(File.read!(target)) == %{
             "anthropic" => "synthetic-existing",
             "openai" => "synthetic-openai"
           }

    assert {:ok, "synthetic-openai", :file} = Credentials.resolve("openai", context.opts)
    assert Bitwise.band(File.stat!(target).mode, 0o777) == 0o600

    assert :ok = Credentials.revoke("openai", context.opts)
    assert File.lstat!(context.path).type == :symlink
    assert File.lstat!(intermediate).type == :symlink
    assert JSON.decode!(File.read!(target)) == %{"anthropic" => "synthetic-existing"}

    assert Enum.sort(File.ls!(context.tmp_dir)) == [
             "credential-link.json",
             "minga",
             "private-target.json"
           ]
  end

  test "link targets traverse symlinked directories before resolving parent segments", context do
    parent = Path.dirname(context.path)
    nested = Path.join([context.tmp_dir, "destination", "nested"])
    target = Path.join(Path.dirname(nested), "keys.json")
    unrelated = Path.join(parent, "keys.json")
    File.mkdir_p!(nested)
    File.mkdir_p!(parent)
    File.write!(target, JSON.encode!(%{"openai" => "synthetic-old"}))
    File.write!(unrelated, JSON.encode!(%{"openai" => "synthetic-unrelated"}))
    File.ln_s!(nested, Path.join(parent, "alias"))
    File.ln_s!("alias/../keys.json", context.path)

    assert {:ok, "synthetic-old", :file} = Credentials.resolve("openai", context.opts)
    assert :ok = Credentials.store("openai", "synthetic-new", context.opts)
    assert {:ok, "synthetic-new", :file} = Credentials.resolve("openai", context.opts)
    assert :ok = Credentials.revoke("openai", context.opts)
    assert :error = Credentials.resolve("openai", context.opts)
    assert File.read_link!(context.path) == "alias/../keys.json"
    assert JSON.decode!(File.read!(unrelated)) == %{"openai" => "synthetic-unrelated"}
  end

  test "direct paths, final links and parent links preserve concurrent provider updates",
       context do
    direct = context.tmp_dir
    alias_dir = Path.join(context.tmp_dir, "parent-link")
    final_link_dir = Path.join(context.tmp_dir, "final-link")
    configured_link = Path.join([final_link_dir, "minga", "credentials.json"])
    File.mkdir_p!(Path.dirname(context.path))
    File.mkdir_p!(Path.dirname(configured_link))
    File.write!(context.path, "{}")
    File.ln_s!(direct, alias_dir)
    File.ln_s!(context.path, configured_link)
    providers = Credentials.known_providers()
    paths = Stream.cycle([direct, alias_dir, final_link_dir])

    results =
      providers
      |> Stream.zip(paths)
      |> Task.async_stream(
        fn {provider, config_dir} ->
          opts = Keyword.put(context.opts, :config_dir, config_dir)
          Credentials.store(provider, "synthetic-#{provider}", opts)
        end,
        ordered: false
      )
      |> Enum.to_list()

    assert results == List.duplicate({:ok, :ok}, length(providers))
    assert File.read_link!(configured_link) == context.path
    assert File.read_link!(alias_dir) == direct
    stored = JSON.decode!(File.read!(context.path))

    for provider <- Credentials.known_providers() do
      assert stored[provider] == "synthetic-#{provider}"
    end
  end

  test "precommit failure preserves both final symlink and prior target bytes", context do
    File.mkdir_p!(Path.dirname(context.path))
    target_dir = Path.join(context.tmp_dir, "private-target")
    File.mkdir_p!(target_dir)
    target = Path.join(target_dir, "credentials.json")
    previous = JSON.encode!(%{"openai" => "synthetic-prior"})
    File.write!(target, previous)
    File.ln_s!(target, context.path)
    File.chmod!(target_dir, 0o500)

    try do
      assert {:error, :eacces} = Credentials.store("openai", "synthetic-new", context.opts)
      assert File.lstat!(context.path).type == :symlink
      assert File.read!(target) == previous
      assert File.ls!(target_dir) == ["credentials.json"]
    after
      File.chmod!(target_dir, 0o700)
    end
  end

  test "a dangling final link creates its file but never invents missing target directories",
       context do
    File.mkdir_p!(Path.dirname(context.path))
    target = Path.join(context.tmp_dir, "new-target.json")
    File.ln_s!(target, context.path)
    assert :ok = Credentials.store("openai", "synthetic-new", context.opts)
    assert File.lstat!(context.path).type == :symlink
    assert JSON.decode!(File.read!(target)) == %{"openai" => "synthetic-new"}

    File.rm!(context.path)
    missing = Path.join([context.tmp_dir, "missing-directory", "credentials.json"])
    File.ln_s!(missing, context.path)
    assert {:error, :enoent} = Credentials.store("openai", "synthetic-refused", context.opts)
    assert File.lstat!(context.path).type == :symlink
    refute File.exists?(Path.dirname(missing))
  end

  test "final links requiring a directory cannot overwrite a regular file", context do
    parent = Path.dirname(context.path)
    File.mkdir_p!(parent)
    target = Path.join(parent, "keys.json")
    previous = JSON.encode!(%{"openai" => "synthetic-prior"})
    File.write!(target, previous)

    for link <- ["keys.json/", target <> "/"] do
      File.ln_s!(link, context.path)
      assert :error = Credentials.resolve("openai", context.opts)
      assert {:error, :enotdir} = Credentials.store("openai", "synthetic-new", context.opts)
      assert {:error, :enotdir} = Credentials.revoke("openai", context.opts)
      assert File.read!(target) == previous
      assert File.read_link!(context.path) == link
      File.rm!(context.path)
    end
  end

  test "cyclic final links return a bounded safe error without replacing either link", context do
    File.mkdir_p!(Path.dirname(context.path))
    other = Path.join(context.tmp_dir, "other-link.json")
    File.ln_s!(other, context.path)
    File.ln_s!(context.path, other)
    assert {:error, :eloop} = Credentials.store("openai", "synthetic-refused", context.opts)
    assert File.lstat!(context.path).type == :symlink
    assert File.lstat!(other).type == :symlink
  end
end
