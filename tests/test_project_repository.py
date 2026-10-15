from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
import sqlite3
import pytest
from fastapi.testclient import TestClient
from graphischema import api
from graphischema.application.controller import ApplicationController, HistoryUnavailable
from graphischema.models import DiagramProject
from graphischema.storage import ProjectStore, REQUEST_SCOPE, RevisionConflict, VersionNotFound
from graphischema.legacy_storage import ProjectStore as LegacyStore

ROOT = Path(__file__).resolve().parents[1]

@contextmanager
def scope(project_id, branch_id=None):
    token = REQUEST_SCOPE.set((project_id, branch_id))
    try:
        yield
    finally:
        REQUEST_SCOPE.reset(token)

def headers(workspace):
    return {"X-GraphiSchema-Project": workspace["projectId"], "X-GraphiSchema-Branch": workspace["branchId"]}

def test_imports_with_the_same_document_id_create_independent_repositories():
    with TestClient(api.app) as client:
        source = client.get('/api/diagram').json()
        first = client.post('/api/projects/import', json=source['diagram']).json()
        second = client.post('/api/projects/import', json=source['diagram']).json()
        ids = {p['diagram']['project']['id'] for p in (source, first, second)}
        assert len(ids) == 3, 'Importing copies must not add branches to an unrelated open project'
        for envelope in (first, second):
            h = {'X-GraphiSchema-Project': envelope['diagram']['project']['id'], 'X-GraphiSchema-Branch': envelope['branchId']}
            tree = client.get('/api/commits/tree', headers=h).json()
            assert len(tree['branches']) == len(tree['commits']) == 1
            assert tree['commits'][0]['parentId'] is None
            assert tree['commits'][0]['projectNumber'] == 1

def test_migration_keeps_legacy_ids_dates_snapshots_and_partitions_projects(tmp_path):
    legacy = LegacyStore(tmp_path, ROOT/"examples"/"starter.json")
    first = legacy.load()
    first.nodes[0].label = "Первая схема"
    legacy.save(first)
    second = first.model_copy(deep=True)
    second.project.id = "another_project"
    second.project.title = "Вторая схема"
    legacy.save(second)
    first.nodes[0].label = "Первая схема позже"
    legacy.save(first)
    before = legacy.list_versions()
    store = ProjectStore(tmp_path, ROOT/"examples"/"starter.json")
    assert store.load() == first
    assert len(store.list_projects()) == 2
    for project_id in (first.project.id, second.project.id):
        with scope(project_id):
            versions = store.list_versions()
            assert all(item["projectId"] == project_id for item in versions)
            expected = [item for item in before if item["projectId"] == project_id]
            assert [(v["id"], v["createdAt"], v["revision"]) for v in versions] == [(v["id"], v["createdAt"], v["revision"]) for v in expected]
            assert [v["parentId"] for v in versions] == [v["id"] for v in versions[1:]]+[None]
    assert ProjectStore(tmp_path, ROOT/"examples"/"starter.json").load() == first

def test_branch_forks_from_any_commit_and_keeps_independent_heads(isolated_application_storage):
    store = isolated_application_storage
    base = store.load()
    main = store.workspace()
    original = store.list_versions()[0]
    changed = base.model_copy(deep=True)
    changed.nodes[0].label = "Изменено в main"
    store.save(changed)
    main_head = store.list_versions()[0]
    fork = store.create_branch("Эксперимент", original["id"])
    with scope(fork["projectId"], fork["branchId"]):
        assert store.load() == base
        candidate = store.load()
        candidate.nodes[0].label = "Ветка"
        store.save(candidate, expected_revision=store.revision(base))
        history = store.list_versions()
        assert history[0]["parentId"] == original["id"]
        assert history[1]["id"] == original["id"]
        assert main_head["id"] not in {v["id"] for v in history}
        tree = store.commit_tree()
        assert len(tree["branches"]) == 2
        assert len(tree["commits"]) == 3
    with scope(base.project.id, main["id"]):
        assert store.load() == changed
        assert store.list_versions()[0]["id"] == main_head["id"]

