#!/usr/bin/env python3
"""Build a secret-free runtime dependency PCK; never archive the whole checkout.

Includes normal selected runtime imports, not editor state. Source bytes and all
packed dependencies are SHA256 recorded. An unresolved dependency fails closed.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import tempfile
from urllib.parse import unquote, urlsplit
import re
import shutil
import subprocess
from pathlib import Path

CODE_ROOTS=('common','core','client','assets','scenes','resources','server','addons/netfox','addons/netfox.extras','addons/netfox.internals','addons/netfox.noray')
TEXT_SUFFIXES={'.gd','.tscn','.tres','.cfg','.godot','.gdshader','.gdshaderinc','.shader','.json','.import','.gltf'}
NATIVE_SUFFIXES={'.res','.scn','.ctex','.stex','.mesh','.material','.anim','.tscn','.tres'}
REF=re.compile(r'(["\'])(\*?(?:res|uid)://(?:\\.|(?!\1).)+)\1')
TOKENS=re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\#[^\n]*')
FORBIDDEN={'.env','.git','docs','backend','tests','openspec','.atl','.gemini','.agents','.codex','noikar-noray'}
BUILTIN_TYPES=set('bool int float String StringName Array Dictionary Callable Signal Vector2 Vector2i Rect2 Rect2i Vector3 Vector3i Vector4 Vector4i Transform2D Transform3D Plane Quaternion AABB Basis Projection Color RID NodePath Variant void Error PackedByteArray PackedInt32Array PackedInt64Array PackedFloat32Array PackedFloat64Array PackedStringArray PackedVector2Array PackedVector3Array PackedVector4Array PackedColorArray'.split())


def runtime_files(repo):
    """Runtime candidate inventory, not a whole-repo payload."""
    result=[]
    for root,dirs,files in os.walk(repo):
        relative=Path(root).relative_to(repo)
        dirs[:]=[d for d in dirs if d not in FORBIDDEN and not d.startswith('.env')
                 and d not in ('editor','examples','node_modules')
                 and not (relative==Path('addons') and d=='gut')
                 and not (relative==Path('.godot') and d!='imported')]
        for name in files:
            if name.startswith('.env'):continue
            path=Path(root)/name
            if path.is_symlink():continue
            part=path.relative_to(repo)
            if part.parts[0]=='.godot' and (len(part.parts)<2 or part.parts[1]!='imported'):continue
            result.append(part.as_posix())
    return result


def uid_index(repo, candidates):
    index={}
    def record(uid,path):
        # Existing duplicate asset UIDs cannot select an arbitrary source. Keep
        # ambiguity explicit; native/text references must supply a valid fallback.
        if uid in index and index[uid]!=path:index[uid]=None
        else:index[uid]=path
    for path in candidates:
        source=repo/path
        if source.suffix=='.uid':
            record(source.read_text().strip(),path[:-4])
        elif source.suffix=='.import':
            match=re.search(r'^uid="(uid://[^"\n]+)"',source.read_text(),re.M)
            if match:record(match[1],path[:-7])
        elif source.suffix in ('.tscn','.tres'):
            first=source.read_text().splitlines()[0]
            match=re.search(r'uid="(uid://[^"\n]+)"',first)
            if match:record(match[1],path)
    return index


def script_registry(repo, candidates):
    classes={}
    for path in candidates:
        if not path.endswith('.gd'):continue
        text=(repo/path).read_text()
        name=re.search(r'^class_name\s+(\w+)',text,re.M)
        if not name or re.search(r'^extends\s+Editor\w*',text,re.M):continue
        if name[1] in classes:raise ValueError('duplicate runtime class: '+name[1])
        classes[name[1]]=path
    return classes


def resolve_dependency(value, uids):
    # Native API returns uid::type::fallback, path::type, or a plain path.
    fields=value.split('::')
    fallback=next((p for p in reversed(fields) if p.startswith('res://')),None)
    if fallback:return fallback[6:]
    uid=fields[0]
    if uid.startswith('uid://') and uids.get(uid):return uids[uid]
    raise ValueError('unresolved native/UID dependency: '+value)



def resource_literal(value):
    value=value.lstrip('*')
    # Godot source strings can escape either quote even when the other quote
    # delimits the literal (e.g. imported kog\'maw texture paths).
    return re.sub(r"\\([\\'\"])",lambda match:match[1],value)


def source_text(text, mask_strings=False):
    return TOKENS.sub(lambda match:'' if match[0].startswith('#') else ('""' if mask_strings else match[0]),text)


def gltf_dependencies(repo, path, data):
    document=json.loads(data)
    result=[]
    for item in document.get('images',[])+document.get('buffers',[]):
        uri=item.get('uri')
        if uri is None or uri.startswith('data:'):continue
        parsed=urlsplit(uri)
        if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or '\\' in uri:
            raise ValueError('non-local glTF dependency: '+path)
        target=os.path.normpath(str(Path(path).parent/unquote(parsed.path)))
        safe_resource(repo,target)  # Reject a missing file or repo/private escape.
        result.append(target)
    return result



def shader_source_text(text):
    """Keep resource string literals and directives; ignore C-style comments."""
    tokens = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*[\s\S]*?\*/')
    return tokens.sub(lambda match: match[0] if match[0].startswith('"') else '\n' * match[0].count('\n'), text)


def shader_dependencies(repo, path, text):
    result = []
    for line in shader_source_text(text).splitlines():
        if not re.match(r'^\s*#\s*include\b', line):
            continue
        match = re.fullmatch(r'\s*#\s*include\s+"([^"\r\n]+)"\s*', line)
        if match is None:
            raise ValueError('malformed shader include: ' + path)
        value = match[1]
        if value.startswith('res://'):
            target = value[6:]
        else:
            parsed = urlsplit(value)
            if parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or '\\' in value:
                raise ValueError('non-local shader include: ' + path)
            target = os.path.normpath(str(Path(path).parent / value))
        safe_resource(repo, target)
        result.append(target)
    return result


def preview_import_remaps(text):
    """Pure fixture/static preview only; export requires native ConfigFile values."""
    section=re.search(r'(?ms)^\[remap\]\s*\n(.*?)(?=^\[|\Z)',text)
    if not section:raise ValueError('missing import remap section')
    paths={}
    for line in section[1].splitlines():
        key=re.match(r'^\s*(path(?:\.[A-Za-z0-9_]+)?)\s*=',line)
        if not key:continue
        literal=REF.search(line)
        if literal is None:raise ValueError('invalid import remap value')
        paths[key[1]]=resource_literal(literal[2])
    return paths


def resource_text_without_uid_metadata(text, uids):
    """UID declarations are metadata; ext_resource pairs use their path fallback."""
    def header(match):
        row=match[0]
        uid=re.search(r'\buid="(uid://[^"\n]+)"',row)
        if not uid:return row
        if row.startswith('[ext_resource'):
            path=re.search(r'\bpath=("(?:\\.|[^"\\])*")',row)
            if not path:
                # No explicit fallback: a unique known UID is still required.
                dep=resolve_dependency(uid[1],uids)
                row=row[:-1]+' path='+json.dumps('res://'+dep)+']'
        return row.replace(uid[0],'uid=""',1)
    return re.sub(r'(?m)^\[(?:gd_scene|gd_resource|ext_resource)\b[^\n]*\]',header,text)


def native_dependency_scan(repo, godot, scratch):
    """One metadata-only native process, no original editor/import/autoload."""
    candidates=runtime_files(repo);uids=uid_index(repo,candidates)
    paths=sorted(p for p in candidates if Path(p).suffix in NATIVE_SUFFIXES)
    imports=sorted(p for p in candidates if p.endswith('.import'))
    scratch.mkdir(mode=0o700)
    (scratch/'project.godot').write_text('config_version=5\n')
    for path in [*paths,*imports]:
        target=scratch/path
        target.parent.mkdir(parents=True,exist_ok=True)
        target.symlink_to((repo/path).resolve())
    # Preserve only a minimal scratch project; scanner itself is not packaged.
    shutil.copyfile(Path(__file__).with_name('package_dependency_scan.gd'),scratch/'scan.gd')
    request=scratch/'request.json';output=scratch/'dependencies.json'
    request.write_text(json.dumps(dict(paths=paths,import_paths=imports,uids={k:v for k,v in uids.items() if v is not None})))
    result=subprocess.run([str(godot),'--headless','--path',str(scratch),'--script','res://scan.gd','--',str(request),str(output)],
        capture_output=True,text=True,timeout=40)
    (scratch/'scan.log').write_text(result.stdout+result.stderr)
    if result.returncode or re.search(r'(?:SCRIPT ERROR|ERROR:)',result.stdout+result.stderr) or not output.is_file():
        raise RuntimeError('native dependency metadata scan failed; no export')
    data=json.loads(output.read_text())
    if set(data['dependencies'])!=set(paths):raise ValueError('incomplete native dependency inventory')
    if set(data.get('import_remaps',{}))!=set(imports):raise ValueError('incomplete native import remap inventory')
    return data


def safe_resource(repo, relative):
    path=Path(relative)
    if path.is_absolute() or '..' in path.parts or any(part in FORBIDDEN or part.startswith('.env') for part in path.parts):
        raise ValueError('forbidden/non-runtime dependency')
    source=repo/path
    if source.is_symlink() or not source.resolve().is_relative_to(repo.resolve()) or not source.is_file():
        raise ValueError('missing/escaping dependency: '+str(path))
    if path.parts[0]=='.godot' and (len(path.parts)<2 or path.parts[1]!='imported'):
        raise ValueError('editor cache dependency refused')
    return source


def dependency_closure(repo, native_dependencies=None, builtin_classes=None, strict_native=False, import_remaps=None):
    candidates=runtime_files(repo);uids=uid_index(repo,candidates);registry=script_registry(repo,candidates)
    queue=['project.godot','tools/benchmark_profiles.json',*registry.values()]
    seen={}
    while queue:
        relative=queue.pop()
        if relative in seen:continue
        source=safe_resource(repo,relative);data=source.read_bytes();seen[relative]=hashlib.sha256(data).hexdigest()
        if source.suffix=='.import':
            if strict_native:
                if import_remaps is None or relative not in import_remaps:
                    raise ValueError('native import remap readback missing: '+relative)
                remaps=import_remaps[relative]
            else:
                remaps=preview_import_remaps(data.decode('utf-8'))
            if not isinstance(remaps,dict):raise ValueError('invalid import remap readback')
            for key,value in remaps.items():
                if key!='path' and not key.startswith('path.'):raise ValueError('non-remap key in native inventory')
                if not isinstance(value,str) or not value.startswith('res://'):raise ValueError('invalid native import remap value')
                # Native ConfigFile already decoded this value. Never apply a
                # blanket source-string normalization to native paths.
                queue.append(resolve_dependency(value,uids))
        elif source.suffix in TEXT_SUFFIXES:
            text=data.decode('utf-8')
            if source.suffix=='.gd':text=source_text(text)
            if source.suffix in ('.gdshader','.gdshaderinc','.shader'):
                queue.extend(shader_dependencies(repo,relative,text))
                text=shader_source_text(text)
            if source.suffix in ('.tscn','.tres'):text=resource_text_without_uid_metadata(text,uids)
            if source.name=='project.godot':text=re.sub(r'(?ms)^\[editor_plugins\]\n.*?(?=^\[|\Z)','',text)
            for match in REF.finditer(text):
                value=resource_literal(match[2])
                dep=resolve_dependency(value,uids)
                if (repo/dep).is_dir():continue
                queue.append(dep)
            # Relative quoted script inheritance is also a real dependency.
            if source.suffix=='.gd':
                parent=re.search(r'^extends\s+["\']([^"\']+)["\']',text,re.M)
                if parent and not parent[1].startswith(('res://','uid://')):
                    queue.append(os.path.normpath(str(Path(relative).parent/parent[1])))
            if source.suffix=='.gltf':queue.extend(gltf_dependencies(repo,relative,data))
        if source.suffix in NATIVE_SUFFIXES:
            if native_dependencies is not None and relative in native_dependencies:
                queue.extend(resolve_dependency(p,uids) for p in native_dependencies[relative])
            elif strict_native:raise ValueError('native dependency readback missing: '+relative)
        for suffix in ('.import','.uid'):
            descriptor=source.with_name(source.name+suffix)
            if descriptor.exists():queue.append(str(descriptor.relative_to(repo)))
    if sum((repo/p).stat().st_size for p in seen)>=1024**3:raise ValueError('dependency payload exceeds1GiB')
    class_cache(repo,seen,builtin_classes=builtin_classes)
    return seen


def class_cache(repo, paths, builtin_classes=None):
    registry=script_registry(repo,runtime_files(repo))
    project=(repo/'project.godot').read_text()
    autoload=re.search(r'(?ms)^\[autoload\]\n(.*?)(?=^\[|\Z)',project)
    autoload_names=set(re.findall(r'^([A-Za-z_]\w*)=',autoload[1],re.M)) if autoload else set()
    known=set(registry)|BUILTIN_TYPES|set(builtin_classes or ())|autoload_names
    entries=[]
    uids=uid_index(repo,runtime_files(repo))
    def resolve_base(text, relative, visiting=()):
        direct=re.search(r'^extends\s+(\w+)',text,re.M)
        if direct:
            base=direct[1]
            if base in registry and registry[base] not in paths:raise ValueError('class base omitted: '+base)
            if builtin_classes is not None and base not in known:raise ValueError('unresolved class base: '+base)
            return base
        quoted=re.search(r'^extends\s+["\']([^"\'\n]+)["\']',text,re.M)
        if quoted:
            parent_path=resolve_dependency(quoted[1],uids) if quoted[1].startswith(('res://','uid://')) else os.path.normpath(str(Path(relative).parent/quoted[1]))
            if parent_path in visiting:raise ValueError('cyclic script inheritance')
            if parent_path not in paths:raise ValueError('quoted class base omitted')
            parent=safe_resource(repo,parent_path).read_text()
            named=re.search(r'^class_name\s+(\w+)',parent,re.M)
            return named[1] if named else resolve_base(parent,parent_path,(*visiting,parent_path))
        return 'RefCounted'
    for name in sorted(paths):
        if not name.endswith('.gd'):continue
        text=(repo/name).read_text()
        base=resolve_base(text,name,(name,))
        if builtin_classes is not None:
            clean=source_text(text,mask_strings=True)
            local_names=set(re.findall(r'\b(?:class|enum|const)\s+(\w+)',clean))
            type_pattern=r'[A-Za-z_]\w*(?:\.\w+)*(?:\s*\[[\w.,\[\] ]+\])?'
            expressions=[]
            for prefix in (r'\bvar\s+\w+\s*:\s*',r'->\s*'):
                expressions.extend(re.findall(prefix+'('+type_pattern+')',clean))
            for arguments in re.findall(r'\b(?:func\s+\w+|signal\s+\w+|func)\s*\(([^)]*)\)',clean):
                expressions.extend(re.findall(r'(?:^|,)\s*\w+\s*:\s*('+type_pattern+')',arguments))
            for expression in expressions:
                for token in re.findall(r'[A-Za-z_]\w*(?:\.\w+)*',expression):
                    typ=token.split('.')[0]
                    if typ not in known|local_names:raise ValueError('unresolved named type: '+typ+' in '+name)
        klass=re.search(r'^class_name\s+(\w+)',text,re.M)
        if not klass:continue
        entries.append('{\n"base": &'+json.dumps(base)+',\n"class": &'+json.dumps(klass[1])+',\n"icon": "",\n"is_abstract": '+str(bool(re.search(r'^@abstract',text,re.M))).lower()+',\n"is_tool": '+str(bool(re.search(r'^@tool',text,re.M))).lower()+',\n"language": &"GDScript",\n"path": '+json.dumps('res://'+name)+'\n}')
    return 'list=['+', '.join(entries)+']\n'


def build(repo, destination, godot):
    if destination.exists():raise ValueError('destination must be new, outside project')
    if destination.resolve().is_relative_to(repo.resolve()):raise ValueError('do not stage into source checkout')
    destination.mkdir(mode=0o700,parents=True)
    version=subprocess.run([str(godot),'--version'],capture_output=True,text=True,check=True,timeout=5).stdout.strip()
    if version!='4.8.dev6.official.8898c2b3d':raise RuntimeError('matched local Godot required')
    native=native_dependency_scan(repo,godot,destination/'dependency-scan')
    hashes=dependency_closure(repo,native['dependencies'],native['builtin_classes'],strict_native=True,import_remaps=native.get('import_remaps'))
    source=destination/'source';source.mkdir()
    for relative,digest in hashes.items():
        original=safe_resource(repo,relative)
        output=source/relative;output.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,output)
        if hashlib.sha256(output.read_bytes()).hexdigest()!=digest:raise RuntimeError('source changed while staging')
    generated=source/'.godot/global_script_class_cache.cfg';generated.parent.mkdir(exist_ok=True)
    generated.write_text(class_cache(repo,hashes,builtin_classes=native['builtin_classes']))
    # Run this tiny packer in an empty scratch project: no gameplay, autoloads,
    # editor import, network or mutation of the selected original project.
    packer=destination/'packer';packer.mkdir();(packer/'project.godot').write_text('config_version=5\n')
    paths=list(sorted(hashes))+['.godot/global_script_class_cache.cfg']
    (packer/'files.json').write_text(json.dumps(paths))
    output=destination/'game.pck'
    script='''extends SceneTree
func _initialize() -> void:
 var p := PCKPacker.new()
 if p.pck_start(%s) != OK: quit(1); return
 var paths = JSON.parse_string(FileAccess.get_file_as_string("res://files.json"))
 for path in paths:
  if p.add_file("res://" + path, %s + "/" + path) != OK: quit(2); return
 if p.flush() != OK: quit(3); return
 quit(0)
'''%(json.dumps(str(output)),json.dumps(str(source)))
    (packer/'pack.gd').write_text(script)
    result=subprocess.run([str(godot),'--headless','--path',str(packer),'--script','res://pack.gd'],
                          stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=45)
    (destination/'pack.log').write_text(result.stdout)
    if result.returncode or not output.is_file() or output.stat().st_size>=1024**3:
        raise RuntimeError('PCK build failed/size limit')
    manifest=dict(schema=1,godot_version=version,source_sha256=hashes,
        generated_class_cache_sha256=hashlib.sha256(generated.read_bytes()).hexdigest(),
        pck_sha256=hashlib.sha256(output.read_bytes()).hexdigest(),pck_bytes=output.stat().st_size,
        excluded=['secrets/VCS/docs/backend/test infrastructure','editor state except generated runtime class registry'],
        native_dependency_metadata_sha256=hashlib.sha256(json.dumps(native,sort_keys=True).encode()).hexdigest(),
        native_scanned_resources=len(native['dependencies']),native_import_descriptors=len(native['import_remaps']),closure_policy='conservative runtime global classes + source/shader-includes/glTF/UID/import + native metadata transitive closure',
        limitation='Metadata closure does not prove Linux resource/script startup; actual Linux startup remains a required qualification gate')
    (destination/'manifest.json').write_text(json.dumps(manifest,indent=2))
    return manifest


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination',type=Path,required=True);parser.add_argument('--godot',type=Path,required=True)
    args=parser.parse_args();root=Path(__file__).resolve().parents[2]
    manifest=build(root,args.destination,args.godot)
    print(json.dumps({k:manifest[k] for k in ('pck_sha256','pck_bytes','godot_version')}))

if __name__=='__main__':main()
