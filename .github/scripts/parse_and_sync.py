import os
import re
import io
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

SERVICE_ACCOUNT_FILE = 'github_credentials.json' 
GOOGLE_FOLDER_ID = os.environ.get('GOOGLE_FOLDER_ID') 

# Список баз данных, которые мы ищем в корне репозитория
TARGET_DATABASES = ['MAIN_DB', 'AP_DB']

def parse_sql_header_and_relations(sql_text):
    header_match = re.search(r'-- ===+.*?-- ===+', sql_text, re.DOTALL)
    header_info = ""
    description = "Описание не указано"
    
    if header_match:
        raw_header = header_match.group(0)
        md_lines = []
        for line in raw_header.split('\n'):
            clean_line = re.sub(r'^--\s?', '', line).strip()
            if "=== " in line or "===" in clean_line:
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
    if tables:
        relations_md = "\n".join([f"* **Связан с сущностью:** `[[{t}]]`" for t in tables])
    else:
        relations_md = "*Связи не найдены*"
        
    entity_labels = {
        'stored_procedure': f"# ⚙️ `dbo.{name}` (Хранимая процедура)",
        'table': f"# 📊 `dbo.{name}` (Таблица)",
        'trigger': f"# 🪤 `dbo.{name}` (Триггер)",
        'view': f"# 👁️ `dbo.{name}` (Представление/View)",
        'sql_script': f"# 📝 `dbo.{name}` (Скрипт)"
    }
        
    parts = [
        "---",
        f"type: {entity_type}",
        "db_version: MS SQL Server 2019",
        "dialect: T-SQL",
        "---",
        "",
        entity_labels.get(entity_type, f"# `{name}`"),
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

def update_db_map(db_name, entity_registry):
    map_path = f'./wiki/{db_name}/{db_name}.md'
    os.makedirs(os.path.dirname(map_path), exist_ok=True)
    
    card_parts = [
        "---",
        "type: database_map",
        "---",
        f"# 🗺️ Архитектурная карта базы данных {db_name}",
        "",
        f"Здесь находится автоматическая структура всех объектов базы данных {db_name}.",
        ""
    ]
    
    categories = {
        'table': ('📊 Таблицы данных', []),
        'stored_procedure': ('⚙️ Хранимые процедуры', []),
        'trigger': ('🪤 Триггеры', []),
        'view': ('👁️ Представления (Views)', []),
        'sql_script': ('📝 Прочие скрипты', [])
    }
    
    for name, info in entity_registry.items():
        ent_type = info['type']
        desc = info['desc']
        if ent_type in categories:
            categories[ent_type][1].append((name, desc))
            
    for ent_type, (title, items) in categories.items():
        if items:
            card_parts.append(f"## {title}")
            for name, desc in sorted(items, key=lambda x: x[0]):
                card_parts.append(f"* **[[{name}]]** — {desc}")
            card_parts.append("")
            
    updated_content = "\n".join(card_parts)
    with open(map_path, 'w', encoding='utf-8') as f:
        f.write(updated_content)
        
    return updated_content

def get_or_create_drive_folder(service, folder_name, parent_id):
    query = f"name = '{folder_name}' and '{parent_id}' in parents and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    results = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
    items = results.get('files', [])
    if items:
        return items[0]['id']
        
    folder_metadata = {
        'name': folder_name,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parent_id]
    }
    folder = service.files().create(body=folder_metadata, fields='id', supportsAllDrives=True).execute()
    return folder['id']

def upload_to_drive(service, filename, content, target_folder_id):
    query = f"name = '{filename}' and '{target_folder_id}' in parents and trashed = false"
    results = service.files().list(q=query, fields="files(id)", supportsAllDrives=True, includeItemsFromAllDrives=True).execute()
    items = results.get('files', [])

    file_stream = io.BytesIO(content.encode('utf-8'))
    media = MediaIoBaseUpload(file_stream, mimetype='text/markdown', resumable=False)

    if items:
        file_id = items[0]['id']
        service.files().update(fileId=file_id, media_body=media, supportsAllDrives=True).execute()
        print(f"🔄 Обновлен в Drive: {filename}")
    else:
        file_metadata = {
            'name': filename, 
            'parents': [target_folder_id]
        }
        service.files().create(body=file_metadata, media_body=media, fields="id", supportsAllDrives=True).execute()
        print(f"📥 Создан в Drive: {filename}")