def test_api_windows_are_isolated_and_cross_project_versions_rejected():
    with TestClient(api.app) as client:
        first = client.post("/api/projects", json={"title": "Окно A", "template": True}).json()
        second = client.post("/api/projects", json={"title": "Окно B"}).json()
        a = client.get("/api/diagram", headers=headers(first)).json()
        b = client.get("/api/diagram", headers=headers(second)).json()
        assert a["diagram"]["project"]["id"] != b["diagram"]["project"]["id"]
        a["diagram"]["nodes"][0]["label"] = "Только окно A"
        saved = client.put("/api/diagram", headers={**headers(first), "If-Match": a["revision"]}, json=a["diagram"])
        assert saved.status_code == 200
        assert client.get("/api/diagram", headers=headers(second)).json() == b
        versions = client.get("/api/versions", headers=headers(first)).json()["versions"]
        assert all(v["projectId"] == first["projectId"] for v in versions)
        for suffix in ("preview", "diff", "restore"):
            call = client.post if suffix == "restore" else client.get
            assert call(f'/api/versions/{versions[0]["id"]}/{suffix}', headers=headers(second)).status_code == 404
        forged = {**headers(first), "X-GraphiSchema-Branch": second["branchId"]}
        assert client.get("/api/diagram", headers=forged).status_code == 404

def test_concurrent_request_contexts_do_not_leak_between_projects():
    with TestClient(api.app) as client:
        workspaces = [client.post("/api/projects", json={"title": f"Проект {i}"}).json() for i in range(6)]
        def change(workspace):
            current = client.get("/api/diagram", headers=headers(workspace)).json()
            current["diagram"]["project"]["title"] = workspace["projectId"]
            result = client.put("/api/diagram", headers={**headers(workspace), "If-Match": current["revision"]}, json=current["diagram"])
            assert result.status_code == 200
            return result.json()
        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(change, workspaces))
        assert [r["diagram"]["project"]["id"] for r in results] == [w["projectId"] for w in workspaces]
        for workspace in workspaces:
            current = client.get("/api/diagram", headers=headers(workspace)).json()
            assert current["diagram"]["project"]["title"] == workspace["projectId"]
            assert len(client.get("/api/versions", headers=headers(workspace)).json()["versions"]) == 2

def test_undo_redo_isolated_by_branch(isolated_application_storage):
    store = isolated_application_storage
    controller = ApplicationController(store)
    original = store.load()
    main = store.workspace()["id"]
    fork = store.create_branch("other")
    changed = original.model_copy(deep=True)
    changed.project.title = "main changed"
    controller.replace_project(changed)
    assert controller.history_state["canUndo"]
    with scope(original.project.id, fork["branchId"]):
        assert controller.history_state == {"canUndo": False, "canRedo": False}
        with pytest.raises(HistoryUnavailable):
            controller.undo()
        candidate = store.load()
        candidate.project.title = "branch changed"
        controller.replace_project(candidate)
        controller.undo()
        assert store.load() == original
    with scope(original.project.id, main):
        assert store.load() == changed
        controller.undo()
        assert store.load() == original
        controller.redo()
        assert store.load() == changed

def test_preview_read_only_restore_appends_and_manual_commit_has_message():
    with TestClient(api.app) as client:
        current = client.get("/api/diagram").json()
        h = {"X-GraphiSchema-Project": current["diagram"]["project"]["id"], "X-GraphiSchema-Branch": current["branchId"]}
        oldest = client.get("/api/versions", headers=h).json()["versions"][0]
        modified = current["diagram"]
        modified["project"]["title"] = "Изменено"
        client.put("/api/diagram", headers={**h, "If-Match": current["revision"]}, json=modified).raise_for_status()
        before = client.get("/api/diagram", headers=h).json()
        history = client.get("/api/versions", headers=h).json()
        for _ in range(3):
            response = client.get(f'/api/versions/{oldest["id"]}/preview', headers=h)
            assert response.status_code == 200
            assert response.json()["diagram"]["project"]["title"] != "Изменено"
        assert client.get("/api/diagram", headers=h).json() == before
        assert client.get("/api/versions", headers=h).json() == history
        restored = client.post(f'/api/versions/{oldest["id"]}/restore', headers={**h, "If-Match": before["revision"]})
        restored.raise_for_status()
        after = client.get("/api/versions", headers=h).json()["versions"]
        assert len(after) == len(history["versions"])+1
        assert after[0]["parentId"] == history["versions"][0]["id"]
        commit = client.post("/api/commits", headers=h, json={"message": "Контрольная точка"})
        commit.raise_for_status()
        latest = client.get("/api/versions", headers=h).json()["versions"][0]
        assert latest["message"] == "Контрольная точка" and latest["source"] == "manual"

