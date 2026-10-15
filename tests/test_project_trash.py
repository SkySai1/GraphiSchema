"""Retention boundaries, fork independence and complete project cleanup."""
import base64
import asyncio
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
import sqlite3

import pytest
from fastapi.testclient import TestClient

from graphischema import api
from graphischema.storage import ProjectStore, ProjectNotFound


def create(client, name='Project'):
    response = client.post('/api/projects', json={'title': name, 'template': True})
    response.raise_for_status()
    return response.json()


def headers(workspace):
    return {'X-GraphiSchema-Project': workspace['projectId'], 'X-GraphiSchema-Branch': workspace['branchId']}


def tree(client, workspace):
    response = client.get('/api/commits/tree', headers=headers(workspace))
    response.raise_for_status()
    return response.json()


def trash(client, workspace):
    response = client.post(f"/api/projects/{workspace['projectId']}/trash")
    response.raise_for_status()
    return response.json()


def purge(client, workspace):
    return client.delete(f"/api/projects/{workspace['projectId']}/permanent")


def test_trash_retains_snapshots_and_all_branches_then_restores_without_new_commits(isolated_application_storage, monkeypatch):
    now = datetime(2026, 10, 15, 8, 15, tzinfo=timezone.utc)
    monkeypatch.setattr(isolated_application_storage, '_now', lambda: now)
    with TestClient(api.app) as client:
        first, other = create(client, 'A'), create(client, 'B')
        branch = client.post('/api/branches', headers=headers(first), json={'name': 'experiment'}).json()
        client.post('/api/commits', headers=headers(branch), json={'message': 'Branch checkpoint'}).raise_for_status()
        before, other_before = tree(client, first), tree(client, other)
        deleted = trash(client, first)
        assert datetime.fromisoformat(deleted['deletedAt']) == now
        assert datetime.fromisoformat(deleted['purgeAfter']) == now + timedelta(days=10)
        assert trash(client, first) == deleted  # Repeated deletion must not extend retention.
        assert {p['id'] for p in client.get('/api/projects').json()['projects']} == {other['projectId']}
        items = client.get('/api/projects/trash').json()['projects']
        assert len(items) == 1 and items[0]['id'] == first['projectId']
        assert items[0]['branchCount'] == 2 and items[0]['purgeAfter'] == deleted['purgeAfter']
        assert tree(client, other) == other_before
        restored = client.post(f"/api/projects/{first['projectId']}/restore")
        restored.raise_for_status()
        assert tree(client, first) == before
        assert client.get('/api/projects/trash').json()['projects'] == []
        assert len(client.get('/api/projects').json()['projects']) == 2


@pytest.mark.parametrize('path', ['diagram', 'versions', 'commits/tree', 'branches', 'layout', 'dot', 'history'])
def test_trashed_project_cannot_be_opened_or_edited_from_stale_windows(path):
    with TestClient(api.app) as client:
        workspace = create(client)
        current = client.get('/api/diagram', headers=headers(workspace)).json()
        trash(client, workspace)
        assert client.get('/api/'+path, headers=headers(workspace)).status_code == 410
        assert client.put('/api/diagram', headers=headers(workspace), json=current['diagram']).status_code == 410
        assert client.post('/api/projects/open', json=current['diagram']).status_code == 410
        assert client.get(f"/api/projects/{workspace['projectId']}/branches").status_code == 410
        assert client.get('/api/storage').json()['trashedProjectCount'] == 1


@pytest.mark.parametrize('elapsed,expired', [(timedelta(days=10)-timedelta(microseconds=1), False),
                                           (timedelta(days=10), True), (timedelta(days=11), True)])
def test_retention_is_exactly_ten_days_in_utc(isolated_application_storage, monkeypatch, elapsed, expired):
    # Crosses the end of daylight saving time in Europe: retention is 240 hours.
    start = datetime(2026, 10, 24, 12, tzinfo=timezone.utc)
    monkeypatch.setattr(isolated_application_storage, '_now', lambda: start)
    with TestClient(api.app) as client:
        workspace = create(client)
        trash(client, workspace)
        monkeypatch.setattr(isolated_application_storage, '_now', lambda: start+elapsed)
        listed = client.get('/api/projects/trash').json()['projects']
        assert bool(listed) != expired
        restore = client.post(f"/api/projects/{workspace['projectId']}/restore")
        assert restore.status_code == (404 if expired else 200)
        if expired:
            assert client.get('/api/storage').json()['versionCount'] == 0
            assert api.CONTROLLER.cleanup_expired_projects() == []


