import os
import re
import io
from google.oauth2.service_account import Credentials
from googleapiclient.discovery import build
from googleapiclient.http import MediaIoBaseUpload

SERVICE_ACCOUNT_FILE = 'github_credentials.json' 
GOOGLE_FOLDER_ID = os.environ.get('GOOGLE_FOLDER_ID') 
SQL_FOLDER_PATH = './MAIN_DB/StoredProcedure/' 
MAIN_DB_MAP_PATH = './MAIN_DB.md' 

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
        return None
        
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

def upload_to_drive(service, filename, content):
    # Ищем файл, указывая параметр supportsAllDrives для Общих дисков
    query = f"name = '{filename}' and '{GOOGLE_FOLDER_ID}' in parents and trashed = false"
    results = service.files().list(
        q=query, 
        fields="files(id)",
        supportsAllDrives=True,
        includeItemsFromAllDrives=True
    ).execute()
    items = results.get('files', [])

    file_stream = io.BytesIO(content.encode('utf-8'))
    media = MediaIoBaseUpload(file_stream, mimetype='text/markdown', resumable=False)

    if items:
        file_id = items[0]['id']
        service.files().update(
            fileId=file_id, 
            media_body=media,
            supportsAllDrives=True
        ).execute()
        print(f"🔄 Синхронизирован в облако: {filename}")
    else:
        file_metadata = {
            'name': filename, 
            'parents': [GOOGLE_FOLDER_ID]
        }
        # Создаем файл в Общем диске организации
        service.files().create(
            body=file_metadata, 
            media_body=media, 
            fields="id",
            supportsAllDrives=True
        ).execute()
        print(f"📥 Загружен новый в облако: {filename}")

def main():
    creds = Credentials.from_service_account_file(SERVICE_ACCOUNT_FILE, scopes=['https://www.googleapis.com/auth/drive'])
    service = build('drive', 'v3', credentials=creds)
    
    proc_list = []
    
    if os.path.exists(SQL_FOLDER_PATH):
        for root, dirs, files in os.walk(SQL_FOLDER_PATH):
            for file in files:
                if file.endswith('.sql'):
                    proc_name = file.replace('.sql', '')
                    with open(os.path.join(root, file), 'r', encoding='utf-8') as f:
                        sql_content = f.read()
                    
                    header_info, tables, description = parse_sql_header_and_relations(sql_content)
                    proc_list.append((proc_name, description))
                    
                    md_content = generate_proc_md(proc_name, header_info, tables)
                    
                    with open(os.path.join(root, f"{proc_name}.md"), 'w', encoding='utf-8') as md_f:
                        md_f.write(md_content)
                    
                    upload_to_drive(service, f"{proc_name}.md", md_content)

    updated_map_content = update_main_db_map(proc_list)
    if updated_map_content:
        upload_to_drive(service, "MAIN_DB.md", updated_map_content)

if __name__ == '__main__':
    main()
