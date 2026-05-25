import os
import sys
import json
import shutil
import re
import io
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build

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

def update_db_map_md(db_folder, entity_registry, WIKI_BASE):
    map_path = os.path.join(WIKI_BASE, 'DB', db_folder, f"{db_folder}.md")
    os.makedirs(os.path.dirname(map_path), exist_ok=True)
    card_parts = ["---", "type: database_map", "---", f"# 🗺️ Архитектурная карта БД {db_folder}", "", "Структура объектов:", ""]
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
        print(f"🔄 Обновлен в Drive: {doc_name}")
    else:
        meta = {'name': doc_name, 'mimeType': 'application/vnd.google-apps.document', 'parents': [target_folder_id]}
        service.files().create(body=meta, media_body=media, fields="id", supportsAllDrives=True).execute()
        print(f"📥 Создан в Drive: {doc_name}")

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
    if not os.path.exists(SERVICE_ACCOUNT_FILE): 
        print(f"❌ Файл ключей {SERVICE_ACCOUNT_FILE} не найден.")
        return
        
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=['https://www.googleapis.com/auth/drive'])
    service = build('drive', 'v3', credentials=creds)
    
    BASE_DIR = os.getcwd()
    WIKI_BASE = os.path.join(BASE_DIR, 'wiki')
    
    # =========================================================================
    # 🔥 ТОТАЛЬНАЯ ОЧИСТКА МУСОРА ПЕРЕД ЗАПУСКОМ
    # =========================================================================
    if os.path.exists(WIKI_BASE):
        print("🧹 Обнаружен старый кэш локальной вики. Полная очистка мусора...")
        shutil.rmtree(WIKI_BASE)
    
    os.makedirs(WIKI_BASE, exist_ok=True)
    print("✨ Создана чистая папка wiki. Начинаем полную сборку...")
    
    # Получаем имя текущего проекта (название корневой папки репозитория, например, WIKI_PROJ)
    project_name = os.path.basename(BASE_DIR)
    
    # Для Google Диска нам все еще нужен список реально измененных файлов, чтобы не спамить API
    changed_files = json.loads(os.environ.get('CHANGED_FILES_JSON', '[]'))
    changed_files_norm = [os.path.normpath(f) for f in changed_files]
    
    # =========================================================================
    # 1. ТОТАЛЬНОЕ СКАНИРОВАНИЕ И СБОРКА ВСЕХ MD-МОДУЛЕЙ ПРОЕКТА
    # =========================================================================
    print("📂 Сканирование репозитория на наличие md-модулей...")
    
    for root, dirs, files in os.walk(BASE_DIR):
        # Пропускаем служебные каталоги, чтобы не уйти в бесконечный цикл
        if 'wiki' in dirs: dirs.remove('wiki')
        if '.github' in dirs: dirs.remove('.github')
        if '.git' in dirs: dirs.remove('.git')
        
        for file in files:
            if not file.endswith('.md'):
                continue
                
            # Вычисляем относительный путь файла от корня репозитория
            full_path = os.path.join(root, file)
            rel_file_path = os.path.relpath(full_path, BASE_DIR)
            parent_dir = os.path.dirname(rel_file_path)
            file_base_name = file.replace('.md', '')
            
            # Проверяем условия валидности модуля:
            # 1. Имя файла совпадает с именем подпапки (стандартные модули)
            # 2. Это файл DB.md в корне каталога DB
            # 3. Это файл в самом корне репозитория, и его имя совпадает с именем проекта (например, WIKI_PROJ.md)
            is_valid_module = parent_dir and file_base_name == os.path.basename(parent_dir)
            is_root_db_md = (rel_file_path == f"DB{os.sep}DB.md" or rel_file_path == "DB/DB.md")
            is_project_root_md = (not parent_dir and file_base_name == project_name)
            
            if is_valid_module or is_root_db_md or is_project_root_md:
                print(f"📝 Локальная сборка md-модуля: {rel_file_path}")
                
                with open(full_path, 'r', encoding='utf-8', errors='ignore') as f: 
                    md_content = f.read()
                
                # ВСЕГДА пишем в локальную вики, спасая от очистки shutil.rmtree
                w_path = os.path.join(WIKI_BASE, rel_file_path)
                os.makedirs(os.path.dirname(w_path), exist_ok=True)
                with open(w_path, 'w', encoding='utf-8') as f: 
                    f.write(md_content)
                
                # А на Google Диск отправляем ТОЛЬКО если файл был реально изменен в коммите!
                if rel_file_path in changed_files_norm:
                    print(f"📥 Обновление md-модуля на Google Диск: {rel_file_path}")
                    f_id = GOOGLE_FOLDER_ID
                    if parent_dir:
                        for part in parent_dir.split(os.sep): 
                            f_id = get_or_create_drive_folder(service, part, f_id)
                            
                    upload_or_update_google_doc(
                        service, 
                        file_base_name, 
                        convert_markdown_to_basic_html(md_content, file_base_name), 
                        f_id
                    )

    # =========================================================================
    # 2. ПОЛНОЕ СКАНИРОВАНИЕ КАТАЛОГА DB И ГЕНЕРАЦИЯ СТРУКТУРЫ СВЯЗЕЙ SQL
    # =========================================================================
    db_root_path = os.path.join(BASE_DIR, 'DB')
    if os.path.exists(db_root_path):
        print("🔍 Запуск тотального сканирования каталога DB...")
        
        drive_db_root_id = get_or_create_drive_folder(service, 'DB', GOOGLE_FOLDER_ID)
        
        for db_folder in os.listdir(db_root_path):
            db_path = os.path.join(db_root_path, db_folder)
            if not os.path.isdir(db_path): 
                continue
            
            print(f"⚙️ Сборка документации для базы данных: {db_folder}")
            db_registry = {}
            db_monolith_data = {'table': [], 'stored_procedure': [], 'trigger': [], 'view': [], 'sql_script': []}
            
            for root, _, files in os.walk(db_path):
                for file in files:
                    if file.endswith('.sql'):
                        e_name = file.replace('.sql', '')
                        if e_name in db_registry: 
                            continue
                        e_type, _ = get_entity_type_info(root)
                        
                        sql_content = None
                        for enc in ['utf-8', 'utf-16', 'windows-1251']:
                            try:
                                with open(os.path.join(root, file), 'r', encoding=enc) as f: 
                                    sql_content = f.read()
                                break
                            except Exception: 
                                pass
                        if sql_content is None: 
                            continue
                        
                        h_info, tables, desc = parse_sql_header_and_relations(sql_content)
                        db_registry[e_name] = {'type': e_type, 'desc': desc}
                        
                        rel_root = os.path.relpath(root, BASE_DIR)
                        l_dir = os.path.normpath(os.path.join(WIKI_BASE, rel_root))
                        os.makedirs(l_dir, exist_ok=True)
                        with open(os.path.join(l_dir, f"{e_name}.md"), 'w', encoding='utf-8') as mf: 
                            mf.write(generate_entity_md(e_name, h_info, tables, e_type))
                        
                        db_monolith_data[e_type].append({'name': e_name, 'header_info': h_info, 'tables': tables, 'desc': desc})
            
            if db_registry:
                update_db_map_md(db_folder, db_registry, WIKI_BASE)
                
                titles = {'table': '📊 Таблицы данных', 'stored_procedure': '⚙️ Хранимые процедуры', 'trigger': '🪤 Триггеры', 'view': '👁️ Представления', 'sql_script': '📝 Скрипты'}
                
                html = [f"<html><body><h1>🗺️ Архитектурная карта и монолит БД: {db_folder}</h1>"]
                html.append("<h2>📍 Быстрая навигация по объектам</h2>")
                for t, tl in titles.items():
                    if db_monolith_data[t]:
                        html.append(f"<h3>{tl}</h3><ul>")
                        for x in sorted(db_monolith_data[t], key=lambda i: i['name']): 
                            html.append(f"<li><b><a href='#e_{x['name']}'>{x['name']}</a></b> — <span style='color:#555;'>{x['desc']}</span></li>")
                        html.append("</ul>")
                html.append("<br/><hr style='border:1px solid #ddd;'/><br/>")
                
                for t, tl in titles.items():
                    if db_monolith_data[t]:
                        html.append(f"<h1 style='color:#1a73e8; border-bottom:2px solid #1a73e8; padding-bottom:5px;'>{tl}</h1>")
                        for x in sorted(db_monolith_data[t], key=lambda i: i['name']):
                            html.append(f"<div id='e_{x['name']}' style='margin-bottom:40px; padding:15px; border-left:4px solid #1a73e8; background:#fafafa;'>")
                            html.append(f"<h2>dbo.{x['name']}</h2>")
                            html.append(f"<p><b>Описание бизнес-логики:</b> {x['desc']}</p>")
                            html.append(f"<h3>📄 Метаданные из заголовка:</h3>")
                            html.append(f"<pre style='background:#f4f4f4; padding:12px; border:1px solid #ddd; font-family:Courier,monospace;'>{x['header_info'].strip()}</pre>")
                            html.append(f"<h3>🔗 Архитектурные связи:</h3>")
                            if x['tables']: 
                                html.append("<ul style='margin-top:5px;'>")
                                for s in x['tables']:
                                    html.append(f"<li>Использует объект: <a href='#e_{s}'><b>{s}</b></a></li>")
                                html.append("</ul>")
                            else: 
                                html.append("<p style='color:#777; font-style:italic;'>Объект изолирован (прямых связей не обнаружено)</p>")
                            html.append("</div>")
                html.append("</body></html>")
                
                target_subfolder_id = get_or_create_drive_folder(service, db_folder, drive_db_root_id)
                
                upload_or_update_google_doc(
                    service, 
                    db_folder, 
                    "\n".join(html), 
                    target_subfolder_id
                )
                print(f"📥 Монолит базы {db_folder} успешно сохранен по пути: DB/{db_folder}/{db_folder}")

if __name__ == '__main__':
    main()
