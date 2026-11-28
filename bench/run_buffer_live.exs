# Frame time for streamed edits on a real frontend (#4397, AC 6).
#
# Start the editor as a named node with the development launcher, which uses a private profile. Build first
# without ERL_FLAGS: the flag names every VM the build starts, and they collide.
#
#     python3 -c "open('/tmp/big.txt','w').write(''.join(f'line {i}\n' for i in range(50000)))"
#     make xcodegen-generate native.support
#     mix swift.build -- -project macos/Minga.xcodeproj -scheme Minga -configuration Debug \
#       -derivedDataPath macos/DerivedData -destination "platform=macOS,arch=$(uname -m)" build
#     MINGA_SKIP_NATIVE_LAUNCH_BUILD=1 ERL_FLAGS="-sname mbench -setcookie mbenchcookie" bin/minga-mac /tmp/big.txt
#
# For the terminal frontend, build with `mix native.build.tui` and launch `bin/minga` the same way inside a
# pseudo-terminal, for example `script -q /dev/null sh -c 'stty rows 50 cols 160; exec bin/minga /tmp/big.txt'`.
#
# Then, from another shell, once the window is up:
#
#     elixir --sname ctl --cookie mbenchcookie bench/run_buffer_live.exs mbench B
#
# It prints one JSON object. Post results on the issue, not in the tree.
[node_name, scenario] = System.argv()
{:ok, host} = :inet.gethostname()
node = :"#{node_name}@#{host}"
true = Node.connect(node)
script = File.read!(Path.join(__DIR__, "run_buffer_live_remote.exs"))
binding = [scenario: scenario, hz: 30, seconds: 10, mid: 10_500]
{result, _binding} = :rpc.call(node, Code, :eval_string, [script, binding], 120_000)
IO.puts(:rpc.call(node, JSON, :encode!, [result]))
