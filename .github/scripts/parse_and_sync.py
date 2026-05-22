import os
import re
import io
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

SERVICE_ACCOUNT_FILE = 'github_credentials.json' 
GOOGLE_FOLDER_ID = os.environ.get('GOOGLE_FOLDER_ID') 

TARGET_DATABASES = ['MAIN_DB', 'AP_DB']

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
        return 'stored_procedure', '⚙️', 'Хранимые процедуры'
    elif 'tables' in normalized or 'table' in normalized:
        return 'table', '📊', 'Таблицы данных'
    elif 'triggers' in normalized or 'trigger' in normalized:
        return 'trigger', '🪤', 'Триггеры'
    elif 'views' in normalized or 'view' in normalized:
        return 'view', '👁️', 'Представления (Views)'
    else:
        return 'sql_script', '📝', 'Прочие скрипты'

def generate_entity_md(name, header_info, tables, entity_type):
    """Оставляем генерацию MD для локальной папки wiki/"""
    if tables:
        relations_md = "\n".join([f"* **Связан с сущностью:** `[[{t}]]`" for t in tables])
    else:
        relations_md = "*Связи не найдены*"
        
    type_labels_ru = {
        'stored_procedure': 'Хранимая процедура',
        'table': 'Таблица данных',
        'trigger': 'Триггер',
        'view': 'Представления (Views)',
        'sql_script': 'Скрипт'
    }
    current_type_ru = type_labels_ru.get(entity_type, 'Объект БД')
        
    parts = [
        "---",
        f"type: {entity_type}",
        "db_version: MS SQL Server 2019",
        "dialect: T-SQL",
        "---",
        "",
        f"# {get_entity_icon(entity_type)} dbo.{name} ({current_type_ru})",
        "",
        "## 📄 Метаданные и Описание",
        "```text",
        f"{header_info}",
        "```",
        "",
        "## 🔗 Автоматически найденные связи",
        f"{relations_md}"
    ]
    return "\n".join(parts)

def generate_entity_html_for_google_doc(name, header_info, tables, entity_type):
    """Генерируем HTML для красивого отображения внутри Google Docs"""
    type_labels_ru = {
        'stored_procedure': 'Хранимая процедура',
        'table': 'Таблица данных',
        'trigger': 'Триггер',
        'view': 'Представления (Views)',
        'sql_script': 'Скрипт'
    }
    current_type_ru = type_labels_ru.get(entity_type, 'Объект БД')
    
    relations_html = ""
    if tables:
        relations_html = "<ul>" + "".join([f"<li><b>Связан с сущностью:</b> {t}</li>" for t in tables]) + "</ul>"
    else:
        relations_html = "<p><i>Связи не найдены</i></p>"

    html = f"""
    <html>
    <body>
      <h1>{get_entity_icon(entity_type)} dbo.{name} ({current_type_ru})</h1>
      <p><b>Диалект:</b> T-SQL (MS SQL Server 2019)</p>
      
      <h2>📄 Метаданные и Описание</h2>
      <pre style="background-color: #f4f4f4; padding: 10px; border: 1px solid #ddd;">{header_info}</pre>
      
      <h2>🔗 Автоматически найденные связи</h2>
      {relations_html}
    </body>
    </html>
    """
    return html

def update_db_map_md(db_name, entity_registry):
    """Карта для локального Obsidian"""
    map_path = f'./wiki/{db_name}/{db_name}.md'
    os.makedirs(os.path.dirname(map_path), exist_ok=True)
    
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
    return content

def generate_db_map_html(db_name, entity_registry):
    """HTML Карта для Google Docs"""
    categories = {
        'table': ('📊 Таблицы данных', []), 'stored_procedure': ('⚙️ Хранимые процедуры', []),
        'trigger': ('🪤 Триггеры', []), 'view': ('👁️ Представления (Views)', []), 'sql_script': ('📝 Прочие скрипты', [])
    }
    for name, info in entity_registry.items():
        ent_type = info['type']
        desc = info['desc']
        if ent_type in categories: categories[ent_type][1].append((name, desc))
            
    sections_html = ""
    for ent_type, (title, items) in categories.items():
        if items:
            sections_html += f"<h2>{title}</h2><ul>"
            for name, desc in sorted(items, key=lambda x: x[0]):
                sections_html += f"<li><b>{name}</b> — {desc}</li>"
            sections_html += "</ul>"
            
    html = f"""
    <html>
    <body>
      <h1>🗺️ Архитектурная карта базы данных {db_name}</h1>
      <p>Автоматическая структура всех зарегистрированных объектов.</p>
      {sections_html}
    </body>
    </html>
    """
    return html

