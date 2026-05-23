import os
import re
import io
import json
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

SERVICE_ACCOUNT_FILE = 'github_credentials.json' 
GOOGLE_FOLDER_ID = os.environ.get('GOOGLE_FOLDER_ID') 

def parse_sql_header_and_relations(sql_text):
    header_match = re.search(r'-- ===+.*?-- ===+', sql_text, re.DOTALL)
    header_info = ""
    description = "Описание не указано"
    
    if header_match:
        raw_header = header_match.group(0)
        md_lines = []
        for line in raw_header.split('\n'):
            clean_line = re.sub(r'^--\s*', '', line).strip()
            if "===" in clean_line or not clean_line:
                continue
            md_lines.append(clean_line)
            if "Description:" in clean_line:
                description = clean_line.replace("Description:", "").strip()
                
        header_info = "\n".join(md_lines)
    
    sql_words = re.findall(r'(?:FROM|JOIN|INSERT\s+INTO|UPDATE)\s+([a-zA-Z0-9_.]+)', sql_text, re.IGNORECASE)
    dbo_entities = re.findall(r'(?:dbo)\.([a-zA-Z0-9_]+)', sql_text, re.IGNORECASE)
    
    all_entities = set()
    for entity in (sql_words + dbo_entities):
        clean_entity = entity.upper().replace('DBO.', '').strip()
        if clean_entity and not clean_entity.startswith('@') and clean_entity not in ['SELECT', 'WHERE', 'SET', 'VALUES']:
            all_entities.add(clean_entity)
            
    return header_info, sorted(list(all_entities)), description

def get_entity_type_info(root_path):
    normalized = root_path.replace('\\', '/').lower()
    if 'storedprocedure' in normalized or 'stored_procedure' in normalized:
        return 'stored_procedure', '⚙️'
    elif 'tables' in normalized or 'table' in normalized:
        return 'table', '📊'
    elif 'triggers' in normalized or 'trigger' in normalized:
        return 'trigger', '🪤'
    elif 'views' in normalized or 'view' in normalized:
        return 'view', '👁️'
    else:
        return 'sql_script', '📝'

def generate_entity_md(name, header_info, tables, entity_type):
    if tables:
        relations_md = "\n".join([f"* **Связан с сущностью:** `[[{t}]]`" for t in tables])
    else:
        relations_md = "*Связи не найдены*"
        
    type_labels_ru = {
        'stored_procedure': 'Хранимая процедура', 'table': 'Таблица данных',
        'trigger': 'Триггер', 'view': 'Представления (Views)', 'sql_script': 'Скрипт'
    }
    current_type_ru = type_labels_ru.get(entity_type, 'Объект БД')
    icons = {'stored_procedure': '⚙️', 'table': '📊', 'trigger': '🪤', 'view': '👁️', 'sql_script': '📝'}
    icon = icons.get(entity_type, '📦')
        
    parts = [
        "---", f"type: {entity_type}", "db_version: MS SQL Server 2019", "dialect: T-SQL", "---", "",
        f"# {icon} dbo.{name} ({current_type_ru})", "",
        "## 📄 Метаданные и Описание", "```text", f"{header_info}", "```", "",
        "## 🔗 Автоматически найденные связи", f"{relations_md}"
    ]
    return "\n".join(parts)

def update_db_map_md(db_path, entity_registry):
    map_path = f'./wiki/{db_path}/{os.path.basename(db_path)}.md'
    os.makedirs(os.path.dirname(map_path), exist_ok=True)
    
    db_name = os.path.basename(db_path)
    card_parts = [
        "---", "type: database_map", "---",
        f"# 🗺️ Архитектурная карта базы данных {db_name}", "",
        f"Здесь находится автоматическая структура всех объектов базы данных {db_name}.", ""
    ]
    categories = {
        'table': ('📊 Таблицы данных', []), 'stored_procedure': ('⚙️ Хранимые процедуры', []),
        'trigger': ('🪤 Триггеры', []), 'view': ('👁️ Представления (Views)', []), 'sql_script': ('📝 Прочие скрипты', [])
    }
    for name, info in entity_registry.items():
        ent_type = info['type']
        desc = info['desc']
        if ent_type in categories: categories[ent_type][1].append((name, desc))
            
    for ent_type, (title, items) in categories.items():
        if items:
            card_parts.append(f"## {title}")
            for name, desc in sorted(items, key=lambda x: x[0]):
                card_parts.append(f"* **[[{name}]]** — {desc}")
            card_parts.append("")
    content = "\n".join(card_parts)
    with open(map_path, 'w', encoding='utf-8') as f: f.write(content)

