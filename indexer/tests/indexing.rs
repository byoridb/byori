use byori_indexer::{index, Snapshot};
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Repo(PathBuf);
impl Repo {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "byori-indexer-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        assert!(Command::new("git")
            .args(["init", "-q"])
            .arg(&path)
            .status()
            .unwrap()
            .success());
        Self(path)
    }
    fn write(&self, path: &str, text: &str) {
        let p = self.0.join(path);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }
    fn scan(&self) -> Snapshot {
        index(&self.0, None).unwrap()
    }
}
impl Drop for Repo {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn names(s: &Snapshot) -> Vec<&str> {
    s.symbols
        .iter()
        .map(|s| s.qualified_name.as_str())
        .collect()
}
fn resolved(s: &Snapshot, name: &str) -> bool {
    s.references
        .iter()
        .any(|r| r.kind == "calls" && r.name == name && r.resolution == "resolved")
}
#[test]
fn all_languages_extract_ast_symbols_and_direct_calls() {
    let r = Repo::new();
    r.write("app.py","def helper():\n    pass\nclass User:\n    def method(self):\n        helper()\ndef run():\n    def inner():\n        helper()\n    inner()\n");
    r.write("app.swift","import Foundation\nprotocol Worker { func work() }\nstruct User { func method() { helper() } }\nfunc helper() {}\nfunc run() { helper() }\n");
    r.write("app.js","export function helper() {}\nexport const run = () => helper();\nclass User { method() { helper(); } }\n");
    r.write("app.ts","interface User { name: string; }\ntype ID = string;\nfunction helper(): void {}\nconst run = (): void => helper();\n");
    r.write("view.jsx", "export const View = () => <div>Hello</div>;\n");
    r.write(
        "view.tsx",
        "export function View(): JSX.Element { return <div>Hello</div>; }\n",
    );
    r.write("src/lib.rs","use std::fmt;\nstruct User;\nenum State { Ready }\ntrait Worker { fn work(&self); }\nimpl User { fn method(&self) { helper(); } }\nfn helper() {}\nfn run() { helper(); println!(\"ok\"); }\n");
    let s = r.scan();
    assert_eq!(s.files.len(), 7);
    assert!(s.diagnostics.is_empty(), "{:?}", s.diagnostics);
    for path in ["app.py", "app.swift", "app.js", "app.ts", "src/lib.rs"] {
        assert!(
            s.references
                .iter()
                .any(|r| r.file == path && r.name == "helper" && r.resolution == "resolved"),
            "{path}: {:?}",
            s.references
        );
    }
    for name in ["User::method", "run::inner", "Worker", "ID", "State"] {
        assert!(names(&s).contains(&name), "{name}: {:?}", names(&s));
    }
    assert!(s
        .references
        .iter()
        .any(|r| r.name == "println!" && r.target.is_none()));
    assert!(s
        .references
        .iter()
        .any(|r| r.kind == "imports" && r.name == "Foundation"));
}
#[test]
fn conservative_resolution_preserves_dynamic_and_shadowed_calls() {
    let r = Repo::new();
    r.write("app.py","def helper(): pass\ndef first(helper): helper()\ndef second(obj): obj.helper()\ndef third():\n    helper = lambda: None\n    helper()\n");
    r.write("other.py", "def external(): pass\n");
    r.write("use.py", "external()\n");
    let s = r.scan();
    assert!(!resolved(&s, "helper"));
    assert!(!resolved(&s, "external"));
    assert!(s.references.iter().all(|r| r.target.is_none()));
}
#[test]
fn relative_imports_connect_files_and_named_exported_functions() {
    let r = Repo::new();
    r.write(
        "lib.ts",
        "export function helper() {}\nfunction privateFn() {}\n",
    );
    r.write("app.ts","import { helper as work, privateFn } from './lib';\nfunction run() { work(); privateFn(); }\n");
    r.write("pkg/lib.py", "def helper(): pass\n");
    r.write(
        "pkg/app.py",
        "from .lib import helper as work\ndef run(): work()\n",
    );
    r.write("src/lib.rs", "mod helpers;\n");
    r.write("src/helpers.rs", "fn helper() {}\n");
    let s = r.scan();
    assert_eq!(
        s.references
            .iter()
            .filter(|r| r.name == "work" && r.resolution == "resolved")
            .count(),
        2
    );
    assert!(!resolved(&s, "privateFn"));
    assert_eq!(
        s.references
            .iter()
            .filter(|r| r.kind == "imports" && r.resolution == "resolved")
            .count(),
        3
    );
}
#[test]
fn cache_reuses_only_unchanged_content_and_removes_deleted_files() {
    let r = Repo::new();
    r.write("a.py", "def one(): pass\n");
    r.write("b.rs", "fn two() {}\n");
    let cache = r.0.join("cache");
    let a = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(a.stats.parsed_files, 2);
    let b = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(a.snapshot_id, b.snapshot_id);
    assert_eq!(b.stats.cached_files, 2);
    r.write("a.py", "def changed(): pass\n");
    let c = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(c.stats.parsed_files, 1);
    assert_eq!(c.stats.cached_files, 1);
    assert_ne!(b.snapshot_id, c.snapshot_id);
    fs::remove_file(r.0.join("b.rs")).unwrap();
    let d = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(d.files.len(), 1);
    assert!(!names(&d).contains(&"two"));
    assert_ne!(c.snapshot_id, d.snapshot_id);
    fs::rename(r.0.join("a.py"), r.0.join("renamed.py")).unwrap();
    let e = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(e.files[0].path, "renamed.py");
    assert_eq!(e.stats.parsed_files, 1);
}
#[test]
fn checkout_ids_and_snapshot_ids_are_isolated() {
    let a = Repo::new();
    let b = Repo::new();
    a.write("app.py", "def run(): pass\n");
    b.write("app.py", "def run(): pass\n");
    assert_ne!(a.scan().checkout_id, b.scan().checkout_id);
    assert_ne!(a.scan().snapshot_id, b.scan().snapshot_id);
}
#[test]
fn git_ignores_generated_directories_and_symlinks() {
    let r = Repo::new();
    r.write(".gitignore", "ignored.py\n");
    r.write("ignored.py", "def hidden(): pass\n");
    r.write("node_modules/a.js", "function hidden() {}\n");
    r.write("src/app.py", "def visible(): pass\n");
    #[cfg(unix)]
    std::os::unix::fs::symlink(r.0.join("src/app.py"), r.0.join("link.py")).unwrap();
    let s = r.scan();
    assert_eq!(s.files.len(), 1);
    assert_eq!(s.files[0].path, "src/app.py");
}
#[test]
fn syntax_errors_are_visible_and_calls_are_not_claimed_resolved() {
    let r = Repo::new();
    r.write("bad.py", "def helper(): pass\ndef broken(:\n    helper()\n");
    let s = r.scan();
    assert!(!s.diagnostics.is_empty());
    assert!(!resolved(&s, "helper"));
}
#[test]
fn malformed_cache_is_rebuilt() {
    let r = Repo::new();
    r.write("app.py", "def run(): pass\n");
    let cache = r.0.join("cache");
    let a = index(&r.0, Some(&cache)).unwrap();
    let dir = cache.join(&a.checkout_id);
    for file in fs::read_dir(dir).unwrap() {
        fs::write(file.unwrap().path(), "broken").unwrap();
    }
    let b = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(a.snapshot_id, b.snapshot_id);
    assert_eq!(b.stats.parsed_files, 1);
}

#[test]
fn shadowed_imports_arrow_parameters_and_swift_members_are_not_global_functions() {
    let r = Repo::new();
    r.write("app.py", "def helper(): pass\nimport helper\nhelper()\n");
    r.write("app.js", "function helper() {}\nconst run = helper => helper();\nconst nested = () => [1].map(helper => helper());\n");
    r.write(
        "app.swift",
        "func helper() {}\nstruct User { func helper() {}\nfunc run() { helper() } }\n",
    );
    let s = r.scan();
    assert!(!resolved(&s, "helper"), "{:?}", s.references);
}

#[test]
fn rust_explicit_paths_and_use_aliases_follow_declared_modules() {
    let r = Repo::new();
    r.write("src/lib.rs", "mod helpers;\nmod client;\nuse crate::helpers::{helper as work, hidden};\nfn run() { work(); crate::helpers::helper(); hidden(); }\npub fn parent() {}\nmod inline { pub fn nested() {} }\nfn other() { self::inline::nested(); }\n");
    r.write("src/helpers.rs", "pub fn helper() {}\nfn hidden() {}\n");
    r.write(
        "src/client.rs",
        "use super::parent as work;\nfn run() { work(); super::parent(); }\n",
    );
    let s = r.scan();
    for name in [
        "work",
        "crate::helpers::helper",
        "self::inline::nested",
        "super::parent",
    ] {
        assert!(resolved(&s, name), "{name}: {:?}", s.references);
    }
    assert!(!resolved(&s, "hidden"));
    assert_eq!(
        s.references
            .iter()
            .filter(|r| r.name == "work" && r.target.is_some())
            .count(),
        2
    );
}

#[test]
fn commonjs_relative_requires_resolve_explicit_exports_and_aliases() {
    let r = Repo::new();
    r.write(
        "helpers.cjs",
        "function helper() {}\nfunction hidden() {}\nmodule.exports = { publicFn: helper };\n",
    );
    r.write(
        "single.cjs",
        "function single() {}\nmodule.exports = single;\n",
    );
    r.write("app.cjs", "const lib = require('./helpers.cjs');\nconst { publicFn: work, hidden } = require('./helpers.cjs');\nconst single = require('./single.cjs');\nfunction run() { lib.publicFn(); work(); hidden(); single(); }\n");
    let s = r.scan();
    for name in ["lib.publicFn", "work", "single"] {
        assert!(resolved(&s, name), "{name}: {:?}", s.references);
    }
    assert!(!resolved(&s, "hidden"));
}

#[test]
fn commonjs_shadowed_require_and_reassigned_namespace_are_unresolved() {
    let r = Repo::new();
    r.write(
        "helpers.js",
        "function helper() {}\nexports.helper = helper;\n",
    );
    r.write("app.js", "function run(require) { const lib = require('./helpers'); lib.helper(); }\nconst lib = require('./helpers');\nlib.helper = () => {};\nlib.helper();\n");
    let s = r.scan();
    assert!(!resolved(&s, "lib.helper"), "{:?}", s.references);
}

#[test]
fn commonjs_inline_exported_functions_are_symbols() {
    let r = Repo::new();
    r.write("one.cjs", "module.exports = () => 1;\n");
    r.write("two.cjs", "exports.helper = function () { return 2; };\n");
    r.write("app.cjs","const one = require('./one.cjs');\nconst { helper } = require('./two.cjs');\nfunction run() { one(); helper(); }\n");
    let s = r.scan();
    assert!(resolved(&s, "one"), "{:?}", s.references);
    assert!(resolved(&s, "helper"));
}

#[cfg(unix)]
#[test]
fn checkout_cache_and_entries_are_private_without_changing_cache_root() {
    use std::os::unix::fs::PermissionsExt;
    let r = Repo::new();
    r.write("app.py", "def private_project_fact(): pass\n");
    let cache = r.0.join("cache");
    fs::create_dir(&cache).unwrap();
    fs::set_permissions(&cache, fs::Permissions::from_mode(0o755)).unwrap();
    let first = index(&r.0, Some(&cache)).unwrap();
    let checkout = cache.join(&first.checkout_id);
    assert_eq!(
        fs::metadata(&cache).unwrap().permissions().mode() & 0o777,
        0o755
    );
    assert_eq!(
        fs::metadata(&checkout).unwrap().permissions().mode() & 0o777,
        0o700
    );
    for entry in fs::read_dir(&checkout).unwrap() {
        assert_eq!(
            entry.unwrap().metadata().unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    // Existing caches from versions that inherited a permissive umask are fixed.
    fs::set_permissions(&checkout, fs::Permissions::from_mode(0o777)).unwrap();
    let second = index(&r.0, Some(&cache)).unwrap();
    assert_eq!(second.stats.cached_files, 1);
    assert_eq!(
        fs::metadata(&checkout).unwrap().permissions().mode() & 0o777,
        0o700
    );
}
