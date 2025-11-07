for restoring agents like codex we also need a session-id. unfortuntely codex does not give this out directly.
  workaround:

  in a non-visible area  start codex with "codex 'say ready'" to start a session. the quit it by sending ctrl-c
  after we see sth  like this on stdout:


  › say 'ready'


  • ready

  (ie. it has opened a session)

  when codex quits, it prints sth like

  oken usage: total=267 input=260 (+ 4,992 cached) output=7
  To continue this session, run codex resume 019a4a73-49de-7450-882d-8ffcfe289c0f

  and tells us the session-id.

  we store the session-id with our "open agent terminal" in the config.

  and we instantly open a visible terminal by running codex resume 019a4a73-49de-7450-882d-8ffcfe289c0f

  we also use this command when we restore our workspace.

diff helper sketch
  - :JJDiff splits (default right) and renders `jj diff -tool difftastic --color=always` inside a virtual terminal so ANSI colours survive, but the buffer stays `nofile`/readonly.
  - buffer-local `gr` reruns the command, `gc` prompts for a comment on the current line or visual selection, prefixes it with workspace/file metadata, and forwards the payload to the agent job (auto-opening if needed).
  - comment payload quotes the selected hunk with `> ` lines; ANSI sequences are stripped before sending so the agent text stays clean.
