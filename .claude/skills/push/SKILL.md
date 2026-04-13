# Push Skill

Safe commit-and-push workflow that handles GitHub email privacy and gitignore checks.

## Steps

1. Run `git status` to see staged/unstaged changes. Check for unexpected files.
2. Check `.gitignore` covers any new file types being committed.
3. If there are uncommitted changes, stage the relevant files and create a commit.
4. Before pushing, verify the build passes: `cmake --build build -j 2>&1 | tail -3`
5. Run `git config user.email` — if it is not a `@users.noreply.github.com` address, set it:
   ```
   git config user.email "LPmore@users.noreply.github.com"
   ```
6. Push with `git push origin HEAD`.
7. If push fails due to email privacy, amend the commit:
   ```
   git commit --amend --author="LPmore <LPmore@users.noreply.github.com>" --no-edit
   ```
   Then retry the push.
