# Source control smoke path

The by-hand pass over §7.12 that a release makes from the phone, in order.
Every step is one screen; if a step needs the computer, the feature has
failed its point.

1. **Home → a repository card → "New worktree"** → the New Agent sheet in
   worktree mode. Pick an issue from the menu: the branch is proposed as
   `issue/<number>-<slug>` (`HostSourceControlClient.IssueSummary.branchName`).
2. **The worktree lands** at `<repo>-worktrees/<slug>` with
   `branch.<b>.base` set to the base branch and `push.autoSetupRemote` on,
   so "vs main" reads right and the first push needs no `-u`.
3. **Edit something**, then the worktree header → **Changes**: the files
   appear, stage and unstage move them between the sections.
4. **Commit** with a message; **Commits** shows it at the top.
5. **Push**, then **Pull request** → the PR opens against the base branch
   and the sheet links to it.
6. **`···` → Remove worktree** takes the folder, the branch, and the
   `.git/worktrees` admin directory with it, leaving no `*.removing-*`
   folder behind (#82).

Run it on a real device over a real network, not the simulator: the point
of the pass is the feel, and the simulator has none.
