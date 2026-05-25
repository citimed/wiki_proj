import os, re, io, json
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

SERVICE_ACCOUNT_FILE = 'github_credentials.json' 
GOOGLE_FOLDER_ID = os.environ.get('GOOGLE_FOLDER_ID') 

def parse_sql_header_and_relations(sql_text):
    header_match = re.search(r'-- ===+.*?-- ===+', sql_text, re.DOTALL)
    header_info, description = "", "Описание не указано"
    if header_match:
        raw_header = header_match.group(0)
        md_lines = []
        for line in raw_header.split('\n'):
            clean_line = re.sub(r'^--\s*', '', line).strip()
            if "===" in clean_line or not clean_line: continue
            md_lines.append(clean_line)
            if "Description:" in clean_line: description = clean_line.replace("Description:", "").strip()
        header_info = "\n".join(md_lines)
    sql_words = re.findall(r'(?:FROM|JOIN|INSERT\s+INTO|UPDATE)\s+([a-zA-Z0-9_.]+)', sql_text, re.IGNORECASE)
    dbo_entities = re.findall(r'(?:dbo)\.([a-zA-Z0-9_]+)', sql_text, re.IGNORECASE)
    all_entities = set()
    for entity in (sql_words + dbo_entities):
        clean_entity = entity.upper().replace('DBO.', '').strip()
        if clean_entity and not clean_entity.startswith('@') and clean_entity not in ['SELECT', 'WHERE', 'SET', 'VALUES']: all_entities.add(clean_entity)
    return header_info, sorted(list(all_entities)), description

def get_entity_type_info(root_path):
    normalized = root_path.replace('\\', '/').lower()
    if 'storedprocedure' in normalized or 'stored_procedure' in normalized: return 'stored_procedure', '⚙️'
    if 'tables' in normalized or 'table' in normalized: return 'table', '📊'
    if 'triggers' in normalized or 'trigger' in normalized: return 'trigger', '🪤'
    if 'views' in normalized or 'view' in normalized: return 'view', '👁️'
    return 'sql_script', '📝'

def generate_entity_md(name, header_info, tables, entity_type):
    relations_md = "\n".join([f"* **Связан с сущностью:** `[[{t}]]`" for t in tables]) if tables else "*Связи не найдены*"
    type_labels = {'stored_procedure': 'Хранимая процедура', 'table': 'Таблица данных', 'trigger': 'Триггер', 'view': 'Представление', 'sql_script': 'Скрипт'}
    icons = {'stored_procedure': '⚙️', 'table': '📊', 'trigger': '🪤', 'view': '👁️', 'sql_script': '📝'}
    return f"---\ntype: {entity_type}\ndb_version: MS SQL Server 2019\ndialect: T-SQL\n---\n\n# {icons.get(entity_type, '📦')} dbo.{name} ({type_labels.get(entity_type, 'Объект БД')})\n\n## 📄 Метаданные\n```text\n{header_info}\n```\n\n## 🔗 Связи\n{relations_md}"

def update_db_map_md(db_path, entity_registry):
    map_path = f'./wiki/{db_path}/{os.path.basename(db_path)}.md'
    os.makedirs(os.path.dirname(map_path), exist_ok=True)
    card_parts = ["---", "type: database_map", "---", f"# 🗺️ Архитектурная карта БД {os.path.basename(db_path)}", "", "Структура объектов:", ""]
    categories = {'table': ('📊 Таблицы', []), 'stored_procedure': ('⚙️ Процедуры', []), 'trigger': ('🪤 Триггеры', []), 'view': ('👁️ Представления', []), 'sql_script': ('📝 Скрипты', [])}
    for name, info in entity_registry.items():
        if info['type'] in categories: categories[info['type']][1].append((name, info['desc']))
    for ent_type, (title, items) in categories.items():
        if items:
            card_parts.append(f"## {title}")
            for name, desc in sorted(items, key=lambda x: x[0]): card_parts.append(f"* **[[{name}]]** — {desc}")
            card_parts.append("")
    with open(map_path, 'w', encoding='utf-8') as f: f.write("\n".join(card_parts))

def upload_or_update_google_doc(service, doc_name, html_content, target_folder_id):
    query = f"name = '{doc_name}' and '{target_folder_id}' in parents and mimeType = 'application/vnd.google-apps.document' and trashed = false"
    items = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute().get('files', [])
    media = MediaIoBaseUpload(io.BytesIO(html_content.encode('utf-8')), mimetype='text/html', resumable=False)
    if items:
        service.files().update(fileId=items[0]['id'], media_body=media, supportsAllDrives=True).execute()
        print(f"🔄 Обновлен: {doc_name}")
    else:
        meta = {'name': doc_name, 'mimeType': 'application/vnd.google-apps.document', 'parents': [target_folder_id]}
        service.files().create(body=meta, media_body=media, fields="id", supportsAllDrives=True).execute()
        print(f"📥 Создан: {doc_name}")

def get_or_create_drive_folder(service, folder_name, parent_id):
    query = f"name = '{folder_name}' and '{parent_id}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    items = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute().get('files', [])
    if items: return items[0]['id']
    meta = {'name': folder_name, 'mimeType': 'application/vnd.google-apps.folder', 'parents': [parent_id]}
    return service.files().create(body=meta, fields='id', supportsAllDrives=True).execute()['id']

def convert_markdown_to_basic_html(md_text, title):
    html = []
    for line in md_text.split('\n'):
        if line.startswith('# '): html.append(f"<h1>{line[2:]}</h1>")
        elif line.startswith('## '): html.append(f"<h2>{line[3:]}</h2>")
        elif line.startswith('* '): html.append(f"<li>{line[2:]}</li>")
        elif line.strip() == "": html.append("<br/>")
        else: html.append(f"<p>{line}</p>")
    return f"<html><body><h1>📝 Модуль: {title}</h1>{''.join(html)}</body></html>"

