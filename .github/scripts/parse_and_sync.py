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
    results =
