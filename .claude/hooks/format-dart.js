// PostToolUse hook: run `dart format` on any .dart file Claude edits or writes.
let input = '';
process.stdin.on('data', (c) => (input += c));
process.stdin.on('end', () => {
  try {
    const file = JSON.parse(input)?.tool_input?.file_path;
    if (!file || !file.endsWith('.dart') || file.endsWith('.g.dart')) return;
    require('child_process').spawnSync('dart', ['format', file], {
      stdio: 'ignore',
      shell: true,
    });
  } catch {
    // never block the edit on a formatting failure
  }
});
