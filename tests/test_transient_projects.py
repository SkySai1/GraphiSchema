"""Blank windows remain stateless until the first applied change."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import re
import sqlite3

import pytest
from fastapi.testclient import TestClient

from graphischema import api
from graphischema.models import DiagramProject
from graphischema.storage import ProjectStore


def draft(client):
    result = client.get('/api/projects/draft')
    result.raise_for_status()
    return result.json()


def headers(envelope):
    return {'X-GraphiSchema-Project': envelope['diagram']['project']['id'], 'X-GraphiSchema-Branch': envelope['branchId']}


def registration(preview):
    changed = deepcopy(preview['diagram'])
    changed['nodes'] = [{'id': 'first_node', 'label': 'First change'}]
    changed = DiagramProject.model_validate(changed).model_dump(mode='json')
    return {'diagram': changed, 'base_diagram': preview['diagram']}


def test_blank_previews_never_create_a_database_or_saved_project(isolated_application_storage):
    with TestClient(api.app) as client:
        drafts = [draft(client) for _ in range(20)]
        assert len({p['diagram']['project']['id'] for p in drafts}) == 20
        assert len({p['diagram']['project']['title'] for p in drafts}) == 20
        for preview in drafts:
            assert re.fullmatch(r'Unnamed-[a-z0-9]+', preview['diagram']['project']['title'])
            assert preview['diagram']['nodes'] == preview['diagram']['containers'] == preview['diagram']['edges'] == []
            assert 'digraph' in preview['dot']
            assert 'branchId' not in preview
            check = client.post('/api/projects/preview', json=preview['diagram'])
            check.raise_for_status()
            assert check.json() == preview
            client.post('/api/validate', json=preview['diagram']).raise_for_status()
        assert not isolated_application_storage.database_file.exists()
        assert client.get('/api/projects').json() == {'projects': []}
        size = client.get('/api/storage').json()
        assert size['projectCount'] == size['versionCount'] == 0
        assert ProjectStore(isolated_application_storage.data_dir, isolated_application_storage.starter_file).list_projects() == []


def test_first_change_atomically_registers_one_project_branch_and_snapshot(isolated_application_storage):
    with TestClient(api.app) as client:
        preview = draft(client)
        body = registration(preview)
        saved = client.post('/api/projects/register', json=body)
        saved.raise_for_status()
        result = saved.json()
        assert result['diagram'] == body['diagram']
        assert result['diagram']['project'] == preview['diagram']['project']
        h = headers(result)
        tree = client.get('/api/commits/tree', headers=h).json()
        assert len(tree['branches']) == len(tree['commits']) == 1
        assert tree['commits'][0]['projectNumber'] == 1
        assert tree['commits'][0]['parentId'] is None
        assert client.get('/api/history', headers=h).json()['canUndo']
        for _ in range(3):
            retry = client.post('/api/projects/register', json=body)
            assert retry.json() == result
        assert client.get('/api/commits/tree', headers=h).json() == tree
        assert len(client.get('/api/projects').json()['projects']) == 1
        undone = client.post('/api/undo', headers=h)
        undone.raise_for_status()
        assert undone.json()['diagram'] == preview['diagram']
        assert len(client.get('/api/projects').json()['projects']) == 1
        assert len(client.get('/api/versions', headers=h).json()['versions']) == 2
        redone = client.post('/api/redo', headers=h)
        assert redone.json()['diagram'] == body['diagram']
        assert client.get('/api/storage').json()['projectCount'] == 1


def test_readonly_dot_check_and_png_export_do_not_register_a_blank_canvas(isolated_application_storage):
    with TestClient(api.app) as client:
        preview = draft(client)
        check = client.post('/api/dot/preview', headers={'If-Match': preview['revision']},
                            json={'dot': preview['dot'], 'base_diagram': preview['diagram'], 'current_diagram': preview['diagram']})
        check.raise_for_status()
        assert check.json()['diagram'] == preview['diagram']
        assert all(not values for values in check.json()['changes'].values())
        exported = client.post('/api/export.png', json=preview['diagram'])
        exported.raise_for_status()
        assert exported.content.startswith(b'\x89PNG')
        assert not isolated_application_storage.database_file.exists()


@pytest.mark.parametrize('change', ['title', 'style', 'layout', 'container', 'node'])
def test_different_first_changes_are_persisted_without_an_empty_initial_commit(change):
    with TestClient(api.app) as client:
        preview = draft(client)
        project = deepcopy(preview['diagram'])
        if change == 'title': project['project']['title'] = 'Chosen name'
        if change == 'style': project['presentation']['background'] = '#FFAAEE'
        if change == 'layout': project['diagram']['direction'] = 'TB'
        if change == 'container': project['containers'] = [{'id': 'group', 'label': 'Group'}]
        if change == 'node': project['nodes'] = [{'id': 'node', 'label': 'Node'}]
        result = client.post('/api/projects/register', json={'diagram': project, 'base_diagram': preview['diagram']})
        result.raise_for_status()
        versions = client.get('/api/versions', headers=headers(result.json())).json()['versions']
        assert len(versions) == 1
        loaded = client.get('/api/diagram', headers=headers(result.json())).json()['diagram']
        assert loaded['project']['title'] == project['project']['title']


def test_unchanged_or_foreign_registration_is_rejected_without_touching_existing_projects():
    with TestClient(api.app) as client:
        preview = draft(client)
        unchanged = {'diagram': preview['diagram'], 'base_diagram': preview['diagram']}
        assert client.post('/api/projects/register', json=unchanged).status_code == 422
        assert client.get('/api/projects').json()['projects'] == []
        body = registration(preview)
        original = client.post('/api/projects/register', json=body).json()
        before = client.get('/api/commits/tree', headers=headers(original)).json()
        another = draft(client)
        assert client.post('/api/projects/register', headers=headers(original), json=registration(another)).status_code == 422
        changed = deepcopy(body)
        changed['diagram']['project']['title'] = 'Colliding ID'
        assert client.post('/api/projects/register', json=changed).status_code == 409
        changed = registration(another)
        changed['base_diagram']['project']['id'] = original['diagram']['project']['id']
        assert client.post('/api/projects/register', json=changed).status_code == 422
        assert client.get('/api/commits/tree', headers=headers(original)).json() == before
        assert len(client.get('/api/projects').json()['projects']) == 1


def test_concurrent_first_saves_and_identical_retries_create_only_one_root():
    with TestClient(api.app) as client:
        preview = draft(client)
        body = registration(preview)
        def save(_):
            response = client.post('/api/projects/register', json=body)
            response.raise_for_status()
            return response.json()
        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(save, range(6)))
        assert all(result == results[0] for result in results)
        assert client.get('/api/storage').json()['projectCount'] == client.get('/api/storage').json()['versionCount'] == 1


def test_registration_failure_rolls_back_and_can_be_retried(isolated_application_storage, monkeypatch):
    store = isolated_application_storage
    with TestClient(api.app, raise_server_exceptions=False) as client:
        preview = draft(client)
        body = registration(preview)
        insert = store._insert_version
        def fail(*args, **kwargs): raise RuntimeError('simulated write failure')
        monkeypatch.setattr(store, '_insert_version', fail)
        assert client.post('/api/projects/register', json=body).status_code == 500
        assert client.get('/api/projects').json() == {'projects': []}
        with sqlite3.connect(store.database_file) as db:
            assert db.execute('SELECT count(*) FROM branches').fetchone()[0] == 0
            assert db.execute('SELECT count(*) FROM versions').fetchone()[0] == 0
        monkeypatch.setattr(store, '_insert_version', insert)
        result = client.post('/api/projects/register', json=body)
        result.raise_for_status()


def test_ollama_proposal_for_blank_canvas_is_readonly_until_applied(isolated_application_storage, monkeypatch):
    async def generated(settings, system, user, output_schema):
        return {'project': {'id': 'model_id', 'title': 'AI draft'}, 'nodes': [{'id': 'ai', 'label': 'AI node'}]}
    monkeypatch.setattr('graphischema.ollama._chat_json', generated)
    with TestClient(api.app) as client:
        preview = draft(client)
        request = {'settings': {'model': 'test'}, 'prompt': 'Create a node', 'current_diagram': preview['diagram']}
        response = client.post('/api/ollama/generate', headers={'If-Match': preview['revision']}, json=request)
        response.raise_for_status()
        candidate = response.json()['diagram']
        assert candidate['project']['id'] == preview['diagram']['project']['id']
        assert not isolated_application_storage.database_file.exists()
        saved = client.post('/api/projects/register', json={'diagram': candidate, 'base_diagram': preview['diagram']})
        saved.raise_for_status()
        assert client.get('/api/storage').json()['versionCount'] == 1