def test_branch_names_forks_imports_and_database_size():
    with TestClient(api.app) as client:
        original = client.get("/api/diagram").json()
        h = {"X-GraphiSchema-Project": original["diagram"]["project"]["id"], "X-GraphiSchema-Branch": original["branchId"]}
        assert client.post("/api/branches", headers=h, json={"name": "MAIN"}).status_code == 422
        assert client.post("/api/branches", headers=h, json={"name": "   "}).status_code == 422
        fork = client.post("/api/projects/fork", headers=h, json={"title": "Форк"}).json()
        other = client.get("/api/diagram", headers=headers(fork)).json()["diagram"]
        assert other["nodes"] == original["diagram"]["nodes"]
        assert other["project"]["id"] != original["diagram"]["project"]["id"]
        imported = client.post("/api/projects/import", headers=h, json=original["diagram"])
        imported.raise_for_status()
        assert imported.json()["branchId"] != original["branchId"]
        assert client.get("/api/diagram", headers=h).json() == original
        info = client.get("/api/storage", headers=h).json()
        assert info["totalBytes"] == info["databaseBytes"]+info["walBytes"]+info["shmBytes"]
        assert imported.json()['diagram']['project']['id'] not in (original['diagram']['project']['id'], fork['projectId'])
        assert info["databaseBytes"] > 0 and info["projectCount"] == 3
        assert info["versionCount"] >= 2

def test_failed_revision_conflict_is_atomic_and_does_not_cross_branches(isolated_application_storage):
    store=isolated_application_storage
    base=store.load();head=store.list_versions()[0]
    fork=store.create_branch('parallel')
    changed=base.model_copy(deep=True);changed.project.title='new main'
    store.save(changed,expected_revision=head['revision'])
    before=store.commit_tree()
    with pytest.raises(RevisionConflict):store.save(base,expected_revision=head['revision'])
    assert store.commit_tree()==before and store.load()==changed
    with scope(fork['projectId'],fork['branchId']):
        assert store.load()==base
        assert store.list_versions()[0]['id']==head['id']

def test_project_palette_versions_restore_and_branch_independence():
    with TestClient(api.app) as client:
        current=client.get('/api/diagram').json();h={'X-GraphiSchema-Project':current['diagram']['project']['id'],'X-GraphiSchema-Branch':current['branchId']}
        base=client.get('/api/versions',headers=h).json()['versions'][0]
        current['diagram']['presentation']['saved_colors']=['#11223380']
        saved=client.put('/api/diagram',headers={**h,'If-Match':current['revision']},json=current['diagram']);saved.raise_for_status()
        fork=client.post('/api/branches',headers=h,json={'name':'palette','from_version_id':base['id']}).json()
        assert client.get('/api/diagram',headers=headers(fork)).json()['diagram']['presentation']['saved_colors']==[]
        preview=client.get(f"/api/versions/{base['id']}/preview",headers=h);preview.raise_for_status()
        assert client.get('/api/diagram',headers=h).json()['diagram']['presentation']['saved_colors']==['#11223380']
        restored=client.post(f"/api/versions/{base['id']}/restore",headers=h);restored.raise_for_status()
        assert restored.json()['diagram']['presentation']['saved_colors']==[]
        latest=client.get('/api/versions',headers=h).json()['versions'][0]
        assert latest['source']=='restore' and str(base['id']) in latest['message']

def test_database_file_migration_includes_wal_and_is_idempotent(tmp_path,monkeypatch):
    from graphischema.paths import migrate_legacy_database
    fake_home=tmp_path/'home';monkeypatch.setattr(Path,'home',classmethod(lambda cls:fake_home))
    config=tmp_path/'config';monkeypatch.setenv('GRAPHI_SCHEMA_CONFIG_DIR',str(config));monkeypatch.setenv('GRAPHI_SCHEMA_DISABLE_MIGRATION','0')
    source=fake_home/'Library/Application Support/GraphiSchema/projects/graphischema.sqlite3';source.parent.mkdir(parents=True)
    destination=config/'projects/graphischema.sqlite3'
    with sqlite3.connect(source) as connection:
        connection.execute('PRAGMA journal_mode=WAL');connection.execute('PRAGMA wal_autocheckpoint=0')
        connection.execute('CREATE TABLE sentinel(value TEXT)');connection.execute("INSERT INTO sentinel VALUES('committed WAL')");connection.commit()
        assert source.with_name(source.name+'-wal').exists()
        with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(lambda _:migrate_legacy_database(destination),range(4)))
        with sqlite3.connect(destination) as copied:assert copied.execute('SELECT value FROM sentinel').fetchone()[0]=='committed WAL'
        connection.execute("INSERT INTO sentinel VALUES('later')");connection.commit()
        migrate_legacy_database(destination)
        with sqlite3.connect(destination) as copied:assert copied.execute('SELECT count(*) FROM sentinel').fetchone()[0]==1
        assert connection.execute('SELECT count(*) FROM sentinel').fetchone()[0]==2
        assert destination.stat().st_mode & 0o777 == 0o600