def upload_or_update_google_doc(service, doc_name, html_content, target_folder_id):
    query = f"name = '{doc_name}' and '{target_folder_id}' in parents and mimeType = 'application/vnd.google-apps.document' and trashed = false"
    results = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
    items = results.get('files', [])

    file_stream = io.BytesIO(html_content.encode('utf-8'))
    media = MediaIoBaseUpload(file_stream, mimetype='text/html', resumable=False)

    if items:
        file_id = items[0]['id']
        service.files().update(fileId=file_id, media_body=media, supportsAllDrives=True).execute()
        print(f"🔄 Документ обновлен на Диске: {doc_name}")
    else:
        file_metadata = {
            'name': doc_name, 'mimeType': 'application/vnd.google-apps.document', 'parents': [target_folder_id]
        }
        service.files().create(body=file_metadata, media_body=media, fields="id", supportsAllDrives=True).execute()
        print(f"📥 Создан новый документ на Диске: {doc_name}")

def get_or_create_drive_folder(service, folder_name, parent_id):
    query = f"name = '{folder_name}' and '{parent_id}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    results = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
    items = results.get('files', [])
    if items: return items[0]['id']
        
    folder_metadata = {'name': folder_name, 'mimeType': 'application/vnd.google-apps.folder', 'parents': [parent_id]}
    folder = service.files().create(body=folder_metadata, fields='id', supportsAllDrives=True).execute()
    return folder['id']

def convert_markdown_to_basic_html(md_text, title):
    html_lines = []
    for line in md_text.split('\n'):
        if line.startswith('# '): html_lines.append(f"<h1>{line[2:]}</h1>")
        elif line.startswith('## '): html_lines.append(f"<h2>{line[3:]}</h2>")
        elif line.startswith('### '): html_lines.append(f"<h3>{line[4:]}</h3>")
        elif line.startswith('* '): html_lines.append(f"<li>{line[2:]}</li>")
        elif line.strip() == "": html_lines.append("<br/>")
        else: html_lines.append(f"<p>{line}</p>")
    return f"<html><body><h1>📝 Модуль: {title}</h1>{"".join(html_lines)}</body></html>"

