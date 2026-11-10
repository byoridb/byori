//! Deterministic source facts. A parsed call is not proof of a runtime dispatch.
//! Only unambiguous lexical functions and explicit relative imports are resolved.
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path};
use std::process::Command;
use tree_sitter::{Language, Node, Parser};

pub const ANALYSIS_VERSION: &str = "byori-indexer-2";
pub const MAX_FILE_BYTES: u64 = 2 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileRecord {
    pub id: String,
    pub path: String,
    pub language: String,
    pub hash: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Symbol {
    pub id: String,
    pub name: String,
    pub qualified_name: String,
    pub kind: String,
    pub file: String,
    pub start_line: usize,
    pub end_line: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reference {
    pub source: String,
    pub target: Option<String>,
    pub kind: String,
    pub name: String,
    pub file: String,
    pub line: usize,
    pub resolution: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Diagnostic {
    pub file: String,
    pub message: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Stats {
    pub files: usize,
    pub parsed_files: usize,
    pub cached_files: usize,
    pub symbols: usize,
    pub resolved_references: usize,
    pub unresolved_references: usize,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub format_version: u32,
    pub root: String,
    pub checkout_id: String,
    pub revision: String,
    pub snapshot_id: String,
    pub files: Vec<FileRecord>,
    pub symbols: Vec<Symbol>,
    pub references: Vec<Reference>,
    pub diagnostics: Vec<Diagnostic>,
    pub stats: Stats,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Definition {
    symbol: Symbol,
    scope: String,
    exported: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PendingReference {
    reference: Reference,
    scope: String,
    direct: bool,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct ImportBinding {
    scope: String,
    alias: String,
    module: String,
    member: String,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Scope {
    parent: Option<String>,
    kind: String,
    blocked: BTreeSet<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
struct Analysis {
    definitions: Vec<Definition>,
    references: Vec<PendingReference>,
    scopes: BTreeMap<String, Scope>,
    imports: Vec<ImportBinding>,
    diagnostics: Vec<Diagnostic>,
    exports: BTreeMap<String, String>,
}
#[derive(Serialize, Deserialize)]
struct Cache {
    version: String,
    path: String,
    language: String,
    hash: String,
    analysis: Analysis,
}

fn digest(value: impl AsRef<[u8]>) -> String {
    format!("{:x}", Sha256::digest(value.as_ref()))
}
fn source<'a>(node: Node, text: &'a [u8]) -> &'a str {
    node.utf8_text(text).unwrap_or("")
}
fn field<'a>(node: Node, name: &str, text: &'a [u8]) -> Option<&'a str> {
    node.child_by_field_name(name).map(|n| source(n, text))
}
fn children(node: Node) -> Vec<Node> {
    let mut c = node.walk();
    node.named_children(&mut c).collect()
}
fn identifiers(node: Node, text: &[u8], out: &mut BTreeSet<String>) {
    if matches!(
        node.kind(),
        "identifier" | "simple_identifier" | "pattern_identifier"
    ) {
        out.insert(source(node, text).to_owned());
    }
    for c in children(node) {
        identifiers(c, text, out);
    }
}
fn language(path: &str) -> Option<(&'static str, Language)> {
    let ext = Path::new(path).extension()?.to_str()?;
    Some(match ext {
        "py" | "pyi" => ("python", tree_sitter_python::LANGUAGE.into()),
        "swift" => ("swift", tree_sitter_swift::LANGUAGE.into()),
        "js" | "jsx" | "mjs" | "cjs" => ("javascript", tree_sitter_javascript::LANGUAGE.into()),
        "ts" | "mts" | "cts" => (
            "typescript",
            tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        ),
        "tsx" => ("typescript", tree_sitter_typescript::LANGUAGE_TSX.into()),
        "rs" => ("rust", tree_sitter_rust::LANGUAGE.into()),
        _ => return None,
    })
}
fn is_function(kind: &str) -> bool {
    kind == "function"
}
fn definition(node: Node, lang: &str, text: &[u8]) -> Option<(String, String)> {
    if matches!(lang, "javascript" | "typescript")
        && node.kind() == "assignment_expression"
        && node
            .parent()
            .and_then(|n| n.parent())
            .is_some_and(|n| n.kind() == "program")
        && node.child_by_field_name("right").is_some_and(|n| {
            matches!(
                n.kind(),
                "function_expression" | "arrow_function" | "generator_function"
            )
        })
    {
        let left = field(node, "left", text)?;
        let name = if left == "module.exports" {
            "default"
        } else {
            left.strip_prefix("exports.")
                .or_else(|| left.strip_prefix("module.exports."))?
        };
        if !name.contains('.') {
            return Some((name.to_owned(), "function".into()));
        }
    }
    let kind = match node.kind() {
        "function_definition"
        | "function_item"
        | "function_declaration"
        | "generator_function_declaration"
        | "function_signature_item"
        | "function_signature" => "function",
        "class_definition" | "class_declaration" | "abstract_class_declaration" => "class",
        "struct_item" => "struct",
        "enum_item" | "enum_declaration" => "enum",
        "trait_item" => "trait",
        "protocol_declaration" => "protocol",
        "interface_declaration" => "interface",
        "type_item" | "type_alias_declaration" | "typealias_declaration" => "type",
        "mod_item" | "internal_module" => "module",
        "method_definition" | "method_signature" => "method",
        "macro_definition" => "macro",
        "impl_item" => "impl",
        "variable_declarator"
            if node.child_by_field_name("value").is_some_and(|n| {
                matches!(
                    n.kind(),
                    "arrow_function" | "function_expression" | "generator_function"
                )
            }) =>
        {
            "function"
        }
        "property_declaration"
            if lang == "swift"
                && node
                    .child_by_field_name("value")
                    .is_some_and(|n| n.kind() == "lambda_literal") =>
        {
            "function"
        }
        _ => return None,
    };
    let name = if node.kind() == "impl_item" {
        let ty = field(node, "type", text)?;
        match field(node, "trait", text) {
            Some(tr) => format!("{} for {}", tr, ty),
            None => ty.to_owned(),
        }
    } else {
        field(node, "name", text)?.to_owned()
    };
    if name.is_empty() || name.len() > 512 {
        return None;
    }
    let kind = if lang == "swift" && node.kind() == "class_declaration" {
        field(node, "declaration_kind", text).unwrap_or(kind)
    } else {
        kind
    };
    Some((name, kind.to_owned()))
}

struct Extractor<'a> {
    path: &'a str,
    lang: &'a str,
    text: &'a [u8],
    analysis: Analysis,
}
impl<'a> Extractor<'a> {
    fn reference(&mut self, node: Node, scope: &str, name: String, kind: &str, direct: bool) {
        if name.is_empty() || name.len() > 4096 {
            return;
        }
        self.analysis.references.push(PendingReference {
            reference: Reference {
                source: scope.to_owned(),
                target: None,
                kind: kind.to_owned(),
                name,
                file: self.path.to_owned(),
                line: node.start_position().row + 1,
                resolution: "unresolved".into(),
            },
            scope: scope.to_owned(),
            direct,
        });
    }
    fn walk(&mut self, node: Node, parent: &str, qualified: &str, depth: usize) {
        if depth > 512 {
            if !self
                .analysis
                .diagnostics
                .iter()
                .any(|d| d.message.starts_with("AST depth"))
            {
                self.analysis.diagnostics.push(Diagnostic {
                    file: self.path.to_owned(),
                    message: "AST depth exceeded 512; nested source was skipped".into(),
                });
            }
            return;
        }
        // Macro token trees are syntax, not expanded Rust code.
        if matches!(node.kind(), "token_tree" | "token_tree_pattern") {
            return;
        }
        let mut scope = parent.to_owned();
        let mut qname = qualified.to_owned();
        if let Some((name, mut kind)) = definition(node, self.lang, self.text) {
            if kind == "function"
                && self.analysis.scopes.get(parent).is_some_and(|s| {
                    matches!(
                        s.kind.as_str(),
                        "class"
                            | "struct"
                            | "enum"
                            | "trait"
                            | "protocol"
                            | "interface"
                            | "impl"
                            | "extension"
                            | "actor"
                    )
                })
            {
                kind = "method".into();
            }
            qname = if qualified.is_empty() {
                name.clone()
            } else {
                format!("{}::{}", qualified, name)
            };
            let id = format!("symbol:{}:{}:{}", self.path, node.start_byte(), qname);
            let exported =
                (self.lang != "javascript" && self.lang != "typescript" && self.lang != "rust")
                    || (self.lang == "rust"
                        && children(node)
                            .iter()
                            .any(|n| n.kind() == "visibility_modifier"))
                    || node
                        .parent()
                        .is_some_and(|p| p.kind() == "export_statement")
                    || node
                        .parent()
                        .and_then(|p| p.parent())
                        .is_some_and(|p| p.kind() == "export_statement");
            self.analysis.definitions.push(Definition {
                symbol: Symbol {
                    id: id.clone(),
                    name,
                    qualified_name: qname.clone(),
                    kind: kind.clone(),
                    file: self.path.to_owned(),
                    start_line: node.start_position().row + 1,
                    end_line: node.end_position().row + 1,
                },
                scope: parent.to_owned(),
                exported,
            });
            self.analysis.scopes.insert(
                id.clone(),
                Scope {
                    parent: Some(parent.to_owned()),
                    kind,
                    blocked: BTreeSet::new(),
                },
            );
            scope = id;
            let params = node.child_by_field_name("parameters").or_else(|| {
                node.child_by_field_name("value")
                    .or_else(|| node.child_by_field_name("right"))
                    .and_then(|v| {
                        v.child_by_field_name("parameters")
                            .or_else(|| v.child_by_field_name("parameter"))
                    })
            });
            if let Some(params) = params {
                let mut names = BTreeSet::new();
                identifiers(params, self.text, &mut names);
                self.analysis
                    .scopes
                    .get_mut(&scope)
                    .unwrap()
                    .blocked
                    .extend(names);
            }
            // Swift parameters are direct children instead of one parameters field.
            if self.lang == "swift" {
                for child in children(node)
                    .into_iter()
                    .filter(|n| n.kind() == "parameter")
                {
                    let mut names = BTreeSet::new();
                    identifiers(child, self.text, &mut names);
                    self.analysis
                        .scopes
                        .get_mut(&scope)
                        .unwrap()
                        .blocked
                        .extend(names);
                }
            }
        }
        let commonjs_binding = if matches!(self.lang, "javascript" | "typescript") {
            self.commonjs(node, &scope)
        } else {
            false
        };
        // Shadowed callables are left unresolved even where static analysis could guess.
        let binding = match node.kind() {
            "assignment"
            | "augmented_assignment"
            | "assignment_expression"
            | "augmented_assignment_expression" => node.child_by_field_name("left"),
            "variable_declarator" if scope == parent && !commonjs_binding => {
                node.child_by_field_name("name")
            }
            "let_declaration" => node.child_by_field_name("pattern"),
            "property_declaration" if scope == parent => node.child_by_field_name("name"),
            "for_statement" => node.child_by_field_name("left"),
            _ => None,
        };
        if let Some(binding) = binding {
            let mut names = BTreeSet::new();
            identifiers(binding, self.text, &mut names);
            self.analysis
                .scopes
                .get_mut(&scope)
                .unwrap()
                .blocked
                .extend(names);
        }
        if matches!(node.kind(), "call" | "call_expression") {
            let mut callee = node.child_by_field_name("function").or_else(|| {
                (self.lang == "swift")
                    .then(|| node.named_child(0))
                    .flatten()
            });
            if callee.is_some_and(|n| n.kind() == "generic_function") {
                callee = callee.and_then(|n| n.child_by_field_name("function"));
            }
            if let Some(callee) = callee {
                let name = source(callee, self.text).to_owned();
                let direct = (matches!(callee.kind(), "identifier" | "simple_identifier")
                    || (self.lang == "rust" && callee.kind() == "scoped_identifier")
                    || (matches!(self.lang, "javascript" | "typescript")
                        && callee.kind() == "member_expression"
                        && callee
                            .child_by_field_name("object")
                            .is_some_and(|n| n.kind() == "identifier")
                        && callee
                            .child_by_field_name("property")
                            .is_some_and(|n| n.kind() == "property_identifier")))
                    && node.child_by_field_name("optional_chain").is_none()
                    && !anonymous_ancestor(node);
                self.reference(node, &scope, name.clone(), "calls", direct);
                if matches!(self.lang, "javascript" | "typescript")
                    && matches!(name.as_str(), "require" | "import")
                {
                    if let Some(arg) = node
                        .child_by_field_name("arguments")
                        .and_then(|n| n.named_child(0))
                        .filter(|n| n.kind() == "string")
                    {
                        self.reference(
                            node,
                            &scope,
                            unquote(source(arg, self.text)),
                            "imports",
                            false,
                        );
                    }
                }
            }
        }
        if node.kind() == "macro_invocation" {
            let name = field(node, "macro", self.text)
                .unwrap_or_else(|| source(node, self.text).split('!').next().unwrap_or("macro"));
            self.reference(node, &scope, format!("{}!", name), "calls", false);
        }
        self.imports(node, &scope);
        for child in children(node) {
            self.walk(child, &scope, &qname, depth + 1);
        }
    }
    fn imports(&mut self, node: Node, scope: &str) {
        if self.lang == "python" {
            if node.kind() == "import_statement" {
                for child in children(node) {
                    let module =
                        field(child, "name", self.text).unwrap_or_else(|| source(child, self.text));
                    let alias = field(child, "alias", self.text)
                        .unwrap_or_else(|| module.split('.').next().unwrap_or(module));
                    self.analysis
                        .scopes
                        .get_mut(scope)
                        .unwrap()
                        .blocked
                        .insert(alias.to_owned());
                    self.reference(node, scope, module.to_owned(), "imports", false);
                }
            } else if node.kind() == "import_from_statement" {
                let module = field(node, "module_name", self.text)
                    .unwrap_or("")
                    .to_owned();
                self.reference(node, scope, module.clone(), "imports", false);
                let mut cursor = node.walk();
                for child in node.children_by_field_name("name", &mut cursor) {
                    let member =
                        field(child, "name", self.text).unwrap_or_else(|| source(child, self.text));
                    let alias = field(child, "alias", self.text).unwrap_or(member);
                    self.analysis.imports.push(ImportBinding {
                        scope: scope.to_owned(),
                        alias: alias.to_owned(),
                        module: module.clone(),
                        member: member.to_owned(),
                    });
                }
            }
        } else if matches!(self.lang, "javascript" | "typescript")
            && matches!(node.kind(), "import_statement" | "export_statement")
        {
            if let Some(module) = field(node, "source", self.text) {
                let module = unquote(module);
                self.reference(node, scope, module.clone(), "imports", false);
                if node.kind() == "import_statement" {
                    self.js_bindings(node, scope, &module);
                }
            }
        } else if self.lang == "rust" && node.kind() == "use_declaration" {
            if let Some(argument) = node.child_by_field_name("argument") {
                let mut bindings = Vec::new();
                rust_use_bindings(argument, self.text, "", &mut bindings);
                if bindings.is_empty() {
                    self.reference(
                        node,
                        scope,
                        source(argument, self.text).to_owned(),
                        "imports",
                        false,
                    );
                }
                for (module, alias) in bindings {
                    self.reference(node, scope, module.clone(), "imports", false);
                    self.analysis.imports.push(ImportBinding {
                        scope: scope.to_owned(),
                        alias,
                        module,
                        member: String::new(),
                    });
                }
            }
        } else if self.lang == "rust"
            && node.kind() == "mod_item"
            && node.child_by_field_name("body").is_none()
        {
            if let Some(name) = field(node, "name", self.text) {
                self.reference(node, scope, format!("mod {}", name), "imports", false);
            }
        } else if self.lang == "swift" && node.kind() == "import_declaration" {
            let text = source(node, self.text);
            self.reference(
                node,
                scope,
                text.trim().trim_start_matches("import ").to_owned(),
                "imports",
                false,
            );
        }
    }
    fn commonjs(&mut self, node: Node, scope: &str) -> bool {
        if node.kind() == "variable_declarator" {
            if let (Some(name), Some(value)) = (
                node.child_by_field_name("name"),
                node.child_by_field_name("value"),
            ) {
                if value.kind() == "call_expression"
                    && field(value, "function", self.text) == Some("require")
                {
                    if let Some(arg) = value
                        .child_by_field_name("arguments")
                        .and_then(|n| n.named_child(0))
                        .filter(|n| n.kind() == "string")
                    {
                        let module = unquote(source(arg, self.text));
                        let mut bindings = Vec::new();
                        if name.kind() == "identifier" {
                            bindings.push((
                                source(name, self.text).to_owned(),
                                "__commonjs__".to_owned(),
                            ));
                        }
                        if name.kind() == "object_pattern" {
                            for part in children(name) {
                                if part.kind() == "shorthand_property_identifier_pattern" {
                                    let n = source(part, self.text);
                                    bindings.push((n.to_owned(), format!("cjs:{}", n)));
                                }
                                if part.kind() == "pair_pattern" {
                                    if let (Some(key), Some(value)) = (
                                        part.child_by_field_name("key"),
                                        part.child_by_field_name("value"),
                                    ) {
                                        if value.kind() == "identifier"
                                            && key.kind() == "property_identifier"
                                        {
                                            bindings.push((
                                                source(value, self.text).to_owned(),
                                                format!("cjs:{}", source(key, self.text)),
                                            ));
                                        }
                                    }
                                }
                            }
                        }
                        if !bindings.is_empty() {
                            for (alias, member) in bindings {
                                self.analysis.imports.push(ImportBinding {
                                    scope: scope.to_owned(),
                                    alias,
                                    module: module.clone(),
                                    member,
                                });
                            }
                            return true;
                        }
                    }
                }
            }
        }
        // Conditional/computed exports are intentionally not treated as bindings.
        if node.kind() == "assignment_expression"
            && node
                .parent()
                .and_then(|n| n.parent())
                .is_some_and(|n| n.kind() == "program")
        {
            if let (Some(left), Some(right)) = (
                field(node, "left", self.text),
                node.child_by_field_name("right"),
            ) {
                if left == "module.exports" {
                    self.analysis.exports.clear();
                    if right.kind() == "identifier" {
                        self.analysis
                            .exports
                            .insert("default".into(), source(right, self.text).to_owned());
                    } else if matches!(
                        right.kind(),
                        "function_expression" | "arrow_function" | "generator_function"
                    ) {
                        self.analysis
                            .exports
                            .insert("default".into(), "default".into());
                    }
                    if right.kind() == "object" {
                        for part in children(right) {
                            if part.kind() == "shorthand_property_identifier" {
                                let n = source(part, self.text).to_owned();
                                self.analysis.exports.insert(n.clone(), n);
                            }
                            if part.kind() == "pair" {
                                if let (Some(key), Some(value)) = (
                                    part.child_by_field_name("key"),
                                    part.child_by_field_name("value"),
                                ) {
                                    if value.kind() == "identifier"
                                        && key.kind() == "property_identifier"
                                    {
                                        self.analysis.exports.insert(
                                            source(key, self.text).to_owned(),
                                            source(value, self.text).to_owned(),
                                        );
                                    }
                                }
                            }
                        }
                    }
                } else if let Some(key) = left
                    .strip_prefix("exports.")
                    .or_else(|| left.strip_prefix("module.exports."))
                {
                    if !key.contains('.') {
                        if right.kind() == "identifier" {
                            self.analysis
                                .exports
                                .insert(key.to_owned(), source(right, self.text).to_owned());
                        } else if matches!(
                            right.kind(),
                            "function_expression" | "arrow_function" | "generator_function"
                        ) {
                            self.analysis.exports.insert(key.to_owned(), key.to_owned());
                        } else {
                            self.analysis.exports.remove(key);
                        }
                    }
                }
            }
        }
        false
    }
    fn js_bindings(&mut self, node: Node, scope: &str, module: &str) {
        if node.kind() == "import_specifier" {
            if let Some(member) = field(node, "name", self.text) {
                let alias = field(node, "alias", self.text).unwrap_or(member);
                self.analysis.imports.push(ImportBinding {
                    scope: scope.to_owned(),
                    alias: alias.to_owned(),
                    module: module.to_owned(),
                    member: member.to_owned(),
                });
            }
            return;
        }
        for child in children(node) {
            self.js_bindings(child, scope, module);
        }
    }
}
fn rust_use_bindings(node: Node, text: &[u8], prefix: &str, out: &mut Vec<(String, String)>) {
    let join = |s: &str| {
        if prefix.is_empty() {
            s.to_owned()
        } else {
            format!("{}::{}", prefix, s)
        }
    };
    match node.kind() {
        "use_as_clause" => {
            if let (Some(path), Some(alias)) =
                (field(node, "path", text), field(node, "alias", text))
            {
                out.push((join(path), alias.to_owned()));
            }
        }
        "scoped_use_list" => {
            if let Some(path) = field(node, "path", text) {
                if let Some(list) = node.child_by_field_name("list") {
                    rust_use_bindings(list, text, &join(path), out);
                }
            }
        }
        "use_list" => {
            for child in children(node) {
                rust_use_bindings(child, text, prefix, out);
            }
        }
        "identifier" | "scoped_identifier" | "crate" | "self" | "super" => {
            let path = source(node, text);
            let full = if path == "self" && !prefix.is_empty() {
                prefix.to_owned()
            } else {
                join(path)
            };
            if let Some(alias) = full.rsplit("::").next() {
                out.push((full.clone(), alias.to_owned()));
            }
        }
        _ => {}
    }
}
fn anonymous_ancestor(mut node: Node) -> bool {
    while let Some(parent) = node.parent() {
        if matches!(
            parent.kind(),
            "lambda" | "lambda_literal" | "closure_expression"
        ) {
            return true;
        }
        if matches!(
            parent.kind(),
            "arrow_function" | "function_expression" | "generator_function"
        ) && parent
            .parent()
            .is_none_or(|p| p.kind() != "variable_declarator")
        {
            return true;
        }
        node = parent;
    }
    false
}
fn unquote(s: &str) -> String {
    s.trim_matches(['\'', '"']).to_owned()
}
fn parse(path: &str, lang: &str, language: Language, text: &[u8]) -> Result<Analysis> {
    let mut parser = Parser::new();
    parser.set_language(&language)?;
    let tree = parser
        .parse(text, None)
        .context("Tree-sitter returned no syntax tree")?;
    let file_id = format!("file:{}", path);
    let mut extractor = Extractor {
        path,
        lang,
        text,
        analysis: Analysis {
            definitions: vec![],
            references: vec![],
            scopes: BTreeMap::from([(
                file_id.clone(),
                Scope {
                    parent: None,
                    kind: "file".into(),
                    blocked: BTreeSet::new(),
                },
            )]),
            imports: vec![],
            diagnostics: vec![],
            exports: BTreeMap::new(),
        },
    };
    if tree.root_node().has_error() {
        extractor.analysis.diagnostics.push(Diagnostic{file:path.to_owned(),message:"Syntax errors: recovered definitions are indexed; calls in this file remain unresolved".into()});
    }
    extractor.walk(tree.root_node(), &file_id, "", 0);
    for definition in &extractor.analysis.definitions {
        if definition.scope == file_id && definition.exported {
            extractor
                .analysis
                .exports
                .entry(definition.symbol.name.clone())
                .or_insert_with(|| definition.symbol.name.clone());
        }
    }
    if tree.root_node().has_error() {
        for r in &mut extractor.analysis.references {
            r.direct = false;
        }
    }
    Ok(extractor.analysis)
}

fn normalized_relative(base: &Path, rel: &str) -> Option<String> {
    let mut parts: Vec<String> = base
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => s.to_str().map(str::to_owned),
            _ => None,
        })
        .collect();
    for c in Path::new(rel).components() {
        match c {
            Component::Normal(s) => parts.push(s.to_str()?.to_owned()),
            Component::CurDir => {}
            Component::ParentDir => {
                parts.pop()?;
            }
            _ => return None,
        }
    }
    Some(parts.join("/"))
}
fn imported_file(
    path: &str,
    module: &str,
    lang: &str,
    files: &BTreeMap<String, FileRecord>,
) -> Option<String> {
    let parent = Path::new(path).parent().unwrap_or(Path::new(""));
    let mut candidates = Vec::new();
    if matches!(lang, "javascript" | "typescript") && module.starts_with('.') {
        let base = normalized_relative(parent, module)?;
        candidates.push(base.clone());
        for ext in ["ts", "tsx", "js", "jsx", "mts", "cts", "mjs", "cjs"] {
            candidates.push(format!("{}.{}", base, ext));
            candidates.push(format!("{}/index.{}", base, ext));
        }
        // TypeScript often writes .js in source imports for emitted modules.
        if base.ends_with(".js") {
            candidates.push(format!("{}.ts", base.trim_end_matches(".js")));
        }
    } else if lang == "python" && module.starts_with('.') {
        let count = module.chars().take_while(|c| *c == '.').count();
        let mut root = parent.to_path_buf();
        for _ in 1..count {
            if !root.pop() {
                return None;
            }
        }
        let base = normalized_relative(&root, &module[count..].replace('.', "/"))?;
        candidates.extend([format!("{}.py", base), format!("{}/__init__.py", base)]);
    } else if lang == "rust" && module.starts_with("mod ") {
        let name = &module[4..];
        let base = if matches!(
            Path::new(path).file_name()?.to_str()?,
            "lib.rs" | "main.rs" | "mod.rs"
        ) {
            parent.to_path_buf()
        } else {
            parent.join(Path::new(path).file_stem()?)
        };
        let stem = normalized_relative(&base, name)?;
        candidates.extend([format!("{}.rs", stem), format!("{}/mod.rs", stem)]);
    }
    // Ambiguous extension resolution remains unresolved, rather than guessing a config.
    let found: BTreeSet<_> = candidates
        .into_iter()
        .filter(|s| files.contains_key(s))
        .collect();
    if found.len() == 1 {
        found.into_iter().next()
    } else {
        None
    }
}
fn rust_context(
    path: &str,
    scope: &str,
    analyses: &BTreeMap<String, Analysis>,
) -> (String, String) {
    let analysis = &analyses[path];
    let mut current = scope;
    loop {
        let info = &analysis.scopes[current];
        if matches!(info.kind.as_str(), "module" | "file") {
            return (path.to_owned(), current.to_owned());
        }
        match &info.parent {
            Some(parent) => current = parent,
            None => return (path.to_owned(), format!("file:{}", path)),
        }
    }
}
fn rust_parent(
    context: &(String, String),
    analyses: &BTreeMap<String, Analysis>,
    files: &BTreeMap<String, FileRecord>,
) -> Option<(String, String)> {
    let analysis = &analyses[&context.0];
    let info = &analysis.scopes[&context.1];
    if let Some(parent) = &info.parent {
        return Some(rust_context(&context.0, parent, analyses));
    }
    let mut candidates = Vec::new();
    for (path, a) in analyses {
        if files[path].language != "rust" {
            continue;
        }
        for d in &a.definitions {
            if d.symbol.kind == "module"
                && a.references.iter().any(|r| {
                    r.reference.source == d.symbol.id
                        && r.reference.name == format!("mod {}", d.symbol.name)
                })
                && imported_file(path, &format!("mod {}", d.symbol.name), "rust", files).as_ref()
                    == Some(&context.0)
            {
                candidates.push(rust_context(path, &d.scope, analyses));
            }
        }
    }
    candidates.sort();
    candidates.dedup();
    if candidates.len() == 1 {
        candidates.pop()
    } else {
        None
    }
}
fn rust_target(
    path: &str,
    scope: &str,
    name: &str,
    analyses: &BTreeMap<String, Analysis>,
    files: &BTreeMap<String, FileRecord>,
    call: bool,
) -> Option<String> {
    let mut parts = name.split("::").peekable();
    let first = parts.peek().copied()?;
    if !matches!(first, "crate" | "self" | "super") {
        return None;
    }
    let origin = rust_context(path, scope, analyses);
    let mut context = origin.clone();
    if first == "crate" {
        parts.next();
        let mut seen = BTreeSet::new();
        while let Some(parent) = rust_parent(&context, analyses, files) {
            if !seen.insert(context.clone()) {
                return None;
            }
            context = parent;
        }
        if !matches!(
            Path::new(&context.0).file_name()?.to_str()?,
            "lib.rs" | "main.rs"
        ) {
            return None;
        }
    } else if first == "self" {
        parts.next();
    }
    while parts.peek() == Some(&"super") {
        parts.next();
        context = rust_parent(&context, analyses, files)?;
    }
    while let Some(part) = parts.next() {
        let a = &analyses[&context.0];
        let defs: Vec<_> = a
            .definitions
            .iter()
            .filter(|d| d.scope == context.1 && d.symbol.name == part)
            .collect();
        if defs.len() != 1 {
            return None;
        }
        let d = defs[0];
        if parts.peek().is_none() {
            if call && !is_function(&d.symbol.kind) {
                return None;
            }
            if context != origin && !d.exported && d.symbol.kind != "module" {
                return None;
            }
            if a.scopes[&context.1].blocked.contains(part) {
                return None;
            }
            return Some(d.symbol.id.clone());
        }
        if d.symbol.kind != "module" {
            return None;
        }
        if a.references.iter().any(|r| {
            r.reference.source == d.symbol.id && r.reference.name == format!("mod {}", part)
        }) {
            let file = imported_file(&context.0, &format!("mod {}", part), "rust", files)?;
            context = (file.clone(), format!("file:{}", file));
        } else {
            context.1 = d.symbol.id.clone();
        }
    }
    None
}
fn name_shadowed(analysis: &Analysis, scope: &str, name: &str) -> bool {
    let mut current = Some(scope);
    while let Some(id) = current {
        let info = &analysis.scopes[id];
        if info.blocked.contains(name)
            || analysis
                .definitions
                .iter()
                .any(|d| d.scope == id && d.symbol.name == name)
            || analysis
                .imports
                .iter()
                .any(|i| i.scope == id && i.alias == name)
        {
            return true;
        }
        current = info.parent.as_deref();
    }
    false
}
fn imported_symbol(
    path: &str,
    binding: &ImportBinding,
    member: Option<&str>,
    analyses: &BTreeMap<String, Analysis>,
    files: &BTreeMap<String, FileRecord>,
) -> Option<String> {
    let lang = &files[path].language;
    if lang == "rust" {
        return rust_target(path, &binding.scope, &binding.module, analyses, files, true);
    }
    let is_cjs = binding.member == "__commonjs__" || binding.member.starts_with("cjs:");
    if is_cjs && name_shadowed(&analyses[path], &binding.scope, "require") {
        return None;
    }
    let exported_name = if binding.member == "__commonjs__" {
        member.unwrap_or("default")
    } else if member.is_some() {
        return None;
    } else {
        binding
            .member
            .strip_prefix("cjs:")
            .unwrap_or(&binding.member)
    };
    let target_file = imported_file(path, &binding.module, lang, files)?;
    let target = &analyses[&target_file];
    let scope = format!("file:{}", target_file);
    let local_name = target.exports.get(exported_name)?;
    let matches: Vec<_> = target
        .definitions
        .iter()
        .filter(|d| d.scope == scope && d.symbol.name == *local_name && is_function(&d.symbol.kind))
        .collect();
    if matches.len() == 1 && !target.scopes[&scope].blocked.contains(local_name) {
        Some(matches[0].symbol.id.clone())
    } else {
        None
    }
}
fn resolve(
    analyses: &BTreeMap<String, Analysis>,
    files: &BTreeMap<String, FileRecord>,
) -> Vec<Reference> {
    let mut result = Vec::new();
    for (path, analysis) in analyses {
        let lang = &files[path].language;
        for pending in &analysis.references {
            let mut reference = pending.reference.clone();
            if reference.kind == "imports" {
                reference.target = imported_file(path, &reference.name, lang, files)
                    .map(|p| format!("file:{}", p));
                if lang == "rust" && reference.target.is_none() {
                    reference.target = rust_target(
                        path,
                        &pending.scope,
                        &reference.name,
                        analyses,
                        files,
                        false,
                    );
                }
            } else if pending.direct {
                if lang == "rust" && reference.name.contains("::") {
                    reference.target =
                        rust_target(path, &pending.scope, &reference.name, analyses, files, true);
                } else {
                    let (lookup_name, member) =
                        if matches!(lang.as_str(), "javascript" | "typescript") {
                            reference
                                .name
                                .split_once('.')
                                .map_or((reference.name.as_str(), None), |(base, member)| {
                                    (base, Some(member))
                                })
                        } else {
                            (reference.name.as_str(), None)
                        };
                    let mut scope = Some(pending.scope.as_str());
                    while let Some(current) = scope {
                        let info = &analysis.scopes[current];
                        if info.blocked.contains(lookup_name) {
                            break;
                        }
                        let definitions: Vec<_> = analysis
                            .definitions
                            .iter()
                            .filter(|d| d.scope == current && d.symbol.name == lookup_name)
                            .collect();
                        if !definitions.is_empty() {
                            let also_imported = analysis
                                .imports
                                .iter()
                                .any(|i| i.scope == current && i.alias == lookup_name);
                            if member.is_none()
                                && !also_imported
                                && definitions.len() == 1
                                && is_function(&definitions[0].symbol.kind)
                            {
                                reference.target = Some(definitions[0].symbol.id.clone());
                            }
                            break;
                        }
                        let imports: Vec<_> = analysis
                            .imports
                            .iter()
                            .filter(|i| i.scope == current && i.alias == lookup_name)
                            .collect();
                        if !imports.is_empty() {
                            if imports.len() == 1 {
                                reference.target =
                                    imported_symbol(path, imports[0], member, analyses, files);
                            }
                            break;
                        }
                        scope = info.parent.as_deref();
                        while let Some(id) = scope {
                            let outer = &analysis.scopes[id];
                            if matches!(
                                outer.kind.as_str(),
                                "class"
                                    | "struct"
                                    | "enum"
                                    | "trait"
                                    | "protocol"
                                    | "interface"
                                    | "impl"
                                    | "extension"
                                    | "actor"
                            ) {
                                if lang == "swift"
                                    && analysis
                                        .definitions
                                        .iter()
                                        .any(|d| d.scope == id && d.symbol.name == lookup_name)
                                {
                                    scope = None;
                                    break;
                                }
                                scope = outer.parent.as_deref();
                            } else {
                                break;
                            }
                        }
                    }
                }
            }
            if reference.target.is_some() {
                reference.resolution = "resolved".into();
            }
            result.push(reference);
        }
    }
    result.sort_by(|a, b| {
        (&a.file, a.line, &a.source, &a.kind, &a.name)
            .cmp(&(&b.file, b.line, &b.source, &b.kind, &b.name))
    });
    result
}

fn git(root: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let result = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .output()
        .context("could not start git")?;
    if !result.status.success() {
        bail!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&result.stderr).trim()
        );
    }
    Ok(result.stdout)
}
fn excluded(path: &str) -> bool {
    path.split('/').any(|p| {
        matches!(
            p,
            ".git"
                | "node_modules"
                | "target"
                | "vendor"
                | "third_party"
                | "dist"
                | "build"
                | ".build"
                | ".venv"
                | "venv"
                | "__pycache__"
                | ".byori"
        )
    })
}
fn no_symlinks(root: &Path, relative: &Path) -> bool {
    let mut p = root.to_path_buf();
    for part in relative.components() {
        match part {
            Component::Normal(s) => p.push(s),
            _ => return false,
        };
        if fs::symlink_metadata(&p).is_ok_and(|m| m.file_type().is_symlink()) {
            return false;
        }
    }
    true
}
/// Scan one checkout; cache is rebuildable and never serves data without a content hash match.
pub fn index(root: &Path, cache_dir: Option<&Path>) -> Result<Snapshot> {
    let requested = fs::canonicalize(root).context("root does not exist")?;
    let git_root = git(&requested, &["rev-parse", "--show-toplevel"])?;
    let root = fs::canonicalize(String::from_utf8(git_root)?.trim()).context("invalid Git root")?;
    let root_text = root
        .to_str()
        .context("checkout path is not UTF-8")?
        .to_owned();
    let checkout_id = digest(root_text.as_bytes())[..16].to_owned();
    let revision = git(&root, &["rev-parse", "--verify", "HEAD"])
        .ok()
        .and_then(|v| String::from_utf8(v).ok())
        .unwrap_or_default()
        .trim()
        .to_owned();
    let paths = git(
        &root,
        &[
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
    )?;
    let mut files = BTreeMap::new();
    let mut analyses = BTreeMap::new();
    let mut diagnostics = Vec::new();
    let mut parsed_files = 0;
    let mut cached_files = 0;
    let cache_root = cache_dir.map(|p| p.join(&checkout_id));
    if let Some(cache) = &cache_root {
        fs::create_dir_all(cache).context("could not create cache directory")?;
        if fs::symlink_metadata(cache)?.file_type().is_symlink() {
            bail!("checkout cache directory must not be a symbolic link");
        }
        // Only harden the checkout-owned directory, never chmod the caller's
        // arbitrary cache root. Older caches may have inherited a loose umask.
        #[cfg(unix)]
        fs::set_permissions(cache, fs::Permissions::from_mode(0o700))?;
    }
    let mut unique = BTreeSet::new();
    for raw in paths.split(|b| *b == 0).filter(|p| !p.is_empty()) {
        let path = match std::str::from_utf8(raw) {
            Ok(p) => p,
            Err(_) => {
                diagnostics.push(Diagnostic {
                    file: String::from_utf8_lossy(raw).into_owned(),
                    message: "Non-UTF-8 path was skipped".into(),
                });
                continue;
            }
        };
        if !unique.insert(path.to_owned()) || excluded(path) {
            continue;
        }
        let Some((lang, grammar)) = language(path) else {
            continue;
        };
        let full = root.join(path);
        if !no_symlinks(&root, Path::new(path)) {
            diagnostics.push(Diagnostic {
                file: path.to_owned(),
                message: "Symbolic link was skipped".into(),
            });
            continue;
        }
        let metadata = match fs::metadata(&full) {
            Ok(m) => m,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e).context(format!("cannot stat {}", path)),
        };
        if !metadata.is_file() {
            continue;
        }
        if metadata.len() > MAX_FILE_BYTES {
            diagnostics.push(Diagnostic {
                file: path.to_owned(),
                message: format!("File exceeds {} byte analysis limit", MAX_FILE_BYTES),
            });
            continue;
        }
        let text = fs::read(&full).with_context(|| format!("cannot read {}", path))?;
        if std::str::from_utf8(&text).is_err() {
            diagnostics.push(Diagnostic {
                file: path.to_owned(),
                message: "Non-UTF-8 source was skipped".into(),
            });
            continue;
        }
        let hash = digest(&text);
        let cache_path = cache_root
            .as_ref()
            .map(|p| p.join(format!("{}.json", digest(path))));
        let cached = cache_path
            .as_ref()
            .and_then(|p| fs::read(p).ok())
            .and_then(|b| serde_json::from_slice::<Cache>(&b).ok())
            .filter(|c| {
                c.version == ANALYSIS_VERSION
                    && c.path == path
                    && c.language == lang
                    && c.hash == hash
            });
        let analysis = if let Some(cache) = cached {
            cached_files += 1;
            cache.analysis
        } else {
            parsed_files += 1;
            let analysis = parse(path, lang, grammar, &text)?;
            if let Some(cache) = cache_path {
                let entry = Cache {
                    version: ANALYSIS_VERSION.into(),
                    path: path.into(),
                    language: lang.into(),
                    hash: hash.clone(),
                    analysis: analysis.clone(),
                };
                let nonce = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos();
                let temp = cache.with_extension(format!("{}.{nonce}.tmp", std::process::id()));
                let mut options = fs::OpenOptions::new();
                options.write(true).create_new(true);
                #[cfg(unix)]
                options.mode(0o600);
                let mut output = options.open(&temp)?;
                output.write_all(&serde_json::to_vec(&entry)?)?;
                drop(output);
                fs::rename(temp, cache)?;
            }
            analysis
        };
        diagnostics.extend(analysis.diagnostics.clone());
        files.insert(
            path.to_owned(),
            FileRecord {
                id: format!("file:{}", path),
                path: path.to_owned(),
                language: lang.into(),
                hash,
            },
        );
        analyses.insert(path.to_owned(), analysis);
    }
    let references = resolve(&analyses, &files);
    let symbols: Vec<_> = analyses
        .values()
        .flat_map(|a| a.definitions.iter().map(|d| d.symbol.clone()))
        .collect();
    diagnostics.sort_by(|a, b| (&a.file, &a.message).cmp(&(&b.file, &b.message)));
    let files: Vec<_> = files.into_values().collect();
    // Output content, including parser diagnostics, participates in the immutable snapshot identity.
    let snapshot_id = digest(serde_json::to_vec(&(
        ANALYSIS_VERSION,
        &checkout_id,
        &revision,
        &files,
        &symbols,
        &references,
        &diagnostics,
    ))?);
    let resolved_references = references.iter().filter(|r| r.target.is_some()).count();
    let stats = Stats {
        files: files.len(),
        parsed_files,
        cached_files,
        symbols: symbols.len(),
        resolved_references,
        unresolved_references: references.len() - resolved_references,
    };
    Ok(Snapshot {
        format_version: 1,
        root: root_text,
        checkout_id,
        revision,
        snapshot_id,
        files,
        symbols,
        references,
        diagnostics,
        stats,
    })
}
