import os
import re
import io
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

SERVICE_ACCOUNT_FILE = 'github_credentials.json' 
GOOGLE_FOLDER_ID = os.environ.get('GOOGLE_FOLDER_ID') 

# Базовые пути от корня репозитория
SQL_FOLDER_PATH = './MAIN_DB/StoredProcedure/' 
MAIN_DB_MAP_PATH = './wiki/MAIN_DB/MAIN_DB.md' # 🔥 Карта базы данных теперь тут

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

def generate_proc_md(proc_name, header_info, tables):
    if tables:
        tables_md = "\n".join([f"* **Вызывает сущность:** `[[{t}]]`" for t in tables])
    else:
        tables_md = "*Связи не найдены*"
        
    parts = [
        "---",
        "type: stored_procedure",
        "db_version: MS SQL Server 2019",
        "dialect: T-SQL",
        "---",
        "",
        f"# ⚙️ `dbo.{proc_name}`",
        "",
        "## 📄 Метаданные и История изменений (Changelog)",
        "```text",
        f"{header_info}",
        "```",
        "",
        "## 🔗 Автоматически найденные связи в коде",
        f"{tables_md}"
    ]
    return "\n".join(parts)

def update_main_db_map(proc_list):
    if not os.path.exists(MAIN_DB_MAP_PATH):
        os.makedirs(os.path.dirname(MAIN_DB_MAP_PATH), exist_ok=True)
        with open(MAIN_DB_MAP_PATH, 'w', encoding='utf-8') as f:
            f.write("---\ntype: database_map\n---\n\n")
        
    with open(MAIN_DB_MAP_PATH, 'r', encoding='utf-8') as f:
        content = f.read()
        
    lines_to_insert = [""]
    for proc_name, desc in sorted(proc_list):
        lines_to_insert.append(f"* **[[{proc_name}]]** — {desc}")
    lines_to_insert.append("")
    
    new_block = "\n".join(lines_to_insert)
    pattern = r'.*?'
    updated_content = re.sub(pattern, new_block, content, flags=re.DOTALL)
    
    with open(MAIN_DB_MAP_PATH, 'w', encoding='utf-8') as f:
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
    print(f"📁 Создана новая папка в облаке: {folder_name}")
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
    
    proc_dict = {}
    base_sql_path = os.path.normpath(SQL_FOLDER_PATH)
    
    if os.path.exists(base_sql_path):
        for root, dirs, files in os.walk(base_sql_path):
            for file in files:
                if file.endswith('.sql'):
                    proc_name = file.replace('.sql', '')
                    
                    if proc_name in proc_dict:
                        continue
                    
                    # 1. Вычисляем полный путь от корня репозитория (например, "MAIN_DB/StoredProcedure/Finance")
                    full_git_path = os.path.relpath(root, '.')
                    
                    # 2. Формируем локальный путь в wiki (добавляем 'wiki' в начало: "wiki/MAIN_DB/StoredProcedure/Finance")
                    local_md_dir = os.path.join('wiki', full_git_path)
                    os.makedirs(local_md_dir, exist_ok=True)
                    
                    # 3. Для Google Drive строим структуру папок начиная с названия БД ("MAIN_DB/StoredProcedure/Finance")
                    current_drive_folder_id = GOOGLE_FOLDER_ID
                    folder_parts = full_git_path.split(os.sep)
                    for part in folder_parts:
                        current_drive_folder_id = get_or_create_drive_folder(service, part, current_drive_folder_id)
                    
                    # Читаем SQL исходник
                    with open(os.path.join(root, file), 'r', encoding='utf-8') as f:
                        sql_content = f.read()
                    
                    header_info, tables, description = parse_sql_header_and_relations(sql_content)
                    proc_dict[proc_name] = description
                    
                    md_content = generate_proc_md(proc_name, header_info, tables)
                    
                    # Сохраняем локальный .md файл внутри каталога wiki/
                    with open(os.path.join(local_md_dir, f"{proc_name}.md"), 'w', encoding='utf-8') as md_f:
                        md_f.write(md_content)
                    
                    # Отправляем файл в Google Drive в чистую иерархию папок базы
                    upload_to_drive(service, f"{proc_name}.md", md_content, current_drive_folder_id)

    proc_list = list(proc_dict.items())
    updated_map_content = update_main_db_map(proc_list)
    if updated_map_content:
        # Для Google Drive карту MAIN_DB.md тоже нужно положить внутрь папки MAIN_DB
        # Сначала найдем или создадим папку MAIN_DB в корне Диска
        main_db_drive_id = get_or_create_drive_folder(service, "MAIN_DB", GOOGLE_FOLDER_ID)
        upload_to_drive(service, "MAIN_DB.md", updated_map_content, main_db_drive_id)

if __name__ == '__main__':
    main()
