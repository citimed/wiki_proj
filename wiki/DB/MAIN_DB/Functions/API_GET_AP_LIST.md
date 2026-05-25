---
type: sql_script
db_version: MS SQL Server 2019
dialect: T-SQL
---

# 📝 dbo.API_GET_AP_LIST (Скрипт)

## 📄 Метаданные
```text
Name: FUNCTION API_GET_AP_LIST
Description: Функция получения списка аптек для аггрегаторов
Author: Lukin E.V.
Release: 10.04.2024
Changelog:
* **17.04.2026** Lukin E.V. - добалвены поля rp_name, rp_address
* **28.10.2024** Lukin E.V. - исправлен запрос
* **05.09.2024** Lukin E.V. - добавлен параметр @serviceId - код внешнего сервиса.
```

## 🔗 Связи
* **Связан с сущностью:** `[[REMOTE_POINT]]`
* **Связан с сущностью:** `[[_LINK_SERVICES_TO_REMOTE_POINTS]]`
* **Связан с сущностью:** `[[_SERVICES]]`