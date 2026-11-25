defmodule Minga.Project.TrustTest do
  use ExUnit.Case, async: true

  alias Minga.Project.Root
  alias Minga.Project.Trust

  @moduletag :tmp_dir

  defp under_version_control, do: fn _root -> true end
  defp not_under_version_control, do: fn _root -> false end

  describe "project_root/2" do
    test "an ordinary folder is accepted whatever marks it, and named by its canonical path", %{
      tmp_dir: dir
    } do
      {:ok, canonical} = Root.canonical_path(dir)

      assert Trust.project_root(dir, not_under_version_control()) == {:ok, canonical}
      assert Trust.project_root(dir, under_version_control()) == {:ok, canonical}
    end

    test "a too-broad folder is accepted only under version control", %{tmp_dir: dir} do
      home = Path.expand("~")
      {:ok, canonical_home} = Root.canonical_path(home)
      link = Path.join(dir, "home")
      File.ln_s!(home, link)

      for {broad, canonical} <- [
            {home, canonical_home},
            {Path.dirname(canonical_home), Path.dirname(canonical_home)},
            {"/", "/"},
            {link, canonical_home}
          ] do
        assert Trust.project_root(broad, not_under_version_control()) ==
                 {:error, {:too_broad, canonical}}

        assert Trust.project_root(broad, under_version_control()) == {:ok, canonical}
      end
    end

    test "a path that does not resolve is refused, under version control or not", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing")

      assert Trust.project_root(missing, under_version_control()) == {:error, :unresolvable}
      assert Trust.project_root(missing, not_under_version_control()) == {:error, :unresolvable}
    end
  end

  describe "broad?/1" do
    test "the home directory, the folders above it and the root are broad; a folder inside is not",
         %{
           tmp_dir: dir
         } do
      {:ok, home} = Root.canonical_path(Path.expand("~"))
      {:ok, inside} = Root.canonical_path(dir)

      assert Trust.broad?(home)
      assert Trust.broad?(Path.dirname(home))
      assert Trust.broad?("/")
      refute Trust.broad?(inside)
    end
  end

  describe "owned/3, who may supply configuration" do
    @me 501

    defp found(uid, mode), do: fn _path -> {:ok, %File.Stat{uid: uid, mode: mode}} end
    defp seen(uid, mode, platform \\ :other), do: [stat: found(uid, mode), platform: platform]

    test "a path that belongs to the user and that others cannot write is the user's own" do
      for platform <- [:macos, :other] do
        assert Trust.owned("/work/app", @me, seen(@me, 0o040755, platform)) == :ok
        assert Trust.owned("/work/app/.minga.exs", @me, seen(@me, 0o100644, platform)) == :ok
      end
    end

    test "write access for the group is allowed where an account has a group of its own" do
      assert Trust.owned("/work/app", @me, seen(@me, 0o040775, :other)) == :ok
      assert Trust.owned("/work/app/.minga.exs", @me, seen(@me, 0o100664, :other)) == :ok
    end

    test "on macOS the group is everyone, so write access for it is refused" do
      assert Trust.owned("/work/app", @me, seen(@me, 0o040775, :macos)) ==
               {:error, {:writable_by_group, "/work/app"}}

      assert Trust.owned("/work/app/.minga.exs", @me, seen(@me, 0o100664, :macos)) ==
               {:error, {:writable_by_group, "/work/app/.minga.exs"}}
    end

    test "a path that belongs to another account is not, whatever its mode" do
      # A shared folder such as /tmp: owned by root, writable by all, sticky.
      for mode <- [0o041777, 0o040755, 0o040700] do
        assert Trust.owned("/tmp", @me, seen(0, mode)) == {:error, {:not_yours, "/tmp"}}
      end
    end

    test "a path anyone on the machine can write is not, even when the user owns it" do
      for platform <- [:macos, :other] do
        assert Trust.owned("/work/app", @me, seen(@me, 0o040777, platform)) ==
                 {:error, {:writable_by_others, "/work/app"}}

        assert Trust.owned("/work/app/.minga.exs", @me, seen(@me, 0o100666, platform)) ==
                 {:error, {:writable_by_others, "/work/app/.minga.exs"}}
      end
    end

    test "a path that cannot be examined, or an unknown user, is treated as not the user's" do
      assert Trust.owned("/gone", @me, stat: fn _path -> {:error, :enoent} end) ==
               {:error, {:not_yours, "/gone"}}

      assert Trust.owned("/work/app", nil, seen(@me, 0o040755)) ==
               {:error, {:not_yours, "/work/app"}}
    end

    test "the account running the tests owns what it creates", %{tmp_dir: dir} do
      assert is_integer(Trust.current_user_id())
      assert Trust.owned(dir, Trust.current_user_id()) == :ok
    end

    test "the platform is decided in one place" do
      assert Trust.platform() in [:macos, :other]
    end
  end

  describe "config_root/2" do
    # A real folder under the system's temporary directory, whose own ancestors pass on every platform we run on.
    defp temporary_project(label) do
      root =
        Path.join(System.tmp_dir!(), "minga_trust_#{label}_#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, canonical} = Root.canonical_path(root)
      {root, canonical}
    end

    # Examines the real filesystem, except for the paths a test says belong to someone else or are open.
    defp except_for(overrides) do
      fn path ->
        case Map.fetch(overrides, path) do
          {:ok, {uid, mode}} -> {:ok, %File.Stat{uid: uid, mode: mode}}
          :error -> File.stat(path)
        end
      end
    end

    test "an own, private folder is accepted; one that anyone can write is refused" do
      {root, canonical} = temporary_project("own")
      assert Trust.config_root(root) == {:ok, canonical}

      File.chmod!(root, 0o777)
      assert Trust.config_root(root) == {:error, {:writable_by_others, canonical}}
    end

    test "a folder of another account is refused" do
      {root, canonical} = temporary_project("foreign")
      someone_else = Trust.current_user_id() + 1

      assert Trust.config_root(root, user_id: someone_else) == {:error, {:not_yours, canonical}}
    end

    test "breadth is judged first: a too-broad folder is refused as too broad" do
      assert {:error, {:too_broad, "/"}} =
               Trust.config_root("/", version_controlled?: fn _root -> false end)
    end

    test "a folder above the root that others can write is refused, unless it is sticky like /tmp" do
      {root, canonical} = temporary_project("above")
      above = Path.dirname(canonical)
      me = Trust.current_user_id()

      opts = fn uid, mode ->
        [user_id: me, platform: :other, stat: except_for(%{above => {uid, mode}})]
      end

      # Anyone could rename the project away and put another folder in its place.
      assert Trust.config_root(root, opts.(0, 0o040777)) == {:error, {:writable_by_others, above}}
      # In a sticky folder an account cannot rename or remove what another account put there.
      assert Trust.config_root(root, opts.(0, 0o041777)) == {:ok, canonical}
      # A folder of the system or of the user, closed to others, is fine.
      assert Trust.config_root(root, opts.(0, 0o040755)) == {:ok, canonical}
      assert Trust.config_root(root, opts.(me, 0o040755)) == {:ok, canonical}
    end

    test "a folder above the root that belongs to another account is refused" do
      {root, canonical} = temporary_project("under_foreign")
      above = Path.dirname(canonical)
      me = Trust.current_user_id()

      assert Trust.config_root(root,
               user_id: me,
               platform: :other,
               stat: except_for(%{above => {me + 1, 0o040755}})
             ) == {:error, {:not_yours, above}}
    end

    test "a folder above the root that its group can write is refused on macOS only" do
      {root, canonical} = temporary_project("group_above")
      above = Path.dirname(canonical)
      me = Trust.current_user_id()

      opts = fn platform ->
        [user_id: me, platform: platform, stat: except_for(%{above => {0, 0o040775}})]
      end

      assert Trust.config_root(root, opts.(:macos)) == {:error, {:writable_by_group, above}}
      assert Trust.config_root(root, opts.(:other)) == {:ok, canonical}
    end
  end

  describe "read_config_file/2" do
    test "reads an own file and names it by its canonical path, through a link too", %{
      tmp_dir: dir
    } do
      file = Path.join(dir, "config.exs")
      link = Path.join(dir, "link.exs")
      File.write!(file, "use Minga.Config\n")
      File.ln_s!(file, link)
      {:ok, canonical} = Root.canonical_path(file)
      me = Trust.current_user_id()

      assert Trust.read_config_file(file, me) == {:ok, "use Minga.Config\n", canonical}
      assert Trust.read_config_file(link, me) == {:ok, "use Minga.Config\n", canonical}
    end

    test "refuses a file anyone can write, directly and through a link, and a file of another account",
         %{tmp_dir: dir} do
      file = Path.join(dir, "open.exs")
      link = Path.join(dir, "link.exs")
      File.write!(file, "raise \"must not run\"\n")
      File.chmod!(file, 0o666)
      File.ln_s!(file, link)
      {:ok, canonical} = Root.canonical_path(file)
      me = Trust.current_user_id()

      assert Trust.read_config_file(file, me) == {:error, {:writable_by_others, canonical}}
      assert Trust.read_config_file(link, me) == {:error, {:writable_by_others, canonical}}

      File.chmod!(file, 0o644)
      assert Trust.read_config_file(file, me + 1) == {:error, {:not_yours, canonical}}
    end

    test "a file that is not there is unreadable, not the user's to load", %{tmp_dir: dir} do
      missing = Path.join(dir, "missing.exs")

      assert {:error, {:unreadable, ^missing, _reason}} =
               Trust.read_config_file(missing, Trust.current_user_id())
    end
  end

  describe "read_config_file/2, what is not a small regular file" do
    test "a folder under the file's name is refused before anything is opened", %{tmp_dir: dir} do
      folder = Path.join(dir, ".minga.exs")
      File.mkdir_p!(folder)
      {:ok, canonical} = Root.canonical_path(folder)

      assert Trust.read_config_file(folder, Trust.current_user_id()) ==
               {:error, {:unreadable, canonical, {:not_a_file, :directory}}}
    end

    test "a file too large to be configuration is refused whole", %{tmp_dir: dir} do
      file = Path.join(dir, "huge.exs")
      File.write!(file, :binary.copy("#", 16 * 1024 * 1024 + 1))
      {:ok, canonical} = Root.canonical_path(file)

      assert Trust.read_config_file(file, Trust.current_user_id()) ==
               {:error, {:unreadable, canonical, :too_large}}
    end
  end

  describe "code_root/3, a folder of code that is the user's own all the way down and safe all the way up" do
    setup do
      {root, canonical} = temporary_project("code")
      File.mkdir_p!(Path.join(root, "lib/deep"))
      File.write!(Path.join(root, "lib/a.ex"), "")
      File.write!(Path.join(root, "lib/deep/b.ex"), "")
      File.write!(Path.join(root, "plugin.json"), "{}")
      {:ok, root: root, canonical: canonical, me: Trust.current_user_id()}
    end

    test "an own folder passes and comes back under its canonical name", context do
      assert Trust.code_root(context.root, context.me) == {:ok, context.canonical}
    end

    test "a link to the folder gives the folder's canonical name, never the link's", context do
      {elsewhere, _canonical} = temporary_project("code_link")
      link = Path.join(elsewhere, "plugin")
      File.ln_s!(context.root, link)

      assert Trust.code_root(link, context.me) == {:ok, context.canonical}
    end

    test "an empty subfolder anyone can write is refused: a file added there later would be loaded",
         context do
      empty = Path.join(context.canonical, "lib/later")
      File.mkdir_p!(empty)
      File.chmod!(empty, 0o777)

      assert Trust.code_root(context.root, context.me) == {:error, {:writable_by_others, empty}}
    end

    test "a plugin.json anyone can write is refused: it supplies command lines", context do
      manifest = Path.join(context.canonical, "plugin.json")
      File.chmod!(manifest, 0o666)

      assert Trust.code_root(context.root, context.me) ==
               {:error, {:writable_by_others, manifest}}
    end

    test "a script anyone can write is refused, whatever its name or place", context do
      script = Path.join(context.canonical, "bin/run.sh")
      File.mkdir_p!(Path.dirname(script))
      File.write!(script, "#!/bin/sh\n")
      File.chmod!(script, 0o777)

      assert Trust.code_root(context.root, context.me) == {:error, {:writable_by_others, script}}
    end

    test "a folder above the root that others can write is refused: they could put another folder in its place",
         context do
      above = Path.dirname(context.canonical)
      opts = [platform: :other, stat: except_for(%{above => {0, 0o040777}})]

      assert Trust.code_root(context.root, context.me, opts) ==
               {:error, {:writable_by_others, above}}
    end

    test "a file that is its group's to write is refused on macOS only", context do
      shared = Path.join(context.canonical, "lib/a.ex")
      File.chmod!(shared, 0o664)

      assert Trust.code_root(context.root, context.me, platform: :macos) ==
               {:error, {:writable_by_group, shared}}

      assert Trust.code_root(context.root, context.me, platform: :other) ==
               {:ok, context.canonical}
    end

    test "a link is judged at its target: a file anyone can write", context do
      {elsewhere, canonical_elsewhere} = temporary_project("code_target")
      File.write!(Path.join(elsewhere, "open.ex"), "")
      File.chmod!(Path.join(elsewhere, "open.ex"), 0o666)
      File.ln_s!(Path.join(elsewhere, "open.ex"), Path.join(context.root, "lib/linked.ex"))

      assert Trust.code_root(context.root, context.me) ==
               {:error, {:writable_by_others, Path.join(canonical_elsewhere, "open.ex")}}
    end

    test "a link is judged at its target: a folder is walked, and what is above the target counts",
         context do
      {elsewhere, canonical_elsewhere} = temporary_project("code_folder_target")
      File.mkdir_p!(Path.join(elsewhere, "open/inner"))
      File.write!(Path.join(elsewhere, "open/inner/c.ex"), "")
      File.ln_s!(Path.join(elsewhere, "open/inner"), Path.join(context.root, "lib/vendored"))

      assert Trust.code_root(context.root, context.me) == {:ok, context.canonical}

      # The target is fine, but the folder above it is open: another account could replace the target.
      File.chmod!(Path.join(elsewhere, "open"), 0o777)

      assert Trust.code_root(context.root, context.me) ==
               {:error, {:writable_by_others, Path.join(canonical_elsewhere, "open")}}
    end

    test "a chain of links is judged at every link: one in a folder anyone can write could be pointed elsewhere",
         context do
      {elsewhere, canonical_elsewhere} = temporary_project("code_chain")
      File.mkdir_p!(Path.join(elsewhere, "real/inner"))
      File.write!(Path.join(elsewhere, "real/inner/c.ex"), "")
      File.mkdir_p!(Path.join(elsewhere, "via"))

      # `via/hop` is a link in the middle of the chain. The final target, `real/inner`, is fine either way.
      File.ln_s!("../real", Path.join(elsewhere, "via/hop"))
      File.ln_s!(Path.join(elsewhere, "via/hop/inner"), Path.join(context.root, "lib/vendored"))

      assert Trust.code_root(context.root, context.me) == {:ok, context.canonical}

      File.chmod!(Path.join(elsewhere, "via"), 0o777)

      assert Trust.code_root(context.root, context.me) ==
               {:error, {:writable_by_others, Path.join(canonical_elsewhere, "via")}}
    end

    test "a link that leads nowhere is refused", context do
      File.ln_s!(Path.join(context.root, "gone"), Path.join(context.root, "lib/dangling.ex"))

      assert Trust.code_root(context.root, context.me) ==
               {:error, {:unreadable, Path.join(context.canonical, "gone"), :enoent}}
    end

    test "links that lead back into the folder end: each target is examined once", context do
      File.ln_s!(context.root, Path.join(context.root, "lib/deep/back"))
      File.ln_s!(Path.join(context.root, "lib"), Path.join(context.root, "lib/deep/again"))

      assert Trust.code_root(context.root, context.me) == {:ok, context.canonical}
    end

    test "anything that is not a file, a folder or a link is refused", context do
      socket = Path.join(context.canonical, "s")

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ifaddr: {:local, String.to_charlist(socket)}])

      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, {:unreadable, ^socket, {:not_a_file, _type}}} =
               Trust.code_root(context.root, context.me)
    end

    test "a folder with more entries than the limit is refused instead of walked to the end",
         context do
      assert Trust.code_root(context.root, context.me, entry_limit: 5) == {:ok, context.canonical}

      assert Trust.code_root(context.root, context.me, entry_limit: 4) ==
               {:error, {:too_many_entries, context.canonical, 4}}

      assert Trust.code_entry_limit() == 10_000
    end

    test "a folder of another account, a file, and a path that is not there are refused",
         context do
      assert Trust.code_root(context.root, context.me + 1) ==
               {:error, {:not_yours, context.canonical}}

      file = Path.join(context.canonical, "plugin.json")
      assert Trust.code_root(file, context.me) == {:error, {:unreadable, file, :not_a_folder}}

      assert {:error, {:unreadable, _path, _reason}} =
               Trust.code_root(Path.join(context.root, "gone"), context.me)
    end
  end

  describe "config_folder/3" do
    test "an own folder under safe folders is accepted without looking inside it" do
      {root, canonical} = temporary_project("folder")
      File.write!(Path.join(root, "anything"), "")
      File.chmod!(Path.join(root, "anything"), 0o666)

      assert Trust.config_folder(root, Trust.current_user_id()) == {:ok, canonical}
    end

    test "a folder anyone can write, or one under such a folder, is refused" do
      {root, canonical} = temporary_project("folder_open")
      inner = Path.join(canonical, ".minga/plugins")
      File.mkdir_p!(inner)
      File.chmod!(Path.join(root, ".minga"), 0o777)
      me = Trust.current_user_id()

      assert Trust.config_folder(Path.join(root, ".minga"), me) ==
               {:error, {:writable_by_others, Path.join(canonical, ".minga")}}

      assert Trust.config_folder(inner, me) ==
               {:error, {:writable_by_others, Path.join(canonical, ".minga")}}
    end
  end

  describe "executable/4, the program a project declares" do
    setup do
      {root, canonical} = temporary_project("program")
      File.mkdir_p!(Path.join(root, "scripts"))
      script = Path.join(canonical, "scripts/serve.sh")
      File.write!(script, "#!/bin/sh\n")
      File.chmod!(script, 0o755)
      {:ok, root: canonical, script: script, me: Trust.current_user_id()}
    end

    defp tool_folder(label) do
      {folder, canonical} = temporary_project(label)
      File.write!(Path.join(folder, "tool"), "#!/bin/sh\n")
      File.chmod!(Path.join(folder, "tool"), 0o755)
      canonical
    end

    test "a bare name is the user's environment: it is returned as it is, to be found when the process starts",
         context do
      assert Trust.executable(context.root, "node", context.me) == {:ok, "node"}

      assert Trust.executable(context.root, "no-such-program-anywhere", context.me) ==
               {:ok, "no-such-program-anywhere"}
    end

    test "program/3 finds a bare name on PATH, in absolute folders only", context do
      bin = tool_folder("bin")

      for root <- [context.root, nil] do
        assert Trust.program(root, "tool", path: "/nowhere:" <> bin) ==
                 {:ok, Path.join(bin, "tool")}

        assert Trust.program(root, "tool", path: "/nowhere") ==
                 {:error, {:unreadable, "tool", :not_on_path}}
      end
    end

    @tag :tmp_dir
    test "a relative or an empty PATH entry is passed over: it would mean the directory Minga runs in",
         %{tmp_dir: tmp_dir} = context do
      # This folder sits under the directory the VM runs in, so a relative entry would find the tool.
      relative = Path.relative_to(tmp_dir, File.cwd!())
      assert Path.type(relative) == :relative
      File.write!(Path.join(tmp_dir, "tool"), "#!/bin/sh\n")
      File.chmod!(Path.join(tmp_dir, "tool"), 0o755)

      for path <- [relative, ":" <> relative <> ":", ""] do
        assert Trust.program(context.root, "tool", path: path) ==
                 {:error, {:unreadable, "tool", :not_on_path}}
      end
    end

    test "with no absolute folder on PATH nothing is found, even a program in the directory Minga runs in",
         context do
      # A program in the directory the tests run in: an empty PATH element means that directory to the system.
      name = "minga_path_probe_#{System.unique_integer([:positive])}"
      here = Path.join(File.cwd!(), name)
      File.write!(here, "#!/bin/sh\n")
      File.chmod!(here, 0o755)
      on_exit(fn -> File.rm(here) end)

      assert Trust.program(context.root, name, path: File.cwd!()) == {:ok, here}

      for path <- ["", ":", ".", ".:", "::.", "relative/bin"] do
        assert Trust.program(context.root, name, path: path) ==
                 {:error, {:unreadable, name, :not_on_path}}
      end
    end

    test "an empty name, or one with a zero byte, is refused before anything is looked up",
         context do
      for name <- ["", "to\0ol", "scripts/serve.sh\0.txt"] do
        assert Trust.executable(context.root, name, context.me) ==
                 {:error, {:unreadable, name, :invalid_name}}

        assert Trust.program(context.root, name) == {:error, {:unreadable, name, :invalid_name}}
      end
    end

    test "a bare name is returned as found: some tools decide what to do by the name they are called by",
         context do
      bin = tool_folder("bin_alias")
      File.ln_s!("tool", Path.join(bin, "alias"))

      assert Trust.program(context.root, "alias", path: bin) == {:ok, Path.join(bin, "alias")}
    end

    test "a name with a separator means a file in the root, not in the directory Minga runs in",
         context do
      assert Trust.executable(context.root, "scripts/serve.sh", context.me) ==
               {:ok, context.script}

      assert Trust.executable(context.root, "./scripts/../scripts/serve.sh", context.me) ==
               {:ok, context.script}

      # `mix.exs` is in the directory the tests run in, and not in the root.
      assert File.regular?("mix.exs")

      assert Trust.executable(context.root, "./mix.exs", context.me) ==
               {:error, {:unreadable, Path.join(context.root, "mix.exs"), :enoent}}
    end

    test "a file that is not there is a refusal, not something to skip", context do
      assert Trust.executable(context.root, "scripts/later.sh", context.me) ==
               {:error, {:unreadable, Path.join(context.root, "scripts/later.sh"), :enoent}}

      assert {:error, {:unreadable, "/nowhere/tool", :enoent}} =
               Trust.executable(context.root, "/nowhere/tool", context.me)
    end

    test "inside the root the file and every folder down to it must be the user's own", context do
      File.chmod!(context.script, 0o777)

      assert Trust.executable(context.root, "scripts/serve.sh", context.me) ==
               {:error, {:writable_by_others, context.script}}

      File.chmod!(context.script, 0o755)
      File.chmod!(Path.dirname(context.script), 0o777)

      assert Trust.executable(context.root, "scripts/serve.sh", context.me) ==
               {:error, {:writable_by_others, Path.dirname(context.script)}}

      assert Trust.executable(context.root, context.script, context.me + 1) ==
               {:error, {:not_yours, Path.dirname(context.script)}}
    end

    test "a link inside the root is followed, and it is judged where it sits", context do
      File.ln_s!("serve.sh", Path.join(context.root, "scripts/linked.sh"))

      assert Trust.executable(context.root, "scripts/linked.sh", context.me) ==
               {:ok, context.script}

      File.chmod!(Path.dirname(context.script), 0o777)

      assert Trust.executable(context.root, "scripts/linked.sh", context.me) ==
               {:error, {:writable_by_others, Path.dirname(context.script)}}
    end

    test "a path outside the root is the user's own environment and only has to exist", context do
      bin = tool_folder("outside")
      File.chmod!(Path.join(bin, "tool"), 0o777)

      assert Trust.executable(context.root, Path.join(bin, "tool"), context.me) ==
               {:ok, Path.join(bin, "tool")}
    end

    test "program/3 finds a program the same way without judging who owns it", context do
      File.chmod!(context.script, 0o777)

      assert Trust.program(context.root, "scripts/serve.sh") == {:ok, context.script}

      assert Trust.program(context.root, "scripts/later.sh") ==
               {:error, {:unreadable, Path.join(context.root, "scripts/later.sh"), :enoent}}

      assert Trust.program(context.root, "tool", path: "/nowhere") ==
               {:error, {:unreadable, "tool", :not_on_path}}
    end
  end

  describe "explain/2" do
    test "each refusal names the path that failed and what to do about it" do
      assert Trust.explain({:writable_by_others, "/work/app/lib"}) =~
               "anyone on this machine can write /work/app/lib. Remove write access for others (chmod o-w,"

      assert Trust.explain({:writable_by_group, "/work/app/lib"}) =~ "chmod g-w"
      assert Trust.explain({:not_yours, "/work/app"}) =~ "/work/app belongs to another account"

      assert Trust.explain({:too_many_entries, "/work/app", 10_000}) =~
               "/work/app holds more than 10000 files and folders"

      assert Trust.explain({:unreadable, "/work/app/s", {:not_a_file, :other}}) =~
               "/work/app/s could not be read"

      assert Trust.explain({:too_broad, "/"}) =~ "/ is too broad"

      assert Trust.explain({:unreadable, "node", :not_on_path}) ==
               "node is not a program in any absolute folder on PATH. Install it and start a new conversation."

      assert Trust.explain({:unreadable, "/work/app/scripts/serve.sh", :enoent}) ==
               "/work/app/scripts/serve.sh is not there. Create it, or correct the name, and reload config."
    end

    test "a caller's shorter name is used when it has one" do
      assert Trust.explain({:writable_by_others, "/work/app/.minga.exs"}, ".minga.exs") =~
               "anyone on this machine can write .minga.exs."
    end
  end
end
