# This VM compiles exactly one already-frozen source snapshot, then exits.
[source, output] = System.argv()
expected = [R0Definition.Helper, R0Definition.Left, R0Definition.Right]
true = Enum.all?(expected, &(:code.is_loaded(&1) == false))
Code.compiler_options(no_warn_undefined: [R0.Gate])
File.mkdir_p!(output)
artifacts = Code.compile_file(source)
true = Enum.sort(Enum.map(artifacts, &elem(&1, 0))) == expected
for {module, binary} <- artifacts do
  path = Path.join(output, Atom.to_string(module) <> ".beam")
  File.write!(path, binary, [:exclusive])
  File.chmod!(path, 0o444)
  IO.puts("BEAM #{module} sha256=#{Base.encode16(:crypto.hash(:sha256, binary), case: :lower)}")
end
IO.puts("PREPARED source_sha256=#{Base.encode16(:crypto.hash(:sha256, File.read!(source)), case: :lower)} elixir=#{System.version()} otp=#{:erlang.system_info(:otp_release)} pid=#{System.pid()}")
