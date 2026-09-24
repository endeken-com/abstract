//! End-to-end check of the git plumbing against the real `git` binary:
//! provision a worktree, change files inside it, collect the diff, accept one
//! hunk into the main working tree, and reject a change in the worktree.

use abstract_lib::executor::{local::LocalExecutor, Executor};
use abstract_lib::git::{diff, worktree};

async fn git(exec: &dyn Executor, cwd: &str, args: &[&str]) -> String {
    let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
    let out = exec.exec("git", &owned, Some(cwd)).await.expect("git ran");
    assert!(out.ok(), "git {:?} failed: {}", args, out.stderr);
    out.stdout
}

struct TempRepo {
    root: String,
    _dir: std::path::PathBuf,
}

impl Drop for TempRepo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self._dir);
    }
}

async fn make_repo(exec: &dyn Executor, label: &str) -> TempRepo {
    let dir = std::env::temp_dir().join(format!("abstract-test-{label}-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&dir).unwrap();
    let root = dir.to_string_lossy().to_string();
    git(exec, &root, &["init", "-q", "-b", "main"]).await;
    git(exec, &root, &["config", "user.email", "test@abstract.local"]).await;
    git(exec, &root, &["config", "user.name", "Abstract Test"]).await;
    let base: String = (1..=20).map(|n| format!("line {n}\n")).collect();
    std::fs::write(dir.join("app.txt"), &base).unwrap();
    git(exec, &root, &["add", "-A"]).await;
    git(exec, &root, &["commit", "-qm", "init"]).await;
    TempRepo { root, _dir: dir }
}

#[tokio::test]
async fn worktree_diff_accept_and_reject() {
    let exec = LocalExecutor::new();
    let repo = make_repo(&exec, "flow").await;
    let wt_path = format!("{}-wt", repo.root);

    // 1. Provision an isolated worktree on its own branch.
    worktree::add(&exec, &repo.root, &wt_path, "abstract/test-session", "HEAD")
        .await
        .expect("worktree created");
    assert!(std::path::Path::new(&wt_path).join("app.txt").exists());

    let listed = worktree::list(&exec, &repo.root).await.unwrap();
    assert_eq!(listed.len(), 2, "main working tree plus the new worktree");
    assert!(listed.iter().any(|w| w.branch.as_deref() == Some("abstract/test-session")));

    // 2. The agent edits an existing file (two separate hunks) and adds a new one.
    // Two edits far enough apart that git emits two separate hunks.
    let edited: String = (1..=20)
        .map(|n| match n {
            1 => "FIRST\n".to_string(),
            20 => "LAST\n".to_string(),
            _ => format!("line {n}\n"),
        })
        .collect();
    std::fs::write(std::path::Path::new(&wt_path).join("app.txt"), &edited).unwrap();
    std::fs::write(std::path::Path::new(&wt_path).join("hi.txt"), "hi\n").unwrap();

    // 3. Collect the diff, untracked files included.
    let files = diff::collect(&exec, &wt_path, &[]).await.expect("diff collected");
    let app = files.iter().find(|f| f.path == "app.txt").expect("app.txt changed");
    let hi = files.iter().find(|f| f.path == "hi.txt").expect("hi.txt is a new file");
    assert_eq!(hi.status, "added");
    assert_eq!(app.status, "modified");
    assert_eq!(app.hunks.len(), 2, "edits at both ends of the file are separate hunks");

    // 4. Accept only the first hunk into the project's main working tree.
    let patch = diff::build_patch(app, &[0]);
    diff::apply_patch(&exec, &repo.root, &patch, false, true)
        .await
        .expect("patch applied to the main tree");

    let main_app = std::fs::read_to_string(std::path::Path::new(&repo.root).join("app.txt")).unwrap();
    assert!(main_app.starts_with("FIRST\n"), "accepted hunk landed in the main tree");
    assert!(main_app.trim_end().ends_with("line 20"), "unaccepted hunk stayed behind");

    // 5. Reject the remaining change inside the worktree.
    let patch = diff::build_patch(app, &[1]);
    diff::apply_patch(&exec, &wt_path, &patch, true, false)
        .await
        .expect("hunk reverse-applied in the worktree");
    let wt_app = std::fs::read_to_string(std::path::Path::new(&wt_path).join("app.txt")).unwrap();
    assert!(wt_app.trim_end().ends_with("line 20"), "rejected hunk is gone from the worktree");
    assert!(wt_app.starts_with("FIRST\n"), "the other hunk survived the rejection");

    // 6. Tear the worktree down, branch and all.
    worktree::remove(&exec, &repo.root, &wt_path, Some("abstract/test-session"))
        .await
        .expect("worktree removed");
    assert!(!std::path::Path::new(&wt_path).exists());
    let after = worktree::list(&exec, &repo.root).await.unwrap();
    assert_eq!(after.len(), 1, "only the main working tree is left");
}

#[tokio::test]
async fn nested_repositories_are_found_and_excluded_from_the_diff() {
    let exec = LocalExecutor::new();
    let repo = make_repo(&exec, "nested").await;

    // A vendored repository inside the project: a worktree cannot carry it.
    let inner = format!("{}/vendor/inner", repo.root);
    std::fs::create_dir_all(&inner).unwrap();
    git(&exec, &inner, &["init", "-q", "-b", "main"]).await;
    std::fs::write(format!("{inner}/lib.txt"), "vendored\n").unwrap();

    let nested = worktree::nested_repos(&exec, &repo.root).await.unwrap();
    assert!(
        nested.iter().any(|p| p == "vendor/inner"),
        "nested repo reported relative to the project root, got {nested:?}"
    );

    std::fs::write(format!("{}/tracked.txt", repo.root), "changed\n").unwrap();
    let files = diff::collect(&exec, &repo.root, &nested).await.unwrap();
    assert!(files.iter().any(|f| f.path == "tracked.txt"));
    assert!(
        !files.iter().any(|f| f.path.starts_with("vendor/")),
        "excluded paths must not appear in the diff"
    );
}

#[tokio::test]
async fn an_unknown_nested_repository_does_not_hide_the_rest_of_the_changes() {
    // The project was added before someone vendored a repository into it, so
    // Abstract has no record of it. A whole-tree `git add -N` fails outright
    // in that situation; the review must still show everything else.
    let exec = LocalExecutor::new();
    let repo = make_repo(&exec, "unknown-nested").await;

    let inner = format!("{}/vendor/surprise", repo.root);
    std::fs::create_dir_all(&inner).unwrap();
    git(&exec, &inner, &["init", "-q", "-b", "main"]).await;
    std::fs::write(format!("{inner}/lib.txt"), "vendored\n").unwrap();

    std::fs::write(format!("{}/brand-new.txt", repo.root), "new file\n").unwrap();
    std::fs::write(format!("{}/app.txt", repo.root), "line 1 changed\n").unwrap();

    let files = diff::collect(&exec, &repo.root, &[]).await.unwrap();
    assert!(
        files.iter().any(|f| f.path == "brand-new.txt" && f.status == "added"),
        "a new file must survive an unregistered nested repo, got {:?}",
        files.iter().map(|f| &f.path).collect::<Vec<_>>()
    );
    assert!(files.iter().any(|f| f.path == "app.txt"));
    assert!(!files.iter().any(|f| f.path.starts_with("vendor/")));
}
