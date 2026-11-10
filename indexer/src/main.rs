use anyhow::{bail, Context, Result};
use std::io::{self, Write};
use std::path::PathBuf;

fn run() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let Some(command) = args.next() else {
        bail!("usage: byori-indexer index --root PATH [--cache-dir PATH] [--no-cache]");
    };
    if command == "--version" {
        println!(
            "byori-indexer {} ({})",
            env!("CARGO_PKG_VERSION"),
            byori_indexer::ANALYSIS_VERSION
        );
        return Ok(());
    }
    if command == "--help" || command == "-h" {
        println!("byori-indexer index --root PATH [--cache-dir PATH] [--no-cache]\nIndexes Python, Swift, JavaScript/TypeScript and Rust in a Git checkout.\nWrites one versioned JSON snapshot to stdout. No source code leaves the machine.");
        return Ok(());
    }
    if command != "index" {
        bail!("unknown command: {}", command);
    }
    let mut root = None;
    let mut cache = None;
    let mut no_cache = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => {
                root = Some(PathBuf::from(
                    args.next().context("--root requires a path")?,
                ))
            }
            "--cache-dir" => {
                cache = Some(PathBuf::from(
                    args.next().context("--cache-dir requires a path")?,
                ))
            }
            "--no-cache" => no_cache = true,
            _ => bail!("unknown argument: {}", arg),
        }
    }
    let root = root.context("--root is required")?;
    let cache = if no_cache {
        None
    } else {
        cache.or_else(|| {
            std::env::var_os("BYORI_HOME")
                .map(PathBuf::from)
                .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".byori")))
                .map(|p| p.join("code-cache"))
        })
    };
    let snapshot = byori_indexer::index(&root, cache.as_deref())?;
    for d in &snapshot.diagnostics {
        eprintln!("{}: {}", d.file, d.message);
    }
    let mut out = io::BufWriter::new(io::stdout().lock());
    serde_json::to_writer(&mut out, &snapshot)?;
    writeln!(&mut out)?;
    out.flush()?;
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("byori-indexer: {error:#}");
        std::process::exit(1);
    }
}
