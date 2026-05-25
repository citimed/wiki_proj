---
type: sql_script
db_version: MS SQL Server 2019
dialect: T-SQL
---

# 📝 dbo.LINK_SALE_CREATE_CASH_MARKETING (Скрипт)

## 📄 Метаданные
```text
Name: PROCEDURE LINK_SALE_CREATE_CASH_MARKETING
Description: Процесс создания приходного кассового ордера из расходной накладной для списания маркетинга
Author: Lukin E.V.
Release: 20.03.2026
Changelog:
* 30.03.2026 Lukin E.V. - дата акта = дата накладной
* 01.05.2026 Lukin E.V. - добавлена проверка на роль пользователя ROLE_ID IN (1,7,25,30)
```

## 🔗 Связи
* **Связан с сущностью:** `[[AP_ROLE]]`
* **Связан с сущностью:** `[[DC]]`
* **Связан с сущностью:** `[[DOC_CASH]]`
* **Связан с сущностью:** `[[LINK_DOC]]`
* **Связан с сущностью:** `[[LINK_SALE_CREATE_CASH]]`
* **Связан с сущностью:** `[[SALE]]`
* **Связан с сущностью:** `[[USER_ROLE]]`