def test_permanent_delete_cleans_own_entities_and_undo_but_preserves_parent_and_other_forks(isolated_application_storage, monkeypatch, tmp_path):
    store = isolated_application_storage
    config = tmp_path/'config'; config.mkdir(exist_ok=True)
    monkeypatch.setenv('GRAPHI_SCHEMA_CONFIG_DIR', str(config))
    with TestClient(api.app) as client:
        parent = create(client, 'Parent')
        fork = client.post('/api/projects/fork', headers=headers(parent), json={'title': 'Fork'}).json()
        sibling = client.post('/api/projects/fork', headers=headers(parent), json={'title': 'Sibling'}).json()
        child = client.post('/api/projects/fork', headers=headers(fork), json={'title': 'Child of fork'}).json()
        parent_before, sibling_before, child_before = tree(client, parent), tree(client, sibling), tree(client, child)
        snapshot = client.get('/api/diagram', headers=headers(fork)).json()['diagram']
        snapshot['project']['title'] = 'Changed fork'
        client.put('/api/diagram', headers=headers(fork), json=snapshot).raise_for_status()
        branch_ids = {b['id'] for b in tree(client, fork)['branches']}
        assert branch_ids & api.CONTROLLER._undo.keys()
        # Old revision aliases and early MVP current.json must also be removed.
        with sqlite3.connect(store.database_file) as db:
            db.execute('INSERT INTO revision_aliases(legacy_revision,canonical_revision,snapshot) VALUES(?,?,?)',
                       ('legacy-fork', 'hash', json.dumps(snapshot)))
        store.project_file.write_text(json.dumps(snapshot))
        external = tmp_path/'exported.json'; external.write_text(json.dumps(snapshot))
        last = base64.b64encode(json.dumps(fork).encode()).decode()
        settings = {f"GraphiSchema.themeMode.{fork['projectId']}": 'dark', f"GraphiSchema.projectFile.{fork['projectId']}": str(external),
                    f"GraphiSchema.themeMode.{parent['projectId']}": 'light', 'GraphiSchema.lastWorkspace': {'$data': last},
                    'GraphiSchema.projectFile': str(external), 'GraphiSchema.startupWindow': 'last_project'}
        (config/'settings.json').write_text(json.dumps(settings))
        trash(client, fork)
        purge(client, fork).raise_for_status()
        with sqlite3.connect(store.database_file) as db:
            for table in ('projects', 'branches', 'versions'):
                column = 'id' if table == 'projects' else 'project_id'
                assert db.execute(f'SELECT count(*) FROM {table} WHERE {column}=?', (fork['projectId'],)).fetchone()[0] == 0
            assert db.execute("SELECT count(*) FROM revision_aliases WHERE legacy_revision='legacy-fork'").fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM current_project WHERE project_id=?', (fork['projectId'],)).fetchone()[0] == 0
            assert db.execute('PRAGMA foreign_key_check').fetchall() == []
            assert db.execute('PRAGMA quick_check').fetchone()[0] == 'ok'
        assert not (branch_ids & api.CONTROLLER._undo.keys())
        assert not (branch_ids & api.CONTROLLER._redo.keys())
        assert tree(client, parent) == parent_before and tree(client, sibling) == sibling_before
        assert tree(client, child) == child_before
        child_meta = next(p for p in client.get('/api/projects').json()['projects'] if p['id'] == child['projectId'])
        assert child_meta['originProjectId'] is None and child_meta['originVersionId'] is None
        assert not store.project_file.exists() and external.exists()
        after_settings = json.loads((config/'settings.json').read_text())
        assert after_settings == {f"GraphiSchema.themeMode.{parent['projectId']}": 'light', 'GraphiSchema.startupWindow': 'last_project'}
        assert (config/'settings.json').stat().st_mode & 0o777 == 0o600


def test_purge_requires_trash_and_unknown_targets_do_not_change_existing_data():
    with TestClient(api.app) as client:
        workspace = create(client)
        before = tree(client, workspace)
        assert purge(client, workspace).status_code == 409
        assert client.post('/api/projects/project_missing/trash').status_code == 404
        assert client.post('/api/projects/project_missing/restore').status_code == 404
        assert client.delete('/api/projects/project_missing/permanent').status_code == 404
        assert tree(client, workspace) == before


def test_purging_last_project_does_not_resurrect_starter_or_legacy_json(isolated_application_storage):
    store = isolated_application_storage
    with TestClient(api.app) as client:
        original = client.get('/api/diagram').json()
        workspace = {'projectId': original['diagram']['project']['id'], 'branchId': original['branchId']}
        store.project_file.write_text(json.dumps(original['diagram']))
        trash(client, workspace)
        restarted = ProjectStore(store.data_dir, store.starter_file)
        assert restarted.list_projects() == []
        assert len(restarted.list_projects(trashed=True)) == 1
        purge(client, workspace).raise_for_status()
        restarted = ProjectStore(store.data_dir, store.starter_file)
        assert restarted.list_projects() == restarted.list_projects(trashed=True) == []
        with pytest.raises(ProjectNotFound): restarted.load()
        assert client.get('/api/diagram').status_code == 404
        assert client.put('/api/diagram', headers=headers(workspace), json=original['diagram']).status_code == 404
        assert client.get('/api/storage').json()['projectCount'] == client.get('/api/storage').json()['versionCount'] == 0