def get_or_create_drive_folder(service, folder_name, parent_id):
    query = f"name = '{folder_name}' and '{parent_id}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    results = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
    items = results.get('files', [])
    if items: return items[0]['id']
        
    folder_metadata = {'name': folder_name, 'mimeType': 'application/vnd.google-apps.folder', 'parents': [parent_id]}
    folder = service.files().create(body=folder_metadata, fields='id', supportsAllDrives=True).execute()
    return folder['id']

def upload_to_google_doc(service, doc_name, html_content, target_folder_id):
    """Создает или обновляет именно GOOGLE DOCUMENT из HTML"""
    # Ищем существующий Google Doc с таким именем
    query = f"name = '{doc_name}' and '{target_folder_id}' in parents and mimeType = 'application/vnd.google-apps.document' and trashed = false"
    results = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
    items = results.get('files', [])

    file_stream = io.BytesIO(html_content.encode('utf-8'))
    # Отправляем как HTML, но просим Google конвертировать в Документ
    media = MediaIoBaseUpload(file_stream, mimetype='text/html', resumable=False)

    if items:
        file_id = items[0]['id']
        # При обновлении контента тип конвертации сохраняется
        service.files().update(fileId=file_id, media_body=media, supportsAllDrives=True).execute()
        print(f"🔄 Обновлен Google Doc: {doc_name}")
    else:
        file_metadata = {
            'name': doc_name, 
            'mimeType': 'application/vnd.google-apps.document', # 🔥 Магия здесь: преобразуем в Google Doc
            'parents': [target_folder_id]
        }
        service.files().create(body=file_metadata, media_body=media, fields="id", supportsAllDrives=True).execute()
        print(f"📥 Создан Google Doc: {doc_name}")

def get_entity_icon(entity_type):
    icons = {'stored_procedure': '⚙️', 'table': '📊', 'trigger': '🪤', 'view': '👁️', 'sql_script': '📝'}
    return icons.get(entity_type, '📦')

def main():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=['https://www.googleapis.com/auth/drive'])
    service = build('drive', 'v3', credentials=creds)
    
    db_registries = {db: {} for db in TARGET_DATABASES}
    
    for db_name in TARGET_DATABASES:
        base_db_path = os.path.normpath(f'./{db_name}')
        if not os.path.exists(base_db_path): continue
            
        for root, dirs, files in os.walk(base_db_path):
            if f"{os.sep}wiki{os.sep}" in root or root.endswith(f"{os.sep}wiki"): continue
                
            for file in files:
                if file.endswith('.sql'):
                    entity_name = file.replace('.sql', '')
                    
                    if entity_name in db_registries[db_name]: continue
                    
                    entity_type, icon, category_name = get_entity_type_info(root)
                    full_git_path = os.path.relpath(root, '.')
                    
                    # Локально для Obsidian по-прежнему делаем .md структуры
                    local_md_dir = os.path.normpath(os.path.join('wiki', full_git_path))
                    os.makedirs(local_md_dir, exist_ok=True)
                    
                    # В Облаке создаем структуру папок
                    current_drive_folder_id = GOOGLE_FOLDER_ID
                    folder_parts = full_git_path.split(os.sep)
                    for part in folder_parts:
                        current_drive_folder_id = get_or_create_drive_folder(service, part, current_drive_folder_id)
                    
                    # Чтение файла с подбором кодировок
                    file_full_path = os.path.join(root, file)
                    sql_content = None
                    for encoding_variant in ['utf-8', 'utf-16', 'windows-1251']:
                        try:
                            with open(file_full_path, 'r', encoding=encoding_variant) as f:
                                sql_content = f.read()
                            break
                        except (UnicodeDecodeError, re.error): continue
                    
                    if sql_content is None: continue
                    
                    header_info, tables, description = parse_sql_header_and_relations(sql_content)
                    
                    db_registries[db_name][entity_name] = {'type': entity_type, 'desc': description}
                    
                    # 1. Запись локального .md для Obsidian
                    md_content = generate_entity_md(entity_name, header_info, tables, entity_type)
                    with open(os.path.join(local_md_dir, f"{entity_name}.md"), 'w', encoding='utf-8') as md_f:
                        md_f.write(md_content)
                    
                    # 2. Отправка в Google Drive в виде GOOGLE DOC (передаем имя без расширений)
                    html_doc_content = generate_entity_html_for_google_doc(entity_name, header_info, tables, entity_type)
                    upload_to_google_doc(service, entity_name, html_doc_content, current_drive_folder_id)

        # Синхронизация карт
        if db_registries[db_name]:
            # Карта для локального Git
            update_db_map_md(db_name, db_registries[db_name])
            
            # Карта для Google Drive (как Google Doc)
            map_html = generate_db_map_html(db_name, db_registries[db_name])
            db_root_drive_id = get_or_create_drive_folder(service, db_name, GOOGLE_FOLDER_ID)
            upload_to_google_doc(service, db_name, map_html, db_root_drive_id)

if __name__ == '__main__':
    main()