def main():
    # --- НАШ ДИАГНОСТИЧЕСКИЙ ЩИТ ---
    if not os.path.exists(SERVICE_ACCOUNT_FILE):
        print(f"❌ КРИТИЧЕСКАЯ ОШИБКА: Файл {SERVICE_ACCOUNT_FILE} не найден!")
        return
    print(f"📦 Размер файла ключа: {os.path.getsize(SERVICE_ACCOUNT_FILE)} байт.")
    try:
        with open(SERVICE_ACCOUNT_FILE, 'r', encoding='utf-8') as f:
            content = f.read().strip()
            if not content:
                print("❌ КРИТИЧЕСКАЯ ОШИБКА: Файл ключа ПУСТОЙ!")
                return
            json.loads(content)
    except json.JSONDecodeError as je:
        print(f"❌ КРИТИЧЕСКАЯ ОШИБКА: Невалидный JSON! Начало: {content[:30]}... Ошибка: {je}")
        return

    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=['https://www.googleapis.com/auth/drive'])
    service = build('drive', 'v3', credentials=creds)
    changed_files = json.loads(os.environ.get('CHANGED_FILES_JSON', '[]'))
    if not changed_files: return

    print(f"🚀 Измененных файлов: {len(changed_files)}")
    databases_to_rebuild = set()
    
    for file_path in changed_files:
        file_path = os.path.normpath(file_path)
        if file_path.startswith('wiki' + os.sep) or file_path.startswith('.github'): continue
        parts = file_path.split(os.sep)
        if len(parts) >= 3 and parts[0] == 'DB':
            databases_to_rebuild.add(os.path.join('DB', parts[1]))
            continue
        if file_path.endswith('.md') and os.path.exists(file_path):
            parent_dir = os.path.dirname(file_path)
            if parent_dir and os.path.basename(file_path).replace('.md', '') == os.path.basename(parent_dir):
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f: md_content = f.read()
                w_path = os.path.join('wiki', file_path)
                os.makedirs(os.path.dirname(w_path), exist_ok=True)
                with open(w_path, 'w', encoding='utf-8') as f: f.write(md_content)
                f_id = GOOGLE_FOLDER_ID
                for part in parent_dir.split(os.sep): f_id = get_or_create_drive_folder(service, part, f_id)
                upload_or_update_google_doc(service, os.path.basename(file_path).replace('.md', ''), convert_markdown_to_basic_html(md_content, os.path.basename(file_path).replace('.md', '')), f_id)

    for db_path in databases_to_rebuild:
        db_name = os.path.basename(db_path)
        print(f"⚙️ Монолит для базы: {db_name}")
        db_registry, db_monolith_data = {}, {'table': [], 'stored_procedure': [], 'trigger': [], 'view': [], 'sql_script': []}
        
        for root, _, files in os.walk(os.path.normpath(f'./{db_path}')):
            for file in files:
                if file.endswith('.sql'):
                    e_name = file.replace('.sql', '')
                    if e_name in db_registry: continue
                    e_type, _ = get_entity_type_info(root)
                    sql_content = None
                    for enc in ['utf-8', 'utf-16', 'windows-1251']:
                        try:
                            with open(os.path.join(root, file), 'r', encoding=enc) as f: sql_content = f.read()
                            break
                        except Exception: pass
                    if sql_content is None: continue
                    h_info, tables, desc = parse_sql_header_and_relations(sql_content)
                    db_registry[e_name] = {'type': e_type, 'desc': desc}
                    l_dir = os.path.normpath(os.path.join('wiki', os.path.relpath(root, '.')))
                    os.makedirs(l_dir, exist_ok=True)
                    with open(os.path.join(l_dir, f"{e_name}.md"), 'w', encoding='utf-8') as mf: mf.write(generate_entity_md(e_name, h_info, tables, e_type))
                    db_monolith_data[e_type].append({'name': e_name, 'header_info': h_info, 'tables': tables, 'desc': desc})
                    
        if db_registry:
            update_db_map_md(db_path, db_registry)
            titles = {'table': '📊 Таблицы данных', 'stored_procedure': '⚙️ Хранимые процедуры', 'trigger': '🪤 Триггеры', 'view': '👁️ Представления', 'sql_script': '📝 Скрипты'}
            html = [f"<html><body><h1>🗺️ Архитектура БД {db_name}</h1>"]
            for t, tl in titles.items():
                if db_monolith_data[t]:
                    html.append(f"<h3>{tl}</h3><ul>")
                    for x in sorted(db_monolith_data[t], key=lambda i: i['name']): html.append(f"<li><b><a href='#e_{x['name']}'>{x['name']}</a></b> — {x['desc']}</li>")
                    html.append("</ul>")
            html.append("<hr/>")
            for t, tl in titles.items():
                if db_monolith_data[t]:
                    html.append(f"<h1>{tl}</h1>")
                    for x in sorted(db_monolith_data[t], key=lambda i: i['name']):
                        html.append(f"<div id='e_{x['name']}' style='margin-bottom:30px;'><h2>dbo.{x['name']}</h2><pre style='background:#f4f4f4;padding:10px;'>{x['header_info']}</pre>")
                        if x['tables']: html.append("<ul>" + "".join([f"<li>Связан с: <a href='#e_{s}'>{s}</a></li>" for s in x['tables']]) + "</ul>")
                        else: html.append("<p><i>Связи не найдены</i></p>")
                        html.append("</div>")
            html.append("</body></html>")
            upload_or_update_google_doc(service, db_name, "\n".join(html), get_or_create_drive_folder(service, 'DB', GOOGLE_FOLDER_ID))

if __name__ == '__main__':
    main()
