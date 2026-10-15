"""Repository boundaries exercised through the same API used by native windows."""
from concurrent.futures import ThreadPoolExecutor
import sqlite3

import pytest
from fastapi.testclient import TestClient

from graphischema import api
from graphischema.storage import ProjectStore, REQUEST_SCOPE


def scope_headers(workspace):
    return {"X-GraphiSchema-Project": workspace["projectId"], "X-GraphiSchema-Branch": workspace["branchId"]}


def envelope_headers(envelope):
    return scope_headers({"projectId": envelope["diagram"]["project"]["id"], "branchId": envelope["branchId"]})


def create(client, title="Same title"):
    response = client.post("/api/projects", json={"title": title})
    response.raise_for_status()
    return response.json()


def tree(client, workspace):
    response = client.get("/api/commits/tree", headers=scope_headers(workspace))
    response.raise_for_status()
    result = response.json()
    assert result["projectId"] == workspace["projectId"]
    assert result["activeBranchId"] == workspace["branchId"]
    assert all(row["projectId"] == workspace["projectId"] for row in result["branches"] + result["commits"])
    return result


def test_names_and_commit_numbers_are_personal_to_projects_in_one_database(isolated_application_storage):
    with TestClient(api.app) as client:
        first, second = create(client), create(client)
        workspaces = []
        for workspace in (first, second):
            h = scope_headers(workspace)
            result = tree(client, workspace)
            assert [v["projectNumber"] for v in result["commits"]] == [1]
            branch = client.post("/api/branches", headers=h, json={"name": "release"})
            branch.raise_for_status()
            workspaces.append(branch.json())
            for target in (workspace, branch.json()):
                client.post("/api/commits", headers=scope_headers(target), json={"message": "Same message"}).raise_for_status()
            result = tree(client, workspace)
            assert [v["projectNumber"] for v in result["commits"]] == [3, 2, 1]
            assert {b["name"] for b in result["branches"]} == {"main", "release"}
        assert workspaces[0]["branchId"] != workspaces[1]["branchId"]
        a_ids = {v["id"] for v in tree(client, first)["commits"]}
        b_ids = {v["id"] for v in tree(client, second)["commits"]}
        assert a_ids.isdisjoint(b_ids)
        store = isolated_application_storage
        assert list(store.data_dir.rglob("*.sqlite3")) == [store.database_file]
        assert not list(store.data_dir.rglob(".git"))


@pytest.mark.parametrize("path", ["diagram", "versions", "commits/tree", "history", "branches", "dot"])
def test_forged_project_branch_pair_never_falls_back_to_default(path):
    with TestClient(api.app) as client:
        first, second = create(client, "A"), create(client, "B")
        before = tree(client, first), tree(client, second)
        h = scope_headers(first) | {"X-GraphiSchema-Branch": second["branchId"]}
        assert client.get("/api/" + path, headers=h).status_code == 404
        assert (tree(client, first), tree(client, second)) == before


@pytest.mark.parametrize("path", ["diagram", "versions", "commits/tree", "history", "branches", "dot", "storage"])
def test_project_responses_cannot_be_reused_from_http_cache(path):
    with TestClient(api.app) as client:
        first, second = create(client), create(client)
        for workspace in (first, second):
            response = client.get("/api/" + path, headers=scope_headers(workspace))
            response.raise_for_status()
            assert response.headers["Cache-Control"] == "no-store"
            assert set(response.headers["Vary"].split(", ")) == {"X-GraphiSchema-Project", "X-GraphiSchema-Branch"}


def test_open_resumes_history_while_import_creates_a_new_project():
    with TestClient(api.app) as client:
        original, other = create(client, "Document"), create(client, "Other window")
        document = client.get("/api/diagram", headers=scope_headers(original)).json()
        original_tree, other_tree = tree(client, original), tree(client, other)
        for _ in range(3):
            opened = client.post("/api/projects/open", headers=scope_headers(other), json=document["diagram"])
            opened.raise_for_status()
            assert opened.json() == document
        assert tree(client, original) == original_tree
        assert tree(client, other) == other_tree
        imported = client.post("/api/projects/import", headers=scope_headers(other), json=document["diagram"])
        imported.raise_for_status()
        result = imported.json()
        assert result["diagram"]["project"]["id"] not in (original["projectId"], other["projectId"])
        assert result["diagram"]["project"]["title"] == document["diagram"]["project"]["title"]
        assert tree(client, original) == original_tree
        assert tree(client, other) == other_tree
        assert len(client.get("/api/versions", headers=envelope_headers(result)).json()["versions"]) == 1


