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
    """Парсит шапку процедуры по шаблону и автоматически вытягивает связи с таблицами"""
    header_match = re.search(r'-- ===+.*?-- ===+', sql_text, re.DOTALL)
    header_info = ""
    description = "Описание не указано"
    
    if header_match:
        raw_header = header_match.group(0)
        md_lines = []
        for line in raw_header.split('\n'):
            clean_line = re.sub(r'^--\s?', '', line).strip()
            if "===" in clean_line:
                continue
            md_lines.append(clean_line)
            if "Description:" in clean_line:
                description = clean_line.replace("Description:", "").strip()
                
        header_info = "\n".join(md_lines)
    
    # Поиск таблиц после операторов SQL и схемы dbo.
    sql_words = re.findall(r'(?:FROM|JOIN|INSERT\s+INTO|UPDATE)\s+([a-zA-Z0-9_.]+)', sql_text, re.IGNORECASE)
    dbo_entities = re.findall(r'(?:dbo)\.([a-zA-Z0-9_]+)', sql_text, re.IGNORECASE)
    
    all_entities = set()
    for entity in (sql_words + dbo_entities):
        clean_entity = entity.upper().replace('DBO.', '').strip()
        if clean_entity and not clean_entity.startswith('@') and clean_entity not in ['SELECT', 'WHERE', 'SET', 'VALUES']:
            all_entities.add(clean_entity)
            
    return header_info, sorted(list(all_entities)), description

def generate_proc_md(proc_name, header_info, tables):
    """Формирует текст .md файла для конкретной процедуры"""
    tables_md = "\n".join([f"* **Вызывает сущность:** `[[{t}]]`" for t in tables]) if tables else "*Связи не найдены*"
    return f"""---
type: stored_procedure
db_version: MS SQL Server 2019
dialect: T-SQL
---

# ⚙️ `dbo.{proc_name}`

## 📄 Метаданные и История изменений (Changelog)
```text
{header_info}