def test_expired_trash_is_purged_at_backend_startup(isolated_application_storage, monkeypatch):
    store = isolated_application_storage
    start = datetime(2026, 10, 15, tzinfo=timezone.utc)
    monkeypatch.setattr(store, '_now', lambda: start)
    with TestClient(api.app) as client:
        workspace = create(client)
        trash(client, workspace)
    monkeypatch.setattr(store, '_now', lambda: start+timedelta(days=10))
    with TestClient(api.app) as client:
        assert client.get('/api/projects/trash').json()['projects'] == []
        assert client.get('/api/storage').json()['versionCount'] == 0


def test_concurrent_trash_and_restore_preserve_independent_projects():
    with TestClient(api.app) as client:
        projects = [create(client, f'Project {i}') for i in range(6)]
        before = [tree(client, p) for p in projects]
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda w: trash(client, w), projects))
        assert client.get('/api/projects').json()['projects'] == []
        assert len(client.get('/api/projects/trash').json()['projects']) == 6
        with ThreadPoolExecutor(max_workers=6) as pool:
            results = list(pool.map(lambda w: client.post(f"/api/projects/{w['projectId']}/restore"), projects))
        assert all(r.status_code == 200 for r in results)
        assert [tree(client, p) for p in projects] == before


def test_periodic_cleanup_expires_trash_without_listing_or_restarting(isolated_application_storage, monkeypatch):
    store = isolated_application_storage
    now = datetime(2026, 10, 15, tzinfo=timezone.utc)
    monkeypatch.setattr(store, '_now', lambda: now)
    monkeypatch.setattr(api, 'TRASH_SWEEP_INTERVAL_SECONDS', 0.01)
    workspace = store.create_project('Expired while running')
    api.CONTROLLER.trash_project(workspace['projectId'])

    async def scenario():
        nonlocal now
        async with api.lifespan(api.app):
            assert len(store.list_projects(trashed=True)) == 1
            now += timedelta(days=10)
            # Read the store directly: GET /trash also cleans and would hide a broken timer.
            async def wait_for_purge():
                while store.list_projects(trashed=True):
                    await asyncio.sleep(0.005)
            await asyncio.wait_for(wait_for_purge(), timeout=3)
            assert store.storage_info()['versionCount'] == 0
    asyncio.run(scenario())


def test_cleanup_failure_keeps_snapshots_and_can_be_retried(isolated_application_storage, tmp_path):
    store = isolated_application_storage
    workspace = store.create_project('Recoverable')
    api.CONTROLLER.trash_project(workspace['projectId'])
    config = tmp_path/'config'; config.mkdir(exist_ok=True)
    settings = config/'settings.json'; settings.write_text('invalid JSON')
    with pytest.raises(ValueError):
        api.CONTROLLER.purge_project(workspace['projectId'])
    assert store.list_projects(trashed=True)[0]['id'] == workspace['projectId']
    assert store.storage_info()['versionCount'] == 1
    assert settings.read_text() == 'invalid JSON'
    settings.write_text('{}')
    api.CONTROLLER.purge_project(workspace['projectId'])
    assert store.list_projects(trashed=True) == []
    assert store.storage_info()['versionCount'] == 0


def test_sweep_only_deletes_expired_projects_and_survives_store_restart(isolated_application_storage, monkeypatch):
    store = isolated_application_storage
    now = datetime(2026, 10, 15, tzinfo=timezone.utc)
    monkeypatch.setattr(store, '_now', lambda: now)
    expired = store.create_project('Expired')
    api.CONTROLLER.trash_project(expired['projectId'])
    now += timedelta(days=1)
    retained = store.create_project('Still in trash')
    active = store.create_project('Active')
    api.CONTROLLER.trash_project(retained['projectId'])
    now += timedelta(days=9)
    assert api.CONTROLLER.cleanup_expired_projects() == [expired['projectId']]
    restarted = ProjectStore(store.data_dir, store.starter_file)
    assert [p['id'] for p in restarted.list_projects()] == [active['projectId']]
    assert [p['id'] for p in restarted.list_projects(trashed=True)] == [retained['projectId']]
    assert restarted.storage_info()['versionCount'] == 2


def test_purging_a_parent_preserves_independent_forks():
    with TestClient(api.app) as client:
        parent = create(client, 'Parent')
        fork = client.post('/api/projects/fork', headers=headers(parent), json={'title': 'Independent fork'}).json()
        before = tree(client, fork)
        trash(client, parent)
        purge(client, parent).raise_for_status()
        assert tree(client, fork) == before
        meta = client.get('/api/projects').json()['projects']
        assert len(meta) == 1 and meta[0]['id'] == fork['projectId']
        assert meta[0]['originProjectId'] is meta[0]['originVersionId'] is None