def test_restore_message_uses_the_projects_commit_number():
    with TestClient(api.app) as client:
        first, second = create(client, "A"), create(client, "B")
        root = tree(client, second)["commits"][0]
        assert root["id"] != root["projectNumber"] == 1
        before_a = tree(client, first)
        response = client.post(f'/api/versions/{root["id"]}/restore', headers=scope_headers(second))
        response.raise_for_status()
        result = tree(client, second)
        assert result["commits"][0]["projectNumber"] == 2
        assert result["commits"][0]["message"] == "Восстановление коммита №1"
        assert result["commits"][0]["parentId"] == root["id"]
        assert tree(client, first) == before_a


def test_diverged_json_opens_without_overwriting_main_or_another_project():
    with TestClient(api.app) as client:
        first, second = create(client, "A"), create(client, "B")
        before_a, before_b = tree(client, first), tree(client, second)
        document = client.get("/api/diagram", headers=scope_headers(first)).json()["diagram"]
        document["project"]["title"] = "File contents"
        opened = client.post("/api/projects/open", headers=scope_headers(second), json=document)
        opened.raise_for_status()
        result = opened.json()
        assert result["diagram"] == document
        assert result["branchId"] != first["branchId"]
        assert result["diagram"]["project"]["id"] == first["projectId"]
        again = client.post("/api/projects/open", json=document)
        assert again.json() == result
        assert len(tree(client, first)["branches"]) == 2
        assert tree(client, first)["commits"][0]["parentId"] == before_a["commits"][0]["id"]
        assert client.get("/api/versions", headers=scope_headers(first)).json()["versions"] == before_a["commits"]
        assert tree(client, second) == before_b


def test_parallel_import_of_identical_ids_has_separate_roots():
    with TestClient(api.app) as client:
        source = client.get("/api/diagram").json()
        original_h = envelope_headers(source)
        before = client.get("/api/commits/tree", headers=original_h).json()
        def import_copy(_):
            result = client.post("/api/projects/import", headers=original_h, json=source["diagram"])
            result.raise_for_status()
            return result.json()
        with ThreadPoolExecutor(max_workers=6) as executor:
            imports = list(executor.map(import_copy, range(6)))
        assert len({p["diagram"]["project"]["id"] for p in imports}) == 6
        assert len({p["branchId"] for p in imports}) == 6
        for envelope in imports:
            versions = client.get("/api/versions", headers=envelope_headers(envelope)).json()["versions"]
            assert len(versions) == 1
            assert versions[0]["parentId"] is None and versions[0]["projectNumber"] == 1
        assert client.get("/api/commits/tree", headers=original_h).json() == before


def test_project_numbers_survive_restart_and_continue_after_interleaved_writes(isolated_application_storage):
    store = isolated_application_storage
    first, second = store.create_project("A"), store.create_project("B")
    expected = {}
    for number in range(2, 6):
        for workspace in (first, second):
            token = REQUEST_SCOPE.set((workspace["projectId"], workspace["branchId"]))
            try:
                project = store.load()
                project.project.title = f"Revision {number}"
                store.save(project)
                assert store.list_versions()[0]["projectNumber"] == number
                expected[workspace["projectId"]] = store.commit_tree()
            finally:
                REQUEST_SCOPE.reset(token)
    for workspace in (first, second):
        token = REQUEST_SCOPE.set((workspace["projectId"], workspace["branchId"]))
        try:
            restarted = ProjectStore(store.data_dir, store.starter_file)
            assert restarted.commit_tree() == expected[workspace["projectId"]]
            restarted.save(restarted.load(), force_commit=True)
            assert restarted.list_versions()[0]["projectNumber"] == 6
        finally:
            REQUEST_SCOPE.reset(token)


@pytest.mark.parametrize("statement", [
    "UPDATE branches SET head_version_id=? WHERE id=?",
    "UPDATE branches SET base_version_id=? WHERE id=?",
    "UPDATE versions SET parent_id=? WHERE branch_id=?",
    "UPDATE versions SET branch_id=? WHERE branch_id=?",
    "UPDATE versions SET project_id=? WHERE branch_id=?",
])
def test_sqlite_rejects_cross_project_heads_parents_and_commit_ownership(isolated_application_storage, statement):
    store = isolated_application_storage
    first, second = store.create_project("A"), store.create_project("B")
    with sqlite3.connect(store.database_file) as connection:
        before = connection.execute("SELECT id,head_version_id,base_version_id FROM branches ORDER BY id").fetchall()
        foreign_head = connection.execute("SELECT head_version_id FROM branches WHERE id=?", (second["branchId"],)).fetchone()[0]
        if "SET branch_id" in statement:
            value = second["branchId"]
        elif "SET project_id" in statement:
            value = second["projectId"]
        else:
            value = foreign_head
        with pytest.raises(sqlite3.IntegrityError):
            connection.execute(statement, (value, first["branchId"]))
        assert connection.execute("SELECT id,head_version_id,base_version_id FROM branches ORDER BY id").fetchall() == before
        assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