def test_new_instances_retain_branch_heads_commit_parentage_and_timestamps(isolated_application_storage):
    store=isolated_application_storage;project=store.load();base=store.list_versions()[0]
    fork=store.create_branch('retained',base['id'])
    with scope(fork['projectId'],fork['branchId']):
        project.project.title='Branch persists';store.save(project)
        tree=store.commit_tree()
        reopened=ProjectStore(store.data_dir,ROOT/'examples/starter.json')
        assert reopened.load()==project
        assert reopened.commit_tree()==tree
        assert reopened.list_versions()[0]['parentId']==base['id']


def test_unicode_branch_names_and_explicit_invalid_commit_ids():
    with TestClient(api.app) as client:
        assert client.post('/api/branches',json={'name':'Эксперимент'}).status_code==200
        assert client.post('/api/branches',json={'name':'эксперимент'}).status_code==422
        for invalid in (0,-1):
            assert client.post('/api/branches',json={'name':'invalid','from_version_id':invalid}).status_code==422
            assert client.post('/api/projects/fork',json={'title':'invalid','version_id':invalid}).status_code==422
        assert client.post('/api/branches',json={'name':'bad\nname'}).status_code==422


def test_tree_and_chronology_read_metadata_without_fetching_every_json_snapshot(isolated_application_storage,monkeypatch):
    store=isolated_application_storage;store.load()
    original=sqlite3.connect;queries=[]
    def connect(*args,**kwargs):
        connection=original(*args,**kwargs);connection.set_trace_callback(queries.append);return connection
    monkeypatch.setattr(sqlite3,'connect',connect)
    tree=store.commit_tree();history=store.list_versions()
    assert tree['commits'][0]['id']==history[0]['id']
    version_reads=[query.upper() for query in queries if query.upper().startswith('SELECT') and 'FROM VERSIONS' in query.upper()]
    assert version_reads and all('SNAPSHOT' not in query and 'SELECT *' not in query for query in version_reads)

def test_ollama_generation_stays_in_active_project_and_branch(monkeypatch):
    async def generated(settings,system,user,output_schema):
        return {'project':{'id':'model_invented_project','title':'Generated in A'},
                'nodes':[{'id':'ai_node','label':'Generated component'}]}
    monkeypatch.setattr('graphischema.ollama._chat_json',generated)
    with TestClient(api.app) as client:
        first=client.post('/api/projects',json={'title':'A'}).json()
        second=client.post('/api/projects',json={'title':'B'}).json()
        h=headers(first);before=client.get('/api/diagram',headers=h).json()
        other=client.get('/api/diagram',headers=headers(second)).json()
        history=client.get('/api/versions',headers=h).json()
        result=client.post('/api/ollama/generate',headers={**h,'If-Match':before['revision']},
                           json={'settings':{'model':'local-test'},'prompt':'Создай компонент'})
        result.raise_for_status();proposal=result.json()['diagram']
        assert proposal['project']['id']==first['projectId']
        assert client.get('/api/diagram',headers=h).json()==before
        assert client.get('/api/versions',headers=h).json()==history
        saved=client.put('/api/diagram',headers={**h,'If-Match':before['revision']},json=proposal)
        saved.raise_for_status()
        assert saved.json()['branchId']==first['branchId']
        assert client.get('/api/diagram',headers=headers(second)).json()==other
        assert len(client.get('/api/versions',headers=h).json()['versions'])==len(history['versions'])+1
        assert all(p['id']!='model_invented_project' for p in client.get('/api/projects').json()['projects'])