def main():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=['https://www.googleapis.com/auth/drive'])
    service = build('drive', 'v3', credentials=creds)
    
    print(f"🚀 Старт сканирования баз данных: {TARGET_DATABASES}")
    db_registries = {db: {} for db in TARGET_DATABASES}
    
    for db_name in TARGET_DATABASES:
        base_db_path = os.path.normpath(f'./{db_name}')
        print(f"🔍 Проверка директории для базы {db_name}: {base_db_path}")
        
        if not os.path.exists(base_db_path):
            print(f"⚠️ Папка {db_name} не найдена в корне репозитория. Пропускаем.")
            continue
            
        for root, dirs, files in os.walk(base_db_path):
            if f"{os.sep}wiki{os.sep}" in root or root.endswith(f"{os.sep}wiki"):
                continue
                
            for file in files:
                if file.endswith('.sql'):
                    entity_name = file.replace('.sql', '')
                    print(f"📄 Найдена SQL сущность: {db_name} -> {root} -> {file}")
                    
                    if entity_name in db_registries[db_name]:
                        continue
                    
                    entity_type, icon, category_name = get_entity_type_info(root)
                    full_git_path = os.path.relpath(root, '.')
                    
                    # Путь для Git: wiki/AP_DB/StoredProcedure или wiki/MAIN_DB/Tables
                    local_md_dir = os.path.normpath(os.path.join('wiki', full_git_path))
                    os.makedirs(local_md_dir, exist_ok=True)
                    
                    # Путь для Google Drive
                    current_drive_folder_id = GOOGLE_FOLDER_ID
                    folder_parts = full_git_path.split(os.sep)
                    for part in folder_parts:
                        current_drive_folder_id = get_or_create_drive_folder(service, part, current_drive_folder_id)
                    
                    # Безопасное чтение файла с поддержкой разных кодировок (UTF-8, UTF-16, ANSI)
                    file_full_path = os.path.join(root, file)
                    sql_content = None
                    
                    for encoding_variant in ['utf-8', 'utf-16', 'windows-1251']:
                        try:
                            with open(file_full_path, 'r', encoding=encoding_variant) as f:
                                sql_content = f.read()
                            print(f"   └─ Кодировка определена как: {encoding_variant}")
                            break
                        except (UnicodeDecodeError, re.error):
                            continue
                    
                    if sql_content is None:
                        print(f"❌ Ошибка: Не удалось прочитать файл {file_full_path}. Неизвестная кодировка. Пропускаем.")
                        continue
                    
                    header_info, tables, description = parse_sql_header_and_relations(sql_content)
                    
                    db_registries[db_name][entity_name] = {
                        'type': entity_type,
                        'desc': description
                    }
                    
                    md_content = generate_entity_md(entity_name, header_info, tables, entity_type)
                    
                    # Локальная запись
                    local_file_path = os.path.join(local_md_dir, f"{entity_name}.md")
                    with open(local_file_path, 'w', encoding='utf-8') as md_f:
                        md_f.write(md_content)
                    
                    # Отправка в Drive
                    upload_to_drive(service, f"{entity_name}.md", md_content, current_drive_folder_id)

        # Синхронизация карты базы данных
        if db_registries[db_name]:
            print(f"🗺️ Сборка карты для базы: {db_name} (Всего объектов: {len(db_registries[db_name])})")
            updated_map = update_db_map(db_name, db_registries[db_name])
            db_root_drive_id = get_or_create_drive_folder(service, db_name, GOOGLE_FOLDER_ID)
            upload_to_drive(service, f"{db_name}.md", updated_map, db_root_drive_id)
        else:
            print(f"ℹ️ Для базы {db_name} не найдено ни одного SQL файла. Карта не создана.")

if __name__ == '__main__':
    main()