def main():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=['https://www.googleapis.com/auth/drive'])
    service = build('drive', 'v3', credentials=creds)
    
    changed_files_raw = os.environ.get('CHANGED_FILES_JSON', '[]')
    try:
        changed_files = json.loads(changed_files_raw)
    except Exception:
        print("⚠️ Ошибка парсинга JSON измененных файлов.")
        return

    if not changed_files:
        print("💡 Изменений нет.")
        return

    print(f"🚀 Найдено измененных файлов: {len(changed_files)}")
    
    # Набор баз данных, внутри которых что-то поменялось (динамически вычисляется из путей DB/*)
    databases_to_rebuild = set()
    
    for file_path in changed_files:
        file_path = os.path.normpath(file_path)
        
        # Игнорируем саму папку wiki и экшены github
        if file_path.startswith('wiki' + os.sep) or file_path.startswith('.github'):
            continue
            
        # Папка и имя файла для проверки условий
        parts = file_path.split(os.sep)
        
        # ЛОГИКА 1: Изменения внутри каталога базы данных (DB/[имя_базы]/**)
        if len(parts) >= 3 and parts[0] == 'DB':
            db_folder_name = parts[1] # например 'MAIN_DB' или 'AP_DB'
            db_relative_path = os.path.join('DB', db_folder_name)
            databases_to_rebuild.add(db_relative_path)
            print(f"🎯 Изменение в БД обнаружено: {file_path}. Запланирован монолит для {db_folder_name}.")
            continue

        # ЛОГИКА 2: Изменение обычного описания модуля ([folder_name].md)
        if file_path.endswith('.md') and os.path.exists(file_path):
            parent_dir = os.path.dirname(file_path)
            folder_name = os.path.basename(parent_dir) if parent_dir else ""
            file_name_without_ext = os.path.basename(file_path).replace('.md', '')
            
            # Проверяем строгое условие: имя файла совпадает с именем его каталога
            if folder_name and file_name_without_ext == folder_name:
                print(f"📄 Корневой модуль найден: {file_path}. Запуск пофайловой синхронизации.")
                
                with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
                    md_content = f.read()
                    
                # Копируем локально в wiki/ по структуре репозитория
                wiki_target_path = os.path.join('wiki', file_path)
                os.makedirs(os.path.dirname(wiki_target_path), exist_ok=True)
                with open(wiki_target_path, 'w', encoding='utf-8') as f:
                    f.write(md_content)
                
                # Создаем структуру папок на Google Диске
                current_drive_folder_id = GOOGLE_FOLDER_ID
                if parent_dir:
                    for part in parent_dir.split(os.sep):
                        current_drive_folder_id = get_or_create_drive_folder(service, part, current_drive_folder_id)
                
                html_doc_content = convert_markdown_to_basic_html(md_content, file_name_without_ext)
                upload_or_update_google_doc(service, file_name_without_ext, html_doc_content, current_drive_folder_id)

    # ВЫПОЛНЕНИЕ СБОРКИ МОНОЛИТОВ ДЛЯ БАЗ ДАННЫХ
    for db_path in databases_to_rebuild:
        db_name = os.path.basename(db_path) # Чистое имя, например 'MAIN_DB'
        print(f"⚙️ Сборка монолитного документа для базы: {db_name} из папки {db_path}")
        
        base_db_path = os.path.normpath(f'./{db_path}')
        db_registry = {}
        db_monolith_data = {'table': [], 'stored_procedure': [], 'trigger': [], 'view': [], 'sql_script': []}
        
        for root, dirs, files in os.walk(base_db_path):
            for file in files:
                if file.endswith('.sql'):
                    entity_name = file.replace('.sql', '')
                    if entity_name in db_registry: continue
                    
                    entity_type, icon = get_entity_type_info(root)
                    
                    file_full_path = os.path.join(root, file)
                    sql_content = None
                    for encoding_variant in ['utf-8', 'utf-16', 'windows-1251']:
                        try:
                            with open(file_full_path, 'r', encoding=encoding_variant) as f:
                                sql_content = f.read()
                            break
                        except Exception: continue
                    
                    if sql_content is None: continue
                    
                    header_info, tables, description = parse_sql_header_and_relations(sql_content)
                    db_registry[entity_name] = {'type': entity_type, 'desc': description}
                    
                    # Локально пишем в wiki/DB/[имя_базы]/...
                    local_md_dir = os.path.normpath(os.path.join('wiki', os.path.relpath(root, '.')))
                    os.makedirs(local_md_dir, exist_ok=True)
                    md_content = generate_entity_md(entity_name, header_info, tables, entity_type)
                    with open(os.path.join(local_md_dir, f"{entity_name}.md"), 'w', encoding='utf-8') as md_f:
                        md_f.write(md_content)
                        
                    db_monolith_data[entity_type].append({
                        'name': entity_name, 'header_info': header_info, 'tables': tables, 'desc': description
                    })
                    
        if db_registry:
            update_db_map_md(db_path, db_registry)
            
            type_titles_ru = {
                'table': '📊 Таблицы данных', 'stored_procedure': '⚙️ Хранимые процедуры',
                'trigger': '🪤 Триггеры', 'view': '👁️ Представления (Views)', 'sql_script': '📝 Прочие скрипты'
            }
            icons = {'stored_procedure': '⚙️', 'table': '📊', 'trigger': '🪤', 'view': '👁️', 'sql_script': '📝'}
            
            html_parts = [f"<html><body><h1>🗺️ Архитектура базы данных {db_name}</h1>"]
            html_parts.append("<h2>🗺️ Интерактивная карта базы данных</h2><ul>")
            
            for ent_type, title in type_titles_ru.items():
                items = db_monolith_data[ent_type]
                if items:
                    html_parts.append(f"<h3>{title}</h3><ul>")
                    for item in sorted(items, key=lambda x: x['name']):
                        html_parts.append(f"<li><b><a href='#entity_{item['name']}'>{item['name']}</a></b> — {item['desc']}</li>")
                    html_parts.append("</ul>")
            
            html_parts.append("<hr style='border: 2px solid #333; margin: 40px 0;'>")
            
            for ent_type, title in type_titles_ru.items():
                items = db_monolith_data[ent_type]
                if items:
                    html_parts.append(f"<h1 style='color: #1a5f7a;'>{title}</h1>")
                    for item in sorted(items, key=lambda x: x['name']):
                        html_parts.append(f"<div id='entity_{item['name']}' style='margin-bottom: 50px;'>")
                        html_parts.append(f"<h2>{icons.get(ent_type, '📦')} dbo.{item['name']}</h2>")
                        html_parts.append(f"<pre style='background-color: #f8f9fa; padding: 15px; border: 1px solid #e2e8f0; font-family: monospace; white-space: pre-wrap;'>{item['header_info']}</pre>")
                        html_parts.append("<h3>🔗 Автоматически найденные связи</h3>")
                        if item['tables']:
                            html_parts.append("<ul>")
                            for t in item['tables']:
                                html_parts.append(f"<li><b>Связан с сущностью:</b> <a href='#entity_{t}'>{t}</a></li>")
                            html_parts.append("</ul>")
                        else:
                            html_parts.append("<p><i>Связи не найдены</i></p>")
                        html_parts.append("</div>")
            html_parts.append("</body></html>")
            
            # Создаем или находим папку 'DB' на Google Диске, чтобы монолиты лежали там красиво
            db_drive_folder_id = get_or_create_drive_folder(service, 'DB', GOOGLE_FOLDER_ID)
            upload_or_update_google_doc(service, db_name, "\n".join(html_parts), db_drive_folder_id)

if __name__ == '__main__':
    main()
