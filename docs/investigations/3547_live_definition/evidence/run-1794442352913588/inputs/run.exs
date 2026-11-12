# Usage: pinned elixir run.exs. No Mix, dependencies, production modules, or user config.
root = __DIR__
elixir = Path.expand("~/.asdf/installs/elixir/1.20.5-otp-29/bin/elixir")
erlang_bin = Path.expand("~/.asdf/installs/erlang/29.1.2/bin")
env = [{"PATH", erlang_bin <> ":" <> System.fetch_env!("PATH")}, {"ELIXIR_ERL_OPTIONS", "+S 2:2"}]
run = Path.join([root, "evidence", "run-#{System.system_time(:microsecond)}"])
File.mkdir_p!(run)
File.write!(Path.join(root, "LATEST"), run <> "\n")
files = ["run.exs", "prepare.exs", "fixture.exs", "PRODUCT_CONTRACT.txt"] ++
  Enum.map(["v1", "v2", "rejected", "v3"], &("snapshots/" <> &1 <> ".exs"))
manifest = for file <- files do
  binary = File.read!(Path.join(root, file))
  frozen = Path.join([run, "inputs", file])
  File.mkdir_p!(Path.dirname(frozen))
  File.write!(frozen, binary, [:exclusive])
  File.chmod!(frozen, 0o444)
  "#{Base.encode16(:crypto.hash(:sha256, binary), case: :lower)}  #{file}\n"
end
File.write!(Path.join(run, "SHA256SUMS"), manifest)
execute = fn label, script, args ->
  frozen_script = Path.join([run, "inputs", script])
  command = "PATH=\"$HOME/.asdf/installs/erlang/29.1.2/bin:$PATH\" ELIXIR_ERL_OPTIONS='+S 2:2' \"$HOME/.asdf/installs/elixir/1.20.5-otp-29/bin/elixir\" #{frozen_script} #{Enum.join(args, " ")}"
  File.write!(Path.join(run, label <> ".command"), command <> "\n")
  IO.puts("COMMAND #{command}")
  {output, status} = System.cmd(elixir, [frozen_script | args], env: env, stderr_to_stdout: true, cd: run)
  File.write!(Path.join(run, label <> ".log"), output)
  File.write!(Path.join(run, label <> ".status"), "#{status}\n")
  IO.write(output)
  IO.puts("EXIT #{label} #{status}")
  if status != 0, do: raise("#{label} failed; raw evidence: #{run}")
end
for revision <- ["v1", "v2", "rejected", "v3"] do
  source = Path.join([run, "inputs", "snapshots", revision <> ".exs"])
  execute.("prepare-#{revision}", "prepare.exs", [source, Path.join([run, "artifacts", revision])])
end
for mode <- ["coherent", "before_install", "after_install", "during_restoration", "after_accept"] do
  execute.("fixture-#{mode}", "fixture.exs", [run, mode])
end
IO.puts("ALL_SCHEDULES_PASS evidence=#{run}")
