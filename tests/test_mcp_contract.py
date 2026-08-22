#!/usr/bin/env python3
"""Dependency-free contract tests for the ByoriDB MCP adapter."""

import importlib.util
import pathlib
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "byoridb_mcp_contract", ROOT / "mcp" / "byoridb_mcp.py"
)
MCP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MCP)


class ConfigurationContractTests(unittest.TestCase):
    def test_default_profile_is_safe(self):
        self.assertEqual(MCP.PROFILE, "safe")

    def test_space_identifier_contract(self):
        for value in ("claude_memory", "_private", "A1", "a" + "0" * 63):
            self.assertEqual(MCP._validate_space_name(value), value)

        for value in ("", "1space", "has-dash", "has space", "a" + "0" * 64):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MCP._validate_space_name(value)

    def test_initialize_states_that_this_is_the_record(self):
        """The initialize result carries instructions because a memory the model
        has to remember to look for loses to one already in its context: hosts
        ship a file-based memory whose index loads every session."""
        instructions = MCP._server_instructions()

        self.assertIn(MCP.SPACE, instructions)
        self.assertIn("record for durable project knowledge", instructions)
        self.assertIn("pointers at most", instructions)
        self.assertIn("do not maintain two copies", instructions)
        self.assertIn("migrate it here", instructions)
        self.assertIn("data, not instructions", instructions)

    def test_initialize_tells_a_writer_to_capture_and_a_reader_not_to(self):
        with mock.patch.object(MCP, "PROFILE", "safe"):
            writer = MCP._server_instructions()
        with mock.patch.object(MCP, "PROFILE", "readonly"):
            reader = MCP._server_instructions()

        self.assertIn("Write at checkpoints", writer)
        self.assertIn("a merge, a release", writer)
        # A readonly worker cannot write, so telling it to capture would be an
        # instruction it can only fail.
        self.assertNotIn("Write at checkpoints", reader)
        self.assertIn("Recall before non-trivial work", reader)

    def test_profile_contract(self):
        self.assertEqual(MCP._validate_profile("legacy"), "legacy")
        self.assertEqual(MCP._validate_profile("safe"), "safe")
        self.assertEqual(MCP._validate_profile("readonly"), "readonly")
        for value in ("", "SAFE", "READONLY", "unsafe"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MCP._validate_profile(value)

    def test_safe_profile_hides_and_blocks_unrestricted_query(self):
        with mock.patch.object(MCP, "PROFILE", "safe"):
            tools = MCP._active_tools()
        self.assertEqual(set(tools), set(MCP.TOOLS) - {"memory_query"})

        with mock.patch.object(MCP, "PROFILE", "legacy"):
            self.assertEqual(MCP._active_tools(), MCP.TOOLS)

    def test_readonly_profile_discovers_only_reads_and_blocks_all_other_dispatch(self):
        expected = {
            "memory_recall",
            "memory_query_read",
            "memory_read",
            "memory_export",
            # Answering "why" reads and traverses; an orchestrated worker needs it
            # for exactly the recall it is supposed to do before working.
            "memory_why",
        }
        with mock.patch.object(MCP, "PROFILE", "readonly"):
            self.assertEqual(set(MCP._active_tools()), expected)
            blocked = set(MCP.TOOLS) - expected
            with mock.patch.object(MCP, "_send") as send:
                for request_id, name in enumerate(sorted(blocked), start=1):
                    with self.subTest(name=name):
                        MCP.handle(
                            {
                                "jsonrpc": "2.0",
                                "id": request_id,
                                "method": "tools/call",
                                "params": {"name": name, "arguments": {}},
                            }
                        )
                        send.assert_called_once_with(
                            {
                                "jsonrpc": "2.0",
                                "id": request_id,
                                "error": {
                                    "code": -32602,
                                    "message": f"unknown tool: {name}",
                                },
                            }
                        )
                        send.reset_mock()

    def test_readonly_profile_checks_schema_without_bootstrap_or_migration(self):
        with (
            mock.patch.object(MCP, "PROFILE", "readonly"),
            mock.patch.object(MCP, "_login") as login,
            mock.patch.object(MCP, "_raw_query") as raw_query,
            mock.patch.object(MCP, "_schema_version", return_value=MCP.SCHEMA_VERSION),
            mock.patch.object(MCP, "_migrate") as migrate,
            mock.patch.object(MCP, "log"),
            mock.patch.dict(MCP._session, {"id": None, "ready": False}, clear=True),
        ):
            MCP._ensure_ready()

        login.assert_called_once_with()
        raw_query.assert_called_once_with(f"USE {MCP.SPACE}")
        migrate.assert_not_called()

    def test_readonly_profile_requires_coordinator_migration(self):
        with (
            mock.patch.object(MCP, "PROFILE", "readonly"),
            mock.patch.object(MCP, "_login"),
            mock.patch.object(MCP, "_raw_query"),
            mock.patch.object(MCP, "_schema_version", return_value=1),
            mock.patch.object(MCP, "_migrate") as migrate,
            mock.patch.dict(MCP._session, {"id": None, "ready": False}, clear=True),
        ):
            with self.assertRaisesRegex(RuntimeError, "migrate it with a writer profile"):
                MCP._ensure_ready()

        migrate.assert_not_called()


class ReadOnlyQueryContractTests(unittest.TestCase):
    def test_read_only_statements_are_allowed(self):
        statements = (
            "MATCH (n:note) RETURN n.note.name",
            "FETCH PROP ON note 1",
            "GO FROM 1 OVER rel",
            "LOOKUP ON note YIELD note.name",
            "SHOW TAGS",
            "WHY 1 -> 2 OVER relates_to",
        )
        for statement in statements:
            with self.subTest(statement=statement):
                self.assertEqual(MCP._validate_read_only_query(statement), statement)

    def test_mutations_comments_pipelines_and_multiple_statements_are_rejected(self):
        statements = (
            "INSERT VERTEX note(name) VALUES 1:('x')",
            "MATCH (n) DELETE VERTEX 1",
            "USE another_space",
            "MATCH (n) RETURN n; SHOW TAGS",
            "MATCH (n) RETURN n | LIMIT 1",
            "MATCH (n) RETURN n -- comment",
            "MATCH (n) RETURN n // comment",
            "MATCH (n) RETURN n /* comment */",
            "MATCH (n) RETURN n # comment",
        )
        for statement in statements:
            with self.subTest(statement=statement), self.assertRaises(ValueError):
                MCP._validate_read_only_query(statement)

    def test_mutation_words_inside_string_literals_do_not_trigger(self):
        statements = (
            "MATCH (n:note) WHERE n.note.body == 'INSERT DELETE' RETURN n",
            "MATCH (n:note) WHERE n.note.body == 'https://example.com/a#b' RETURN n",
            "MATCH (n:note) WHERE n.note.body == 'a|b;x' RETURN n",
        )
        for statement in statements:
            with self.subTest(statement=statement):
                self.assertEqual(MCP._validate_read_only_query(statement), statement)


class NoteToolContractTests(unittest.TestCase):
    def test_note_tool_schemas_are_closed_and_bounded(self):
        remember = MCP.TOOLS["memory_remember"]["inputSchema"]
        recall = MCP.TOOLS["memory_recall"]["inputSchema"]
        self.assertFalse(remember["additionalProperties"])
        self.assertFalse(recall["additionalProperties"])
        self.assertEqual(
            remember["properties"]["body"]["maxLength"], MCP.MAX_BODY_LENGTH
        )
        self.assertEqual(
            remember["properties"]["relates_to"]["maxItems"], MCP.MAX_RELATES_TO
        )
        self.assertEqual(
            recall["properties"]["limit"]["maximum"], MCP.MAX_READ_LIMIT
        )

    def test_remember_rejects_invalid_or_oversized_inputs(self):
        with mock.patch.object(MCP, "_ensure_ready"):
            for args in (
                {"name": "fact", "body": ""},
                {"name": "fact", "body": "ok", "unexpected": True},
                {"name": "fact", "body": "ok", "relates_to": None},
                {"name": "fact", "body": "ok", "relates_to": False},
                {"name": "fact", "body": "ok", "relates_to": 0},
                {"name": "fact", "body": "ok", "relates_to": ""},
                {"name": "fact", "body": "ok", "relates_to": {}},
                {"name": "fact", "body": "ok", "relates_to": "not-an-array"},
                {
                    "name": "fact",
                    "body": "ok",
                    "relates_to": ["target"] * (MCP.MAX_RELATES_TO + 1),
                },
            ):
                with self.subTest(args=args), self.assertRaises(ValueError):
                    MCP.tool_remember(args)

    def test_recall_rejects_invalid_limit_and_extra_fields(self):
        with mock.patch.object(MCP, "_ensure_ready"):
            with self.assertRaises(ValueError):
                MCP.tool_recall({"limit": MCP.MAX_READ_LIMIT + 1})
            with self.assertRaises(ValueError):
                MCP.tool_recall({"limit": 1, "unexpected": True})


class EdgeReadContractTests(unittest.TestCase):
    """Reading a node's edges used to cost one round trip per relation type — nine
    — each re-evaluating the same seed filter, and each new type in the ontology
    added another. Engine 0.4.0 makes one statement enough, so what is pinned here
    is that it stays one, and that the rows are interpreted exactly as the loop
    interpreted them."""

    MIXED_ROWS = [
        {"src": 1, "dst": 2, "edge_type": "affects", "relation": None},
        {"src": 2, "dst": 3, "edge_type": "rel", "relation": "relates_to"},
        {"src": 3, "dst": 4, "edge_type": "rel", "relation": None},
        {"src": 4, "dst": 5, "edge_type": "about", "relation": None},
        {"src": 5, "dst": 6, "edge_type": "handmade", "relation": None},
    ]

    def _read(self, vids, rows=None, source_only=False):
        queries = []

        def fake_raw_query(ngql, read_only=False):
            queries.append(ngql)
            return {"results": self.MIXED_ROWS if rows is None else rows}

        with mock.patch.object(MCP, "_raw_query", fake_raw_query):
            return MCP._read_edge_records(vids, source_only=source_only), queries

    def test_one_round_trip_regardless_of_relation_count(self):
        _, queries = self._read(["1", "2"])

        self.assertEqual(len(queries), 1, "one query per edge read")
        self.assertGreater(
            len(MCP.TYPED_RELATIONS), 1,
            "the point of the assertion is that this count no longer matters",
        )

    def test_query_uses_untyped_match_type_accessor_and_set_membership(self):
        _, queries = self._read(["10", "20"])
        query = queries[0]

        self.assertIn("MATCH (a)-[e]->(b)", query, "an empty type list means every type")
        self.assertIn("type(e) AS edge_type", query)
        self.assertIn("e.rel.kind AS relation", query, "legacy rows carry kind, not a type")
        self.assertIn("id(a) IN [10, 20]", query)
        self.assertIn("id(b) IN [10, 20]", query)
        for relation in MCP.TYPED_RELATIONS:
            self.assertNotIn(f"[e:{relation}]", query, "no per-type query may remain")

    def test_typed_and_legacy_rows_keep_their_previous_shape(self):
        edges, _ = self._read(["1"])
        by_pair = {(e["source_vid"], e["target_vid"]): e for e in edges}

        self.assertEqual(
            by_pair[("1", "2")], 
            {"edge_type": "affects", "relation": "affects", "source_vid": "1", "target_vid": "2"},
            "a typed edge's relation is its type",
        )
        self.assertEqual(by_pair[("2", "3")]["relation"], "relates_to")
        self.assertEqual(by_pair[("2", "3")]["edge_type"], "rel")
        self.assertEqual(
            by_pair[("3", "4")]["relation"], "relates_to",
            "a legacy edge with no kind is the plain association the loop defaulted to",
        )

    def test_edge_types_outside_the_ontology_are_dropped(self):
        edges, _ = self._read(["1"])

        self.assertNotIn(
            "handmade", {edge["edge_type"] for edge in edges},
            "an untyped MATCH also returns edges Byori never created",
        )

    def test_duplicates_are_collapsed_and_order_is_stable(self):
        duplicated = self.MIXED_ROWS + self.MIXED_ROWS
        edges, _ = self._read(["1"], rows=duplicated)
        again, _ = self._read(["1"], rows=list(reversed(duplicated)))

        keys = [(e["edge_type"], e["relation"], e["source_vid"], e["target_vid"]) for e in edges]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(edges, again, "row order from the engine must not change the result")

    def test_source_only_filters_one_endpoint(self):
        _, queries = self._read(["7"], source_only=True)

        self.assertIn("id(a) IN [7]", queries[0])
        # `id(b) AS dst` stays in the projection; only the filter narrows.
        self.assertNotIn("id(b) IN", queries[0])

    def test_no_seeds_issues_no_query(self):
        edges, queries = self._read([])

        self.assertEqual(edges, [])
        self.assertEqual(queries, [], "an empty seed set must not reach the engine")


class StructuredToolContractTests(unittest.TestCase):
    def test_canonical_wiki_identity(self):
        for node_type in MCP.WIKI_TYPES:
            name = f"{node_type}:stable-name_1.0"
            self.assertEqual(MCP._validate_wiki_identity(node_type, name), (node_type, name))

        invalid = (
            ("decision", "bug:wrong-prefix"),
            ("module", "module:"),
            ("module", "module:has space"),
            ("unknown", "unknown:value"),
        )
        for node_type, name in invalid:
            with self.subTest(node_type=node_type, name=name), self.assertRaises(ValueError):
                MCP._validate_wiki_identity(node_type, name)

    def test_relation_matrix(self):
        allowed = (
            ("part_of", "module", "module"),
            ("affects", "decision", "module"),
            ("caused_by", "incident", "bug"),
            ("fixed_by", "bug", "task"),
            ("relates_to", "note", "decision"),
        )
        for relation, source, target in allowed:
            with self.subTest(relation=relation):
                MCP._validate_relation(relation, source, target)

        denied = (
            ("affects", "module", "decision"),
            ("part_of", "note", "module"),
            ("unknown", "module", "module"),
        )
        for relation, source, target in denied:
            with self.subTest(relation=relation), self.assertRaises(ValueError):
                MCP._validate_relation(relation, source, target)

    def test_size_and_limit_guards(self):
        with self.assertRaises(ValueError):
            MCP._require_string("x" * (MCP.MAX_BODY_LENGTH + 1), "body", MCP.MAX_BODY_LENGTH)
        with self.assertRaises(ValueError):
            MCP._bounded_int(0, "limit", 1, MCP.MAX_READ_LIMIT)
        with self.assertRaises(ValueError):
            MCP._bounded_int(True, "limit", 1, MCP.MAX_READ_LIMIT)

    def test_wiki_upsert_uses_server_side_63_bit_vid_and_string_response(self):
        statements = []
        name = "decision:server-side-vid"
        with (
            mock.patch.object(MCP, "_ensure_ready"),
            mock.patch.object(MCP, "_nodes_at_vid", return_value=[]),
            mock.patch.object(
                MCP,
                "_raw_query",
                side_effect=lambda query: statements.append(query) or {},
            ),
            mock.patch.object(MCP.time, "time", return_value=1_720_000_000.0),
        ):
            result = MCP.tool_wiki_upsert(
                {"type": "decision", "name": name, "body": "Use the safe surface."}
            )

        expected = (
            int.from_bytes(MCP.hashlib.sha1(name.encode()).digest()[:8], "big")
            & 0x7FFF_FFFF_FFFF_FFFF
        )
        self.assertEqual(result["vid"], str(expected))
        self.assertIsInstance(result["vid"], str)
        self.assertIn(f"VALUES {expected}:", statements[-1])

    def test_wiki_upsert_reuses_v020_legacy_vid(self):
        statements = []
        name = "decision:use-redb"
        legacy_vid = int(MCP.hashlib.sha1(name.encode()).hexdigest()[:15], 16)
        current_vid = MCP._vid(name)
        self.assertNotEqual(legacy_vid, current_vid)
        existing = {
            "vid": str(legacy_vid),
            "type": "decision",
            "name": name,
            "body": "old rationale",
            "state": "active",
            "ts": 1,
        }

        with (
            mock.patch.object(MCP, "_ensure_ready"),
            mock.patch.object(MCP, "_query_nodes", return_value=[existing]),
            mock.patch.object(MCP, "_nodes_at_vid", return_value=[existing]),
            mock.patch.object(
                MCP,
                "_raw_query",
                side_effect=lambda query: statements.append(query) or {},
            ),
        ):
            result = MCP.tool_wiki_upsert(
                {"type": "decision", "name": name, "body": "new rationale"}
            )

        self.assertEqual(result["vid"], str(legacy_vid))
        self.assertIn(f"VALUES {legacy_vid}:", statements[-1])
        self.assertNotIn(f"VALUES {current_vid}:", statements[-1])

    def test_wiki_upsert_preserves_omitted_lifecycle_fields(self):
        fixtures = (
            ("decision", "decision:preserve", {"state": "superseded"}, "superseded"),
            ("bug", "bug:preserve", {"state": "fixed"}, "fixed"),
            ("task", "task:preserve", {"state": "done"}, "done"),
            ("incident", "incident:preserve", {"resolved": True}, "true"),
        )
        for node_type, name, lifecycle, stored_value in fixtures:
            existing = {
                "vid": "123",
                "type": node_type,
                "name": name,
                "body": "old",
                "ts": 1,
                **lifecycle,
            }
            statements = []
            with (
                self.subTest(node_type=node_type),
                mock.patch.object(MCP, "_ensure_ready"),
                mock.patch.object(MCP, "_find_existing_node", return_value=existing),
                mock.patch.object(MCP, "_nodes_at_vid", return_value=[existing]),
                mock.patch.object(
                    MCP,
                    "_raw_query",
                    side_effect=lambda query: statements.append(query) or {},
                ),
            ):
                result = MCP.tool_wiki_upsert(
                    {"type": node_type, "name": name, "body": "new"}
                )

            self.assertEqual(
                result.get("state", result.get("resolved")),
                lifecycle.get("state", lifecycle.get("resolved")),
            )
            self.assertIn(f"'{stored_value}'", statements[-1])

    def test_exact_name_lookup_finds_arbitrary_existing_vid(self):
        name = "module:legacy-location"
        stored_vid = 12345
        queries = []
        payload = {
            "results": [
                {
                    "vid": stored_vid,
                    "name": name,
                    "body": "legacy module",
                    "ts": 1,
                }
            ]
        }
        with mock.patch.object(
            MCP,
            "_raw_query",
            side_effect=lambda query: queries.append(query) or payload,
        ):
            nodes = MCP._query_nodes("module", name=name, limit=2)

        self.assertEqual(nodes[0]["vid"], str(stored_vid))
        self.assertIn(f"n.module.name == '{name}'", queries[0])
        self.assertNotIn(f"id(n) == {MCP._vid(name)}", queries[0])

    def test_link_and_delete_use_existing_legacy_vid(self):
        decision_name = "decision:legacy-link"
        module_name = "module:legacy-link"
        task_name = "task:legacy-delete"
        nodes = {
            "decision": {
                "vid": "101",
                "type": "decision",
                "name": decision_name,
                "body": "decision",
                "state": "active",
                "ts": 1,
            },
            "module": {
                "vid": "202",
                "type": "module",
                "name": module_name,
                "body": "module",
                "ts": 1,
            },
            "task": {
                "vid": "303",
                "type": "task",
                "name": task_name,
                "body": "task",
                "state": "open",
                "ts": 1,
            },
        }
        statements = []

        def lookup(node_type, name=None, text=None, limit=20):
            node = nodes.get(node_type)
            return [node] if node and node["name"] == name else []

        with (
            mock.patch.object(MCP, "_ensure_ready"),
            mock.patch.object(MCP, "_query_nodes", side_effect=lookup),
            mock.patch.object(MCP, "_read_edge_records", return_value=[]),
            mock.patch.object(
                MCP,
                "_raw_query",
                side_effect=lambda query: statements.append(query) or {},
            ),
        ):
            linked = MCP.tool_link(
                {
                    "relation": "affects",
                    "source": {"type": "decision", "name": decision_name},
                    "target": {"type": "module", "name": module_name},
                }
            )
            deleted = MCP.tool_delete(
                {"type": "task", "name": task_name, "cascade": False}
            )

        self.assertEqual(linked["source"]["vid"], "101")
        self.assertEqual(linked["target"]["vid"], "202")
        self.assertTrue(any("VALUES 101->202" in query for query in statements))
        self.assertEqual(deleted["vid"], "303")
        self.assertIn("DELETE VERTEX 303", statements)

    def test_cascade_deletes_incoming_and_outgoing_edges_before_vertex(self):
        name = "task:cascade"
        node = {
            "vid": "303",
            "type": "task",
            "name": name,
            "body": "task",
            "state": "open",
            "ts": 1,
        }
        records = [
            {
                "edge_type": "about",
                "relation": "about",
                "source_vid": "303",
                "target_vid": "202",
            },
            {
                "edge_type": "fixed_by",
                "relation": "fixed_by",
                "source_vid": "101",
                "target_vid": "303",
            },
        ]
        statements = []
        with (
            mock.patch.object(MCP, "_ensure_ready"),
            mock.patch.object(MCP, "_find_existing_node", return_value=node),
            mock.patch.object(MCP, "_read_edge_records", return_value=records),
            mock.patch.object(
                MCP,
                "_raw_query",
                side_effect=lambda query: statements.append(query) or {},
            ),
        ):
            result = MCP.tool_delete(
                {"type": "task", "name": name, "cascade": True}
            )

        self.assertEqual(
            statements,
            [
                "DELETE EDGE about 303->202",
                "DELETE EDGE fixed_by 101->303",
                "DELETE VERTEX 303",
            ],
        )
        self.assertEqual(result["cascaded_links"], 2)

    def test_duplicate_canonical_name_is_rejected(self):
        name = "decision:duplicate"
        duplicates = [
            {"vid": "1", "type": "decision", "name": name},
            {"vid": "2", "type": "decision", "name": name},
        ]
        with (
            mock.patch.object(MCP, "_ensure_ready"),
            mock.patch.object(MCP, "_query_nodes", return_value=duplicates),
            self.assertRaisesRegex(ValueError, "duplicate canonical .* node"),
        ):
            MCP.tool_wiki_upsert(
                {"type": "decision", "name": name, "body": "ambiguous"}
            )

    def test_schema_version_note_cannot_be_deleted(self):
        with mock.patch.object(MCP, "_ensure_ready"):
            with self.assertRaisesRegex(ValueError, "schema version note"):
                MCP.tool_delete(
                    {"type": "note", "name": MCP.SCHEMA_VERSION_NAME, "cascade": True}
                )

    def test_new_tool_schemas_are_closed(self):
        structured = {
            "memory_query_read",
            "memory_wiki_upsert",
            "memory_link",
            "memory_read",
            "memory_delete",
            "memory_export",
        }
        self.assertLessEqual(structured, MCP.TOOLS.keys())
        for name in structured:
            with self.subTest(name=name):
                self.assertFalse(MCP.TOOLS[name]["inputSchema"]["additionalProperties"])

    def test_all_tool_handlers_reject_undeclared_fields(self):
        calls = (
            (MCP.tool_query, {"ngql": "SHOW TAGS", "unexpected": True}),
            (MCP.tool_query_read, {"ngql": "SHOW TAGS", "unexpected": True}),
            (
                MCP.tool_wiki_upsert,
                {
                    "type": "decision",
                    "name": "decision:closed-input",
                    "body": "closed",
                    "unexpected": True,
                },
            ),
            (
                MCP.tool_link,
                {
                    "relation": "affects",
                    "source": {"type": "decision", "name": "decision:closed"},
                    "target": {"type": "module", "name": "module:closed"},
                    "unexpected": True,
                },
            ),
            (MCP.tool_read, {"text": "closed", "unexpected": True}),
            (
                MCP.tool_delete,
                {"type": "task", "name": "task:closed", "unexpected": True},
            ),
            (MCP.tool_export, {"limit": 1, "unexpected": True}),
        )
        for handler, args in calls:
            with self.subTest(handler=handler.__name__), self.assertRaises(ValueError):
                handler(args)

        query_schema = MCP.TOOLS["memory_query"]["inputSchema"]
        self.assertFalse(query_schema["additionalProperties"])
        self.assertEqual(
            query_schema["properties"]["ngql"]["maxLength"], MCP.MAX_QUERY_LENGTH
        )

    def test_all_tool_handlers_reject_non_object_arguments(self):
        handlers = {tool["handler"] for tool in MCP.TOOLS.values()}
        for handler in handlers:
            with self.subTest(handler=handler.__name__), self.assertRaises(ValueError):
                handler([])

    def test_new_vid_fields_are_stringified_recursively(self):
        value = {"results": [{"vid": 9, "nested": {"src": 10, "count": 2}}]}
        self.assertEqual(
            MCP._stringify_vid_fields(value),
            {"results": [{"vid": "9", "nested": {"src": "10", "count": 2}}]},
        )


if __name__ == "__main__":
    unittest.main()
