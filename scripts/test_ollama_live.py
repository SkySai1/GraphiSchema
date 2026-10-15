"""Optional live integration check; requires a preinstalled local Ollama model.

Run: uv run python scripts/test_ollama_live.py --model <local-model>
Only a temporary repository and synthetic diagram are used.
"""
import argparse
import json
import os
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from time import perf_counter
from xml.etree import ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--model',required=True)
    parser.add_argument('--timeout',type=float,default=120)
    parser.add_argument('--output',type=Path,default=ROOT/'dist/quality/ollama-live.json')
    args=parser.parse_args();started=perf_counter()
    with TemporaryDirectory(prefix='graphischema-live-ollama-') as temporary:
        os.environ['GRAPHI_SCHEMA_CONFIG_DIR']=temporary+'/config'
        os.environ['GRAPHI_SCHEMA_DATA_DIR']=temporary+'/projects'
        os.environ['GRAPHI_SCHEMA_DISABLE_MIGRATION']='1'
        from fastapi.testclient import TestClient
        from graphischema.api import app
        with TestClient(app) as client:
            workspace=client.post('/api/projects',json={'title':'Live Ollama QA'}).json()
            other=client.post('/api/projects',json={'title':'Isolation control'}).json()
            h={'X-GraphiSchema-Project':workspace['projectId'],'X-GraphiSchema-Branch':workspace['branchId']}
            oh={'X-GraphiSchema-Project':other['projectId'],'X-GraphiSchema-Branch':other['branchId']}
            before=client.get('/api/diagram',headers=h).json();other_before=client.get('/api/diagram',headers=oh).json()
            versions=client.get('/api/versions',headers=h).json()
            response=client.post('/api/ollama/generate',headers={**h,'If-Match':before['revision']},json={
                'settings':{'endpoint':'http://127.0.0.1:11434','model':args.model,'temperature':0,'num_ctx':8192,'timeout':args.timeout},
                'prompt':'Создай минимальную схему: ровно два узла с id client_qa (Клиент) и server_qa (Сервер), ровно одна связь с id http_qa от client_qa к server_qa с подписью HTTPS. Контейнеров нет. Используй допустимые значения JSON-схемы. Верни только JSON проекта.'})
            if response.status_code!=200: raise RuntimeError(f'Ollama generation HTTP {response.status_code}: {response.text[:1200]}')
            proposal=response.json();diagram=proposal['diagram']
            assert diagram['project']['id']==workspace['projectId'],'Model output changed workspace identity'
            assert {n['id'] for n in diagram['nodes']}=={'client_qa','server_qa'},'Unexpected generated nodes'
            assert len(diagram['edges'])==1 and diagram['edges'][0]['source']=='client_qa' and diagram['edges'][0]['target']=='server_qa','Unexpected generated connection'
            assert client.get('/api/diagram',headers=h).json()==before,'Preview changed the project'
            assert client.get('/api/versions',headers=h).json()==versions,'Preview changed history'
            applied=client.put('/api/diagram',headers={**h,'If-Match':before['revision']},json=diagram);applied.raise_for_status()
            assert applied.json()['branchId']==workspace['branchId']
            svg=client.get('/api/render.svg',headers=h);svg.raise_for_status()
            assert len([e for e in ET.fromstring(svg.text).iter() if e.get('data-node')])==2
            undone=client.post('/api/undo',headers={**h,'If-Match':applied.json()['revision']});undone.raise_for_status()
            assert undone.json()['diagram']==before['diagram']
            redone=client.post('/api/redo',headers={**h,'If-Match':undone.json()['revision']});redone.raise_for_status()
            assert redone.json()['diagram']==applied.json()['diagram']
            assert client.get('/api/diagram',headers=oh).json()==other_before,'Other project changed'
            result={'status':'passed','model':args.model,'nodes':2,'edges':1,'layout_engine':proposal['layout']['engine'],
                    'readonly_preview':True,'apply_undo_redo':True,'project_isolation':True,'temporary_repository':True,
                    'elapsed_seconds':round(perf_counter()-started,2)}
            args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
            print(json.dumps(result,ensure_ascii=False))

if __name__=='__main__':main()
