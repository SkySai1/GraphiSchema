"""Render every bundled figure using the production model, layout and SVG scene."""
import argparse
import csv
import json
import shutil
import subprocess
from pathlib import Path
import sys
from xml.etree import ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'backend'))
from graphischema.geometry import icon_library
from graphischema.layout import compute_layout
from graphischema.models import DiagramProject
from graphischema.scene_renderer import render_scene


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--output',type=Path,default=ROOT/'dist/quality/figures')
    output=parser.parse_args().output;output.mkdir(parents=True,exist_ok=True)
    rows=[]
    for name,geometry in sorted(icon_library().items()):
        rows.append({'icon':name,'strokes':len(geometry['paths']),'fill_parts':len(geometry['fill_paths']),
                     'vertices':len(geometry['vertices']),'aspect_ratio':geometry['aspect_ratio']})
    with (output/'audit.csv').open('w') as stream:
        writer=csv.DictWriter(stream,fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)
    for theme in ['light','dark']:
        nodes=[]
        for index,row in enumerate(rows):
            nodes.append({'id':f'figure_{index}','label':'X','icon':row['icon'],'x':index%9*2.2,'y':-(index//9)*2.3,
                          'style':{'fill':'#FFE0A080','stroke':'#A855F7' if theme=='dark' else '#6520A0','text':'#00000000'}})
        project=DiagramProject.model_validate({'diagram':{'layout_mode':'manual'},'presentation':{'theme':theme},'nodes':nodes})
        layout=compute_layout(project);scene=ET.fromstring(render_scene(project,layout))
        for index,(node,geometry) in enumerate(zip(project.nodes,layout['nodes'])):
            x=(geometry['x']-layout['minX'])*72+28
            y=(layout['minY']+layout['height']-geometry['y'])*72+28+geometry['height']*36+14
            text=ET.SubElement(scene,'{http://www.w3.org/2000/svg}text',{'x':str(x),'y':str(y),'fill':'#FFFFFF' if theme=='dark' else '#172238','font-family':'Arial','font-size':'9','text-anchor':'middle'})
            text.text=f'{index+1}. {rows[index]["icon"].split("/")[-1]}'
        svg=output/f'{theme}.svg';ET.ElementTree(scene).write(svg,encoding='unicode')
        binary=shutil.which('rsvg-convert')
        if binary:subprocess.run([binary,str(svg),'-o',str(output/f'{theme}.png')],check=True)
    print(json.dumps({'figures':len(rows),'wire_only':[r['icon'] for r in rows if not r['fill_parts']],'output':str(output)},ensure_ascii=False))

if __name__=='__main__':main()
